# L1-B2 in a participant account (roadmap v3 6.5 and 6.7), off until switched on, so
# adding this file changes nothing by itself:
#
#   data_bucket    this hospital's source data in its own S3 bucket, read by the
#                  client through an S3 gateway endpoint in this VPC only
#
# Raw data stays in this account; nothing here grants another account access to it.
# The Flower execution key is a Secrets Manager secret in this account
# (execution_key.tf): no KMS, as decided on 26 October 2026.

variable "data_bucket" {
  description = "B2: load the dataset from this account's S3 bucket instead of downloading it"
  type        = bool
  default     = false
}

variable "data_file" {
  description = "Object the client loads; must be the unchanged MedMNIST file (checked by MD5)"
  default     = "pathmnist.npz"
}

variable "fetch_image" {
  description = "One-shot copy from S3 into the task before the client starts"
  default     = "public.ecr.aws/aws-cli/aws-cli:2.31.0"
}

locals {
  task_role_name = element(split("/", module.base.task_role_arn), 1)
}

# -----------------------------
# Source data: participant-local S3
# -----------------------------
resource "aws_s3_bucket" "data" {
  count  = var.data_bucket ? 1 : 0
  bucket = "${var.stack}-data-${data.aws_caller_identity.this.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  count                   = var.data_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.data[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Gateway endpoints are free; the client's S3 traffic stays inside AWS.
resource "aws_vpc_endpoint" "s3" {
  count             = var.data_bucket ? 1 : 0
  vpc_id            = module.base.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [module.base.route_table_id]
  tags              = { Name = "${var.stack}-s3" }
}

# Objects can be read only through this VPC's endpoint, and only over TLS.
# Uploading from an admin's machine still works; downloading from there does not.
resource "aws_s3_bucket_policy" "data" {
  count  = var.data_bucket ? 1 : 0
  bucket = aws_s3_bucket.data[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ReadOnlyThroughThisVpc"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.data[0].arn}/*"
        Condition = { StringNotEquals = { "aws:SourceVpce" = aws_vpc_endpoint.s3[0].id } }
      },
      {
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.data[0].arn, "${aws_s3_bucket.data[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.data]
}

resource "aws_iam_role_policy" "data" {
  count = var.data_bucket ? 1 : 0
  name  = "read-own-data"
  role  = local.task_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.data[0].arn}/*"
    }]
  })
}

output "b2_data_upload" {
  description = "Command that puts the dataset into this hospital's bucket (B2 plan, step 2)"
  value       = var.data_bucket ? "aws s3 cp ${var.data_file} s3://${aws_s3_bucket.data[0].bucket}/${var.data_file} --profile ${var.profile}" : null
}
