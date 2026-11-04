# Issue #7: the token the hub must present on this server's /bind_envelope (the call that
# sets which execution keys admission trusts). Kept in this account's Secrets Manager.
#
# Terraform creates only the empty secret and lets this account's task execution role read
# it. The value is the governance host's flower-control.token, put in with the AWS CLI (README
# step 6), so it never appears in Terraform state.
#
# Until a value is set, the task cannot start; a server without the token refuses every binding.

resource "aws_secretsmanager_secret" "control_token" {
  name                    = "${var.stack}-flower-control-token"
  description             = "Token the hub presents on the Flower server's /bind_envelope (issue #7)"
  recovery_window_in_days = 0 # as the execution-key secrets: a rebuild can reuse the name at once
}

resource "aws_iam_role_policy" "read_control_token" {
  name       = "read-flower-control-token"
  role       = "${var.stack}-execution" # created by modules/base
  depends_on = [module.base]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.control_token.arn
    }]
  })
}

output "control_token_secret" {
  description = "Put the governance host's flower-control.token into this secret before starting the server."
  value       = aws_secretsmanager_secret.control_token.name
}
