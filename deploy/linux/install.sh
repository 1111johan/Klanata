#!/usr/bin/env bash
set -euo pipefail

archive_path="${1:-}"
service_template="${2:-$(dirname "$0")/klanata.service}"
install_root="${KLANATA_INSTALL_ROOT:-/opt/klanata}"
data_root="${KLANATA_DATA_ROOT:-/var/lib/klanata}"
service_name="${KLANATA_SERVICE_NAME:-klanata.service}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run install.sh as root." >&2
  exit 1
fi
if [[ -z "${archive_path}" || ! -f "${archive_path}" ]]; then
  echo "Usage: install.sh /path/to/klanata-linux-x64.tar.gz [service-template]" >&2
  exit 1
fi
if [[ ! -f "${service_template}" ]]; then
  echo "Service template was not found: ${service_template}" >&2
  exit 1
fi

if ! id klanata >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "${data_root}" --shell /usr/sbin/nologin klanata
fi

release_id="$(date -u +%Y%m%dT%H%M%SZ)"
release_root="${install_root}/releases/${release_id}"
mkdir -p "${release_root}" "${data_root}/data" "${data_root}/keys" "${data_root}/logs" "${data_root}/backups"
tar -xzf "${archive_path}" -C "${release_root}"

if [[ ! -x "${release_root}/Klanata.Api" ]]; then
  chmod 0755 "${release_root}/Klanata.Api"
fi
chown -R root:root "${release_root}"
chown -R klanata:klanata "${data_root}"
chmod 0750 "${data_root}" "${data_root}/data" "${data_root}/keys" "${data_root}/logs" "${data_root}/backups"

install -o root -g root -m 0644 "${service_template}" "/etc/systemd/system/${service_name}"
systemctl daemon-reload
systemctl stop "${service_name}" 2>/dev/null || true
ln -sfn "${release_root}" "${install_root}/current.next"
mv -Tf "${install_root}/current.next" "${install_root}/current"
systemctl enable --now "${service_name}"

ready=false
for _ in $(seq 1 75); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:4318/health/ready >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "${ready}" != true ]]; then
  systemctl status "${service_name}" --no-pager --full || true
  journalctl -u "${service_name}" -n 100 --no-pager || true
  echo "Klanata did not pass its readiness check." >&2
  exit 1
fi

echo "Klanata installed successfully from ${release_root}."
