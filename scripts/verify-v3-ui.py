from pathlib import Path
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import Route, sync_playwright


BASE_URL = "http://127.0.0.1:4323"
OUTPUT = Path(__file__).resolve().parents[1] / "output"
OUTPUT.mkdir(exist_ok=True)

CONTEXT = {
    "sellerId": "AC7OMGZBRADKF",
    "sellerName": "Carkee",
    "marketplaceId": "ATVPDKIKX0DER",
    "marketplaceName": "United States",
    "countryCode": "US",
    "currencyCode": "USD",
    "region": "NorthAmerica",
    "lastVerifiedAtUtc": "2026-07-16T06:30:00Z",
    "authorizationProfileCount": 2,
    "capabilities": {
        "canReadListings": True,
        "canReadCatalog": True,
        "canReadPricing": True,
        "canCreateDraftChangeSets": False,
        "canSimulatePricing": False,
        "canWritePrices": False,
        "canWriteMfnInventory": False,
        "writeBlockReason": "Production writes are disabled by the V3 rollout gate.",
        "verifiedAtUtc": "2026-07-16T06:30:00Z",
    },
}

ITEMS = [
    {
        "sku": "SKU-MFN-001",
        "asin": "B0TEST0001",
        "title": "Heavy Duty Cargo Organizer",
        "fulfillment": "MFN",
        "status": "Active",
        "currencyCode": "USD",
        "price": 39.99,
        "businessPrice": 35.99,
        "mfnQuantity": 28,
        "freshness": "fresh",
        "synchronizedAtUtc": "2026-07-16T07:20:00Z",
        "snapshotVersion": 4,
    },
    {
        "sku": "SKU-FBA-002",
        "asin": "B0TEST0002",
        "title": "All Weather Floor Mat Set",
        "fulfillment": "FBA",
        "status": "Active",
        "currencyCode": "USD",
        "price": 79.5,
        "businessPrice": None,
        "mfnQuantity": None,
        "freshness": "aging",
        "synchronizedAtUtc": "2026-07-16T02:00:00Z",
        "snapshotVersion": 2,
    },
    {
        "sku": "SKU-MFN-003",
        "asin": "B0TEST0003",
        "title": "Replacement Hardware Kit",
        "fulfillment": "MFN",
        "status": "Suppressed",
        "currencyCode": "USD",
        "price": 14.25,
        "businessPrice": 12.8,
        "mfnQuantity": 0,
        "freshness": "stale",
        "synchronizedAtUtc": "2026-07-14T01:00:00Z",
        "snapshotVersion": 7,
    },
]


def catalog_response():
    return {
        "context": CONTEXT,
        "metrics": {
            "totalListings": 3,
            "activeListings": 2,
            "mfnListings": 2,
            "staleListings": 1,
            "lastSynchronizedAtUtc": "2026-07-16T07:20:00Z",
        },
        "items": ITEMS,
        "page": 1,
        "pageSize": 50,
        "totalItems": 3,
        "totalPages": 1,
        "generatedAtUtc": "2026-07-16T07:22:00Z",
    }


def install_api_fixture(page, catalog_requests):
    def handle(route: Route):
        parsed = urlparse(route.request.url)
        if parsed.path == "/api/v3/workspace/contexts":
            route.fulfill(json=[CONTEXT])
            return

        if parsed.path.startswith("/api/v3/catalog/listings/"):
            sku = parsed.path.rsplit("/", 1)[-1]
            item = next(item for item in ITEMS if item["sku"] == sku)
            route.fulfill(json={
                **item,
                "sellerId": CONTEXT["sellerId"],
                "marketplaceId": CONTEXT["marketplaceId"],
                "amazonUpdatedAtUtc": "2026-07-16T07:18:00Z",
                "sourceReference": "GET_MERCHANT_LISTINGS_ALL_DATA",
            })
            return

        if parsed.path == "/api/v3/catalog/listings":
            catalog_requests.append(parse_qs(parsed.query))
            route.fulfill(json=catalog_response())
            return

        route.continue_()

    page.route("**/api/v3/**", handle)


