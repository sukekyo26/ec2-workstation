# モジュールのロールとポリシーを、permissions boundary (cloudformation/permissions-boundary.yaml) と照らす。AWS には出ない。
# - モジュールは apply で走らせ、aws のリソースは全部 override_resource で置き換える (plan では、リソースに頼る
#   ポリシーの JSON が分からないため)。aws_iam_policy_document は本物の provider が作る
# - 決まりは tests/checker の output の precondition。本物を渡す run "check" と、1 か所だけ壊して落ちることを見る run を並べる
# LIMIT: モジュールの output iam に載せたロール・ポリシー・管理ポリシーだけを見る (aws_iam_* を足したら iam にも載せる。
# count で 0 になるものは、ここの変数で 0 なら見ない)。載せ忘れが起きたら、tofu show -json の plan の全部のリソースをなめる検査にする
# LIMIT: スタックがモジュールに渡す値 (permissions_boundary_name など) の配線は見ない。Resource の広さも見ない
#
#   tofu -chdir=opentofu/stacks/workstations init -backend=false && tofu -chdir=opentofu/stacks/workstations test

# AWS に出ない守りを 3 つ重ねる。利用者の認証があっても偽の鍵で署名し、要求は 127.0.0.1:1 の proxy で手元で落ちる。
# provider の no_proxy は、環境の NO_PROXY で proxy が外れないようにする (provider の値が環境より勝つ)
provider "aws" {
  region                      = "ap-northeast-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  http_proxy                  = "http://127.0.0.1:1"
  https_proxy                 = "http://127.0.0.1:1"
  no_proxy                    = "127.0.0.1"
  max_retries                 = 1
}

run "config" {
  module {
    source = "../../modules/config"
  }
}

run "workstation" {
  module {
    source = "../../modules/workstation"
  }

  variables {
    project_name              = "p"
    environment               = "dev"
    username                  = "u"
    vpc_id                    = "vpc-1"
    subnet_id                 = "subnet-1"
    os                        = "al2023"
    instance_type             = "t3.micro"
    availability_zone         = "ap-northeast-1a"
    root_volume_size          = 30
    root_volume_type          = "gp3"
    data_volume_size          = 30
    data_volume_type          = "gp3"
    enable_elastic_ip         = false
    cpu_threshold             = 5
    cpu_evaluation_periods    = 6
    scheduled_stop_hour       = 20
    scheduled_stop_minute     = 0
    permissions_boundary_name = run.config.permissions_boundary_name
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "ap-northeast-1" }
  }
  override_data {
    target = data.aws_ssm_parameter.ami
    values = { insecure_value = "ami-12345678" }
  }

  # ロールの id は name と同じ値にする (ポリシーは role に .id、管理ポリシーは .name を渡すので、どちらも id と比べられる)
  override_resource {
    target = aws_iam_role.instance
    values = { id = "p-dev-u-instance-role", arn = "arn:aws:iam::123456789012:role/p-dev-u-instance-role" }
  }
  override_resource {
    target = aws_iam_role.scheduler
    values = { id = "p-dev-u-scheduler-role", arn = "arn:aws:iam::123456789012:role/p-dev-u-scheduler-role" }
  }
  override_resource {
    target = aws_iam_role_policy_attachment.ssm_core
  }
  override_resource {
    target = aws_iam_role_policy.deny_keypair_read
  }
  override_resource {
    target = aws_iam_role_policy.scheduler_stop
  }
  override_resource {
    target = aws_iam_instance_profile.this
  }
  override_resource {
    target = aws_instance.this
  }
  override_resource {
    target = aws_key_pair.this
  }
  override_resource {
    target = aws_ssm_parameter.private_key
  }
  override_resource {
    target = aws_cloudwatch_metric_alarm.cpu_low
  }
  override_resource {
    target = aws_scheduler_schedule.daily_stop
  }
  override_resource {
    target = aws_ebs_volume.data
  }
  override_resource {
    target = aws_volume_attachment.data
  }
  override_resource {
    target = aws_security_group.this
  }
  override_resource {
    target = aws_vpc_security_group_egress_rule.https
  }
  override_resource {
    target = aws_vpc_security_group_egress_rule.http
  }
  override_resource {
    target = aws_vpc_security_group_egress_rule.dns
  }
}

