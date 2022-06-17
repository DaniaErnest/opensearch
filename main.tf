# terraform {
#   required_providers {
#     elasticsearch = {
#       source = "phillbaker/elasticsearch"
#       version = "2.0.0-beta.4"
#     }
#   }
# }

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.65"
    }
    elasticsearch = {
      source  = "phillbaker/elasticsearch"
      version = ">= 2.0.0"
    }
  }
}

locals {
  indices = merge({
    for filename in var.index_files :
    replace(basename(filename), "/\\.(ya?ml|json)$/", "") =>
    length(regexall("\\.ya?ml$", filename)) > 0 ? yamldecode(file(filename)) : jsondecode(file(filename))
  }, var.indices)

  index_templates = merge({
    for filename in var.index_template_files :
    replace(basename(filename), "/\\.(ya?ml|json)$/", "") =>
    length(regexall("\\.ya?ml$", filename)) > 0 ? yamldecode(file(filename)) : jsondecode(file(filename))
  }, var.index_templates)

  ism_policies = merge({
    for filename in var.ism_policy_files :
    replace(basename(filename), "/\\.(ya?ml|json)$/", "") =>
    length(regexall("\\.ya?ml$", filename)) > 0 ? yamldecode(file(filename)) : jsondecode(file(filename))
  }, var.ism_policies)

  roles = merge({
    for filename in var.role_files :
    replace(basename(filename), "/\\.(ya?ml|json)$/", "") =>
    length(regexall("\\.ya?ml$", filename)) > 0 ? yamldecode(file(filename)) : jsondecode(file(filename))
  }, var.roles)

  role_mappings = merge({
    for filename in var.role_mapping_files :
    replace(basename(filename), "/\\.(ya?ml|json)$/", "") =>
    length(regexall("\\.ya?ml$", filename)) > 0 ? yamldecode(file(filename)) : jsondecode(file(filename))
  }, var.role_mappings)
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "opensearch" {
  name = var.cluster_domain
}

data "aws_iam_policy_document" "access_policy" {
  statement {
    actions   = ["es:*"]
    resources = ["arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${var.cluster_name}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "elasticsearch_index_template" "index_template" {
  for_each = local.index_templates

  name = each.key
  body = jsonencode(each.value)

  depends_on = [elasticsearch_opensearch_roles_mapping.master_user_arn]
}

resource "elasticsearch_index" "index" {
  for_each = local.indices

  name               = each.key
  number_of_shards   = try(each.value.number_of_shards, "")
  number_of_replicas = try(each.value.number_of_replicas, "")
  refresh_interval   = try(each.value.refresh_interval, "")
  mappings           = jsonencode(try(each.value.mappings, {}))
  aliases            = jsonencode(try(each.value.aliases, {}))
  force_destroy      = true

  depends_on = [
    elasticsearch_index_template.index_template,
    elasticsearch_opensearch_ism_policy.ism_policy,
  ]

  lifecycle {
    ignore_changes = [
      number_of_shards,
      number_of_replicas,
      refresh_interval,
    ]
  }
}

resource "elasticsearch_opensearch_ism_policy" "ism_policy" {
  for_each = local.ism_policies

  policy_id = each.key
  body      = jsonencode({ "policy" = each.value })

  depends_on = [elasticsearch_opensearch_roles_mapping.master_user_arn]
}

resource "aws_iam_service_linked_role" "es" {
  count            = var.create_service_role ? 1 : 0
  aws_service_name = "es.amazonaws.com"
}

resource "aws_elasticsearch_domain" "opensearch" {
  domain_name           = var.cluster_name
  elasticsearch_version = "OpenSearch_${var.cluster_version}"
  access_policies       = data.aws_iam_policy_document.access_policy.json

  cluster_config {
    dedicated_master_enabled = var.master_instance_enabled
    dedicated_master_count   = var.master_instance_enabled ? var.master_instance_count : null
    dedicated_master_type    = var.master_instance_enabled ? var.master_instance_type : null

    instance_count = var.hot_instance_count
    instance_type  = var.hot_instance_type

    warm_enabled = var.warm_instance_enabled
    warm_count   = var.warm_instance_enabled ? var.warm_instance_count : null
    warm_type    = var.warm_instance_enabled ? var.warm_instance_type : null

    zone_awareness_enabled = (var.availability_zones > 1) ? true : false

    dynamic "zone_awareness_config" {
      for_each = (var.availability_zones > 1) ? [var.availability_zones] : []
      content {
        availability_zone_count = zone_awareness_config.value
      }
    }
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false

    master_user_options {
      master_user_arn = (var.master_user_arn != "") ? var.master_user_arn : data.aws_caller_identity.current.arn
    }
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"

    custom_endpoint_enabled         = true
    custom_endpoint                 = "${var.cluster_name}.${data.aws_route53_zone.opensearch.name}"
    custom_endpoint_certificate_arn = var.acm_certificate_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.encrypt_kms_key_id
  }

  tags = var.tags

  depends_on = [aws_iam_service_linked_role.es]
}

# resource "aws_elasticsearch_domain_saml_options" "opensearch" {
#   domain_name = aws_elasticsearch_domain.opensearch.domain_name

#   saml_options {
#     enabled                 = true
#     subject_key             = var.saml_subject_key
#     roles_key               = var.saml_roles_key
#     session_timeout_minutes = var.saml_session_timeout
#     master_user_name        = var.saml_master_user_name
#     master_backend_role     = var.saml_master_backend_role

#     idp {
#       entity_id        = var.saml_entity_id
#       metadata_content = sensitive(replace(var.saml_metadata_content, "\ufeff", ""))
#     }
#   }
# }

resource "aws_route53_record" "opensearch" {
  zone_id = data.aws_route53_zone.opensearch.id
  name    = var.cluster_name
  type    = "CNAME"
  ttl     = "60"

  records = [aws_elasticsearch_domain.opensearch.endpoint]
}



# resource "aws_elasticsearch_domain" "opensearch" {
#   domain_name           = var.cluster_name
#   elasticsearch_version = "OpenSearch_${var.cluster_version}"
#   access_policies       = data.aws_iam_policy_document.access_policy.json

#   cluster_config {
#     dedicated_master_enabled = var.master_instance_enabled
#     dedicated_master_count   = var.master_instance_enabled ? var.master_instance_count : null
#     dedicated_master_type    = var.master_instance_enabled ? var.master_instance_type : null

#     instance_count = var.hot_instance_count
#     instance_type  = var.hot_instance_type

#     warm_enabled = var.warm_instance_enabled
#     warm_count   = var.warm_instance_enabled ? var.warm_instance_count : null
#     warm_type    = var.warm_instance_enabled ? var.warm_instance_type : null

#     zone_awareness_enabled = (var.availability_zones > 1) ? true : false

#     dynamic "zone_awareness_config" {
#       for_each = (var.availability_zones > 1) ? [var.availability_zones] : []
#       content {
#         availability_zone_count = zone_awareness_config.value
#       }
#     }
#   }

#   advanced_security_options {
#     enabled                        = true
#     internal_user_database_enabled = false

#     master_user_options {
#       master_user_arn = (var.master_user_arn != "") ? var.master_user_arn : data.aws_caller_identity.current.arn
#     }
#   }

#   domain_endpoint_options {
#     enforce_https       = true
#     tls_security_policy = "Policy-Min-TLS-1-2-2019-07"

#     custom_endpoint_enabled         = var.enable_custom_endpoint
#     custom_endpoint                 = var.enable_custom_endpoint ? "${var.cluster_name}.${data.aws_route53_zone.opensearch.name}" : null
#     custom_endpoint_certificate_arn = var.enable_custom_endpoint ? var.acm_certificate_arn : null
#   }

#   node_to_node_encryption {
#     enabled = var.node_to_node_encryption
#   }

#   encrypt_at_rest {
#     enabled    = var.encrypt_at_rest
#     kms_key_id = var.encrypt_at_rest ? var.encrypt_kms_key_id : null
#   }

#   tags = var.tags

#   depends_on = [aws_iam_service_linked_role.es]
# }

# resource "elasticsearch_opensearch_roles_mapping" "role_mapping" {
#   for_each = {
#     for key, value in local.role_mappings :
#     key => value if !contains(["all_access", "security_manager"], key)
#   }

#   role_name     = each.key
#   description   = try(each.value.description, "")
#   backend_roles = try(each.value.backend_roles, [])
#   hosts         = try(each.value.hosts, [])
#   users         = try(each.value.users, [])

#   depends_on = [elasticsearch_opensearch_role.role]
# }

resource "elasticsearch_opensearch_roles_mapping" "master_user_arn" {
  for_each = {
    for key in ["all_access", "security_manager"] :
    key => try(local.role_mappings[key], {})
  }

  role_name     = each.key
  description   = try(each.value.description, "")
  backend_roles = concat(try(each.value.backend_roles, []), [var.master_user_arn])
  hosts         = try(each.value.hosts, [])
  users         = try(each.value.users, [])

  depends_on = [aws_route53_record.opensearch]
}

resource "elasticsearch_opensearch_role" "role" {
  for_each = local.roles

  role_name           = each.key
  description         = try(each.value.description, "")
  cluster_permissions = try(each.value.cluster_permissions, [])

  dynamic "index_permissions" {
    for_each = try([each.value.index_permissions], [])
    content {
      index_patterns          = try(index_permissions.value.index_patterns, [])
      allowed_actions         = try(index_permissions.value.allowed_actions, [])
      document_level_security = try(index_permissions.value.document_level_security, "")
    }
  }

  dynamic "tenant_permissions" {
    for_each = try([each.value.tenant_permissions], [])
    content {
      tenant_patterns = try(tenant_permissions.value.tenant_patterns, [])
      allowed_actions = try(tenant_permissions.value.allowed_actions, [])
    }
  }

  depends_on = [elasticsearch_opensearch_roles_mapping.master_user_arn]
}




# resource "elasticsearch_index" "index" {
#   for_each = local.indices
#   name               = each.key
#   number_of_shards   = try(each.value.number_of_shards, "")
#   number_of_replicas = try(each.value.number_of_replicas, "")
#   refresh_interval   = try(each.value.refresh_interval, "")
#   mappings           = jsonencode(try(each.value.mappings, {}))
#   aliases            = jsonencode(try(each.value.aliases, {}))
#   force_destroy      = true

#   depends_on = [
#     elasticsearch_index_template.index_template,
#     elasticsearch_opendistro_ism_policy.ism_policy,
#   ]

#   lifecycle {
#     ignore_changes = [
#       number_of_shards,
#       number_of_replicas,
#       refresh_interval,
#     ]
#   }
# }

# resource "elasticsearch_index_template" "index_template" {
#   for_each = local.index_templates

#   name = each.key
#   body = jsonencode(each.value)

#   depends_on = [elasticsearch_opendistro_roles_mapping.master_user_arn]
# }

# resource "aws_iam_service_linked_role" "es" {
#   count            = var.create_service_role ? 1 : 0
#   aws_service_name = "es.amazonaws.com"
# }

# resource "aws_elasticsearch_domain_saml_options" "opensearch" {
#   domain_name = aws_elasticsearch_domain.opensearch.domain_name

#   saml_options {
#     enabled                 = true
#     subject_key             = var.saml_subject_key
#     roles_key               = var.saml_roles_key
#     session_timeout_minutes = var.saml_session_timeout

#     idp {
#       entity_id        = var.saml_entity_id
#       metadata_content = sensitive(replace(var.saml_metadata_content, "\ufeff", ""))
#     }
#   }
# }

# resource "aws_route53_record" "opensearch" {
#   zone_id = data.aws_route53_zone.opensearch.id
#   name    = var.cluster_name
#   type    = "CNAME"
#   ttl     = "60"

#   records = [aws_elasticsearch_domain.opensearch.endpoint]
# }


# resource "elasticsearch_opendistro_roles_mapping" "role_mapping" {
#   for_each = {
#     for key, value in local.role_mappings :
#     key => value if !contains(["all_access", "security_manager"], key)
#   }

#   role_name     = each.key
#   description   = try(each.value.description, "")
#   backend_roles = try(each.value.backend_roles, [])
#   hosts         = try(each.value.hosts, [])
#   users         = try(each.value.users, [])

#   depends_on = [elasticsearch_opendistro_role.role]
# }

# resource "elasticsearch_opendistro_roles_mapping" "master_user_arn" {
#   for_each = {
#     for key in ["all_access", "security_manager"] :
#     key => try(local.role_mappings[key], {})
#   }

#   role_name     = each.key
#   description   = try(each.value.description, "")
#   backend_roles = concat(try(each.value.backend_roles, []), [var.master_user_arn])
#   hosts         = try(each.value.hosts, [])
#   users         = try(each.value.users, [])

#  depends_on = [aws_route53_record.opensearch]                                
# }

# resource "elasticsearch_opendistro_role" "role" {
#   for_each = local.roles

#   role_name           = each.key
#   description         = try(each.value.description, "")
#   cluster_permissions = try(each.value.cluster_permissions, [])

#   dynamic "index_permissions" {
#     for_each = try([each.value.index_permissions], [])
#     content {
#       index_patterns          = try(index_permissions.value.index_patterns, [])
#       allowed_actions         = try(index_permissions.value.allowed_actions, [])
#       document_level_security = try(index_permissions.value.document_level_security, "")
#     }
#   }

#   dynamic "tenant_permissions" {
#     for_each = try([each.value.tenant_permissions], [])
#     content {
#       tenant_patterns = try(tenant_permissions.value.tenant_patterns, [])
#       allowed_actions = try(tenant_permissions.value.allowed_actions, [])
#     }
#   }

#   depends_on = [elasticsearch_opendistro_roles_mapping.master_user_arn]
# }

# resource "elasticsearch_opendistro_ism_policy" "ism_policy" {
#   for_each = local.ism_policies

#   policy_id = each.key
#   body      = jsonencode({ "policy" = each.value })

#   depends_on = [elasticsearch_opendistro_roles_mapping.master_user_arn]
# }