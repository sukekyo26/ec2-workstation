# SessionManager のセッションログ用 CloudWatch Logs

resource "aws_cloudwatch_log_group" "session_logs" {
  name              = "/ssm/session-logs/${local.resource_prefix}"
  retention_in_days = 30
}