def assert_no_page_overflow(page):
    overflow = page.evaluate("document.documentElement.scrollWidth > document.documentElement.clientWidth")
    assert not overflow, "Page has horizontal overflow outside the catalog table scroller"


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    errors = []

    empty_page = browser.new_page(viewport={"width": 1440, "height": 1000})
    empty_page.on("console", lambda message: errors.append(f"console:{message.type}:{message.text}") if message.type == "error" else None)
    empty_page.on("pageerror", lambda error: errors.append(f"pageerror:{error}"))
    empty_page.goto(BASE_URL, wait_until="networkidle")
    empty_page.get_by_role("heading", name="商品中心").wait_for()
    empty_page.get_by_role("heading", name="尚无已验证的 Carkee 生产上下文").wait_for()
    assert_no_page_overflow(empty_page)
    empty_page.screenshot(path=OUTPUT / "v3-catalog-empty-desktop.png", full_page=True)

    catalog_requests = []
    desktop = browser.new_page(viewport={"width": 1440, "height": 1000})
    desktop.on("console", lambda message: errors.append(f"console:{message.type}:{message.text}") if message.type == "error" else None)
    desktop.on("pageerror", lambda error: errors.append(f"pageerror:{error}"))
    install_api_fixture(desktop, catalog_requests)
    desktop.goto(BASE_URL, wait_until="networkidle")
    context_select = desktop.get_by_label("Carkee 站点", exact=True)
    context_select.wait_for()
    assert context_select.input_value() == "AC7OMGZBRADKF::ATVPDKIKX0DER"
    assert context_select.locator("option").count() == 1
    assert context_select.locator("option").inner_text() == "Carkee · United States"
    desktop.get_by_text("Heavy Duty Cargo Organizer").wait_for()
    desktop.get_by_role("button", name="Heavy Duty Cargo Organizer SKU-MFN-001 · B0TEST0001").click()
    desktop.get_by_role("heading", name="商品详情").wait_for()
    desktop.get_by_text("GET_MERCHANT_LISTINGS_ALL_DATA").wait_for()
    desktop.screenshot(path=OUTPUT / "v3-catalog-detail-desktop.png", full_page=True)
    desktop.get_by_role("button", name="关闭商品详情").click()
    desktop.get_by_role("searchbox", name="搜索商品").fill("SKU-MFN")
    desktop.get_by_role("button", name="搜索", exact=True).click()
    desktop.wait_for_timeout(150)
    assert any(request.get("search") == ["SKU-MFN"] for request in catalog_requests)
    desktop.get_by_role("button", name="系统状态").click()
    desktop.get_by_role("heading", name="系统状态").wait_for()
    desktop.get_by_text("V3MultipleSellerAuthorizations").wait_for()
    assert_no_page_overflow(desktop)

    mobile_requests = []
    mobile = browser.new_page(viewport={"width": 390, "height": 844})
    mobile.on("console", lambda message: errors.append(f"console:{message.type}:{message.text}") if message.type == "error" else None)
    mobile.on("pageerror", lambda error: errors.append(f"pageerror:{error}"))
    install_api_fixture(mobile, mobile_requests)
    mobile.goto(f"{BASE_URL}/#catalog", wait_until="networkidle")
    mobile.get_by_role("heading", name="商品中心").wait_for()
    mobile.get_by_text("Heavy Duty Cargo Organizer").wait_for()
    assert_no_page_overflow(mobile)
    mobile.screenshot(path=OUTPUT / "v3-catalog-mobile.png", full_page=True)

    browser.close()

    assert not errors, "Browser errors:\n" + "\n".join(errors)
    print("V3 UI verification passed: Carkee-only context, empty state, catalog, detail, search, system and mobile layout.")
