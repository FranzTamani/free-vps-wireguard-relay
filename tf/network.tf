# VCN, Internet Gateway, route table, subnet - all Always Free (limit: 2 VCNs).

resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_ocid
  cidr_blocks    = [local.network.vcn_cidr]
  display_name   = "${local.name_prefix}-vcn"
  dns_label      = local.dns_label
  freeform_tags  = local.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-igw"
  enabled        = true
  freeform_tags  = local.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-public-rt"
  freeform_tags  = local.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

# Least privilege: strip the default security list (which allows SSH from anywhere).
# All traffic rules live on the instance's NSG instead.
resource "oci_core_default_security_list" "deny_all" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  compartment_id             = local.compartment_ocid
  display_name               = "${local.name_prefix}-default-deny-all"
  freeform_tags              = local.freeform_tags
}

resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.network.subnet_cidr
  display_name               = "${local.name_prefix}-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_default_security_list.deny_all.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.freeform_tags
}

# -----------------------------------------------------------------------------
# Network Security Group (attached to the instance VNIC)
# -----------------------------------------------------------------------------
locals {
  ip_protocols = { all = "all", icmp = "1", tcp = "6", udp = "17" }

  # Uniform shape for every rule: port = 0 / icmp_* = -1 mean "not applicable".
  nsg_ingress = merge(
    {
      for i, cidr in local.ssh.allowed_cidrs : "in-ssh-${i}" => {
        direction = "INGRESS", protocol = "tcp", port = 22, cidr = cidr, icmp_type = -1, icmp_code = -1
        description = "SSH"
      }
    },
    {
      "in-wireguard" = {
        direction = "INGRESS", protocol = "udp", port = local.wireguard.port, cidr = "0.0.0.0/0", icmp_type = -1, icmp_code = -1
        description = "WireGuard"
      }
      "in-icmp-pmtu" = {
        direction = "INGRESS", protocol = "icmp", port = 0, cidr = "0.0.0.0/0", icmp_type = 3, icmp_code = 4
        description = "ICMP fragmentation-needed (Path MTU discovery)"
      }
    },
    {
      for k, v in local.enabled_game_ports : "in-game-${k}" => {
        direction = "INGRESS", protocol = v.protocol, port = v.port, cidr = "0.0.0.0/0", icmp_type = -1, icmp_code = -1
        description = v.description
      }
    }
  )

  nsg_egress = local.network.restrict_egress ? {
    "out-http" = {
      direction = "EGRESS", protocol = "tcp", port = 80, cidr = "0.0.0.0/0", icmp_type = -1, icmp_code = -1
      description = "Package mirrors (HTTP)"
    }
    "out-https" = {
      direction = "EGRESS", protocol = "tcp", port = 443, cidr = "0.0.0.0/0", icmp_type = -1, icmp_code = -1
      description = "Package mirrors, Git, Oracle Cloud Agent (HTTPS)"
    }
    "out-instance-services" = {
      direction = "EGRESS", protocol = "all", port = 0, cidr = "169.254.0.0/16", icmp_type = -1, icmp_code = -1
      description = "OCI instance metadata, DNS and NTP"
    }
    "out-icmp-unreachable" = {
      direction = "EGRESS", protocol = "icmp", port = 0, cidr = "0.0.0.0/0", icmp_type = 3, icmp_code = -1
      description = "ICMP unreachable / fragmentation-needed (Path MTU discovery)"
    }
    } : {
    "out-all" = {
      direction = "EGRESS", protocol = "all", port = 0, cidr = "0.0.0.0/0", icmp_type = -1, icmp_code = -1
      description = "All outbound"
    }
  }

  nsg_rules = merge(local.nsg_ingress, local.nsg_egress)
}

resource "oci_core_network_security_group" "vps" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-nsg"
  freeform_tags  = local.freeform_tags
}

# All rules are stateful, so replies to inbound flows (WireGuard handshakes from home,
# player connections) are allowed back out even with restricted egress.
resource "oci_core_network_security_group_security_rule" "rules" {
  for_each = local.nsg_rules

  network_security_group_id = oci_core_network_security_group.vps.id
  direction                 = each.value.direction
  protocol                  = local.ip_protocols[each.value.protocol]
  description               = each.value.description
  stateless                 = false

  source           = each.value.direction == "INGRESS" ? each.value.cidr : null
  source_type      = each.value.direction == "INGRESS" ? "CIDR_BLOCK" : null
  destination      = each.value.direction == "EGRESS" ? each.value.cidr : null
  destination_type = each.value.direction == "EGRESS" ? "CIDR_BLOCK" : null

  dynamic "tcp_options" {
    for_each = each.value.protocol == "tcp" ? [each.value.port] : []
    content {
      destination_port_range {
        min = tcp_options.value
        max = tcp_options.value
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "udp" ? [each.value.port] : []
    content {
      destination_port_range {
        min = udp_options.value
        max = udp_options.value
      }
    }
  }

  dynamic "icmp_options" {
    for_each = each.value.protocol == "icmp" ? [each.value] : []
    content {
      type = icmp_options.value.icmp_type
      code = icmp_options.value.icmp_code >= 0 ? icmp_options.value.icmp_code : null
    }
  }
}
