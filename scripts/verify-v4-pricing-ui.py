import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import Page, Route, sync_playwright


DEFAULT_BASE_URL = os.environ.get("KLANATA_UI_URL", "http://127.0.0.1:5173").rstrip("/")
DEFAULT_LIVE_EMPTY_CONTEXTS_URL = os.environ.get("KLANATA_LIVE_EMPTY_CONTEXTS_URL", "").rstrip("/")
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output"
OUTPUT.mkdir(exist_ok=True)

MIN_VISIBLE_TEXT_PX = 12
MIN_FORM_TEXT_PX = 13
MIN_MOBILE_TARGET_PX = 44

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
        "canWritePrices": True,
        "canWriteMfnInventory": False,
        "writeBlockReason": "",
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


def assert_typography(page: Page, label: str):
    issues = page.evaluate(
        """({ minimumText, minimumFormText }) => {
            const visible = (element) => {
                const style = getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.display !== 'none'
                    && style.visibility !== 'hidden'
                    && Number.parseFloat(style.opacity || '1') > 0
                    && rect.width > 0
                    && rect.height > 0;
            };
            const describe = (element) => {
                const id = element.id ? `#${element.id}` : '';
                const classes = [...element.classList].slice(0, 3).map(value => `.${value}`).join('');
                return `${element.tagName.toLowerCase()}${id}${classes}`;
            };
            const failures = [];
            const elements = [...document.querySelectorAll('body *')];
            for (const element of elements) {
                if (!visible(element) || element.closest('svg, script, style, noscript')) continue;
                const ownsText = [...element.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim());
                if (!ownsText) continue;
                const style = getComputedStyle(element);
                const size = Number.parseFloat(style.fontSize);
                const formText = Boolean(element.closest('button')) && !element.matches('.step-index');
                const minimum = formText ? minimumFormText : minimumText;
                if (Number.isFinite(size) && size + 0.01 < minimum) {
                    failures.push({
                        element: describe(element),
                        text: element.textContent.trim().replace(/\\s+/g, ' ').slice(0, 80),
                        actual: size,
                        minimum,
                    });
                }
            }
            for (const element of document.querySelectorAll('input, select, textarea')) {
                if (!visible(element)) continue;
                const type = (element.getAttribute('type') || '').toLowerCase();
                if (type === 'checkbox' || type === 'radio') continue;
                const size = Number.parseFloat(getComputedStyle(element).fontSize);
                if (Number.isFinite(size) && size + 0.01 < minimumFormText) {
                    failures.push({ element: describe(element), text: element.getAttribute('aria-label') || element.value || '', actual: size, minimum: minimumFormText });
                }
            }
            return failures.slice(0, 25);
        }""",
        {"minimumText": MIN_VISIBLE_TEXT_PX, "minimumFormText": MIN_FORM_TEXT_PX},
    )
    assert not issues, f"{label}: text below production minimum: {json.dumps(issues, ensure_ascii=False)}"


def assert_no_unexpected_overflow(page: Page, label: str):
    result = page.evaluate("""() => {
        const visible = (element) => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
        };
        const describe = (element) => {
            const id = element.id ? `#${element.id}` : '';
            const classes = [...element.classList].slice(0, 3).map(value => `.${value}`).join('');
            return `${element.tagName.toLowerCase()}${id}${classes}`;
        };
        const issues = [];
        const elements = [document.documentElement, document.body, ...document.querySelectorAll('.app-shell *')];
        for (const element of elements) {
            if (element !== document.documentElement && element !== document.body && !visible(element)) continue;
            if (element.matches('svg, path, circle, line, polyline, polygon, option, input, select, textarea')) continue;
            const style = getComputedStyle(element);
            const horizontalOverflow = element.scrollWidth > element.clientWidth + 1;
            const verticalOverflow = element.scrollHeight > element.clientHeight + 1;
            const scrollsX = style.overflowX === 'auto' || style.overflowX === 'scroll';
            const scrollsY = style.overflowY === 'auto' || style.overflowY === 'scroll';
            const intentionalEllipsis = style.textOverflow === 'ellipsis'
                || Number.parseInt(style.webkitLineClamp || '0', 10) > 0;
            if (horizontalOverflow && !scrollsX && !intentionalEllipsis) {
                issues.push({ axis: 'x', element: describe(element), client: element.clientWidth, scroll: element.scrollWidth, overflow: style.overflowX });
            }
            if (verticalOverflow && !scrollsY && (style.overflowY === 'hidden' || style.overflowY === 'clip')) {
                issues.push({ axis: 'y', element: describe(element), client: element.clientHeight, scroll: element.scrollHeight, overflow: style.overflowY });
            }
        }
        return {
            viewport: document.documentElement.clientWidth,
            documentWidth: document.documentElement.scrollWidth,
            bodyWidth: document.body.scrollWidth,
            issues: issues.slice(0, 25),
        };
    }""")
    assert result["documentWidth"] <= result["viewport"] + 1, f"{label}: document overflow {result}"
    assert result["bodyWidth"] <= result["viewport"] + 1, f"{label}: body overflow {result}"
    assert not result["issues"], f"{label}: unexpected internal overflow: {json.dumps(result['issues'], ensure_ascii=False)}"


