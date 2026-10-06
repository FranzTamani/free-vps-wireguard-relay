# -----------------------------------------------------------------------------
# Variables
# Locally: all variables are automatically auto-discovered from ~/.oci/config
# and ~/.ssh/id_ed25519.pub with ZERO manual configuration required.
# In OCI Resource Manager: RM populates tenancy_ocid, region, and compartment_ocid.
# -----------------------------------------------------------------------------

variable "tenancy_ocid" {
  description = "OCI Tenancy OCID. If empty, automatically detected from ~/.oci/config when running locally."
  type        = string
  default     = ""
}

variable "region" {
  description = "OCI Region. If empty, automatically detected from ~/.oci/config when running locally."
  type        = string
  default     = ""
}

variable "compartment_ocid" {
  description = "Compartment OCID. If empty, automatically defaults to tenancy root compartment."
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key string OR path to public key file. Defaults to ~/.ssh/id_ed25519.pub."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "budget_alert_email" {
  description = "Optional recipient email address for zero-spend budget alerts. Set in terraform.tfvars (uncommitted) or pass via -var."
  type        = string
  default     = ""
}

variable "home_peer_public_key" {
  description = "Optional WireGuard public key of the home server (from home.pub). Set in terraform.tfvars (uncommitted) or pass via -var."
  type        = string
  default     = ""
}

variable "anti_idle_enabled" {
  description = "Enable anti-idle keepalive background task to keep CPU and memory >20% to prevent instance reclamation on free tier (non-PAYG)."
  type        = bool
  default     = true
}

