# 自動停止 (CDK: AutoStopConstruct と同等)
# - CPU 低使用率が続いた場合: CloudWatch Alarm + EC2 stop アクション
# - 毎日定時 (Asia/Tokyo): EventBridge Scheduler

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# ============================================================
# CPU 監視による自動停止
# ============================================================

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${local.resource_prefix}-cpu-low-alarm"
  alarm_description   = "Stop EC2 instance when CPU < ${var.cpu_threshold}% for ${var.cpu_evaluation_periods * 5} minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  threshold           = var.cpu_threshold
  evaluation_periods  = var.cpu_evaluation_periods
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.this.id
  }

  alarm_actions = ["arn:aws:automate:${data.aws_region.current.region}:ec2:stop"]

  tags = {
    Owner = var.username
  }
}

# ============================================================
# 定時停止 (EventBridge Scheduler)
# ============================================================

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.resource_prefix}-scheduler-role"
  description        = "IAM role for EventBridge Scheduler to stop EC2 instance for ${var.username}"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json

  tags = {
    Owner = var.username
  }
}

data "aws_iam_policy_document" "scheduler_stop" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.this.id}"]
  }
}

resource "aws_iam_role_policy" "scheduler_stop" {
  name   = "scheduler-stop"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_stop.json
}

resource "aws_scheduler_schedule" "daily_stop" {
  name                         = "${local.resource_prefix}-daily-stop"
  description                  = "Stop EC2 instance daily at ${var.scheduled_stop_hour}:${format("%02d", var.scheduled_stop_minute)} JST for ${var.username}"
  schedule_expression          = "cron(${var.scheduled_stop_minute} ${var.scheduled_stop_hour} * * ? *)"
  schedule_expression_timezone = "Asia/Tokyo"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.this.id]
    })
  }
}
