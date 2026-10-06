# Oracle Free VPS (Always Free WireGuard Game Relay)

Terraform stack designed for Oracle Cloud Infrastructure (OCI) **Always Free** tier to bypass ISP CGNAT for home-hosted game servers (Palworld, Minecraft, etc.) using WireGuard.

Compatible with both the **Local Terraform CLI** (zero-configuration auto-discovery) and **OCI Resource Manager**.

---

## Architecture Overview

```mermaid
flowchart TD
    subgraph Internet ["Public Internet"]
        Players["Players / Clients"]
    end

    subgraph OCI ["Oracle Cloud (Always Free Tier)"]
        subgraph VCN ["VCN (10.0.0.0/16) - Free"]
            subgraph Subnet ["Public Subnet (10.0.1.0/24)"]
                NSG["Network Security Group<br/>- SSH (Port 22)<br/>- WireGuard (Port 51820 UDP)<br/>- Game Ports (e.g. 25565, 8211)"]
                
                subgraph VPS ["Always Free A1 VPS (Ubuntu 24.04 LTS Minimal)"]
                    PublicIP["1x Reserved Public IPv4<br/>(play.yourdomain.com)"]
                    IPTables["iptables NAT & MSS Clamping<br/>(PREROUTING DNAT)"]
                    WGServer["WireGuard Server<br/>(10.66.66.1/24)"]
                    Hardening["Security Hardening<br/>- Key-only SSH (non-root)<br/>- Auto OS security updates<br/>- IMDSv2 enforced"]
                end
            end
        end
        Budget["Zero-Spend Budget Alert<br/>(Alerts at $0.01 actual spend)"]
    end

    subgraph Home ["Home Network (Behind ISP CGNAT)"]
        WGPilot["WireGuard Client (10.66.66.2)<br/>(Persistent outbound keepalive)"]
        GameServers["Game Server Daemons<br/>- Minecraft Java (:25565)<br/>- Palworld (:8211, :27015)"]
    end

    Players -->|"Game Traffic (play.yourdomain.com)"| PublicIP
    PublicIP --> NSG
    NSG --> IPTables
    IPTables -->|"DNAT forward"| WGServer
    WGServer <-->|"Encrypted WireGuard UDP :51820 Tunnel<br/>(Bypasses CGNAT)"| WGPilot
    WGPilot --> GameServers
```

---

## Features & Free Tier Guarantees

1. **Strict Always Free Guardrails (ARM A1 Only)**:
   - Restricted strictly to **Ampere ARM** (`VM.Standard.A1.Flex`) for maximum performance-per-dollar and dedicated network bandwidth (1 Gbps per OCPU).
   - Built-in Terraform `precondition` blocks enforce conservative caps (max **2 OCPUs**, **12 GB RAM**, and **100 GB storage**)—well below Oracle's official tenancy maximums (4 OCPU / 24 GB / 200 GB)—ensuring you stay completely safe even if Oracle decreases free tier limits or policy thresholds in the future.
   - Includes **1 OCI Reserved Public IP** (1 free per region) ensuring your public IP never changes across instance redeployments, so your DNS `A` records never break.
2. **Single Source of Truth ([tf/locals.tf](tf/locals.tf))**:
   - Everything (OCI compartments, instance shape, game ports, SSH keys, WireGuard CIDRs, update schedule) is configured cleanly in one place.
3. **Dual Deployment Support**:
   - **Local CLI**: Automatically discovers tenancy OCID, region, and default SSH key from your local environment with **zero manual configuration**.
   - **OCI Resource Manager (ORM)**: Automatically detects ORM execution, skips local file reads, and renders a clean UI form using [tf/schema.yaml](tf/schema.yaml).
4. **Least Privilege & Security Hardening**:
   - Default VCN Security List stripped to `deny-all`; all rules managed in an instance-specific NSG in [tf/network.tf](tf/network.tf).
   - No IAM instance principal / dynamic group attached (zero cloud API permissions).
   - OCI IMDSv2 enforced (legacy metadata disabled).
   - Root SSH disabled (`PermitRootLogin no`, `PasswordAuthentication no`). Access only via `ubuntu` with your SSH key.
5. **Self-Updating & In-Place Reconcile**:
   - **OS Level**: `unattended-upgrades` patches security vulnerabilities and schedules a reboot at off-peak hours (default 04:00).
   - **Config Level**: Systemd timer on the VPS polls instance metadata every 5 minutes. Updating ports or settings in `locals.tf` applies changes in place without rebuilding the instance.
   - **Git Self-Update (Optional flag)**: Can pull versioned management script updates from Git with syntax checks, health checks, and automatic rollback.
