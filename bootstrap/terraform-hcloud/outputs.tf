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
  value = hcloud_volume.data.linux_device
}

output "firewall_name" {
  value = hcloud_firewall.vps.name
}
