import json
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import Page, Route, sync_playwright


BASE_URL = os.environ.get("KLANATA_UI_URL", "http://127.0.0.1:5173").rstrip("/")
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output"
OUTPUT.mkdir(exist_ok=True)

CONTEXT = {
    "sellerId": "AC7OMGZBRADKF",
    "sellerName": "Carkee",
    "marketplaceId": "ATVPDKIKX0DER",
    "marketplaceName": "美国站",
    "countryCode": "US",
    "currencyCode": "USD",
    "region": "NorthAmerica",
    "lastVerifiedAtUtc": "2026-07-17T04:00:00Z",
    "authorizationProfileCount": 2,
    "capabilities": {
        "canReadListings": True,
        "canReadCatalog": True,
        "canReadPricing": True,
        "canCreateDraftChangeSets": True,
        "canSimulatePricing": True,
        "canWritePrices": False,
        "canWriteMfnInventory": False,
        "writeBlockReason": "Production validation is required before submission.",
        "verifiedAtUtc": "2026-07-17T04:00:00Z",
    },
}


def now_utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def catalog_response():
    return {
        "context": CONTEXT,
        "metrics": {
            "totalListings": 2,
            "activeListings": 2,
            "mfnListings": 1,
            "staleListings": 0,
            "lastSynchronizedAtUtc": now_utc(),
        },
        "items": [],
        "page": 1,
        "pageSize": 50,
        "totalItems": 0,
        "totalPages": 0,
        "generatedAtUtc": now_utc(),
    }


def pricing_run(payload):
    rule = payload["rule"]
    items = [
        {
            "id": "ITEM-001",
            "sku": "SKU-FBM-001",
            "asin": "B0V4FBM001",
            "title": "Carkee Cargo Organizer",
            "eligible": True,
            "exclusionCodes": [],
            "exclusionReasons": [],
            "currentPrice": 99.50,
            "targetPrice": 100.00,
            "priceChange": 0.50,
            "priceChangePercent": 0.5025,
            "currentBusinessPrice": 94.00,
            "targetBusinessPrice": 94.00,
            "currencyCode": "USD",
            "snapshotVersion": 12,
            "synchronizedAtUtc": now_utc(),
        },
        {
            "id": "ITEM-002",
            "sku": "SKU-FBA-002",
            "asin": "B0V4FBA002",
            "title": "Carkee Floor Mat",
            "eligible": False,
            "exclusionCodes": ["FBA_LISTING"],
            "exclusionReasons": ["该 SKU 为 FBA 配送，不属于纯 FBM 候选"],
            "currentPrice": 129.00,
            "targetPrice": None,
            "priceChange": None,
            "priceChangePercent": None,
            "currentBusinessPrice": None,
            "targetBusinessPrice": None,
            "currencyCode": "USD",
            "snapshotVersion": 12,
            "synchronizedAtUtc": now_utc(),
        },
    ]
    for index in range(3, 103):
        items.append({
            "id": f"ITEM-{index:03d}",
            "sku": f"SKU-FBA-{index:03d}",
            "asin": f"B0V4FBA{index:03d}",
            "title": f"Excluded FBA fixture {index:03d}",
            "eligible": False,
            "exclusionCodes": ["FBA_LISTING"],
            "exclusionReasons": ["该 SKU 为 FBA 配送，不属于纯 FBM 候选"],
            "currentPrice": 129.00,
            "targetPrice": None,
            "priceChange": None,
            "priceChangePercent": None,
            "currentBusinessPrice": None,
            "targetBusinessPrice": None,
            "currencyCode": "USD",
            "snapshotVersion": 12,
            "synchronizedAtUtc": now_utc(),
        })
    return {
        "id": "RUN-001",
        "runNumber": "PR-20260717-001",
        "sellerId": payload["sellerId"],
        "marketplaceId": payload["marketplaceId"],
        "status": "Draft",
        "initiatedBy": payload["initiator"],
        "createdAtUtc": now_utc(),
        "rule": {
            "id": "RULE-001",
            "version": 1,
            **rule,
            "currencyPrecision": 2,
        },
        "summary": {"total": len(items), "eligible": 1, "excluded": len(items) - 1},
        "items": items,
    }