def assert_mobile_targets(page: Page, label: str, mobile: bool):
    if not mobile:
        return
    issues = page.evaluate(
        """minimum => {
            const visible = (element) => {
                const style = getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
            };
            const describe = (element) => {
                const id = element.id ? `#${element.id}` : '';
                const classes = [...element.classList].slice(0, 3).map(value => `.${value}`).join('');
                return `${element.tagName.toLowerCase()}${id}${classes}`;
            };
            const failures = [];
            for (const control of document.querySelectorAll('button, a[href], input, select, textarea, [role="button"]')) {
                if (!visible(control)) continue;
                const type = (control.getAttribute('type') || '').toLowerCase();
                const target = (type === 'checkbox' || type === 'radio') ? control.closest('label') : control;
                if (!target || !visible(target)) continue;
                const rect = target.getBoundingClientRect();
                if (rect.height + 0.5 < minimum) {
                    failures.push({
                        element: describe(control),
                        target: describe(target),
                        text: (control.getAttribute('aria-label') || control.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 60),
                        height: Math.round(rect.height * 100) / 100,
                        minimum,
                    });
                }
            }
            return failures.slice(0, 25);
        }""",
        MIN_MOBILE_TARGET_PX,
    )
    assert not issues, f"{label}: mobile target below {MIN_MOBILE_TARGET_PX}px: {json.dumps(issues, ensure_ascii=False)}"


def assert_fixed_navigation_clear(page: Page, label: str):
    page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight)")
    page.wait_for_timeout(50)
    result = page.evaluate("""() => {
        const sidebar = document.querySelector('.mobile-navigation');
        const main = document.querySelector('.pricing-main');
        if (!sidebar || !main || getComputedStyle(sidebar).position !== 'fixed') return null;
        const navRect = sidebar.getBoundingClientRect();
        const mainRect = main.getBoundingClientRect();
        const candidates = [...document.querySelectorAll('.pricing-stage button, .pricing-stage input, .pricing-stage select')]
            .filter(element => {
                const style = getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
            });
        const target = candidates.at(-1);
        const targetRect = target?.getBoundingClientRect();
        const centerX = targetRect ? Math.min(innerWidth - 1, Math.max(0, targetRect.left + targetRect.width / 2)) : 0;
        const centerY = targetRect ? Math.min(innerHeight - 1, Math.max(0, targetRect.top + targetRect.height / 2)) : 0;
        const hit = targetRect ? document.elementFromPoint(centerX, centerY) : null;
        return {
            navTop: navRect.top,
            mainBottom: mainRect.bottom,
            targetBottom: targetRect?.bottom,
            targetText: (target?.getAttribute('aria-label') || target?.textContent || '').trim(),
            targetHit: !target || !hit || target === hit || target.contains(hit),
        };
    }""")
    page.evaluate("window.scrollTo(0, 0)")
    if result is None:
        return
    assert result["mainBottom"] <= result["navTop"] + 2, f"{label}: fixed navigation covers main content {result}"
    assert result["targetBottom"] is None or result["targetBottom"] <= result["navTop"] + 2, f"{label}: fixed navigation covers the final control {result}"
    assert result["targetHit"], f"{label}: fixed navigation intercepts the final control {result}"


