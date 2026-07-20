import json
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

from playwright.sync_api import Route, sync_playwright


BASE_URL = (
    sys.argv[1]
    if len(sys.argv) > 1
    else os.environ.get("KLANATA_UI_BASE_URL", "http://127.0.0.1:4348")
).rstrip("/")
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "output"
OUTPUT_DIR.mkdir(exist_ok=True)
SELLER_ID = "AC7OMGZBRADKF"
CALLBACK_CODE = "ui-authorization-code-never-expose"
CALLBACK_STATE = "ui-oauth-state-never-expose"
REFRESH_TOKEN = "Atzr|ui-refresh-token-never-expose"
ACCESS_TOKEN = "ui-access-token-never-expose"

MARKETPLACES = [
    {
        "id": "A13V1IB3VIYZZH",
        "name": "Amazon.fr",
        "countryCode": "FR",
        "domainName": "amazon.fr",
        "storeName": "Carkee",
        "isParticipating": True,
        "hasSuspendedListings": False,
    },
    {
        "id": "A1PA6795UKMFR9",
        "name": "Amazon.de",
        "countryCode": "DE",
        "domainName": "amazon.de",
        "storeName": "Carkee",
        "isParticipating": True,
        "hasSuspendedListings": False,
    },
]

AUTH_SESSION = {
    "authSessionId": "mock-oauth-session",
    "sellerId": SELLER_ID,
    "verifiedStoreName": "Carkee",
    "storeAllowed": True,
    "expiresIn": 3540,
    "region": "eu",
    "endpoint": "https://sellingpartnerapi-eu.amazon.com",
    "regionAutoDetected": True,
    "storeNames": ["Carkee", "Invoicing_1367520_AC7OMGZBRADKF"],
    "marketplaces": MARKETPLACES,
}

UNBOUND_CARKEE_SESSION = {
    "authSessionId": "mock-unbound-carkee-session",
    "sellerId": "",
    "verifiedStoreName": "Carkee",
    "storeAllowed": True,
    "expiresIn": 3540,
    "region": "eu",
    "endpoint": "https://sellingpartnerapi-eu.amazon.com",
    "regionAutoDetected": True,
    "storeNames": ["Carkee"],
    "marketplaces": [{
        "id": "APJ6JRA9NG5V4",
        "name": "Amazon.it",
        "countryCode": "IT",
        "domainName": "amazon.it",
        "storeName": "Carkee",
        "isParticipating": True,
        "hasSuspendedListings": False,
    }],
}

OTHER_STORE_SESSION = {
    "authSessionId": "mock-other-store-session",
    "sellerId": "A1NOTCARKEE99",
    "verifiedStoreName": "Other Store",
    "storeAllowed": False,
    "expiresIn": 3540,
    "region": "na",
    "endpoint": "https://sellingpartnerapi-na.amazon.com",
    "regionAutoDetected": True,
    "storeNames": ["Other Store"],
    "marketplaces": [{
        "id": "ATVPDKIKX0DER",
        "name": "Amazon.com",
        "countryCode": "US",
        "domainName": "amazon.com",
        "storeName": "Other Store",
        "isParticipating": True,
        "hasSuspendedListings": False,
    }],
}

STATUS = {
    "ok": True,
    "bind": "127.0.0.1:4348",
    "credentialStorage": "aes-256-gcm-file",
    "defaultFileName": "",
    "defaultFileAvailable": False,
    "apiVersion": "1.5",
    "submissionConfirmation": "risk-based-row-count",
    "pricingProductionEnabled": False,
    "legacyPricingSimulationAvailable": True,
    "adminConfigurationWritable": True,
    "allowedAmazonStoreName": "Carkee",
    "developerApplication": {
        "configured": True,
        "oauthReady": True,
        "applicationId": "amzn1.sellerapps.app.mock-operator",
        "authorizationBaseUri": "https://sellercentral.amazon.test/apps/authorize/consent",
        "clientId": "amzn1.application-oa2-client.mock...",
        "clientSecret": "encrypted",
        "credentialStorage": "aes-256-gcm-file",
    },
}

WORKFLOW = {
    "analysis": None,
    "auth": AUTH_SESSION,
    "authSessions": [AUTH_SESSION, UNBOUND_CARKEE_SESSION, OTHER_STORE_SESSION],
    "account": None,
}

AUTHORIZATION_URL = (
    "https://sellercentral.amazon.test/apps/authorize/consent"
    "?application_id=amzn1.sellerapps.app.mock-operator"
    "&state=ui-start-state-safe-to-forward"
)


