import json
import os
from pathlib import Path

from playwright.sync_api import Route, sync_playwright


BASE_URL = os.environ.get("KLANATA_UI_BASE_URL", "http://127.0.0.1:4337").rstrip("/")
OUTPUT = Path(__file__).resolve().parents[1] / "output" / "simplified-operator-flow.png"
SELLER_ID = "AC7OMGZBRADKF"
MARKETPLACE = {
    "id": "ATVPDKIKX0DER",
    "name": "Amazon.com",
    "countryCode": "US",
    "domainName": "amazon.com",
    "storeName": "Carkee",
    "isParticipating": True,
    "hasSuspendedListings": False,
}
SESSIONS = [
    {
        "authSessionId": session_id,
        "sellerId": SELLER_ID,
        "verifiedStoreName": "Carkee",
        "storeAllowed": True,
        "expiresIn": 3000,
        "region": "na",
        "endpoint": "https://sellingpartnerapi-na.amazon.com",
        "storeNames": ["Carkee", "Invoicing_1367520_AC7OMGZBRADKF"],
        "marketplaces": [MARKETPLACE],
    }
    for session_id in ("auth-session-primary", "auth-session-backup")
]
SESSIONS.extend([
    {
        "authSessionId": "auth-session-unbound-carkee",
        "sellerId": "",
        "verifiedStoreName": "Carkee",
        "storeAllowed": True,
        "expiresIn": 3000,
        "region": "eu",
        "endpoint": "https://sellingpartnerapi-eu.amazon.com",
        "storeNames": ["Carkee"],
        "marketplaces": [{
            **MARKETPLACE,
            "id": "A1PA6795UKMFR9",
            "name": "Amazon.de",
            "countryCode": "DE",
        }],
    },
    {
        "authSessionId": "auth-session-other-store",
        "sellerId": "A1NOTCARKEE99",
        "verifiedStoreName": "Other Store",
        "storeAllowed": False,
        "expiresIn": 3000,
        "region": "na",
        "endpoint": "https://sellingpartnerapi-na.amazon.com",
        "storeNames": ["Other Store"],
        "marketplaces": [{**MARKETPLACE, "storeName": "Other Store"}],
    },
])
ANALYSIS = {
    "analysisId": "analysis-multi-token",
    "fileName": "inventory-test.txt",
    "templateSellerId": SELLER_ID,
    "templateMarketplaceId": MARKETPLACE["id"],
    "summary": {
        "rows": 1,
        "columnCount": 3,
        "uniqueSkus": 1,
        "skippedExampleRows": 0,
        "zeroQuantity": 0,
        "positiveQuantity": 1,
        "minQuantity": 5,
        "maxQuantity": 5,
        "totalQuantity": 5,
    },
    "distribution": [{"key": "positive", "label": "有库存", "count": 1}],
    "preview": [{"row": 1, "sku": "SKU-001", "channel": "DEFAULT", "quantity": 5}],
    "nonEmptyColumns": [{"label": "SKU"}, {"label": "Quantity"}],
}
ACCOUNT = {
    "accountValidationId": "validation-multi-token",
    "authSessionId": "auth-session-primary",
    "authSessionIds": ["auth-session-primary", "auth-session-backup"],
    "authorizationProfileCount": 2,
    "rejectedAuthorizationProfileCount": 0,
    "status": "VALID",
    "sku": "SKU-001",
    "issues": [],
    "sellerId": SELLER_ID,
    "marketplaceId": MARKETPLACE["id"],
}
PRICING_RESULT = {
    "simulationId": "pricing-simulation",
    "fileName": "pricing.csv",
    "scope": {
        "sellerId": SELLER_ID,
        "marketplaceId": MARKETPLACE["id"],
        "storeName": "Carkee",
        "countryCode": "US",
        "currency": "USD",
    },
    "summary": {
        "totalRows": 1,
        "eligible": 1,
        "excluded": 0,
        "overallRisk": "LOW",
        "missingColumns": [],
    },
    "exclusions": [],
    "eligibleItems": [{
        "sku": "SKU-001",
        "asin": "B001",
        "quantity": 5,
        "currentPrice": 10.0,
        "newPrice": 10.5,
        "delta": 0.5,
        "deltaPercent": 5.0,
        "currentBusinessPrice": None,
        "newBusinessPrice": None,
        "risk": "LOW",
    }],
    "previewTruncated": False,
    "gate": {"locked": True, "code": "V4_REQUIRED", "message": "生产调价请使用 V4 API 原生流程。"},
}
PRICING_BATCH = {
    "id": "abcdef0123456789abcdef0123456789",
    "simulationId": "pricing-simulation",
    "status": "APPROVAL_PENDING",
    "requiredConfirmation": "APPROVE RADKF US 1 UP LOW",
    "accountValidationId": "pricing-validation",
    "sellerId": SELLER_ID,
    "marketplaceId": MARKETPLACE["id"],
    "storeName": "Carkee",
    "countryCode": "US",
    "rows": 1,
    "direction": "UP",
    "risk": "LOW",
    "validationPreview": {"accepted": 1},
}
MISMATCH_ANALYSIS = {
    **ANALYSIS,
    "analysisId": "analysis-wrong-seller",
    "fileName": "wrong-store.txt",
    "templateSellerId": "A238CU8SD85H9R",
}


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 1000})
    browser_errors = []
    account_bodies = []
    pricing_simulation_bodies = []
    pricing_write_requests = []
    submit_bodies = []
    analysis_response = ANALYSIS
    page.on("console", lambda message: browser_errors.append(message.text) if message.type == "error" else None)
    page.on("pageerror", lambda error: browser_errors.append(str(error)))

    def handle_api(route: Route):
        request = route.request
        path = request.url.split(BASE_URL, 1)[-1].split("?", 1)[0]
        if path == "/api/status":
            route.fulfill(json={
                "ok": True,
                "bind": "127.0.0.1:4337",
                "credentialStorage": "memory-only",
                "defaultFileName": "",
                "defaultFileAvailable": False,
                "apiVersion": "1.5",
                "submissionConfirmation": "risk-based-row-count",
                "pricingProductionEnabled": False,
                "legacyPricingSimulationAvailable": True,
                "allowedAmazonStoreName": "Carkee",
                "developerApplication": {
                    "configured": True,
                    "clientId": "amzn1.application-oa2-client...",
                    "clientSecret": "encrypted",
                },
            })
        elif path == "/api/workflow/current":
            route.fulfill(json={"analysis": None, "auth": SESSIONS[0], "authSessions": SESSIONS, "account": None})
        elif path == "/api/analyze" and request.method == "POST":
            route.fulfill(json=analysis_response)
        elif path == "/api/account/validate" and request.method == "POST":
            account_bodies.append(json.loads(request.post_data or "{}"))
            route.fulfill(json=ACCOUNT)
        elif path == "/api/pricing/simulate" and request.method == "POST":
            pricing_simulation_bodies.append(json.loads(request.post_data or "{}"))
            route.fulfill(json=PRICING_RESULT)
        elif path == "/api/pricing/batches" and request.method == "POST":
            pricing_write_requests.append(path)
            route.fulfill(status=403, json={"error": {"code": "V4_REQUIRED", "message": "Use V4."}})
        elif path == f"/api/pricing/batches/{PRICING_BATCH['id']}/approve" and request.method == "POST":
            pricing_write_requests.append(path)
            route.fulfill(status=403, json={"error": {"code": "V4_REQUIRED", "message": "Use V4."}})
        elif path == "/api/feeds/submit" and request.method == "POST":
            submit_bodies.append(json.loads(request.post_data or "{}"))
            route.fulfill(status=201, json={
                "id": "0123456789abcdef0123456789abcdef",
                "feedId": "FEED-SIMPLIFIED-FLOW",
                "status": "IN_QUEUE",
                "sellerId": SELLER_ID,
                "marketplaceId": MARKETPLACE["id"],
                "region": "na",
                "fileName": "inventory-test.txt",
                "rows": 1,
                "zeroQuantity": 0,
                "positiveQuantity": 1,
                "createdAt": "2026-07-17T08:00:00Z",
                "updatedAt": "2026-07-17T08:00:00Z",
                "reportAvailable": False,
                "reportSummary": None,
                "error": None,
            })
        elif path == "/api/jobs":
            route.fulfill(json={"jobs": []})
        elif path.startswith("/api/jobs/"):
            route.fulfill(json={"status": "IN_QUEUE"})
        else:
            route.continue_()

    page.route("**/api/**", handle_api)
    page.goto(f"{BASE_URL}/#workspace", wait_until="networkidle")
    upload_options = page.locator("#marketplace-select option").all_inner_texts()
    assert len(upload_options) == 2
    assert "Carkee" in upload_options[1]
    assert all("Other Store" not in option and "Amazon.de" not in option for option in upload_options)

    # Local administrators can run a read-only legacy simulation, but the UI exposes no pricing write action.
    page.locator('[data-view-target="pricing"]').click()
    pricing_options = page.locator("#pricing-marketplace-select option").all_inner_texts()
    assert len(pricing_options) == 2
    assert "Carkee" in pricing_options[1]
    assert all("Other Store" not in option and "Amazon.de" not in option for option in pricing_options)
    page.locator("#pricing-marketplace-select").select_option(f"{SELLER_ID}::{MARKETPLACE['id']}")
    page.locator("#pricing-file-input").set_input_files({
        "name": "pricing.csv",
        "mimeType": "text/csv",
        "buffer": b"sku,asin,quantity,fulfillment,status,price\nSKU-001,B001,5,FBM,Active,10.00",
    })
    assert page.locator("#pricing-run-button").is_enabled()
    page.locator("#pricing-run-button").click()
    page.locator("#pricing-results").wait_for()
    assert len(pricing_simulation_bodies) == 1
    assert "accountValidationId" not in pricing_simulation_bodies[0]
    assert pricing_simulation_bodies[0]["rule"]["businessPriceMode"] == "DO_NOT_CHANGE"
    assert page.locator("#pricing-approval-button").is_hidden()
    assert page.locator("#pricing-production-strip").is_hidden()
    assert "V4" in page.locator("#pricing-gate-message").inner_text()
    assert pricing_write_requests == []

    # Upload derives Seller and Marketplace from the file, then validates automatically.
    page.locator('[data-view-target="workspace"]').click()
    assert page.locator("#seller-id").get_attribute("type") == "hidden"
    page.locator("#file-input").set_input_files({
        "name": "inventory-test.txt",
        "mimeType": "text/plain",
        "buffer": b"mock Amazon inventory template",
    })
    page.locator("#account-state").filter(has_text="匹配通过").wait_for()
    assert len(account_bodies) == 1
    assert account_bodies[0]["sellerId"] == SELLER_ID
    assert account_bodies[0]["marketplaceId"] == MARKETPLACE["id"]
    assert account_bodies[0]["authSessionIds"] == ["auth-session-backup", "auth-session-primary"]
    assert "2 个" in page.locator("#account-result").inner_text()

    page.locator("#confirm-checkbox").check()
    assert page.locator("#submit-feed-button").is_enabled()
    page.locator("#submit-feed-button").click()
    assert "授权" in page.locator("#dialog-auth-profile").inner_text()
    page.screenshot(path=OUTPUT, full_page=True)
    page.locator("#confirm-submit-button").click()
    page.wait_for_timeout(200)

    assert len(submit_bodies) == 1
    assert submit_bodies[0]["authSessionId"] in {"auth-session-primary", "auth-session-backup"}
    assert submit_bodies[0]["accountValidationId"] == "validation-multi-token"
    assert submit_bodies[0]["confirmation"] == "SUBMIT"

    # A file from another Seller remains blocked even when an operator selects this store.
    analysis_response = MISMATCH_ANALYSIS
    page.locator('[data-view-target="workspace"]').click()
    page.locator("#file-input").set_input_files({
        "name": "wrong-store.txt",
        "mimeType": "text/plain",
        "buffer": b"mock template owned by another Seller",
    })
    page.locator("#marketplace-select").select_option(f"{SELLER_ID}::{MARKETPLACE['id']}")
    page.locator(".target-mismatch").wait_for()
    assert "文件所属 Seller 与当前店铺不同" in page.locator("#account-result").inner_text()
    assert len(account_bodies) == 1
    assert page.locator("#submit-feed-button").is_disabled()
    assert not browser_errors, browser_errors
    browser.close()

print("Simplified operator flow passed: Carkee-only multi-token targets, read-only legacy pricing, and unchanged inventory submission workflow.")