def assert_keyboard_focus_visible(page: Page, label: str):
    page.evaluate("""() => {
        window.scrollTo(0, 0);
        if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
    }""")
    page.keyboard.press("Tab")
    result = page.evaluate("""() => {
        const element = document.activeElement;
        if (!(element instanceof HTMLElement) || element === document.body) return null;
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
        return {
            element: `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ''}`,
            text: (element.getAttribute('aria-label') || element.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 80),
            outlineStyle: style.outlineStyle,
            outlineWidth: Number.parseFloat(style.outlineWidth || '0'),
            boxShadow: style.boxShadow,
            inViewport: rect.top >= 0 && rect.left >= 0 && rect.bottom <= innerHeight && rect.right <= innerWidth,
            hit: Boolean(hit && (hit === element || element.contains(hit))),
        };
    }""")
    assert result is not None, f"{label}: Tab did not reach an interactive element"
    has_focus_style = (
        result["outlineStyle"] not in ("none", "hidden") and result["outlineWidth"] >= 1
    ) or result["boxShadow"] != "none"
    assert has_focus_style, f"{label}: keyboard focus is not visibly styled {result}"
    assert result["inViewport"] and result["hit"], f"{label}: focused control is clipped or covered {result}"
    page.evaluate("document.activeElement instanceof HTMLElement && document.activeElement.blur()")


def assert_production_layout(page: Page, label: str, mobile: bool):
    assert_typography(page, label)
    assert_no_unexpected_overflow(page, label)
    assert_mobile_targets(page, label, mobile)
    assert_fixed_navigation_clear(page, label)


def capture_request_failure(errors, request):
    failure = request.failure or "unknown"
    if request.method == "GET" and failure == "net::ERR_ABORTED":
        return
    errors.append(f"requestfailed:{request.method}:{request.url}:{failure}")