def install_api_fixture(page: Page, captured):
    def handle(route: Route):
        request = route.request
        parsed = urlparse(request.url)
        path = parsed.path

        if path == "/api/v2/system/session":
            route.fulfill(json={"csrfToken": "playwright-csrf-token"})
            return
        if path == "/api/v2/system/health":
            healthy = {"status": "healthy", "detail": "Operational"}
            route.fulfill(json={
                "overallStatus": "healthy",
                "service": healthy,
                "database": healthy,
                "disk": healthy,
                "worker": healthy,
                "secretStore": healthy,
                "environment": "Playwright",
                "bindAddress": "127.0.0.1:5173",
                "dataRoot": "mock",
                "availableDiskBytes": 10_000_000_000,
                "checkedAtUtc": now_utc(),
            })
            return
        if path == "/api/v2/system/version":
            route.fulfill(json={
                "version": "4.0.0-test",
                "phase": "V4 API-native pricing",
                "framework": "ASP.NET Core",
                "databaseProvider": "PostgreSQL",
                "databaseSchema": "V4Pricing",
                "startedAtUtc": now_utc(),
            })
            return
        if path == "/api/v3/workspace/contexts":
            route.fulfill(json=[CONTEXT])
            return
        if path == "/api/v3/catalog/listings":
            route.fulfill(json=catalog_response())
            return
        if path == "/api/v4/pricing/sync-status":
            route.fulfill(json={
                "sellerId": CONTEXT["sellerId"],
                "marketplaceId": CONTEXT["marketplaceId"],
                "state": "SNAPSHOT_FRESH",
                "reportsExecutorAvailable": False,
                "canStart": True,
                "listingCount": 2,
                "snapshotVersion": 12,
                "lastSynchronizedAtUtc": now_utc(),
                "snapshotAgeSeconds": 30,
                "detail": "Fresh Amazon report snapshot is available.",
            })
            return
        if path == "/api/v4/pricing/runs" and request.method == "POST":
            payload = request.post_data_json
            captured["run"] = payload
            captured["csrf"].append(request.headers.get("x-klanata-csrf"))
            route.fulfill(status=201, json=pricing_run(payload))
            return
        if path == "/api/v4/pricing/runs/RUN-001/change-sets" and request.method == "POST":
            captured["change_set"] = request.post_data_json
            captured["csrf"].append(request.headers.get("x-klanata-csrf"))
            route.fulfill(status=201, json={
                "id": "CHANGE-001",
                "runId": "RUN-001",
                "sellerId": CONTEXT["sellerId"],
                "marketplaceId": CONTEXT["marketplaceId"],
                "status": "PendingApproval",
                "initiatedBy": "operator-a",
                "itemCount": 1,
                "createdAtUtc": now_utc(),
                "approval": None,
            })
            return
        if path == "/api/v4/pricing/change-sets/CHANGE-001/approve" and request.method == "POST":
            payload = request.post_data_json
            captured["approval"] = payload
            captured["csrf"].append(request.headers.get("x-klanata-csrf"))
            route.fulfill(json={
                "id": "CHANGE-001",
                "runId": "RUN-001",
                "sellerId": CONTEXT["sellerId"],
                "marketplaceId": CONTEXT["marketplaceId"],
                "status": "REVIEW_RECORDED",
                "initiatedBy": "operator-a",
                "itemCount": 1,
                "createdAtUtc": now_utc(),
                "approval": {
                    "approver": payload["approver"],
                    "approvedAtUtc": now_utc(),
                    "identityVerified": False,
                    "identityAssurance": "UNVERIFIED_LOCAL_LABEL",
                },
            })
            return
        if path == "/api/v4/pricing/change-sets/CHANGE-001/validate" and request.method == "POST":
            captured["validated"] = True
            captured["csrf"].append(request.headers.get("x-klanata-csrf"))
            route.fulfill(
                status=409,
                content_type="application/problem+json",
                body=json.dumps({
                    "type": "https://klanata.local/problems/live-validation-unavailable",
                    "title": "Amazon 实时校验不可用",
                    "status": 409,
                    "detail": "复核人身份未认证，且提交前最新价与自动调价状态尚未核验，生产提交已安全阻止。",
                    "code": "LIVE_VALIDATION_UNAVAILABLE",
                    "identityVerified": False,
                }, ensure_ascii=False),
            )
            return

        if path.startswith("/api/"):
            route.fulfill(status=404, json={"title": "Unexpected mocked API request", "detail": f"No fixture for {request.method} {path}"})
            return
        route.continue_()

    page.route("**/*", handle)


def assert_no_page_overflow(page: Page, label: str):
    dimensions = page.evaluate("""() => ({
        viewport: document.documentElement.clientWidth,
        document: document.documentElement.scrollWidth,
        body: document.body.scrollWidth,
        clippedContextText: [...document.querySelectorAll('.pricing-context-fact strong, .pricing-context-fact small')]
            .filter(element => {
                const style = getComputedStyle(element);
                return style.display !== 'none' && element.scrollWidth > element.clientWidth + 1;
            })
            .map(element => element.textContent.trim()),
    })""")
    assert dimensions["document"] <= dimensions["viewport"] + 1, f"{label}: document overflow {dimensions}"
    assert dimensions["body"] <= dimensions["viewport"] + 1, f"{label}: body overflow {dimensions}"
    assert not dimensions["clippedContextText"], f"{label}: clipped context text {dimensions['clippedContextText']}"


