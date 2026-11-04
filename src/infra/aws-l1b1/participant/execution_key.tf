# Issue #7: this hospital's Flower execution key, kept in this hospital's own account.
#
# Terraform creates only the empty secret and lets this account's task execution role
# read it. The value (the 32-byte Ed25519 seed, hex) is put in by the hospital with the
# AWS CLI (README step 6), so it never appears in Terraform state.
#
# The public half is registered with the organisation's issuer (Hospital C's with
# Hospital A's issuer, as its sponsor) by src/tools/bootstrap_members.sh. ECS injects the
# value into the client container as EXECUTION_KEY_HEX. Until a value is set, the task
# cannot start, and a client without the key is refused by the Flower server anyway.

resource "aws_secretsmanager_secret" "execution_key" {
  name                    = "${var.stack}-flower-execution-key-${lower(var.hospital)}"
  description             = "Flower execution key (issue #7), Hospital ${local.hospital}"
  recovery_window_in_days = 0
}

resource "aws_iam_role_policy" "read_execution_key" {
  name       = "read-flower-execution-key"
  role       = "${var.stack}-execution" # created by modules/base
  depends_on = [module.base]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.execution_key.arn
    }]
  })
}

output "execution_key_secret" {
  description = "Put this hospital's execution key into this secret before starting the client."
  value       = aws_secretsmanager_secret.execution_key.name
}