def run_pricing_flow(page: Page, base_url: str, label: str, screenshot_name: str, mobile: bool):
    captured = {"run": None, "change_set": None, "approval": None, "validated": False, "csrf": []}
    errors = []
    expected_conflicts = []

    def capture_console(message):
        if message.type not in ("error", "warning"):
            return
        if message.type == "error" and "409" in message.text:
            return
        errors.append(f"console:{message.type}:{message.text}")

    page.on("console", capture_console)
    page.on("pageerror", lambda error: errors.append(f"pageerror:{error}"))
    page.on("requestfailed", lambda request: capture_request_failure(errors, request))

    def capture_response(response):
        if response.status < 400:
            return
        path = urlparse(response.url).path
        if response.status == 409 and path == "/api/v4/pricing/change-sets/CHANGE-001/validate":
            expected_conflicts.append(f"{response.status}:{path}")
            return
        errors.append(f"response:{response.status}:{response.request.method}:{path}")

    page.on("response", capture_response)
    install_api_fixture(page, captured)

    response = page.goto(f"{base_url}/#pricing", wait_until="networkidle")
    assert response is not None and response.ok, f"{label}: application did not load"
    page.get_by_role("heading", name="智能调价工作台", exact=True).wait_for()
    context_select = page.get_by_label("Carkee 站点")
    assert context_select.input_value() == "AC7OMGZBRADKF::ATVPDKIKX0DER"
    assert context_select.locator("option").count() == 1
    assert context_select.locator("option").inner_text() == "Carkee · 美国站"
    page.get_by_text("读取已验证", exact=True).wait_for()
    page.get_by_text("快照 v12", exact=True).wait_for()
    assert page.locator("input[type=file]").count() == 0, f"{label}: pricing flow still exposes a file input"
    sync_button = page.locator(".sync-panel .primary-action")
    assert sync_button.count() == 1 and sync_button.is_disabled(), f"{label}: unavailable Reports executor did not disable synchronization"
    assert_keyboard_focus_visible(page, f"{label}:keyboard")
    assert_production_layout(page, f"{label}:step-1", mobile)

    page.get_by_role("button", name="使用当前快照继续").click()
    page.get_by_role("heading", name="自动筛选纯 FBM 候选").wait_for()
    page.get_by_text("提交门禁", exact=True).wait_for()
    assert_production_layout(page, f"{label}:step-2", mobile)
    page.get_by_role("button", name="配置调价规则").click()
    page.get_by_role("heading", name="配置版本化调价规则").wait_for()
    assert_production_layout(page, f"{label}:step-3", mobile)

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
    assert_production_layout(page, f"{label}:step-4", mobile)
    page.get_by_role("button", name="创建待复核变更集").click()

    page.get_by_role("heading", name="记录异人复核草稿").wait_for()
    assert_production_layout(page, f"{label}:step-5", mobile)
    approval_input = page.locator(".approval-identity input")
    approval_input.fill("operator-a")
    page.get_by_text("复核人标签不能与发起人相同", exact=True).wait_for()
    approve_button = page.get_by_role("button", name="记录复核草稿")
    assert approve_button.is_disabled(), f"{label}: same person approval was not blocked"

    approval_input.fill("operator-b")
    checks = page.locator(".approval-checks input[type=checkbox]")
    assert checks.count() == 4
    for index in range(4):
        checks.nth(index).check()
    assert approve_button.is_enabled(), f"{label}: valid four-confirmation approval stayed disabled"
    approve_button.click()

    page.get_by_role("heading", name="检查生产就绪状态").wait_for()
    assert captured["approval"] == {
        "approver": "operator-b",
        "confirmations": {
            "sellerMarketplace": True,
            "ruleVersion": True,
            "anomaliesReviewed": True,
            "amazonAcceptance": True,
        },
    }
    validate_button = page.get_by_role("button", name="检查生产就绪条件")
    assert validate_button.is_enabled(), f"{label}: reviewed change set did not unlock validation"
    validate_button.click()
    page.get_by_text("LIVE_VALIDATION_UNAVAILABLE", exact=True).wait_for()
    page.get_by_role("heading", name="Amazon 实时校验不可用").wait_for()
    page.get_by_text("复核人身份未认证，且提交前最新价与自动调价状态尚未核验，生产提交已安全阻止。", exact=True).wait_for()
    assert page.get_by_text("未接通", exact=True).count() >= 2
    assert captured["validated"], f"{label}: validation request was not sent"
    assert len(expected_conflicts) == 1, f"{label}: expected one browser network diagnostic for the mocked 409, got {expected_conflicts}"
    assert captured["csrf"] and all(token == "playwright-csrf-token" for token in captured["csrf"]), f"{label}: CSRF header missing from a V4 POST"

    assert_production_layout(page, f"{label}:step-6", mobile)
    page.screenshot(path=str(OUTPUT / screenshot_name), full_page=True)
    page.get_by_role("button", name="新建任务").click()
    assert page.get_by_label("Carkee 站点").is_enabled(), f"{label}: new task did not release the context lock"
    page.get_by_role("heading", name="自动筛选纯 FBM 候选").wait_for()
    page.get_by_role("button", name="配置调价规则").click()
    page.get_by_role("button", name="生成差异预览").click()
    page.get_by_role("heading", name="逐 SKU 审核价格差异").wait_for()
    page.get_by_role("button", name="创建待复核变更集").click()
    page.get_by_role("heading", name="记录异人复核草稿").wait_for()
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


