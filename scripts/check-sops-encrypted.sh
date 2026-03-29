#!/usr/bin/env bash
set -euo pipefail

failed=0

for file in "$@"; do
  # A properly encrypted SOPS file must contain the ENC[ marker
  if ! grep -q 'ENC\[' "$file"; then
    echo "ERROR: $file appears to be unencrypted (no ENC[ marker found)"
    echo "       Encrypt it with: sops --encrypt --in-place $file"
    failed=1
  fi

  # Also verify the sops metadata block is present
  if ! grep -q 'sops:' "$file"; then
    echo "ERROR: $file is missing the 'sops:' metadata block"
    failed=1
  fi
done

exit $failed