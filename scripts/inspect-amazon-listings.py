#!/usr/bin/env python3
"""Read current Amazon listing state for SKUs contained in a feed input JSON.

This is an incident-response utility. It decrypts the production authorization
profiles in memory, performs GET requests only, and never submits listing data.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


LWA_TOKEN_URL = "https://api.amazon.com/auth/o2/token"
REGION_ENDPOINTS = {
    "na": "https://sellingpartnerapi-na.amazon.com",
    "eu": "https://sellingpartnerapi-eu.amazon.com",
    "fe": "https://sellingpartnerapi-fe.amazon.com",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--feed-input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seller-id", required=True)
    parser.add_argument("--marketplace-id", required=True)
    parser.add_argument("--key", default="/etc/klanata/credential.key", type=Path)
    parser.add_argument(
        "--profiles", default="/etc/klanata/amazon-profiles.enc", type=Path
    )
    parser.add_argument("--delay", default=0.24, type=float)
    return parser.parse_args()


def decrypt_profiles(key_path: Path, profiles_path: Path) -> list[dict[str, str]]:
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
            f"file:{key_path}",
            "-in",
            str(profiles_path),
        ],
        check=True,
        capture_output=True,
    )
    value = json.loads(result.stdout)
    if not isinstance(value, list) or not value:
        raise RuntimeError("No encrypted Amazon profiles were found.")
    return value


def json_request(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    attempts: int = 6,
) -> tuple[dict[str, Any] | None, int]:
    for attempt in range(attempts):
        request = urllib.request.Request(
            url, data=data, headers=headers or {}, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                payload = response.read()
                return (json.loads(payload) if payload else {}, response.status)
        except urllib.error.HTTPError as error:
            payload = error.read().decode("utf-8", errors="replace")
            if error.code == 404:
                return ({"error": payload}, error.code)
            if error.code not in (429, 500, 502, 503, 504) or attempt == attempts - 1:
                raise RuntimeError(
                    f"Amazon request failed with HTTP {error.code}: {payload[:1000]}"
                ) from error
            retry_after = error.headers.get("Retry-After")
            wait_seconds = (
                float(retry_after)
                if retry_after and retry_after.replace(".", "", 1).isdigit()
                else min(20.0, 0.75 * (2**attempt))
            )
            time.sleep(wait_seconds)
        except urllib.error.URLError as error:
            if attempt == attempts - 1:
                raise RuntimeError(f"Amazon request failed: {error}") from error
            time.sleep(min(20.0, 0.75 * (2**attempt)))
    raise AssertionError("unreachable")


def get_access_token(profile: dict[str, str]) -> str:
    form = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": profile["refreshToken"],
            "client_id": profile["clientId"],
            "client_secret": profile["clientSecret"],
        }
    ).encode("ascii")
    payload, _ = json_request(
        LWA_TOKEN_URL,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=form,
    )
    if not payload or not payload.get("access_token"):
        raise RuntimeError("LWA did not return an access token.")
    return str(payload["access_token"])


def profile_matches_store(
    endpoint: str, access_token: str, marketplace_id: str
) -> bool:
    payload, _ = json_request(
        f"{endpoint}/sellers/v1/marketplaceParticipations",
        headers={"x-amz-access-token": access_token},
    )
    for item in (payload or {}).get("payload", []):
        marketplace = item.get("marketplace") or {}
        participation = item.get("participation") or {}
        if marketplace.get("id") == marketplace_id and participation.get(
            "isParticipating"
        ):
            return True
    return False


def find_profile(
    profiles: list[dict[str, str]], marketplace_id: str
) -> tuple[str, str, int]:
    errors: list[str] = []
    for index, profile in enumerate(profiles):
        try:
            region = profile.get("region", "na").lower()
            endpoint = REGION_ENDPOINTS[region]
            access_token = get_access_token(profile)
            if profile_matches_store(endpoint, access_token, marketplace_id):
                return endpoint, access_token, index
        except Exception as error:  # Continue to the next separately authorized profile.
            errors.append(f"profile {index + 1}: {error}")
    detail = " | ".join(errors) if errors else "no participating marketplace"
    raise RuntimeError(f"No profile could read marketplace {marketplace_id}: {detail}")


def load_skus(feed_input: Path) -> list[dict[str, Any]]:
    value = json.loads(feed_input.read_text(encoding="utf-8"))
    records: list[dict[str, Any]] = []
    for message in value.get("messages", []):
        availability = (message.get("attributes") or {}).get(
            "fulfillment_availability", []
        )
        records.append(
            {
                "messageId": message.get("messageId"),
                "sku": str(message["sku"]),
                "submittedQuantity": (
                    availability[0].get("quantity") if availability else None
                ),
            }
        )
    if not records:
        raise RuntimeError("The feed input contains no messages.")
    return records


def inspect_listing(
    endpoint: str,
    access_token: str,
    seller_id: str,
    marketplace_id: str,
    record: dict[str, Any],
) -> dict[str, Any]:
    sku = record["sku"]
    query = urllib.parse.urlencode(
        {
            "marketplaceIds": marketplace_id,
            "includedData": (
                "summaries,attributes,issues,offers,"
                "fulfillmentAvailability,procurement"
            ),
        }
    )
    url = (
        f"{endpoint}/listings/2021-08-01/items/"
        f"{urllib.parse.quote(seller_id, safe='')}/"
        f"{urllib.parse.quote(sku, safe='')}?{query}"
    )
    payload, status = json_request(
        url, headers={"x-amz-access-token": access_token}
    )
    result = dict(record)
    result["httpStatus"] = status
    if status == 404:
        result["exists"] = False
        return result

    response = payload or {}
    summaries = response.get("summaries") or []
    summary = summaries[0] if summaries else {}
    availability = response.get("fulfillmentAvailability") or []
    attributes = response.get("attributes") or {}
    offers = response.get("offers") or []
    procurement = response.get("procurement") or []
    issues = response.get("issues") or []
    has_listing_data = bool(
        summaries or attributes or offers or availability or procurement or issues
    )
    attribute_availability = attributes.get("fulfillment_availability") or []
    attribute_default_availability = next(
        (
            item
            for item in attribute_availability
            if item.get("fulfillment_channel_code") == "DEFAULT"
        ),
        None,
    )
    default_availability = next(
        (
            item
            for item in availability
            if item.get("fulfillmentChannelCode") == "DEFAULT"
        ),
        None,
    )
    result.update(
        {
            "exists": True,
            "hasListingData": has_listing_data,
            "hasListingSummary": bool(summaries),
            "responseKeys": sorted(response.keys()),
            "attributeKeys": sorted(attributes.keys()),
            "asin": summary.get("asin"),
            "status": summary.get("status"),
            "createdDate": summary.get("createdDate"),
            "lastUpdatedDate": summary.get("lastUpdatedDate"),
            "mfnQuantity": (
                default_availability.get("quantity")
                if default_availability is not None
                else None
            ),
            "attributeMfnQuantity": (
                attribute_default_availability.get("quantity")
                if attribute_default_availability is not None
                else None
            ),
            "attributeFulfillmentAvailability": attribute_availability,
            "fulfillmentAvailability": availability,
            "issues": issues,
        }
    )
    return result


def main() -> int:
    args = parse_args()
    records = load_skus(args.feed_input)
    profiles = decrypt_profiles(args.key, args.profiles)
    endpoint, access_token, profile_index = find_profile(
        profiles, args.marketplace_id
    )

    results: list[dict[str, Any]] = []
    for index, record in enumerate(records, 1):
        results.append(
            inspect_listing(
                endpoint,
                access_token,
                args.seller_id,
                args.marketplace_id,
                record,
            )
        )
        if index % 25 == 0 or index == len(records):
            print(f"Inspected {index}/{len(records)}", flush=True)
        time.sleep(max(0.0, args.delay))

    found = [item for item in results if item.get("exists")]
    summarized = [item for item in found if item.get("hasListingSummary")]
    orphaned = [
        item
        for item in found
        if item.get("hasListingData") and not item.get("hasListingSummary")
    ]
    output = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "requestMode": "GET_ONLY",
        "sellerId": args.seller_id,
        "marketplaceId": args.marketplace_id,
        "profileIndex": profile_index + 1,
        "summary": {
            "requested": len(results),
            "found": len(found),
            "notFound": len(results) - len(found),
            "withListingSummary": len(summarized),
            "orphanAttributeRecords": len(orphaned),
            "currentQuantityMatchesSubmission": sum(
                (
                    item.get("mfnQuantity") == item.get("submittedQuantity")
                    or item.get("attributeMfnQuantity")
                    == item.get("submittedQuantity")
                )
                for item in found
            ),
        },
        "listings": results,
    }
    args.output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(output["summary"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
