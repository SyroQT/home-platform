#!/usr/bin/env bash
set -euo pipefail

TF_DIR="bootstrap/terraform-hcloud"
OUT_FILE="bootstrap/ansible/inventories/prod/group_vars/vps/generated.yml"
PUBKEY_FILE="${PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
TF_JSON="/tmp/tf_outputs.json"

mkdir -p "$(dirname "$OUT_FILE")"

if [[ ! -f "$PUBKEY_FILE" ]]; then
  echo "Public key not found: $PUBKEY_FILE" >&2
  exit 1
fi

terraform -chdir="$TF_DIR" output -json > "$TF_JSON"

PUBKEY_CONTENT="$(<"$PUBKEY_FILE")"
PUBKEY_YAML="$(printf '%s' "$PUBKEY_CONTENT" | jq -R .)"

cat > "$OUT_FILE" <<EOF
---
ansible_host: $(jq -r '.server_ipv4.value' "$TF_JSON")

data_device: $(jq -r '.volume_linux_device.value' "$TF_JSON")
data_mount_point: $(jq -r '.data_mount_point.value' "$TF_JSON")

ssh_allowed_cidrs:
$(jq -r '.ssh_allowed_cidrs.value[] | "  - \(.)"' "$TF_JSON")

kube_api_allowed_cidrs:
$(jq -r 'if (.kube_api_allowed_cidrs.value | length) > 0 then .kube_api_allowed_cidrs.value[] | "  - \(.)" else "  []" end' "$TF_JSON")

ssh_public_keys:
  - $PUBKEY_YAML

backup_bucket_name: $(jq -r '.backup_bucket_name.value' "$TF_JSON")
backup_bucket_endpoint: $(jq -r '.backup_bucket_endpoint.value' "$TF_JSON")
backup_location: $(jq -r '.location.value' "$TF_JSON")
EOF

echo "Wrote $OUT_FILE"
