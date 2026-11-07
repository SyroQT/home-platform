#!/bin/bash
# Reboots if a package requested it or a newer kernel is installed than is running.
set -euo pipefail

running="/boot/vmlinuz-$(uname -r)"
newest="$(ls -1 /boot/vmlinuz-* | sort -V | tail -n 1)"

if [[ -e /run/reboot-required ]]; then
  reason="/run/reboot-required is present"
elif [[ "$running" != "$newest" ]]; then
  reason="running ${running##*/}, newest installed ${newest##*/}"
else
  echo "No reboot required"
  exit 0
fi

echo "Rebooting: $reason"
systemctl --no-block reboot