def run_pricing_flow(page: Page, label: str, screenshot_name: str):
    captured = {"run": None, "change_set": None, "approval": None, "validated": False, "csrf": []}
    errors = []
    expected_conflicts = []

    def capture_console(message):
        if message.type != "error":
            return
        if message.text == "Failed to load resource: the server responded with a status of 409 (Conflict)":
            expected_conflicts.append(message.text)
            return
        errors.append(f"console:{message.type}:{message.text}")

    page.on("console", capture_console)
    page.on("pageerror", lambda error: errors.append(f"pageerror:{error}"))
    install_api_fixture(page, captured)

    response = page.goto(f"{BASE_URL}/#pricing", wait_until="networkidle")
    assert response is not None and response.ok, f"{label}: application did not load"
    page.get_by_role("heading", name="智能调价", exact=True).wait_for()
    context_select = page.get_by_label("Carkee 站点")
    assert context_select.input_value() == "AC7OMGZBRADKF::ATVPDKIKX0DER"
    assert context_select.locator("option").count() == 1
    assert context_select.locator("option").inner_text() == "Carkee · 美国站"
    page.get_by_text("读取已验证", exact=True).wait_for()
    page.get_by_text("快照 v12", exact=True).wait_for()
    assert page.locator("input[type=file]").count() == 0, f"{label}: pricing flow still exposes a file input"

    page.get_by_role("button", name="使用当前快照继续").click()
    page.get_by_role("heading", name="自动筛选纯 FBM 候选").wait_for()
    page.get_by_text("提交门禁", exact=True).wait_for()
    page.get_by_role("button", name="配置调价规则").click()
    page.get_by_role("heading", name="配置版本化调价规则").wait_for()

    fields = page.locator(".rule-form > label.field")
    bands = page.locator(".rule-form > .band-rule")
    assert fields.nth(2).locator("input").input_value() == "100"
    assert bands.nth(0).locator("input").input_value() == "0.50"
    assert bands.nth(1).locator("input").input_value() == "0.50"
    assert fields.nth(3).locator("input").input_value() == "0.90"
    assert fields.nth(4).locator("input").input_value() == "5"
    page.get_by_text("小于等于 100", exact=True).wait_for()
    page.get_by_text("大于 100", exact=True).wait_for()
    page.get_by_text("企业价格策略").locator("..").get_by_text("不修改", exact=True).wait_for()
    fields.nth(1).locator("input").fill("operator-a")
    page.get_by_role("button", name="生成差异预览").click()

    page.wait_for_timeout(300)
    difference_heading = page.get_by_role("heading", name="逐 SKU 审核价格差异")
    if difference_heading.count() == 0:
        alerts = page.locator(".pricing-alert").all_inner_texts()
        raise AssertionError(f"{label}: difference review did not open; captured={captured}; alerts={alerts}; browser={errors}")
    difference_heading.wait_for()
    assert captured["run"] is not None, f"{label}: run request was not sent"
    assert page.get_by_label("Carkee 站点").is_disabled(), f"{label}: production context was not locked after run creation"
    for index in range(3):
        assert page.locator(".pricing-steps button").nth(index).is_disabled(), f"{label}: immutable run allowed navigation back to step {index + 1}"
    run_payload = captured["run"]
    assert run_payload["sellerId"] == CONTEXT["sellerId"]
    assert run_payload["marketplaceId"] == CONTEXT["marketplaceId"]
    assert run_payload["idempotencyKey"], f"{label}: stable run idempotency key was not sent"
    assert run_payload["rule"]["businessPriceStrategy"] == "UNCHANGED"
    assert run_payload["rule"]["belowThreshold"] == {"type": "FIXED_AMOUNT", "value": 0.5}
    assert run_payload["rule"]["atOrAboveThreshold"] == {"type": "PERCENTAGE", "value": 0.5}
    assert "currencyPrecision" not in run_payload["rule"]
    page.get_by_text("SKU-FBM-001", exact=True).wait_for()
    page.get_by_text("候选", exact=True).wait_for()
    page.get_by_text("SKU-FBA-002", exact=True).wait_for()
    page.get_by_text("该 SKU 为 FBA 配送，不属于纯 FBM 候选", exact=True).first.wait_for()
    page.get_by_text("报告快照价", exact=True).wait_for()
    page.get_by_text("第 1 / 2 页 · 共 102 条", exact=True).wait_for()
    page.get_by_role("button", name="下一页").click()
    page.get_by_text("SKU-FBA-102", exact=True).wait_for()
    page.get_by_role("button", name="上一页").click()
    page.get_by_text("SKU-FBM-001", exact=True).wait_for()
    page.get_by_role("button", name="创建待复核变更集").click()

    page.get_by_role("heading", name="记录异人复核后进入生产校验").wait_for()
    approval_input = page.locator(".approval-identity input")
    approval_input.fill("operator-a")
    page.get_by_text("复核人标签不能与发起人相同", exact=True).wait_for()
    approve_button = page.get_by_role("button", name="记录复核并进入校验")
    assert approve_button.is_disabled(), f"{label}: same person approval was not blocked"

    approval_input.fill("operator-b")
    checks = page.locator(".approval-checks input[type=checkbox]")
    assert checks.count() == 4
    for index in range(4):
        checks.nth(index).check()
    assert approve_button.is_enabled(), f"{label}: valid four-confirmation approval stayed disabled"
    approve_button.click()

    page.get_by_role("heading", name="验证 Amazon 最终结果").wait_for()
    assert captured["approval"] == {
        "approver": "operator-b",
        "confirmations": {
            "sellerMarketplace": True,
            "ruleVersion": True,
            "anomaliesReviewed": True,
            "amazonAcceptance": True,
        },
    }
    validate_button = page.get_by_role("button", name="执行生产校验")
    assert validate_button.is_enabled(), f"{label}: reviewed change set did not unlock validation"
    validate_button.click()
    page.get_by_text("LIVE_VALIDATION_UNAVAILABLE", exact=True).wait_for()
    page.get_by_role("heading", name="Amazon 实时校验不可用").wait_for()
    page.get_by_text("复核人身份未认证，且提交前最新价与自动调价状态尚未核验，生产提交已安全阻止。", exact=True).wait_for()
    page.get_by_text("尚未提交", exact=True).wait_for()
    page.get_by_text("尚未核验", exact=True).wait_for()
    assert captured["validated"], f"{label}: validation request was not sent"
    assert len(expected_conflicts) == 1, f"{label}: expected one browser network diagnostic for the mocked 409, got {expected_conflicts}"
    assert captured["csrf"] and all(token == "playwright-csrf-token" for token in captured["csrf"]), f"{label}: CSRF header missing from a V4 POST"

    assert_no_page_overflow(page, label)
    context_rail = page.locator(".pricing-context")
    original_position = context_rail.evaluate("element => element.style.position")
    context_rail.evaluate("element => { element.style.position = 'static'; }")
    page.screenshot(path=str(OUTPUT / screenshot_name), full_page=True)
    context_rail.evaluate("(element, value) => { element.style.position = value; }", original_position)
    page.get_by_role("button", name="新建任务").click()
    assert page.get_by_label("Carkee 站点").is_enabled(), f"{label}: new task did not release the context lock"
    page.get_by_role("heading", name="自动筛选纯 FBM 候选").wait_for()
    page.get_by_role("button", name="配置调价规则").click()
    page.get_by_role("button", name="生成差异预览").click()
    page.get_by_role("heading", name="逐 SKU 审核价格差异").wait_for()
    page.get_by_role("button", name="创建待复核变更集").click()
    page.get_by_role("heading", name="记录异人复核后进入生产校验").wait_for()
    assert page.locator(".approval-identity input").input_value() == "", f"{label}: new task inherited the previous reviewer"
    reset_checks = page.locator(".approval-checks input[type=checkbox]")
    assert reset_checks.count() == 4 and all(not reset_checks.nth(index).is_checked() for index in range(4)), f"{label}: new task inherited previous review confirmations"
    assert not errors, f"{label}: browser errors:\n" + "\n".join(errors)
    return {
        "viewport": label,
        "screenshot": str(OUTPUT / screenshot_name),
        "v4Posts": len(captured["csrf"]),
        "validation": "LIVE_VALIDATION_UNAVAILABLE",
    }


def main():
    results = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            desktop = browser.new_page(viewport={"width": 1440, "height": 1000})
            results.append(run_pricing_flow(desktop, "desktop-1440", "v4-pricing-desktop.png"))
            desktop.close()

            mobile = browser.new_page(viewport={"width": 390, "height": 844})
            results.append(run_pricing_flow(mobile, "mobile-390", "v4-pricing-mobile.png"))
            mobile.close()

            small_mobile = browser.new_page(viewport={"width": 375, "height": 812})
            results.append(run_pricing_flow(small_mobile, "mobile-375", "v4-pricing-small-mobile.png"))
            small_mobile.close()
        finally:
            browser.close()

    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
