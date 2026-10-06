# =============================================================================
#  SINGLE SOURCE OF CONFIGURATION
#  Edit values here. Everything else in this stack is derived from these.
#
#  Changes to wireguard / game_ports / os_updates / self_update / instance.timezone
#  are pushed to the running VPS via instance metadata and applied in place
#  (within ~5 min) by the on-box `vps-reconcile` timer - no rebuild required.
# =============================================================================
locals {
  # ---------------------------------------------------------------------------
  # OCI account & placement
  # ---------------------------------------------------------------------------
  oci = {
    config_file_profile = "DEFAULT"

    # Optional overrides: if left empty, tenancy and region are automatically
    # discovered from ~/.oci/config (zero manual config needed!).
    tenancy_ocid = ""

    # Optional override: empty = tenancy root compartment.
    compartment_ocid = ""

    # A1 capacity differs per AD. If you hit "Out of host capacity", try 1 or 2
    # (single-AD regions only have index 0).
    availability_domain_index = 0
  }

  name_prefix = "free-vps"

  freeform_tags = {
    project    = "free-vps-wireguard-relay"
    managed-by = "terraform"
  }

  # ---------------------------------------------------------------------------
  # Always Free guardrails - `terraform plan` FAILS if config exceeds these.
  # OCI limits the Always Free Ampere A1 compute allocation to a maximum of
  # 2 OCPUs and 12 GB of RAM (1,500 OCPU hours and 9,000 GB hours per month),
  # having halved these limits from the previous 4 OCPU / 24 GB allowance.
  # ---------------------------------------------------------------------------
  free_tier = {
    allowed_shapes      = ["VM.Standard.A1.Flex"] # Strictly ARM Ampere
    a1_max_ocpus        = 2   # Official OCI Always Free limit (1,500 OCPU-hrs/month)
    a1_max_memory_gbs   = 12  # Official OCI Always Free limit (9,000 GB-hrs/month)
    max_block_gbs       = 100 # Conservative block volume cap (limit is 200 GB)
    min_boot_volume_gbs = 47
  }

  # ---------------------------------------------------------------------------
  # Instance (1 OCPU, 6 GB RAM, 50 GB boot volume)
  # ---------------------------------------------------------------------------
  instance = {
    shape                   = "VM.Standard.A1.Flex" # ARM Ampere (1 Gbps per OCPU)
    ocpus                   = 1                     # 1 OCPU (1 Gbps bandwidth)
    memory_in_gbs           = 6                     # 6 GB RAM
    boot_volume_size_in_gbs = 50                    # 50 GB boot volume
    ubuntu_version          = "24.04"               # Minimal image (aarch64)
    hostname                = "free-vps"
    admin_user              = "ubuntu"              # Default non-root sudo user
    timezone                = "Australia/Sydney"
  }

  # ---------------------------------------------------------------------------
  # SSH (key-only, non-root sudo user)
  # ---------------------------------------------------------------------------
  ssh = {
    # Read at plan time from the machine running Terraform (missing files are skipped).
    public_key_paths = ["~/.ssh/id_ed25519.pub"]

    # Lock this down if you can. Your home IP is CGNAT/shared, so a /32 may change;
    # you can always SSH over the WireGuard tunnel instead (see README).
    allowed_cidrs = ["0.0.0.0/0"]
  }

  # ---------------------------------------------------------------------------
  # Network
  # ---------------------------------------------------------------------------
  network = {
    vcn_cidr    = "10.0.0.0/16"
    subnet_cidr = "10.0.1.0/24"

    # Reserved IP survives instance rebuilds, so your home WireGuard Endpoint never changes.
    # (Changing this flag after creation replaces the instance.)
    reserved_public_ip = true

    # true  = egress limited to HTTP/HTTPS + OCI instance services (DNS/NTP/metadata).
    # false = allow all outbound.
    restrict_egress = true
  }

  # ---------------------------------------------------------------------------
  # WireGuard (VPS = server, home game server = peer that dials out through CGNAT)
  # ---------------------------------------------------------------------------
  wireguard = {
    interface         = "wg0"
    port              = 51820
    tunnel_cidr       = "10.66.66.0/24"
    server_address    = "10.66.66.1"
    home_peer_address = "10.66.66.2"

    # WireGuard public key of your home game server (set in terraform.tfvars).
    # While empty, the tunnel is up but no game traffic is forwarded.
    home_peer_public_key = trimspace(var.home_peer_public_key)

    mtu = 1420

    # false = VPS SNATs forwarded traffic; home server sees all players as 10.66.66.1 (zero home config).
    # true  = real player IPs reach the home server; home MUST route replies back via wg0 (see README).
    preserve_client_ip = false
  }

  # ---------------------------------------------------------------------------
  # Game ports forwarded VPS -> WireGuard -> home peer (same port on both sides)
  # ---------------------------------------------------------------------------
  game_ports = {
    palworld_game     = { enabled = true, protocol = "udp", port = 8211, description = "Palworld game" }
    palworld_query    = { enabled = true, protocol = "udp", port = 27015, description = "Palworld Steam query (server browser)" }
    minecraft_java    = { enabled = true, protocol = "tcp", port = 25565, description = "Minecraft Java" }
    minecraft_bedrock = { enabled = false, protocol = "udp", port = 19132, description = "Minecraft Bedrock" }
  }

  # ---------------------------------------------------------------------------
  # Automatic OS updates (unattended-upgrades)
  # ---------------------------------------------------------------------------
  os_updates = {
    enabled              = true
    include_non_security = false   # true = also apply -updates pocket (less conservative)
    auto_reboot          = true    # reboot when a kernel/libc update requires it
    reboot_time          = "04:00" # local time (instance.timezone)
  }

  # ---------------------------------------------------------------------------
  # Self-update of the VPS management scripts from Git (OPTIONAL)
  # Pulls `path` from `repo_url` at `ref`, applies it, health-checks, and rolls back
  # automatically on failure. Repo must be publicly readable (or add a deploy key).
  # ---------------------------------------------------------------------------
  self_update = {
    enabled  = false
    repo_url = "https://github.com/FranzTamani/free-vps-wireguard-relay.git"
    ref      = "main"            # branch or tag - pin to a tag (e.g. "v1.0.0") for stability
    path     = "tf/vps"          # directory inside the repo containing bin/ and systemd/
    schedule = "*-*-* 04:30:00"  # systemd OnCalendar (after the OS reboot window)
  }

  # ---------------------------------------------------------------------------
  # Cost guard: emails you if the tenancy spends ANY money. Leave email empty to skip.
  # (Budgets are free. Strongly recommended if you upgrade to Pay-As-You-Go.)
  # ---------------------------------------------------------------------------
  budget = {
    alert_email     = trimspace(var.budget_alert_email)
    monthly_amount  = 1    # in your account currency
    alert_threshold = 0.01 # absolute amount of ACTUAL spend that triggers the email
  }

  # ---------------------------------------------------------------------------
  # Anti-idle keepalive (prevent Oracle Always Free instance reclamation)
  # Free Tier (non-PAYG) instances are reclaimed by Oracle if CPU and Memory
  # utilization stay below 20% (95th percentile over 7 days).
  # This background service maintains steady ~25% CPU and memory at lowest priority (nice 19).
  # Pay-As-You-Go (PAYG) accounts are immune to reclamation; PAYG users can set
  # this to false.
  # ---------------------------------------------------------------------------
  anti_idle = {
    enabled           = var.anti_idle_enabled
    cpu_target_pct    = 25 # Target CPU utilization (percent across all cores)
    memory_target_pct = 25 # Target memory utilization (percent of total RAM)
  }
}
