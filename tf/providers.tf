terraform {
  # OCI Resource Manager supports Terraform 1.5.x - avoid features newer than that.
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.8"
    }
  }
}

# Locally: Terraform reads C:\Users\<Username>\.oci\config using the profile set in locals.tf.
# In OCI Resource Manager: auth + region are injected automatically, so no profile is used.
provider "oci" {
  config_file_profile = local.is_resource_manager ? null : local.oci.config_file_profile
  region              = local.region
}