6. **Zero-Dollar Budget Guard**:
   - Optional budget alert that triggers if actual spend hits **$0.01**. Pass your email directly to the CLI command or environment variable without committing it to Git.

---

## Prerequisites

Before deploying, ensure you have:

1. **Oracle Cloud Infrastructure (OCI) Account**:
   - Always Free or upgraded to **Pay-As-You-Go (PAYG)** (recommended for 24/7 uptime without idle reclamation).
2. **Pre-Authenticated Local OCI CLI Configuration**:
   - A valid configuration file at `~/.oci/config` (or `C:\Users\<Username>\.oci\config` on Windows) with an active API signing key.
3. **SSH Key Pair**:
   - An Ed25519 public key at `~/.ssh/id_ed25519.pub` (automatically picked up by default).
4. **Terraform CLI**:
   - Terraform **v1.5.0 or later** installed and available in your `PATH`.
5. **Home Server**:
   - Linux host running your game server(s) with `wireguard-tools` installed (`sudo apt install wireguard-tools`).

---

## Step-by-Step Deployment Commands

### Step 1: Open the Terraform Directory
```bash
cd tf
```

### Step 2: Initialize Terraform
Download the required Oracle Cloud Infrastructure provider:
```bash
terraform init
```

### Step 3: Review the Execution Plan
Generate and review the plan.

- **Option A (With zero-spend alert email passed via CLI)**:
  ```bash
  terraform plan -var="budget_alert_email=your-email@example.com"
  ```
- **Option B (Using environment variable so you don't type it each time)**:
  ```bash
  # PowerShell
  $env:TF_VAR_budget_alert_email="your-email@example.com"
  terraform plan

  # Bash / Linux / macOS
  export TF_VAR_budget_alert_email="your-email@example.com"
  terraform plan
  ```
- **Option C (Without budget alerts)**:
  ```bash
  terraform plan
  ```

Terraform will automatically read your `~/.oci/config` profile, detect your tenancy and region, find the latest Ubuntu 24.04 ARM image, and locate your `~/.ssh/id_ed25519.pub` file.

### Step 4: Apply the Infrastructure
Deploy the stack to Oracle Cloud:
```bash
terraform apply -var="budget_alert_email=your-email@example.com"
# Type 'yes' when prompted to confirm
```

Once deployment completes (~1–2 minutes), Terraform displays your outputs, including your reserved public IP, SSH command, and game endpoints.

---

## Post-Deployment Setup

### Step 5: Map Your DNS Record
Retrieve the allocated reserved public IP:
```bash
terraform output dns_a_record_target
```
In your DNS provider (Cloudflare, Porkbun, Namecheap, etc.):
- **Type**: `A`
- **Name**: `play` (or `@` for root domain)
- **Target / Value**: `<reserved_public_ip>`
- **Proxy Status**: **DNS Only (Grey Cloud)** — *Crucial: do not proxy game traffic through Cloudflare HTTP CDN proxies.*

---

### Step 6: Connect Your Home Game Server via WireGuard

1. **Generate a WireGuard key pair on your home server**:
   ```bash
   wg genkey | tee home.key | wg pubkey > home.pub
   ```
2. **Add the home public key to the VPS configuration**:
   Open [tf/locals.tf](tf/locals.tf) and paste the contents of `home.pub` into `wireguard.home_peer_public_key`:
   ```hcl
   wireguard = {
     ...
     home_peer_public_key = "PASTE_HOME_PUBLIC_KEY_HERE"
   }
   ```
   Apply the change (it updates in place on the running VPS within minutes without a rebuild):
   ```bash
   terraform apply -var="budget_alert_email=your-email@example.com"
   ```

3. **Fetch the VPS WireGuard public key**:
   ```bash
   terraform output wireguard_server_public_key_command
   # Run the command printed, for example:
   ssh ubuntu@<public_ip> sudo cat /etc/wireguard/server.pub
   ```

4. **Install the WireGuard configuration on your home server**:
   Print the pre-formatted client config:
   ```bash
   terraform output -raw home_wireguard_config
   ```
   Save the output to `/etc/wireguard/wg0.conf` on your home server, insert your `home.key` content into `PrivateKey`, insert the VPS public key into `PublicKey`, and start the tunnel:
   ```bash
   sudo systemctl enable --now wg-quick@wg0
   ```

5. **Verify Connection**:
   On your home server, check tunnel status:
   ```bash
   sudo wg show
   ping 10.66.66.1
   ```

Your home server is now connected over WireGuard. Any players connecting to your domain or VPS IP (e.g., `play.yourdomain.com:25565` or `:8211`) will be routed directly to your home server behind CGNAT!
