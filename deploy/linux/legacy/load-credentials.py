#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


STATUS_URL = "http://127.0.0.1:4319/api/status"
AUTH_URL = "http://127.0.0.1:4319/api/auth/verify"
KEY_PATH = "/etc/klanata/credential.key"
PROFILES_PATH = "/etc/klanata/amazon-profiles.enc"
PRODUCTION_CONTEXT_PATH = "/etc/klanata/production-context.json"


def wait_for_service() -> None:
    for _ in range(90):
        try:
            with urllib.request.urlopen(STATUS_URL, timeout=2) as response:
                status = json.load(response)
            if status.get("ok"):
                return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(1)
    raise RuntimeError("Amazon workstation did not become ready.")


def decrypt_profiles() -> list[dict[str, str]]:
    result = subprocess.run(
        [
            "/usr/bin/openssl",
            "enc",
            "-d",
            "-aes-256-cbc",
            "-pbkdf2",
            "-iter",
            "200000",
            "-pass",
            f"file:{KEY_PATH}",
            "-in",
            PROFILES_PATH,
        ],
        check=True,
        capture_output=True,
    )
    value = json.loads(result.stdout)
    if not isinstance(value, list) or not value:
        raise ValueError("No Amazon authorization profiles were configured.")
    return value


def verify_profile(profile: dict[str, str], fallback_seller_id: str = "") -> str:
    seller_id = str(profile.get("sellerId", "")).strip() or fallback_seller_id
    profile_payload = {
        "clientId": profile["clientId"],
        "clientSecret": profile["clientSecret"],
        "refreshToken": profile["refreshToken"],
    }
    if seller_id:
        profile_payload["sellerId"] = seller_id
    payload = json.dumps(profile_payload).encode("utf-8")
    request = urllib.request.Request(
        AUTH_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        result = json.load(response)
    auth_session_id = result.get("authSessionId")
    if not auth_session_id:
        raise RuntimeError("Amazon authorization did not return a session ID.")
    return str(auth_session_id)


def load_production_context() -> dict[str, str] | None:
    try:
        with open(PRODUCTION_CONTEXT_PATH, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        return None

    seller_id = str(value.get("sellerId", "")).strip()
    marketplace_id = str(value.get("marketplaceId", "")).strip()
    if not seller_id or not marketplace_id:
        raise ValueError("production-context.json must contain sellerId and marketplaceId.")
    return {"sellerId": seller_id, "marketplaceId": marketplace_id}


def main() -> int:
    wait_for_service()
    if not os.path.isfile(KEY_PATH) or not os.path.isfile(PROFILES_PATH):
        print("No legacy Amazon authorization profiles were found; OAuth-managed storage will be used.")
        return 0
    profiles = decrypt_profiles()
    try:
        context = load_production_context()
    except Exception as error:
        context = None
        print(f"Seller ID fallback was not loaded: {error}", file=sys.stderr)
    fallback_seller_id = context["sellerId"] if context else ""
    for profile in profiles:
        verify_profile(profile, fallback_seller_id)
    print(f"Loaded {len(profiles)} encrypted Amazon authorization profiles.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Credential loading failed: {error}", file=sys.stderr)
        raise SystemExit(1)