run "network" {
  module {
    source = "../../modules/network"
  }

  variables {
    resource_prefix           = "p-dev"
    vpc_cidr                  = "10.0.0.0/16"
    vpc_name                  = "p-dev-vpc"
    public_subnet_name        = "p-dev-public"
    permissions_boundary_name = run.config.permissions_boundary_name
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["ap-northeast-1a"] }
  }

  override_resource {
    target = aws_iam_role.flow_logs
    values = { id = "p-dev-flow-log-role", arn = "arn:aws:iam::123456789012:role/p-dev-flow-log-role" }
  }
  override_resource {
    target = aws_cloudwatch_log_group.flow_logs
    values = { arn = "arn:aws:logs:ap-northeast-1:123456789012:log-group:/vpc/flow-logs/p-dev" }
  }
  override_resource {
    target = aws_iam_role_policy.flow_logs_write
  }
  override_resource {
    target = aws_vpc.this
  }
  override_resource {
    target = aws_subnet.public
  }
  override_resource {
    target = aws_internet_gateway.this
  }
  override_resource {
    target = aws_route_table.public
  }
  override_resource {
    target = aws_route_table_association.public
  }
  override_resource {
    target = aws_flow_log.this
  }
}

run "check" {
  module {
    source = "./tests/checker"
  }

  variables {
    input = {
      account_id              = "123456789012"
      roles                   = merge(run.workstation.iam.roles, run.network.iam.roles)
      role_policies           = merge(run.workstation.iam.role_policies, run.network.iam.role_policies)
      role_policy_attachments = merge(run.workstation.iam.role_policy_attachments, run.network.iam.role_policy_attachments)
      keypair_parameter_name  = run.workstation.iam.keypair_parameter_name
      config = {
        permissions_boundary_name = run.config.permissions_boundary_name
        project_name              = run.config.project_name
        environment               = run.config.environment
      }
      boundary          = yamldecode(file("../../../cloudformation/permissions-boundary.yaml")).Resources.PermissionsBoundary.Properties
      pipeline_template = file("../../../cloudformation/codepipeline.yaml")
    }
  }
}

# ここから下は、run "check" の入力を 1 か所だけ壊し、狙った決まりで落ちることを見る

run "allow_not_actions" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        scheduler_stop = { role = "p-dev-u-scheduler-role", policy = jsonencode({ Statement = [{ Effect = "Allow", NotAction = "iam:PassRole", Resource = "*" }] }) }
      })
    })
  }
  expect_failures = [output.allow_statements_readable]
}

run "allow_without_action" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        scheduler_stop = { role = "p-dev-u-scheduler-role", policy = jsonencode({ Statement = [{ Effect = "Allow", Action = [], Resource = "*" }] }) }
      })
    })
  }
  expect_failures = [output.allow_statements_readable]
}

run "no_allow" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = { deny_keypair_read = run.check.input.role_policies.deny_keypair_read }
    })
  }
  expect_failures = [output.module_allow_not_empty]
}

run "action_not_in_boundary" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        scheduler_stop = { role = "p-dev-u-scheduler-role", policy = jsonencode({ Statement = [{ Effect = "Allow", Action = ["ec2:StopInstances", "ec2:TerminateInstances"], Resource = "*" }] }) }
      })
    })
  }
  expect_failures = [output.actions_in_boundary]
}

# Deny の Action は、boundary に要る Action に数えない。NotResource の Allow も、Action で照らせる
run "deny_and_not_resource_pass" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        scheduler_stop = { role = "p-dev-u-scheduler-role", policy = jsonencode({ Statement = [
          { Effect = "Allow", Action = "ec2:StopInstances", NotResource = "arn:aws:ec2:*:*:instance/i-1" },
          { Effect = "Deny", Action = "ssm:DeleteParameter", Resource = "*" },
        ] }) }
      })
    })
  }
}

run "boundary_allow_not_action" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      boundary = merge(run.check.input.boundary, {
        PolicyDocument = { Statement = concat(run.check.input.boundary.PolicyDocument.Statement, [{ Effect = "Allow", NotAction = "iam:*", Resource = "*" }]) }
      })
    })
  }
  expect_failures = [output.boundary_readable]
}

run "boundary_without_allow" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      boundary = merge(run.check.input.boundary, { PolicyDocument = { Statement = [] } })
    })
  }
  expect_failures = [output.boundary_readable, output.actions_in_boundary, output.managed_policies_in_boundary]
}

run "boundary_deny_action" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      boundary = merge(run.check.input.boundary, {
        PolicyDocument = { Statement = concat(run.check.input.boundary.PolicyDocument.Statement, [{ Effect = "Deny", Action = ["ec2:StopInstances"], Resource = "*" }]) }
      })
    })
  }
  expect_failures = [output.not_denied_by_boundary]
}

run "boundary_deny_not_action" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      boundary = merge(run.check.input.boundary, {
        PolicyDocument = { Statement = concat(run.check.input.boundary.PolicyDocument.Statement, [{ Effect = "Deny", NotAction = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }]) }
      })
    })
  }
  expect_failures = [output.not_denied_by_boundary]
}

run "role_without_boundary" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      roles = merge(run.check.input.roles, { scheduler = merge(run.check.input.roles.scheduler, { permissions_boundary = null }) })
    })
  }
  expect_failures = [output.roles_have_boundary]
}

