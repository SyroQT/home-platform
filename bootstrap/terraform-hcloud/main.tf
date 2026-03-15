provider "hcloud" {
  token = var.hcloud_token
}

locals {
  ssh_public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "hcloud_ssh_key" "default" {
  name       = "${var.server_name}-ssh-key"
  public_key = local.ssh_public_key
}

resource "hcloud_firewall" "vps" {
  name = "${var.server_name}-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.allowed_ssh_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "vps" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}

resource "hcloud_firewall_attachment" "vps" {
  firewall_id = hcloud_firewall.vps.id
  server_ids  = [hcloud_server.vps.id]
}

resource "hcloud_volume" "data" {
  name     = "${var.server_name}-data"
  size     = var.volume_size_gb
  location = var.location
  format   = "ext4"
}

resource "hcloud_volume_attachment" "data" {
  volume_id = hcloud_volume.data.id
  server_id = hcloud_server.vps.id
  automount = false
}