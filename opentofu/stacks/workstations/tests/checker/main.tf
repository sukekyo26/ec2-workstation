# boundary.tftest.hcl の決まり。モジュールのロールとポリシー (output iam) を、permissions boundary
# (cloudformation/permissions-boundary.yaml) と照らす。決まりごとに 1 つの output の precondition にし、
# 壊した入力がどの決まりで落ちるかを expect_failures で見分けられるようにする
# LIMIT: Action は文字のまま比べる (ワイルドカードを展開しない)。boundary の Allow の "ssm:*" は落ち、Deny の "ssm:*" は見落とす
variable "input" {
  description = "account_id, roles, role_policies, role_policy_attachments, keypair_parameter_name, config, boundary (Properties of the template), pipeline_template"
  type        = any
}

locals {
  in = var.input

  statements = flatten([
    for name, p in local.in.role_policies : [
      for st in jsondecode(p.policy).Statement : merge(st, { policy = name, role = p.role })
    ]
  ])
  module_allow = [for st in local.statements : st if st.Effect != "Deny"]
  # 文の Action・NotAction は、1 つなら文字列、複数なら配列
  module_allow_actions = toset(flatten([for st in local.module_allow : lookup(st, "Action", [])]))

  boundary_statements = local.in.boundary.PolicyDocument.Statement
  boundary_allow      = [for st in local.boundary_statements : st if st.Effect == "Allow"]
  boundary_deny       = [for st in local.boundary_statements : st if st.Effect == "Deny"]
  boundary_actions    = toset(flatten([for st in local.boundary_allow : lookup(st, "Action", [])]))
  boundary_sids       = [for st in local.boundary_statements : lookup(st, "Sid", "")]

  boundary_arn = "arn:aws:iam::${local.in.account_id}:policy/${local.in.config.permissions_boundary_name}"
  role_ids     = [for r in local.in.roles : r.id]

  # 秘密鍵の値を読む道: インスタンスのロールに付いた Deny の文
  keypair_actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
  instance_deny = [
    for st in local.statements : st
    if st.Effect == "Deny" && st.role == local.in.roles.instance.id && contains(keys(st), "Action")
  ]
  keypair_denied = anytrue([
    for st in local.instance_deny : (
      length(setsubtract(local.keypair_actions, flatten([st.Action]))) == 0 &&
      length(flatten([st.Resource])) == 1 &&
      can(regex("^arn:\\*:ssm:\\*:\\*:parameter(/.+/)\\*$", flatten([st.Resource])[0])) &&
      startswith(local.in.keypair_parameter_name, try(regex("^arn:\\*:ssm:\\*:\\*:parameter(/.+/)\\*$", flatten([st.Resource])[0])[0], "-"))
    )
  ])
  bypath_denied = anytrue([
    for st in local.instance_deny : contains(flatten([st.Action]), "ssm:GetParametersByPath") && flatten([st.Resource]) == ["*"]
  ])

  # boundary の名前: config、テンプレートの ManagedPolicyName、codepipeline.yaml の条件の ARN (全部の出現)
  name_prefix   = "${local.in.config.project_name}-${local.in.config.environment}-"
  template_name = replace(local.in.boundary.ManagedPolicyName["Fn::Sub"], "$${ProjectName}-$${Environment}-", local.name_prefix)
  pipeline_names = [
    for m in regexall(":policy/\\$\\{ProjectName\\}-\\$\\{Environment\\}-([A-Za-z0-9-]+)", local.in.pipeline_template) : "${local.name_prefix}${m[0]}"
  ]
}

output "input" {
  description = "The input as given, for the runs that break one part of it"
  value       = var.input
}

