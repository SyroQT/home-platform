variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name of the VPS"
  type        = string
  default     = "k3s-prod"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx23"
}

variable "image" {
  description = "OS image"
  type        = string
  default     = "debian-12"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "nbg1"
}

variable "ssh_public_key_path" {
  description = "Path to your local SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to access SSH"
  type        = string
}

variable "volume_size_gb" {
  description = "Attached data volume size in GB"
  type        = number
  default     = 50
}
