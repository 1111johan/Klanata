#!/usr/bin/env bash
set -euo pipefail

data_root="${KLANATA_DATA_ROOT:-/var/lib/klanata}"
backup_root="${KLANATA_BACKUP_ROOT:-/var/backups/klanata}"
service_name="${KLANATA_SERVICE_NAME:-klanata.service}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run backup.sh as root." >&2
  exit 1
fi
if [[ ! -d "${data_root}" ]]; then
  echo "Data directory was not found: ${data_root}" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="${backup_root}/${timestamp}"
mkdir -p "${destination}"

restart=false
if systemctl is-active --quiet "${service_name}"; then
  restart=true
  systemctl stop "${service_name}"
fi

restore_service() {
  if [[ "${restart}" == true ]]; then
    systemctl start "${service_name}"
    for _ in $(seq 1 75); do
      if curl --fail --silent --max-time 2 http://127.0.0.1:4318/health/ready >/dev/null; then
        return 0
      fi
      sleep 1
    done
    echo "Klanata did not recover after the backup." >&2
    return 1
  fi
}
trap restore_service EXIT

tar -C "$(dirname "${data_root}")" -czf "${destination}/klanata-data.tar.gz" "$(basename "${data_root}")"
sha256sum "${destination}/klanata-data.tar.gz" > "${destination}/SHA256SUMS"
sha256sum --check "${destination}/SHA256SUMS"

trap - EXIT
restore_service
echo "Backup created at ${destination}."
