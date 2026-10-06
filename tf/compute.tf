# The VPS. No IAM dynamic group / instance principal is created, so the instance has
# ZERO permissions against the OCI API (least privilege).

resource "oci_core_instance" "vps" {
  compartment_id      = local.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[local.oci.availability_domain_index].name
  display_name        = local.name_prefix
  shape               = local.instance.shape
  freeform_tags       = local.freeform_tags

  dynamic "shape_config" {
    for_each = local.is_flex ? [1] : []
    content {
      ocpus         = local.instance.ocpus
      memory_in_gbs = local.instance.memory_in_gbs
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    nsg_ids          = [oci_core_network_security_group.vps.id]
    hostname_label   = local.instance.hostname
    display_name     = "${local.name_prefix}-vnic"
    assign_public_ip = !local.network.reserved_public_ip # reserved IP is attached below instead
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = local.instance.boot_volume_size_in_gbs
    boot_volume_vpus_per_gb = 10 # "Balanced" - higher performance tiers are NOT free
  }

  metadata = {
    ssh_authorized_keys = join("\n", local.ssh_authorized_keys)
    user_data           = base64gzip(local.cloud_init)
    # Updatable in place; the VPS polls this and converges (see tf/vps/bin/vps-reconcile).
    vps_config = jsonencode(local.vps_config)
  }

  # IMDSv2 only (blocks SSRF-style access to the legacy metadata endpoint).
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  is_pv_encryption_in_transit_enabled = true

  agent_config {
    is_monitoring_disabled = false # free metrics in the console
    is_management_disabled = false

    # No remote command execution path via the OCI API.
    plugins_config {
      name          = "Compute Instance Run Command"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "DISABLED"
    }
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [
      # New monthly images must NOT rebuild the box - it patches itself in place.
      source_details[0].source_id,
      # Bootstrap-only. Rebuild explicitly with: terraform apply -replace=oci_core_instance.vps
      metadata["user_data"],
      metadata["ssh_authorized_keys"],
    ]

    precondition {
      condition     = contains(local.free_tier.allowed_shapes, local.instance.shape)
      error_message = "Shape ${local.instance.shape} is not permitted. Only ARM Ampere shapes (${join(", ", local.free_tier.allowed_shapes)}) are allowed."
    }
    precondition {
      condition = (
        local.instance.ocpus <= local.free_tier.a1_max_ocpus &&
        local.instance.memory_in_gbs <= local.free_tier.a1_max_memory_gbs
      )
      error_message = "A1 config (${local.instance.ocpus} OCPU, ${local.instance.memory_in_gbs} GB) exceeds conservative guardrails (max ${local.free_tier.a1_max_ocpus} OCPU / ${local.free_tier.a1_max_memory_gbs} GB)."
    }
    precondition {
      condition = (
        local.instance.boot_volume_size_in_gbs >= local.free_tier.min_boot_volume_gbs &&
        local.instance.boot_volume_size_in_gbs <= local.free_tier.max_block_gbs
      )
      error_message = "Boot volume must be between ${local.free_tier.min_boot_volume_gbs} and ${local.free_tier.max_block_gbs} GB to stay within conservative guardrails."
    }
    precondition {
      condition     = length(local.ssh_authorized_keys) > 0
      error_message = "No SSH public key found. Check ssh.public_key_paths in locals.tf (or fill the RM form)."
    }
    precondition {
      condition     = length(data.oci_core_images.ubuntu.images) > 0
      error_message = "No Ubuntu ${local.instance.ubuntu_version} Minimal image found for ${local.instance.shape} (regex ${local.image_name_regex})."
    }
  }
}

# -----------------------------------------------------------------------------
# Reserved public IP (stable WireGuard endpoint across rebuilds)
# -----------------------------------------------------------------------------
data "oci_core_vnic_attachments" "vps" {
  compartment_id = local.compartment_ocid
  instance_id    = oci_core_instance.vps.id
}

data "oci_core_private_ips" "vps" {
  vnic_id = data.oci_core_vnic_attachments.vps.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "vps" {
  count = local.network.reserved_public_ip ? 1 : 0

  compartment_id = local.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${local.name_prefix}-ip"
  private_ip_id  = data.oci_core_private_ips.vps.private_ips[0].id
  freeform_tags  = local.freeform_tags
}

locals {
  public_ip = local.network.reserved_public_ip ? oci_core_public_ip.vps[0].ip_address : oci_core_instance.vps.public_ip
}
