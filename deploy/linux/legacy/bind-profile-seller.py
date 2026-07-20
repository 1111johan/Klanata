#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


KEY_PATH = "/etc/klanata/credential.key"
PROFILES_PATH = "/etc/klanata/amazon-profiles.enc"


def openssl_arguments(*extra: str) -> list[str]:
    return [
        "/usr/bin/openssl",
        "enc",
        "-aes-256-cbc",
        "-pbkdf2",
        "-iter",
        "200000",
        "-pass",
        f"file:{KEY_PATH}",
        *extra,
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="Bind encrypted Amazon profiles to one verified Seller ID.")
    parser.add_argument("seller_id")
    args = parser.parse_args()
    seller_id = args.seller_id.strip().upper()
    if not re.fullmatch(r"A[A-Z0-9]{9,19}", seller_id):
        raise ValueError("Invalid Amazon Seller ID.")
    if os.geteuid() != 0:
        raise PermissionError("Run this migration as root.")

    decrypted = subprocess.run(
        openssl_arguments("-d", "-in", PROFILES_PATH),
        check=True,
        capture_output=True,
    ).stdout
    profiles = json.loads(decrypted)
    if not isinstance(profiles, list) or not profiles:
        raise ValueError("No Amazon authorization profiles were configured.")
    for profile in profiles:
        if not isinstance(profile, dict) or not all(profile.get(key) for key in ("clientId", "clientSecret", "refreshToken")):
            raise ValueError("An encrypted authorization profile is incomplete.")
        profile["sellerId"] = seller_id

    backup_suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = f"{PROFILES_PATH}.bak-{backup_suffix}"
    shutil.copy2(PROFILES_PATH, backup_path)
    os.chmod(backup_path, 0o600)

    encoded = json.dumps(profiles, separators=(",", ":")).encode("utf-8")
    directory = os.path.dirname(PROFILES_PATH)
    descriptor, temporary_path = tempfile.mkstemp(prefix=".amazon-profiles-", suffix=".enc", dir=directory)
    os.close(descriptor)
    try:
        subprocess.run(
            openssl_arguments("-salt", "-out", temporary_path),
            input=encoded,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, PROFILES_PATH)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)

    print(f"Bound {len(profiles)} encrypted authorization profiles to Seller {seller_id}.")
    print(f"Encrypted backup: {backup_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
