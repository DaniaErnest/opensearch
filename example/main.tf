# provider "aws" {}

# data "aws_region" "current" {}

# data "http" "saml_metadata" {
#   count = var.enable_saml ? 1 : 0
#   url   = var.saml_metadata_url
# }

# provider "elasticsearch" {
#   url                   = "https://${var.cluster_name}.${var.cluster_domain}"
#   aws_region            = data.aws_region.current.name
#   elasticsearch_version = "OpenSearch_1.0"
#   healthcheck           = false
# }

# module "opensearch" {
#   source = "../"

#   cluster_name    = var.cluster_name
#   cluster_domain  = "infra-dev.codainfra-staging.com"
#   cluster_version = "1.0"

#   saml_entity_id        = var.saml_entity_id
#   saml_metadata_content = data.http.saml_metadata.*.body
#   saml_session_timeout  = 120

#   index_files          = fileset(path.module, "indices/*.{yml,yaml}")
#   index_template_files = fileset(path.module, "index-templates/*.{yml,yaml}")
#   ism_policy_files     = fileset(path.module, "ism-policies/*.{yml,yaml}")
#   role_files           = fileset(path.module, "roles/*.{yml,yaml}")
#   role_mapping_files   = fileset(path.module, "role-mappings/*.{yml,yaml}")
# }



provider "aws" {
  default_tags {
    tags = {
      ManagedBy = "Terraform"
    }
  }
  assume_role {
    session_name = "terraform"
    role_arn     = var.master_user_arn
  }
}

data "aws_region" "current" {}

# data "http" "saml_metadata" {
#   url = var.saml_metadata_url
# }

provider "elasticsearch" {
  url         = module.opensearch.cluster_endpoint
  aws_region  = data.aws_region.current.name
  healthcheck = false
}

module "opensearch" {
  source = "../"

  cluster_name    = var.cluster_name
  cluster_domain  = var.cluster_domain
  cluster_version = "1.2"

  # saml_entity_id        = var.saml_entity_id
  # saml_metadata_content = data.http.saml_metadata.body
  # saml_session_timeout  = 120

  index_files          = fileset(path.module, "indices/*.{yml,yaml}")
  index_template_files = fileset(path.module, "index-templates/*.{yml,yaml}")
  ism_policy_files     = fileset(path.module, "ism-policies/*.{yml,yaml}")
  role_files           = fileset(path.module, "roles/*.{yml,yaml}")
  role_mapping_files   = fileset(path.module, "role-mappings/*.{yml,yaml}")
}