output "allow_statements_readable" {
  value = true
  precondition {
    condition     = alltrue([for st in local.module_allow : !contains(keys(st), "NotAction") && length(flatten([lookup(st, "Action", [])])) > 0])
    error_message = "A non-Deny statement has NotAction or no Action (write the allowed actions in actions): ${join(", ", distinct([for st in local.module_allow : st.policy if contains(keys(st), "NotAction") || length(flatten([lookup(st, "Action", [])])) == 0]))}"
  }
}

output "module_allow_not_empty" {
  value = true
  precondition {
    condition     = length(local.module_allow_actions) > 0
    error_message = "No Allow action found in the module policies."
  }
}

output "boundary_readable" {
  value = true
  precondition {
    condition     = length(local.boundary_actions) > 0 && alltrue([for st in local.boundary_allow : !contains(keys(st), "NotAction")])
    error_message = "The boundary has no Allow action, or an Allow statement with NotAction (list the actions in Action)."
  }
}

output "actions_in_boundary" {
  value = true
  precondition {
    condition     = length(setsubtract(local.module_allow_actions, local.boundary_actions)) == 0
    error_message = "Not in the Allow statements of cloudformation/permissions-boundary.yaml: ${join(", ", sort(setsubtract(local.module_allow_actions, local.boundary_actions)))}"
  }
}

output "not_denied_by_boundary" {
  value = true
  precondition {
    condition = alltrue([
      for st in local.boundary_deny : contains(keys(st), "NotAction")
      ? length(setsubtract(local.module_allow_actions, flatten([lookup(st, "NotAction", [])]))) == 0
      : length(setintersection(local.module_allow_actions, flatten([lookup(st, "Action", [])]))) == 0
    ])
    error_message = "A Deny statement of cloudformation/permissions-boundary.yaml denies an action that a module policy allows."
  }
}

output "roles_have_boundary" {
  value = true
  precondition {
    condition     = alltrue([for r in local.in.roles : r.permissions_boundary == local.boundary_arn])
    error_message = "Roles without the boundary ${local.boundary_arn}: ${join(", ", [for k, r in local.in.roles : k if r.permissions_boundary != local.boundary_arn])}"
  }
}

output "policies_on_listed_roles" {
  value = true
  precondition {
    condition     = alltrue([for p in merge(local.in.role_policies, local.in.role_policy_attachments) : contains(local.role_ids, p.role)])
    error_message = "A policy is attached to a role that is not in the iam output of the module (add the role to it)."
  }
}

output "roles_without_inline" {
  value = true
  precondition {
    condition     = alltrue([for r in local.in.roles : length(coalesce(r.inline_policy, [])) == 0])
    error_message = "A role has inline_policy (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)."
  }
}

output "managed_policies_in_boundary" {
  value = true
  precondition {
    condition = alltrue([
      for a in local.in.role_policy_attachments :
      can(regex("^arn:aws:iam::aws:policy/[A-Za-z0-9]+$", a.policy_arn)) && contains(local.boundary_sids, element(split("/", a.policy_arn), 1))
    ])
    error_message = "A managed policy is not \"arn:aws:iam::aws:policy/<name>\", or has no statement with Sid: <name> in cloudformation/permissions-boundary.yaml."
  }
}

output "keypair_deny" {
  value = true
  precondition {
    condition     = local.keypair_denied && local.bypath_denied
    error_message = "The instance role lacks a Deny of ${join(", ", local.keypair_actions)} on arn:*:ssm:*:*:parameter<prefix of ${local.in.keypair_parameter_name}>*, or a Deny of ssm:GetParametersByPath on *."
  }
}

output "boundary_names_match" {
  value = true
  precondition {
    condition     = length(local.pipeline_names) > 0 && alltrue([for n in concat([local.template_name], local.pipeline_names) : n == local.in.config.permissions_boundary_name])
    error_message = "The permissions boundary names differ: config '${local.in.config.permissions_boundary_name}', cloudformation/permissions-boundary.yaml '${local.template_name}', cloudformation/codepipeline.yaml '${join(" ", distinct(local.pipeline_names))}'"
  }
}
