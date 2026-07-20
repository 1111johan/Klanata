#!/usr/bin/env bash
set -euo pipefail

source_file="${1:-}"
keep_source="${2:-}"
config_root="${KLANATA_AMAZON_CONFIG_ROOT:-/etc/klanata}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run provision-credentials.sh as root." >&2
  exit 1
fi
if [[ -z "${source_file}" || ! -f "${source_file}" ]]; then
  echo "Usage: provision-credentials.sh /path/to/amazon-profiles.json [--keep-source]" >&2
  exit 1
fi

python3 - "${source_file}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    profiles = json.load(handle)
if not isinstance(profiles, list) or not profiles:
    raise SystemExit("At least one authorization profile is required.")
required = {"clientId", "clientSecret", "refreshToken", "sellerId"}
for index, profile in enumerate(profiles, start=1):
    if not isinstance(profile, dict) or not required.issubset(profile):
        raise SystemExit(f"Authorization profile {index} is incomplete.")
    seller_id = str(profile["sellerId"]).strip().upper()
    if not re.fullmatch(r"A[A-Z0-9]{9,19}", seller_id):
        raise SystemExit(f"Authorization profile {index} has an invalid Seller ID.")
PY

umask 077
install -d -o root -g root -m 0700 "${config_root}"
if [[ ! -s "${config_root}/credential.key" ]]; then
  openssl rand -base64 48 > "${config_root}/credential.key"
fi
chmod 0400 "${config_root}/credential.key"

temporary_cipher="${config_root}/amazon-profiles.enc.tmp"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
  -pass "file:${config_root}/credential.key" \
  -in "${source_file}" \
  -out "${temporary_cipher}"
install -o root -g root -m 0400 "${temporary_cipher}" "${config_root}/amazon-profiles.enc"
rm -f "${temporary_cipher}"

if [[ "${keep_source}" != "--keep-source" ]]; then
  shred -u "${source_file}" 2>/dev/null || rm -f "${source_file}"
fi

echo "Encrypted Amazon authorization profiles were written to ${config_root}/amazon-profiles.enc."
