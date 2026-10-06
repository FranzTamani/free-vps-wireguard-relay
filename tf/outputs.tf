output "public_ip" {
  description = "VPS public IP (WireGuard endpoint and game server address for players)."
  value       = local.public_ip
}

output "reserved_public_ip" {
  description = "Reserved Public IP address allocated for the instance (safe for persistent DNS mapping)."
  value       = local.network.reserved_public_ip ? oci_core_public_ip.vps[0].ip_address : null
}

output "reserved_public_ip_id" {
  description = "OCID of the OCI Reserved Public IP entity."
  value       = local.network.reserved_public_ip ? oci_core_public_ip.vps[0].id : null
}

output "dns_a_record_target" {
  description = "The IPv4 address to use when creating DNS 'A' records (e.g., mc.example.com or pal.example.com)."
  value       = local.public_ip
}

output "instance_id" {
  description = "OCID of the compute instance."
  value       = oci_core_instance.vps.id
}

output "instance_private_ip" {
  description = "Private IP of the VPS within the OCI VCN subnet."
  value       = oci_core_instance.vps.private_ip
}

output "ssh_command" {
  value = "ssh ${local.instance.admin_user}@${local.public_ip}"
}

output "wireguard_server_public_key_command" {
  description = "The VPS WireGuard key is generated on the box (never in Terraform state). Fetch it with this."
  value       = "ssh ${local.instance.admin_user}@${local.public_ip} sudo cat /etc/wireguard/server.pub"
}

output "image" {
  value = data.oci_core_images.ubuntu.images[0].display_name
}

output "game_endpoints" {
  description = "Addresses players connect to."
  value       = { for k, v in local.enabled_game_ports : k => "${local.public_ip}:${v.port}/${v.protocol}" }
}

output "dns_records_guide" {
  description = "Quick copy-paste DNS records setup for your domain registrar (e.g. Cloudflare, Porkbun, Namecheap)."
  value       = <<-EOT
    Type: A
    Name: @ (or subdomain, e.g. 'play', 'mc', 'pal')
    Target / Value: ${local.public_ip}
    TTL: Auto / 300s
    Proxy Status: DNS Only (Grey Cloud - do NOT proxy UDP/Minecraft traffic through Cloudflare HTTP proxy!)
  EOT
}

output "home_wireguard_config" {
  description = "Template for the home game server's /etc/wireguard/wg0.conf."
  value       = <<-EOT
    [Interface]
    PrivateKey = <contents of home.key>
    Address    = ${local.wireguard.home_peer_address}/${split("/", local.wireguard.tunnel_cidr)[1]}
    MTU        = ${local.wireguard.mtu}
    %{~if local.wireguard.preserve_client_ip~}
    # preserve_client_ip = true: send replies to players back through the tunnel.
    Table      = 51820
    PostUp     = ip rule add from ${local.wireguard.home_peer_address} table 51820 priority 100
    PostDown   = ip rule del from ${local.wireguard.home_peer_address} table 51820 priority 100
    %{~endif~}

    [Peer]
    PublicKey           = <output of: wireguard_server_public_key_command>
    Endpoint            = ${local.public_ip}:${local.wireguard.port}
    AllowedIPs          = ${local.wireguard.preserve_client_ip ? "0.0.0.0/0" : "${local.wireguard.server_address}/32"}
    PersistentKeepalive = 25
  EOT
}

output "summary" {
  description = "Consolidated post-deployment summary and instructions."
  value       = <<-EOT
    =============================================================================
      DEPLOYMENT COMPLETE - ALWAYS FREE WIREGUARD GAME RELAY
    =============================================================================

    1. CONNECTION & SERVER DETAILS:
       - Reserved Public IP:    ${local.public_ip}
       - SSH Command:           ssh ${local.instance.admin_user}@${local.public_ip}
       - OS Image:              ${data.oci_core_images.ubuntu.images[0].display_name}

    2. DNS CONFIGURATION (Cloudflare / Namecheap / Porkbun):
       - Record Type:           A
       - Host / Name:           @ (or subdomain, e.g. 'play', 'mc', 'pal')
       - Target / Value:        ${local.public_ip}
       - Proxy Status:          DNS Only (Grey Cloud - do NOT proxy UDP/game traffic!)

    3. ACTIVE GAME ENDPOINTS (Share these with players):
       ${join("\n       ", [for k, v in local.enabled_game_ports : format("%-18s -> %s:%d/%s", k, local.public_ip, v.port, v.protocol)])}

    4. WIREGUARD SETUP (For your home server):
       a) Fetch VPS WireGuard Public Key:
          ssh ${local.instance.admin_user}@${local.public_ip} sudo cat /etc/wireguard/server.pub

       b) View ready-made /etc/wireguard/wg0.conf for home:
          terraform output -raw home_wireguard_config
    =============================================================================
  EOT
}


