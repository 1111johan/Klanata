#!/usr/bin/env python3
"""Delete only the orphan Amazon SKU records proven by a prior GET-only audit."""

from __future__ import annotations

import argparse
import importlib.util
import json
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


EXPECTED_CONFIRMATION = "DELETE_289_ORPHAN_RECORDS_FROM_CARKEE_US"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--confirmation", required=True)
    parser.add_argument("--key", default="/etc/klanata/credential.key", type=Path)
    parser.add_argument(
        "--profiles", default="/etc/klanata/amazon-profiles.enc", type=Path
    )
    parser.add_argument("--delay", default=0.3, type=float)
    return parser.parse_args()


def load_inspector() -> Any:
    source = Path(__file__).with_name("inspect-amazon-listings.py")
    spec = importlib.util.spec_from_file_location("amazon_listing_inspector", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load inspector module from {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_audit(audit: dict[str, Any]) -> list[dict[str, Any]]:
    if audit.get("requestMode") != "GET_ONLY":
        raise RuntimeError("The input is not a GET-only audit.")
    if audit.get("sellerId") != "AC7OMGZBRADKF":
        raise RuntimeError("The audit does not belong to the Carkee seller.")
    if audit.get("marketplaceId") != "ATVPDKIKX0DER":
        raise RuntimeError("The audit does not belong to Amazon US.")

    listings = audit.get("listings") or []
    if len(listings) != 289:
        raise RuntimeError(f"Expected 289 audited records, found {len(listings)}.")

    submitted_quantities = {0: 0, 999: 0}
    invalid: list[str] = []
    for item in listings:
        quantity = item.get("submittedQuantity")
        if quantity in submitted_quantities:
            submitted_quantities[quantity] += 1
        if not (
            item.get("httpStatus") == 200
            and item.get("exists") is True
            and item.get("hasListingData") is True
            and item.get("hasListingSummary") is False
            and item.get("attributeKeys") == ["fulfillment_availability"]
            and item.get("asin") is None
            and item.get("status") is None
            and item.get("mfnQuantity") is None
            and item.get("attributeMfnQuantity") == quantity
            and not item.get("fulfillmentAvailability")
            and not item.get("issues")
        ):
            invalid.append(str(item.get("sku")))

    if submitted_quantities != {0: 256, 999: 33}:
        raise RuntimeError(
            f"Unexpected quantity distribution: {submitted_quantities}."
        )
    if invalid:
        raise RuntimeError(
            "Audit contains records that are not proven orphans: "
            + ", ".join(invalid[:10])
        )
    return listings


def write_progress(
    output_path: Path,
    audit: dict[str, Any],
    results: list[dict[str, Any]],
    completed: bool,
) -> None:
    value = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "operation": "DELETE_PROVEN_ORPHAN_LISTING_ITEMS",
        "sellerId": audit["sellerId"],
        "marketplaceId": audit["marketplaceId"],
        "completed": completed,
        "summary": {
            "requested": 289,
            "attempted": len(results),
            "accepted": sum(item.get("accepted") is True for item in results),
            "failed": sum(item.get("accepted") is False for item in results),
        },
        "results": results,
    }
    temporary = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    temporary.replace(output_path)


def main() -> int:
    args = parse_args()
    if args.confirmation != EXPECTED_CONFIRMATION:
        raise RuntimeError("Production deletion confirmation does not match.")

    audit = json.loads(args.audit.read_text(encoding="utf-8"))
    listings = validate_audit(audit)
    inspector = load_inspector()
    profiles = inspector.decrypt_profiles(args.key, args.profiles)
    endpoint, access_token, _ = inspector.find_profile(
        profiles, audit["marketplaceId"]
    )

    results: list[dict[str, Any]] = []
    for index, item in enumerate(listings, 1):
        sku = str(item["sku"])
        query = urllib.parse.urlencode(
            {
                "marketplaceIds": audit["marketplaceId"],
                "issueLocale": "en_US",
            }
        )
        url = (
            f"{endpoint}/listings/2021-08-01/items/"
            f"{urllib.parse.quote(audit['sellerId'], safe='')}/"
            f"{urllib.parse.quote(sku, safe='')}?{query}"
        )
        result: dict[str, Any] = {
            "messageId": item.get("messageId"),
            "sku": sku,
            "submittedQuantity": item.get("submittedQuantity"),
        }
        try:
            response, http_status = inspector.json_request(
                url,
                method="DELETE",
                headers={"x-amz-access-token": access_token},
            )
            response = response or {}
            issues = response.get("issues") or []
            errors = [
                issue
                for issue in issues
                if str(issue.get("severity", "")).upper() == "ERROR"
            ]
            operation_status = str(response.get("status", ""))
            accepted = (
                http_status in (200, 202)
                and operation_status in ("ACCEPTED", "VALID")
                and not errors
            )
            result.update(
                {
                    "httpStatus": http_status,
                    "operationStatus": operation_status,
                    "submissionId": response.get("submissionId"),
                    "issues": issues,
                    "accepted": accepted,
                }
            )
        except Exception as error:
            result.update({"accepted": False, "error": str(error)})
        results.append(result)
        write_progress(args.output, audit, results, completed=False)
        if index % 25 == 0 or index == len(listings):
            accepted_count = sum(x.get("accepted") is True for x in results)
            print(
                f"Deleted {index}/{len(listings)}; accepted {accepted_count}",
                flush=True,
            )
        time.sleep(max(0.0, args.delay))

    completed = len(results) == len(listings) and all(
        item.get("accepted") is True for item in results
    )
    write_progress(args.output, audit, results, completed=completed)
    summary = {
        "requested": len(listings),
        "accepted": sum(item.get("accepted") is True for item in results),
        "failed": sum(item.get("accepted") is False for item in results),
        "completed": completed,
    }
    print(json.dumps(summary), flush=True)
    return 0 if completed else 1


if __name__ == "__main__":
    raise SystemExit(main())