def assert_secret_absent(value: str, context: str) -> None:
    for secret in (CALLBACK_CODE, CALLBACK_STATE, REFRESH_TOKEN, ACCESS_TOKEN):
        assert secret not in value, f"{context} leaked callback or token material"


public_payload = json.dumps({"status": STATUS, "workflow": WORKFLOW}, ensure_ascii=False)
assert_secret_absent(public_payload, "mock public API contract")
for forbidden_property in ("refreshToken", "accessToken"):
    assert forbidden_property not in public_payload


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 1000})
    browser_errors = []
    start_api_calls = []
    seller_central_requests = []

    page.on(
        "console",
        lambda message: browser_errors.append(message.text)
        if message.type == "error"
        else None,
    )
    page.on("pageerror", lambda error: browser_errors.append(str(error)))

    def handle_api(route: Route) -> None:
        request = route.request
        parsed = urlparse(request.url)
        path = parsed.path
        if path == "/api/status":
            route.fulfill(json=STATUS)
        elif path == "/api/workflow/current":
            route.fulfill(json=WORKFLOW)
        elif path == "/api/jobs":
            route.fulfill(json={"jobs": []})
        elif path == "/api/auth/oauth/start":
            start_api_calls.append({"method": request.method, "url": request.url})
            route.fulfill(
                json={
                    "authorizationUrl": AUTHORIZATION_URL,
                    "callbackUrl": f"{BASE_URL}/api/auth/oauth/callback",
                    "expiresIn": 600,
                }
            )
        else:
            route.fulfill(
                status=404,
                json={"error": {"code": "NOT_MOCKED", "message": path}},
            )

    def handle_seller_central(route: Route) -> None:
        seller_central_requests.append(route.request.url)
        route.fulfill(
            status=200,
            content_type="text/html; charset=utf-8",
            body="<!doctype html><title>Mock Seller Central authorization</title>",
        )

    page.route("**/api/**", handle_api)
    page.route("https://sellercentral.amazon.test/**", handle_seller_central)

    callback_fragment = (
        "#settings?amazon=connected"
        f"&state={quote(CALLBACK_STATE)}"
        f"&selling_partner_id={quote(SELLER_ID)}"
        f"&spapi_oauth_code={quote(CALLBACK_CODE)}"
    )
    response = page.goto(f"{BASE_URL}/{callback_fragment}", wait_until="networkidle")
    assert response is not None and response.ok
    page.wait_for_url(f"{BASE_URL}/#settings")

    # Callback material is removed before the normal page becomes interactive.
    assert page.url == f"{BASE_URL}/#settings"
    assert_secret_absent(page.url, "cleaned browser URL")
    assert_secret_absent(page.content(), "rendered DOM")

    # The normal Settings surface is OAuth-first. Manual migration and developer
    # credentials exist only in closed administrator details elements.
    assert page.locator("#settings-auth-slot > #flow-panel-auth").count() == 1
    assert page.locator("#oauth-auth-button").is_visible()
    assert not page.locator("details.legacy-auth-settings").evaluate("node => node.open")
    assert not page.locator("#admin-application-settings").evaluate("node => node.open")
    assert not page.locator("#auth-seller-id").is_visible()
    assert not page.locator("#refresh-token").is_visible()
    assert not page.locator("#client-id").is_visible()
    assert not page.locator("#client-secret").is_visible()

    accounts = page.locator("#authorized-accounts .authorized-account")
    assert accounts.count() == 2
    assert page.locator("#authorized-accounts .site-chip").count() == 3
    account_text = accounts.first.inner_text()
    assert "FR" in account_text and "DE" in account_text
    assert "AC7O…ADKF" in account_text
    assert "待绑定 Seller ID" in accounts.nth(1).inner_text()
    assert "Other Store" not in page.locator("#authorized-accounts").inner_text()
    assert page.locator("#oauth-auth-button-label").inner_text() == "重新授权 Carkee"
    page.screenshot(path=OUTPUT_DIR / "oauth-settings-desktop.png", full_page=True)

    # Daily upload and pricing pages expose only bound Carkee targets. The
    # allowed-but-unbound and rejected store fixtures remain settings-only/hidden.
    page.locator('[data-view-target="workspace"]').click()
    page.wait_for_url(f"{BASE_URL}/#workspace")
    assert page.locator("#view-workspace #auth-seller-id").count() == 0
    assert page.locator("#view-workspace #refresh-token").count() == 0
    assert page.locator("#view-workspace #seller-id").get_attribute("type") == "hidden"
    assert page.locator("#marketplace-select").is_enabled()
    assert page.locator("#marketplace-select option").count() == 3
    upload_options = page.locator("#marketplace-select option").all_inner_texts()
    assert all("Other Store" not in option and "Amazon.it" not in option for option in upload_options)
    assert all("Carkee" in option for option in upload_options[1:])
    assert page.locator("#view-workspace .workflow-step").count() == 3
    assert page.locator('[data-workflow-step="auth"]').count() == 0
    assert page.locator("#validate-account-button").count() == 0

    page.locator('[data-view-target="pricing"]').click()
    page.wait_for_url(f"{BASE_URL}/#pricing")
    assert page.locator("#view-pricing #auth-seller-id").count() == 0
    assert page.locator("#view-pricing #refresh-token").count() == 0
    assert page.locator("#view-pricing input[name*='seller']").count() == 0
    assert page.locator("#pricing-marketplace-select").is_enabled()
    assert page.locator("#pricing-marketplace-select option").count() == 3
    pricing_options = page.locator("#pricing-marketplace-select option").all_inner_texts()
    assert all("Other Store" not in option and "Amazon.it" not in option for option in pricing_options)
    assert all("Carkee" in option for option in pricing_options[1:])
    assert_secret_absent(page.content(), "daily workspace DOM")

    # Operators start authorization with one click. Seller Central is fully
    # intercepted, so this remains an offline UI test.
    page.locator('[data-view-target="settings"]').click()
    page.wait_for_url(f"{BASE_URL}/#settings")
    page.locator("#oauth-auth-button").click()
    page.wait_for_url("https://sellercentral.amazon.test/**")
    assert start_api_calls == [
        {"method": "GET", "url": f"{BASE_URL}/api/auth/oauth/start"}
    ]
    assert seller_central_requests == [AUTHORIZATION_URL]
    authorization_query = parse_qs(urlparse(seller_central_requests[0]).query)
    assert authorization_query["application_id"] == [
        "amzn1.sellerapps.app.mock-operator"
    ]
    assert authorization_query["state"] == ["ui-start-state-safe-to-forward"]
    assert_secret_absent(seller_central_requests[0], "Seller Central start URL")
    assert not browser_errors, browser_errors

    rejected = browser.new_page(viewport={"width": 1024, "height": 768})
    rejected.route("**/api/**", handle_api)
    rejected.goto(
        f"{BASE_URL}/#settings?amazon=error&reason=store_not_allowed",
        wait_until="networkidle",
    )
    rejected.get_by_text(
        "登录的 Amazon 店铺不是 Carkee，本次授权未保存；请切换到 Carkee 后重试",
        exact=True,
    ).wait_for()
    assert rejected.url == f"{BASE_URL}/#settings"
    rejected.close()

    mobile_errors = []
    mobile = browser.new_page(viewport={"width": 390, "height": 844})
    mobile.on(
        "console",
        lambda message: mobile_errors.append(message.text)
        if message.type == "error"
        else None,
    )
    mobile.on("pageerror", lambda error: mobile_errors.append(str(error)))
    mobile.route("**/api/**", handle_api)
    mobile.route("https://sellercentral.amazon.test/**", handle_seller_central)
    mobile.goto(f"{BASE_URL}/#settings", wait_until="networkidle")
    assert mobile.locator("#oauth-auth-button").is_visible()
    assert not mobile.locator("details.legacy-auth-settings").evaluate("node => node.open")
    assert not mobile.locator("#admin-application-settings").evaluate("node => node.open")
    assert mobile.locator("#authorized-accounts .authorized-account").count() == 2
    assert mobile.locator("#authorized-accounts .site-chip").count() == 3
    assert "Other Store" not in mobile.locator("#authorized-accounts").inner_text()
    assert mobile.evaluate(
        "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
    )
    assert_secret_absent(mobile.content(), "mobile Settings DOM")
    mobile.screenshot(path=OUTPUT_DIR / "oauth-settings-mobile.png", full_page=True)

    for target in ("workspace", "pricing"):
        mobile.locator(f'[data-view-target="{target}"]').click()
        mobile.wait_for_url(f"{BASE_URL}/#{target}")
        assert mobile.evaluate(
            "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
        ), f"mobile {target} has horizontal overflow"
        assert mobile.locator(f"#view-{target} #auth-seller-id").count() == 0
        assert mobile.locator(f"#view-{target} #refresh-token").count() == 0
    assert not mobile_errors, mobile_errors
    mobile.close()
    browser.close()

print(
    "OAuth UI verification passed: Carkee-only operational targets, pending binding, "
    "rejected-store messaging, responsive layout, and credential-free daily workspaces."
)
