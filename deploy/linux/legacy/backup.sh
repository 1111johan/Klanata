#!/usr/bin/env bash
set -euo pipefail

data_root="${KLANATA_AMAZON_DATA_ROOT:-/var/lib/klanata-amazon}"
config_root="${KLANATA_AMAZON_CONFIG_ROOT:-/etc/klanata}"
backup_root="${KLANATA_AMAZON_BACKUP_ROOT:-/var/backups/klanata-amazon}"
service_name="${KLANATA_AMAZON_SERVICE_NAME:-klanata-amazon.service}"
store_path="${data_root}/runtime/authorization-store.json"
store_key_path="${config_root}/workstation-store.key"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run backup.sh as root." >&2
  exit 1
fi
if [[ ! -d "${data_root}" || ! -d "${config_root}" ]]; then
  echo "Amazon workstation data or encrypted configuration was not found." >&2
  exit 1
fi
if [[ -L "${store_key_path}" || ! -f "${store_key_path}" ]]; then
  echo "The 32-byte workstation store key was not found: ${store_key_path}" >&2
  exit 1
fi
if [[ "$(stat -c '%s' "${store_key_path}")" -ne 32 ]]; then
  echo "The workstation store key has an invalid length: ${store_key_path}" >&2
  exit 1
fi
if [[ -e "${store_path}" && ( -L "${store_path}" || ! -f "${store_path}" ) ]]; then
  echo "The encrypted workstation store must be a regular file: ${store_path}" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="${backup_root}/${timestamp}"
mkdir -p "${destination}"
chmod 0700 "${backup_root}" "${destination}"

restart=false
expected_auth_count=0
if systemctl is-active --quiet "${service_name}"; then
  restart=true
  if expected_auth_count="$(
    curl --fail --silent --max-time 5 http://127.0.0.1:4319/api/workflow/current \
      | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("authSessions", [])))'
  )"; then
    :
  else
    expected_auth_count=0
  fi
  systemctl stop "${service_name}"
fi

restore_service() {
  if [[ "${restart}" == true ]]; then
    systemctl start "${service_name}"
    for _ in $(seq 1 90); do
      if curl --fail --silent --max-time 2 http://127.0.0.1:4319/api/workflow/current \
        | python3 -c 'import json,sys; expected=int(sys.argv[1]); raise SystemExit(0 if len(json.load(sys.stdin).get("authSessions", [])) >= expected else 1)' "${expected_auth_count}" \
        >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    echo "Amazon workstation did not recover its encrypted profiles after backup." >&2
    return 1
  fi
}
trap restore_service EXIT

tar -czf "${destination}/klanata-amazon-data.tar.gz" "${data_root}" "${config_root}"
tar -tzf "${destination}/klanata-amazon-data.tar.gz" "${store_key_path#/}" >/dev/null
if [[ -f "${store_path}" ]]; then
  tar -tzf "${destination}/klanata-amazon-data.tar.gz" "${store_path#/}" >/dev/null
fi
sha256sum "${destination}/klanata-amazon-data.tar.gz" > "${destination}/SHA256SUMS"
sha256sum --check "${destination}/SHA256SUMS"

trap - EXIT
restore_service
echo "Amazon workstation backup created at ${destination}."
