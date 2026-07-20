import json
import os
from pathlib import Path

from playwright.sync_api import sync_playwright


base_url = os.environ.get("KLANATA_PRODUCTION_URL", "https://www.klanata.com").rstrip("/")
output = Path(__file__).resolve().parents[1] / "output" / "production-simplified-workspace.png"
mobile_output = Path(__file__).resolve().parents[1] / "output" / "production-oauth-mobile.png"

with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 1000})
    errors = []
    page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
    page.on("pageerror", lambda error: errors.append(str(error)))

    response = page.goto(f"{base_url}/#workspace", wait_until="networkidle")
    assert response is not None and response.ok
    status = page.evaluate("async () => (await fetch('/api/status')).json()")
    workflow = page.evaluate("async () => (await fetch('/api/workflow/current')).json()")
    sessions = workflow.get("authSessions") or []
    assert status.get("allowedAmazonStoreName") == "Carkee"
    assert len(sessions) == 2
    assert all(session.get("storeAllowed") is True for session in sessions)
    assert all(session.get("verifiedStoreName") == "Carkee" for session in sessions)
    assert all(session.get("sellerId") == "AC7OMGZBRADKF" for session in sessions)
    assert page.locator("#system-version").inner_text() == "1.5"
    assert page.locator("#drop-title").inner_text() == "选择 Amazon 价格与库存模板"
    assert page.locator("#seller-id").get_attribute("type") == "hidden"
    assert page.locator("#marketplace-select").is_enabled()
    assert page.locator("#marketplace-select option").count() == 5
    upload_options = page.locator("#marketplace-select option").all_inner_texts()
    assert all("Carkee" in option for option in upload_options[1:])
    assert all("Invoicing_" not in option for option in upload_options)
    assert page.locator("#marketplace-select").input_value() == ""
    assert page.locator("#view-workspace .workflow-step").count() == 3
    assert page.locator('[data-workflow-step="auth"]').count() == 0
    assert page.locator("#validate-account-button").count() == 0

    legacy_pricing_nav = page.locator("#legacy-pricing-nav")
    assert legacy_pricing_nav.is_hidden()
    page.goto(f"{base_url}/?pricing-probe=1#pricing", wait_until="networkidle")
    assert page.url.endswith("#workspace")
    assert page.locator("#view-pricing").is_hidden()
    page.goto(f"{base_url}/#workspace", wait_until="networkidle")

    page.locator('[data-view-target="settings"]').click()
    page.wait_for_url("**/#settings")
    assert page.locator("#developer-app-status").inner_text() == "凭证已保存，待补 Application ID"
    assert page.locator("#oauth-auth-button-label").inner_text() == "等待管理员配置"
    assert page.locator("#oauth-auth-button").is_disabled()
    assert page.locator("#admin-application-settings").is_hidden()
    assert page.locator("details.legacy-auth-settings").is_hidden()
    assert not page.locator("#admin-application-settings").evaluate("node => node.open")
    assert not page.locator("details.legacy-auth-settings").evaluate("node => node.open")
    assert not page.locator("#auth-seller-id").is_visible()
    assert not page.locator("#refresh-token").is_visible()
    accounts = page.locator("#authorized-accounts .authorized-account")
    assert accounts.count() == 1
    assert "AC7O…ADKF" in accounts.first.inner_text()
    assert "AC7OMGZBRADKF" not in accounts.first.inner_text()
    assert "2 个授权" in accounts.first.inner_text()
    assert "Carkee" in accounts.first.inner_text()
    assert "Invoicing_" not in accounts.first.inner_text()
    assert page.locator("#authorized-accounts .site-chip").count() == 4
    page_text = page.locator("body").inner_text()
    assert "Atzr|" not in page_text
    assert "oa2-cs" not in page_text
    page.screenshot(path=output, full_page=True)

    assert not errors, errors
    mobile = browser.new_page(viewport={"width": 390, "height": 844})
    mobile_errors = []
    mobile.on("console", lambda message: mobile_errors.append(message.text) if message.type == "error" else None)
    mobile.on("pageerror", lambda error: mobile_errors.append(str(error)))
    mobile_response = mobile.goto(f"{base_url}/#settings", wait_until="networkidle")
    assert mobile_response is not None and mobile_response.ok
    assert mobile.locator("#oauth-auth-button-label").inner_text() == "等待管理员配置"
    assert mobile.locator("#oauth-auth-button").is_disabled()
    assert mobile.locator("#authorized-accounts .site-chip").count() == 4
    assert mobile.evaluate(
        "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
    )
    mobile.screenshot(path=mobile_output, full_page=True)
    assert not mobile_errors, mobile_errors
    mobile.close()
    browser.close()

print(json.dumps({"url": base_url, "sellerId": "AC7O…ADKF", "stores": 1, "authorizedProfiles": 2, "marketplaces": 4}, ensure_ascii=False))
