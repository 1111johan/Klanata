import json
import os
from pathlib import Path

from playwright.sync_api import sync_playwright


base_url = os.environ.get("KLANATA_UI_URL", "http://127.0.0.1:4322").rstrip("/")
root = Path(__file__).resolve().parents[1]
output_dir = root / "output"
output_dir.mkdir(exist_ok=True)

views = {
    "workspace": "商品上传",
    "pricing": "智能调价工作站",
    "jobs": "任务记录",
    "settings": "设置",
}
viewports = [
    ("desktop", {"width": 1440, "height": 1000}, None),
    ("tablet", {"width": 768, "height": 1024}, None),
    ("mobile", {"width": 390, "height": 844}, None),
    ("small-mobile", {"width": 375, "height": 812}, None),
    ("landscape", {"width": 844, "height": 390}, None),
    ("reduced-motion", {"width": 390, "height": 844}, "reduce"),
]
results = []


def wait_for_view(page, view):
    locator = page.locator(f"#view-{view}")
    locator.wait_for(state="visible")
    locator.evaluate(
        "element => Promise.all(element.getAnimations().map(animation => animation.finished))"
    )


def audit_rendered_page(page, label):
    audit = page.evaluate(
        """() => {
            const visible = element => {
                const style = getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
            };
            const controls = [...document.querySelectorAll('button, a.nav-item, input, select')]
                .filter(element => visible(element) && !element.classList.contains('sr-only'));
            const smallTargets = controls.flatMap(element => {
                const target = element.matches('input[type="checkbox"]') ? element.closest('label') : element;
                const rect = target.getBoundingClientRect();
                return rect.width + 0.5 < 44 || rect.height + 0.5 < 44
                    ? [`${element.tagName.toLowerCase()}#${element.id || element.className}:${Math.round(rect.width)}x${Math.round(rect.height)}`]
                    : [];
            });
            const unnamedControls = [...document.querySelectorAll('input, select')]
                .filter(element => element.type !== 'hidden' && !element.name)
                .map(element => element.id || element.outerHTML.slice(0, 80));
            const unlabeledControls = [...document.querySelectorAll('input, select')]
                .filter(element => element.type !== 'hidden'
                    && !element.closest('label')
                    && !element.getAttribute('aria-label')
                    && !(element.id && document.querySelector(`label[for="${CSS.escape(element.id)}"]`)))
                .map(element => element.id || element.outerHTML.slice(0, 80));
            const unlabeledIconButtons = [...document.querySelectorAll('button')]
                .filter(element => visible(element) && !element.textContent.trim() && !element.getAttribute('aria-label'))
                .map(element => element.id || element.outerHTML.slice(0, 80));
            const clippedNavigation = [...document.querySelectorAll('.nav-item > span:nth-child(2)')]
                .filter(element => element.scrollWidth > element.clientWidth + 1)
                .map(element => element.textContent.trim());
            const visibleViews = [...document.querySelectorAll('.view')]
                .filter(visible)
                .map(element => element.dataset.view);
            return {
                viewportWidth: document.documentElement.clientWidth,
                pageWidth: document.documentElement.scrollWidth,
                smallTargets,
                unnamedControls,
                unlabeledControls,
                unlabeledIconButtons,
                clippedNavigation,
                visibleViews,
            };
        }"""
    )
    assert audit["pageWidth"] <= audit["viewportWidth"] + 1, (
        f"{label}: horizontal overflow {audit['pageWidth']} > {audit['viewportWidth']}"
    )
    assert not audit["smallTargets"], f"{label}: targets below 44px: {audit['smallTargets']}"
    assert not audit["unnamedControls"], f"{label}: unnamed controls: {audit['unnamedControls']}"
    assert not audit["unlabeledControls"], f"{label}: unlabeled controls: {audit['unlabeledControls']}"
    assert not audit["unlabeledIconButtons"], (
        f"{label}: unlabeled icon buttons: {audit['unlabeledIconButtons']}"
    )
    assert not audit["clippedNavigation"], f"{label}: clipped navigation: {audit['clippedNavigation']}"
    assert len(audit["visibleViews"]) == 1, f"{label}: visible views: {audit['visibleViews']}"
    return audit


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    try:
        for viewport_name, viewport, reduced_motion in viewports:
            page = browser.new_page(viewport=viewport)
            if reduced_motion:
                page.emulate_media(reduced_motion=reduced_motion)
            console_errors = []
            failed_requests = []
            page.on(
                "console",
                lambda message, errors=console_errors: errors.append(message.text)
                if message.type == "error"
                else None,
            )
            page.on(
                "requestfailed",
                lambda request, failures=failed_requests: failures.append(
                    f"{request.method} {request.url}: {request.failure}"
                ),
            )

            response = page.goto(f"{base_url}/#workspace", wait_until="networkidle")
            assert response is not None and response.ok, f"{viewport_name}: page did not load"
            assert page.locator("#system-version").inner_text() in {"1.3", "1.4", "1.5"}

            for view, heading in views.items():
                page.locator(f'[data-view-target="{view}"]').click()
                page.wait_for_url(f"**/#{view}")
                wait_for_view(page, view)
                page.wait_for_load_state("networkidle")
                label = f"{viewport_name}/{view}"
                audit = audit_rendered_page(page, label)

                assert page.locator("#page-title").inner_text() == heading
                assert page.locator(f'[data-view-target="{view}"]').get_attribute("aria-current") == "page"
                assert page.title() == f"{heading} · Klanata"
                if view == "pricing":
                    assert page.locator("#pricing-approval-button").is_disabled()
                    assert page.locator("#pricing-run-button").is_disabled()
                    assert page.locator("#pricing-marketplace-select").is_disabled()
                if reduced_motion:
                    animation_count = page.locator(f"#view-{view}").evaluate(
                        "element => element.getAnimations().length"
                    )
                    assert animation_count == 0, f"{label}: reduced motion still animates"

                screenshot = None
                if viewport_name in {"desktop", "mobile"}:
                    screenshot = output_dir / f"ui-{view}-{viewport_name}.png"
                    page.screenshot(path=str(screenshot), full_page=True)

                results.append(
                    {
                        "viewport": viewport_name,
                        "view": view,
                        "pageWidth": audit["pageWidth"],
                        "screenshot": str(screenshot) if screenshot else None,
                    }
                )

            page.goto(f"{base_url}/#workspace", wait_until="networkidle")
            page.locator('[data-view-target="pricing"]').click()
            page.wait_for_url("**/#pricing")
            page.go_back(wait_until="networkidle")
            wait_for_view(page, "workspace")
            assert page.url.endswith("/#workspace"), f"{viewport_name}: browser back did not restore view"

            if viewport_name == "desktop":
                page.goto(f"{base_url}/#workspace", wait_until="networkidle")
                page.locator(".skip-link").focus()
                assert page.locator(".skip-link").evaluate("element => element === document.activeElement")
                page.locator(".skip-link").evaluate(
                    "element => Promise.all(element.getAnimations().map(animation => animation.finished))"
                )
                skip_box = page.locator(".skip-link").bounding_box()
                assert skip_box and skip_box["y"] >= 0, "desktop: focused skip link is not visible"
                page.locator(".skip-link").press("Enter")
                assert page.locator("#main-content").evaluate("element => element === document.activeElement")

            assert not console_errors, f"{viewport_name}: console errors: {console_errors}"
            assert not failed_requests, f"{viewport_name}: failed requests: {failed_requests}"
            page.close()
    finally:
        browser.close()

print(json.dumps(results, ensure_ascii=False, indent=2))
