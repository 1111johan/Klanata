#!/usr/bin/env bash
set -euo pipefail

context_archive="${1:-}"
template_file="${2:-}"
service_template="${3:-$(dirname "$0")/klanata-amazon.service}"
credential_loader="${4:-$(dirname "$0")/load-credentials.py}"
install_root="${KLANATA_AMAZON_INSTALL_ROOT:-/opt/klanata-amazon}"
data_root="${KLANATA_AMAZON_DATA_ROOT:-/var/lib/klanata-amazon}"
service_name="${KLANATA_AMAZON_SERVICE_NAME:-klanata-amazon.service}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run install.sh as root." >&2
  exit 1
fi
if [[ -z "${context_archive}" || ! -f "${context_archive}" ]]; then
  echo "A Docker build-context archive is required." >&2
  exit 1
fi
if [[ -z "${template_file}" || ! -f "${template_file}" ]]; then
  echo "An Amazon inventory template file is required." >&2
  exit 1
fi
if [[ ! -f "${service_template}" ]]; then
  echo "Service template was not found: ${service_template}" >&2
  exit 1
fi
if [[ ! -f "${credential_loader}" ]]; then
  echo "Credential loader was not found: ${credential_loader}" >&2
  exit 1
fi
store_key_path="/etc/klanata/workstation-store.key"
if [[ -L "${store_key_path}" ]]; then
  echo "Refusing to use a symbolic link as the workstation store key: ${store_key_path}" >&2
  exit 1
fi
if [[ ! -e "${store_key_path}" ]]; then
  store_key_tmp="$(mktemp)"
  cleanup_store_key_tmp() {
    rm -f -- "${store_key_tmp}"
  }
  trap cleanup_store_key_tmp EXIT
  openssl rand -out "${store_key_tmp}" 32
  install -o root -g 10001 -m 0440 "${store_key_tmp}" "${store_key_path}"
  cleanup_store_key_tmp
  trap - EXIT
fi
if [[ ! -f "${store_key_path}" || "$(stat -c '%s' "${store_key_path}")" -ne 32 ]]; then
  echo "The workstation store key must be a regular 32-byte file: ${store_key_path}" >&2
  exit 1
fi
chown root:10001 "${store_key_path}"
chmod 0440 "${store_key_path}"

release_id="$(date -u +%Y%m%dT%H%M%SZ)"
build_root="${install_root}/builds/${release_id}"
mkdir -p "${build_root}" "${data_root}/runtime" "${data_root}/input"
tar -xzf "${context_archive}" -C "${build_root}"

if [[ ! -f "${build_root}/Dockerfile" || ! -f "${build_root}/server.ps1" || ! -f "${build_root}/pricing.ps1" || ! -d "${build_root}/public" ]]; then
  echo "The build context is incomplete." >&2
  exit 1
fi

template_destination="${data_root}/input/PriceAndQuantity-us.txt"
if [[ "$(readlink -f "${template_file}")" != "$(readlink -f "${template_destination}")" ]]; then
  install -o 10001 -g 10001 -m 0400 "${template_file}" "${template_destination}"
else
  chown 10001:10001 "${template_destination}"
  chmod 0400 "${template_destination}"
fi
chown -R 10001:10001 "${data_root}/runtime" "${data_root}/input"
chmod 0750 "${data_root}" "${data_root}/runtime" "${data_root}/input"

image_tag="klanata-amazon:${release_id}"
docker build --pull --tag "${image_tag}" "${build_root}"
docker tag "${image_tag}" klanata-amazon:current

install -o root -g root -m 0644 "${service_template}" "/etc/systemd/system/${service_name}"
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0750 "${credential_loader}" /usr/local/libexec/klanata-amazon-load-credentials.py
systemctl daemon-reload
systemctl enable "${service_name}"
systemctl restart "${service_name}"

ready=false
for _ in $(seq 1 90); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:4319/api/status >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "${ready}" != true ]]; then
  systemctl status "${service_name}" --no-pager --full || true
  docker logs --tail 100 klanata-amazon 2>/dev/null || true
  echo "The Amazon workstation did not pass its status check." >&2
  exit 1
fi

echo "Klanata Amazon workstation installed successfully as ${image_tag}."
