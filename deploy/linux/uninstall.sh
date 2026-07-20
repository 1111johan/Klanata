#!/usr/bin/env bash
set -euo pipefail

install_root="${KLANATA_INSTALL_ROOT:-/opt/klanata}"
data_root="${KLANATA_DATA_ROOT:-/var/lib/klanata}"
service_name="${KLANATA_SERVICE_NAME:-klanata.service}"
purge_data="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run uninstall.sh as root." >&2
  exit 1
fi

systemctl disable --now "${service_name}" 2>/dev/null || true
rm -f "/etc/systemd/system/${service_name}"
systemctl daemon-reload
rm -rf "${install_root}"

if [[ "${purge_data}" == "--purge-data" ]]; then
  rm -rf "${data_root}"
  userdel klanata 2>/dev/null || true
fi

echo "Klanata was uninstalled. Data was preserved unless --purge-data was supplied."