def run_live_empty_context_smoke(browser, base_url: str):
    label = "live-empty-contexts"
    page = browser.new_page(
        viewport={"width": 390, "height": 844},
        is_mobile=True,
        has_touch=True,
    )
    browser_errors = []
    unsafe_requests = []

    def capture_request(request):
        if urlparse(request.url).path.startswith("/api/") and request.method not in ("GET", "HEAD", "OPTIONS"):
            unsafe_requests.append(f"{request.method}:{urlparse(request.url).path}")

    def capture_response(response):
        if response.status >= 400:
            browser_errors.append(f"response:{response.status}:{response.request.method}:{urlparse(response.url).path}")

    page.on("request", capture_request)
    page.on("response", capture_response)
    page.on("requestfailed", lambda request: capture_request_failure(browser_errors, request))
    page.on("pageerror", lambda error: browser_errors.append(f"pageerror:{error}"))
    page.on("console", lambda message: browser_errors.append(f"console:{message.type}:{message.text}") if message.type in ("error", "warning") else None)

    try:
        response = page.goto(f"{base_url}/#pricing", wait_until="networkidle")
        assert response is not None and response.ok, f"{label}: application did not load"

        contexts_response = page.request.get(f"{base_url}/api/v3/workspace/contexts")
        assert contexts_response.ok, f"{label}: contexts endpoint returned HTTP {contexts_response.status}"
        contexts = contexts_response.json()
        assert isinstance(contexts, list) and not contexts, f"{label}: expected a real empty contexts response, got {contexts}"

        page.get_by_role("heading", name="智能调价工作台", exact=True).wait_for()
        context_select = page.get_by_label("Carkee 站点")
        assert context_select.is_disabled(), f"{label}: empty context selector stayed enabled"
        assert context_select.locator("option").count() == 1
        assert context_select.locator("option").inner_text() == "Carkee 尚未连接"
        page.get_by_role("heading", name="连接 Carkee 后开始调价", exact=True).wait_for()
        page.get_by_text("当前不可执行", exact=True).wait_for()
        page.get_by_text("商品同步、规则模拟、差异复核和 Amazon 价格写入", exact=True).wait_for()
        page.get_by_role("button", name="打开系统设置", exact=True).wait_for()
        page.get_by_role("button", name="重新加载", exact=True).wait_for()
        assert page.locator(".pricing-steps").count() == 0, f"{label}: six-step controls were exposed without an authorization context"
        assert page.locator(".sync-panel").count() == 0, f"{label}: synchronization controls were exposed without an authorization context"
        assert page.locator("input[type=file]").count() == 0, f"{label}: pricing flow exposes a file input"
        assert not unsafe_requests, f"{label}: read-only smoke emitted unsafe requests {unsafe_requests}"

        assert_keyboard_focus_visible(page, f"{label}:keyboard")
        assert_production_layout(page, label, mobile=True)
        assert not browser_errors, f"{label}: browser diagnostics:\n" + "\n".join(browser_errors)
        return {
            "smoke": label,
            "url": base_url,
            "contexts": 0,
            "unsafeRequests": 0,
            "writeState": "LOCKED",
        }
    finally:
        page.close()


def parse_args():
    parser = argparse.ArgumentParser(description="Verify the V4 pricing UI and its production-safe empty-context state.")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="UI origin used for deterministic mocked pricing flows.")
    parser.add_argument(
        "--live-empty-contexts-url",
        default=DEFAULT_LIVE_EMPTY_CONTEXTS_URL,
        help="Optional unmocked UI origin whose /api/v3/workspace/contexts response must be empty.",
    )
    parser.add_argument("--live-empty-only", action="store_true", help="Run only the unmocked empty-context smoke.")
    args = parser.parse_args()
    args.base_url = args.base_url.rstrip("/")
    args.live_empty_contexts_url = args.live_empty_contexts_url.rstrip("/")
    if args.live_empty_only and not args.live_empty_contexts_url:
        parser.error("--live-empty-only requires --live-empty-contexts-url or KLANATA_LIVE_EMPTY_CONTEXTS_URL")
    return args


def main():
    args = parse_args()
    results = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            if not args.live_empty_only:
                viewports = [
                    ("desktop-1440", 1440, 1000, "v4-pricing-desktop.png"),
                    ("desktop-1024", 1024, 768, "v4-pricing-1024.png"),
                    ("breakpoint-820", 820, 900, "v4-pricing-820.png"),
                    ("mobile-390", 390, 844, "v4-pricing-mobile.png"),
                    ("mobile-320", 320, 720, "v4-pricing-320.png"),
                ]
                for label, width, height, screenshot_name in viewports:
                    mobile = width <= 820
                    page = browser.new_page(
                        viewport={"width": width, "height": height},
                        is_mobile=mobile,
                        has_touch=mobile,
                    )
                    try:
                        results.append(run_pricing_flow(page, args.base_url, label, screenshot_name, mobile))
                    finally:
                        page.close()

            if args.live_empty_contexts_url:
                results.append(run_live_empty_context_smoke(browser, args.live_empty_contexts_url))
        finally:
            browser.close()

    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
