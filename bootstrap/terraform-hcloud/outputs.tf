output "server_name" {
  value = hcloud_server.vps.name
}

output "server_ipv4" {
  value = hcloud_server.vps.ipv4_address
}

output "server_ipv6" {
  value = hcloud_server.vps.ipv6_address
}

output "volume_linux_device" {
  value = "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.data.id}"
}

output "volume_id" {
  value = hcloud_volume.data.id
}

output "data_mount_point" {
  value = "/srv/data"
}

output "firewall_name" {
  value = hcloud_firewall.vps.name
}

output "ssh_allowed_cidrs" {
  value = [var.allowed_ssh_cidr]
}

output "backup_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}

output "backup_bucket_endpoint" {
  value = "${var.location}.your-objectstorage.com"
}

output "location" {
  value = var.location
}
