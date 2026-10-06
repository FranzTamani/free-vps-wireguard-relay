# Derived values - auto-detects from ~/.oci/config when run locally.
locals {
  # ---------------------------------------------------------------------------
  # Auto-detection from local ~/.oci/config (zero manual config required locally)
  # ---------------------------------------------------------------------------
  oci_config_path  = pathexpand("~/.oci/config")
  has_local_config = fileexists(local.oci_config_path)
  local_config_raw = local.has_local_config ? file(local.oci_config_path) : ""

  local_parsed_tenancy = local.has_local_config ? try(
    trimspace(regex("(?m)^[ \t]*tenancy[ \t]*=[ \t]*(.+)$", local.local_config_raw)[0]),
    ""
  ) : ""

  local_parsed_region = local.has_local_config ? try(
    trimspace(regex("(?m)^[ \t]*region[ \t]*=[ \t]*(.+)$", local.local_config_raw)[0]),
    ""
  ) : ""

  # Resource Manager executes in a container without ~/.oci/config
  is_resource_manager = var.tenancy_ocid != "" && !local.has_local_config

  tenancy_ocid = (
    var.tenancy_ocid != "" ? var.tenancy_ocid : (
      local.oci.tenancy_ocid != "" ? local.oci.tenancy_ocid : local.local_parsed_tenancy
    )
  )

  region = (
    var.region != "" ? var.region : (
      local.local_parsed_region != "" ? local.local_parsed_region : null
    )
  )

  compartment_ocid = (
    var.compartment_ocid != "" ? var.compartment_ocid : (
      local.oci.compartment_ocid != "" ? local.oci.compartment_ocid : local.tenancy_ocid
    )
  )

  is_flex = endswith(local.instance.shape, ".Flex")
  is_arm  = startswith(local.instance.shape, "VM.Standard.A")

  image_name_regex = format(
    "^Canonical-Ubuntu-%s-Minimal-%s",
    replace(local.instance.ubuntu_version, ".", "\\."),
    local.is_arm ? "aarch64-" : "[0-9]"
  )

  # SSH keys: var.ssh_public_key (resolves file path like ~/.ssh/id_ed25519.pub OR literal key string)
  # + any additional key paths in locals.tf
  resolved_var_ssh_key = (
    trimspace(var.ssh_public_key) != "" ? (
      fileexists(pathexpand(trimspace(var.ssh_public_key))) ?
      trimspace(file(pathexpand(trimspace(var.ssh_public_key)))) :
      trimspace(var.ssh_public_key)
    ) : ""
  )

  ssh_keys_from_files = [
    for p in local.ssh.public_key_paths : trimspace(file(pathexpand(p)))
    if fileexists(pathexpand(p))
  ]
  ssh_authorized_keys = distinct(compact(concat([local.resolved_var_ssh_key], local.ssh_keys_from_files)))

  enabled_game_ports = { for k, v in local.game_ports : k => v if v.enabled }

  dns_label = substr(replace(lower(local.name_prefix), "/[^a-z0-9]/", ""), 0, 15)

  # Desired runtime state, delivered via instance metadata (updatable in place) and
  # consumed by tf/vps/bin/vps-reconcile. Bump schema_version on breaking changes.
  vps_config = {
    schema_version = 1
    admin_user     = local.instance.admin_user
    timezone       = local.instance.timezone
    wireguard      = local.wireguard
    forwards       = [for k, v in local.enabled_game_ports : { name = k, protocol = v.protocol, port = v.port }]
    os_updates     = local.os_updates
    self_update    = local.self_update
    anti_idle      = local.anti_idle
  }

  # Bootstrap copy of the on-box management scripts (CRLF-normalised for Windows checkouts).
  vps_files = {
    for f in fileset("${path.module}/vps", "**") :
    f => replace(file("${path.module}/vps/${f}"), "\r\n", "\n")
  }

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = local.vps_files
  })
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id   = local.compartment_ocid
  operating_system = "Canonical Ubuntu"
  shape            = local.instance.shape
  state            = "AVAILABLE"
  sort_by          = "TIMECREATED"
  sort_order       = "DESC"

  filter {
    name   = "display_name"
    values = [local.image_name_regex]
    regex  = true
  }
}