run "role_with_other_boundary" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      roles = merge(run.check.input.roles, { flow_logs = merge(run.check.input.roles.flow_logs, { permissions_boundary = "arn:aws:iam::123456789012:policy/other" }) })
    })
  }
  expect_failures = [output.roles_have_boundary]
}

run "policy_on_unlisted_role" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        scheduler_stop = merge(run.check.input.role_policies.scheduler_stop, { role = "p-dev-u-other-role" })
      })
    })
  }
  expect_failures = [output.policies_on_listed_roles]
}

run "role_with_inline_policy" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      roles = merge(run.check.input.roles, { instance = merge(run.check.input.roles.instance, { inline_policy = [{ name = "x", policy = "{}" }] }) })
    })
  }
  expect_failures = [output.roles_without_inline]
}

run "managed_policy_without_sid" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policy_attachments = { ssm_core = { role = "p-dev-u-instance-role", policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess" } }
    })
  }
  expect_failures = [output.managed_policies_in_boundary]
}

run "managed_policy_with_path" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policy_attachments = { ssm_core = { role = "p-dev-u-instance-role", policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSSMManagedInstanceCore" } }
    })
  }
  expect_failures = [output.managed_policies_in_boundary]
}

# インスタンスのロールの、秘密鍵 (/ec2/keypair/*) の値を読む道を拒む Deny

run "keypair_deny_removed" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = { for k, v in run.check.input.role_policies : k => v if k != "deny_keypair_read" }
    })
  }
  expect_failures = [output.keypair_deny]
}

run "keypair_deny_without_get_parameter" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        deny_keypair_read = { role = "p-dev-u-instance-role", policy = jsonencode({ Statement = [
          { Effect = "Deny", Action = ["ssm:GetParameters", "ssm:GetParameterHistory"], Resource = "arn:*:ssm:*:*:parameter/ec2/keypair/*" },
          { Effect = "Deny", Action = "ssm:GetParametersByPath", Resource = "*" },
        ] }) }
      })
    })
  }
  expect_failures = [output.keypair_deny]
}

# Allow にすると、Deny でなくなるうえ、boundary に無い Action を許すことになる
run "keypair_deny_to_allow" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        deny_keypair_read = { role = "p-dev-u-instance-role", policy = jsonencode({ Statement = [
          { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"], Resource = "arn:*:ssm:*:*:parameter/ec2/keypair/*" },
          { Effect = "Deny", Action = "ssm:GetParametersByPath", Resource = "*" },
        ] }) }
      })
    })
  }
  expect_failures = [output.keypair_deny, output.actions_in_boundary]
}

run "keypair_deny_on_other_role" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        deny_keypair_read = merge(run.check.input.role_policies.deny_keypair_read, { role = "p-dev-u-scheduler-role" })
      })
    })
  }
  expect_failures = [output.keypair_deny]
}

# Deny の ARN の頭と、パラメータの名前の頭がずれる
run "keypair_prefix_shifted" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, { keypair_parameter_name = "/ec2/keypairs/key-1" })
  }
  expect_failures = [output.keypair_deny]
}

# パスで引くと、IAM はパスの ARN で評価しうるので、keypair の ARN に絞った Deny では止まらない
run "keypair_bypath_narrowed" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      role_policies = merge(run.check.input.role_policies, {
        deny_keypair_read = { role = "p-dev-u-instance-role", policy = jsonencode({ Statement = [
          { Effect = "Deny", Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"], Resource = "arn:*:ssm:*:*:parameter/ec2/keypair/*" },
          { Effect = "Deny", Action = "ssm:GetParametersByPath", Resource = "arn:*:ssm:*:*:parameter/ec2/keypair/*" },
        ] }) }
      })
    })
  }
  expect_failures = [output.keypair_deny]
}

# boundary の名前は、3 か所のどれか 1 つがずれても落ちる

run "name_differs_in_config" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      config = merge(run.check.input.config, { permissions_boundary_name = "${run.check.input.config.permissions_boundary_name}2" })
    })
  }
  expect_failures = [output.boundary_names_match, output.roles_have_boundary]
}

run "name_differs_in_template" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      boundary = merge(run.check.input.boundary, { ManagedPolicyName = { "Fn::Sub" = "$${ProjectName}-$${Environment}-permissions-boundary2" } })
    })
  }
  expect_failures = [output.boundary_names_match]
}

run "name_differs_in_one_pipeline_arn" {
  command = plan
  module {
    source = "./tests/checker"
  }
  variables {
    input = merge(run.check.input, {
      pipeline_template = "${run.check.input.pipeline_template}\n# :policy/$${ProjectName}-$${Environment}-permissions-boundary2\n"
    })
  }
  expect_failures = [output.boundary_names_match]
}
