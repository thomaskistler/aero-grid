# SPDX-License-Identifier: GPL-2.0-only

import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[1]
PAGES = ("developer-guide/build/", "panels/metric/", "reference-guide/yaml/",
         "user-guide/model-settings/", "panels/chart/", "panels/flight-counter/",
         "panels/navigation/", "panels/service-probe/")


class DocumentationLayoutTests(unittest.TestCase):
    def test_installer_developer_release_checkbox_is_opt_in_and_keyboard_accessible(self):
        release_root = "https://github.com/thomaskistler/aero-grid/releases"
        developer_version = "0.4.0-dev.12+g" + "a" * 40
        stable_version = "0.4.0"
        versions = (stable_version, developer_version)
        catalog = {"schema": 1, "latest": stable_version, "releases": [
            {"version": version, "name": "Stable" if version == stable_version else "Developer build",
             "release": f"{release_root}/tag/{'v' + version if version == stable_version else 'dev'}",
             "available": True, "reason": None}
            for version in versions
        ]}

        def release_response(route):
            version = developer_version if route.request.url.endswith("/dev") else stable_version
            tag = "dev" if version == developer_version else "v" + version
            archive = "AeroGrid-dev.zip" if tag == "dev" else f"AeroGrid-{version}.zip"
            route.fulfill(json={
                "tag_name": tag, "draft": False, "prerelease": tag == "dev",
                "name": f"AeroGrid {version} (developer build)" if tag == "dev" else "Stable",
                "assets": [{"name": name, "browser_download_url": f"{release_root}/download/{tag}/{name}"}
                           for name in (archive, archive + ".sha256")],
            })

        def manifest_response(route):
            version = developer_version if "/dev/" in route.request.url else stable_version
            route.fulfill(json={
                "schema": 1, "version": version,
                "release": f"{release_root}/tag/{'dev' if version == developer_version else 'v' + version}",
                "archiveSha256": "a" * 64,
                "files": [{"path": path, "size": 1, "sha256": "a" * 64}
                          for path in ("main.lua", "lib/package.lua")],
            })

        for width in (375, 1280):
            with self.subTest(width=width):
                page = self.new_page(viewport={"width": width, "height": 1000})
                try:
                    errors = []
                    page.on("pageerror", lambda error: errors.append(str(error)))
                    page.route("**/installer/releases.json", lambda route: route.fulfill(json=catalog))
                    page.route("**/installer/releases/*/manifest.json", manifest_response)
                    page.route("https://api.github.com/repos/thomaskistler/aero-grid/releases/tags/*", release_response)
                    page.route("https://api.github.com/repos/thomaskistler/aero-grid/releases?*", lambda route:
                               route.fulfill(json=[{
                                   "tag_name": "v0.4.0", "name": "Stable", "draft": False, "prerelease": False,
                                   "assets": [{"name": name, "browser_download_url": f"{release_root}/download/v0.4.0/{name}"}
                                              for name in ("AeroGrid-0.4.0.zip", "AeroGrid-0.4.0.zip.sha256")],
                               }, {
                                   "tag_name": "dev", "name": f"AeroGrid {developer_version} (developer build)",
                                   "draft": False, "prerelease": True,
                                   "assets": [{"name": name, "browser_download_url": f"{release_root}/download/dev/{name}"}
                                              for name in ("AeroGrid-dev.zip", "AeroGrid-dev.zip.sha256")],
                               }]))
                    page.goto(f"{self.url}/user-guide/installation/")
                    page.wait_for_function("document.querySelector('[data-release-open]').disabled === false")
                    page.locator("[data-release-open]").click()
                    checkbox = page.get_by_role("checkbox", name="Show developer releases")
                    self.assertFalse(checkbox.is_checked())
                    self.assertEqual(page.locator("[data-releases] input").count(), 1)
                    checkbox.focus()
                    page.keyboard.press("Space")
                    self.assertTrue(checkbox.is_checked())
                    self.assertEqual(page.locator("[data-releases] input").count(), 2)
                    page.locator(f'input[value="{developer_version}"]').check()
                    page.wait_for_function("document.querySelector('[data-latest]').textContent.includes('developer build')")
                    page.wait_for_function("document.querySelector('[data-release-open]').disabled === false")
                    self.assertLessEqual(page.evaluate("document.documentElement.scrollWidth"), width)
                    page.locator("[data-release-open]").click()
                    checkbox.uncheck()
                    page.wait_for_function("document.querySelector('[data-latest]').textContent === 'v0.4.0 - latest'")
                    page.wait_for_function("document.querySelectorAll('[data-releases] input').length === 1")
                    self.assertEqual(page.locator("[data-releases] input").count(), 1)
                    self.assertLessEqual(page.evaluate("document.documentElement.scrollWidth"), width)
                    self.assertEqual(errors, [])
                finally:
                    page.close()

    @classmethod
    def setUpClass(cls):
        cls.site = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.site.cleanup)
        subprocess.run(
            [sys.executable, "-m", "mkdocs", "build", "--strict", "--site-dir", cls.site.name],
            cwd=ROOT,
            check=True,
        )
        cls.server = ThreadingHTTPServer(
            ("127.0.0.1", 0),
            functools.partial(SimpleHTTPRequestHandler, directory=cls.site.name),
        )
        cls.addClassCleanup(cls.server.server_close)
        thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        thread.start()
        cls.addClassCleanup(thread.join)
        cls.addClassCleanup(cls.server.shutdown)
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        cls.playwright = sync_playwright().start()
        cls.addClassCleanup(cls.playwright.stop)
        cls.browser = cls.playwright.chromium.launch()
        cls.addClassCleanup(cls.browser.close)

    def new_page(self, **options):
        page = self.browser.new_page(**options)
        page.route("https://www.googletagmanager.com/**", lambda route: route.abort())
        return page

    def test_every_page_image_loads(self):
        page = self.new_page()
        try:
            for source in sorted((ROOT / "docs").rglob("*.md")):
                relative = source.relative_to(ROOT / "docs")
                path = relative.parent if relative.stem == "index" else relative.with_suffix("")
                route = "" if path == Path(".") else path.as_posix() + "/"
                with self.subTest(page=str(relative)):
                    response = page.goto(f"{self.url}/{route}")
                    self.assertEqual(response.status, 200)
                    if relative.parts[0] == "panels":
                        self.assertGreater(page.locator('.ag-article img[src*="/assets/editor/"]').count(), 0,
                                           "every panel reference needs a settings-drawer capture")
                    failed = page.locator(".ag-article img").evaluate_all(
                        """images => Promise.all(images.map(async image => {
                            try { await image.decode(); return null; }
                            catch { return image.getAttribute('src'); }
                        })).then(results => results.filter(Boolean))"""
                    )
                    self.assertEqual(failed, [])
        finally:
            page.close()

    def test_rail_contains_only_available_guides(self):
        labels = ["Install / Upgrade", "User Guide", "Reference Guide", "Developer Guide"]
        for path, active in (
            ("user-guide/installation/", "Install / Upgrade"),
            ("user-guide/add-dashboard/", "User Guide"),
            ("user-guide/model-settings/", "User Guide"),
            ("reference-guide/", "Reference Guide"),
            ("panels/metric/", "Reference Guide"),
            ("developer-guide/build/", "Developer Guide"),
        ):
            with self.subTest(path=path):
                page = self.new_page()
                try:
                    page.goto(f"{self.url}/{path}")
                    rail = page.get_by_role("navigation", name="Main navigation", exact=True)
                    self.assertEqual(rail.locator(":scope > *").count(), 4)
                    self.assertEqual(
                        rail.get_by_role("link").evaluate_all(
                            "links => links.map(link => link.getAttribute('aria-label'))"
                        ),
                        labels,
                    )
                    self.assertEqual(rail.locator(".active").count(), 1)
                    self.assertEqual(
                        rail.locator(".active[aria-current='page']").get_attribute("aria-label"),
                        active,
                    )
                finally:
                    page.close()

    def test_tables_stay_inside_page(self):
        for width in (320, 375, 768, 1024, 1440):
            for path in PAGES:
                with self.subTest(width=width, path=path):
                    page = self.new_page(viewport={"width": width, "height": 900})
                    try:
                        page.goto(f"{self.url}/{path}")
                        page.locator(".ag-table-scroll").first.wait_for()
                        page.evaluate("document.fonts.ready")
                        self.assertLessEqual(
                            page.evaluate("document.documentElement.scrollWidth"), width
                        )
                        tables = page.locator(".ag-article table")
                        self.assertGreater(tables.count(), 0)
                        self.assertEqual(page.get_by_role("table").count(), tables.count())
                        self.assertEqual(
                            page.locator(".ag-table-scroll > table").count(), tables.count()
                        )
                        for table in tables.all():
                            self.assertEqual(
                                table.evaluate("table => getComputedStyle(table).display"),
                                "table",
                            )
                            self.assertGreater(table.locator("th").count(), 0)
                    finally:
                        page.close()

    def test_overflowing_tables_scroll_with_keyboard(self):
        for path, width in (
            ("developer-guide/build/", 320),
            ("panels/metric/", 320),
            ("reference-guide/yaml/", 1024),
        ):
            with self.subTest(width=width, path=path):
                page = self.new_page(viewport={"width": width, "height": 900})
                try:
                    page.goto(f"{self.url}/{path}")
                    page.locator(".ag-table-scroll").first.wait_for()
                    page.evaluate("document.fonts.ready")
                    regions = page.get_by_role("region", name="Scrollable table")
                    overflowing = [
                        region for region in regions.all()
                        if region.evaluate("node => node.scrollWidth > node.clientWidth")
                    ]
                    self.assertTrue(overflowing, "Expected an oversized table")
                    for region in overflowing:
                        region.focus()
                        self.assertTrue(region.evaluate("node => node === document.activeElement"))
                        page.keyboard.press("ArrowRight")
                        page.wait_for_function(
                            "node => node.scrollLeft > 0", arg=region.element_handle()
                        )
                        self.assertEqual(page.evaluate("window.scrollX"), 0)
                finally:
                    page.close()

    def test_homepage_radio_examples_fit_desktop_and_wrap_on_mobile(self):
        for width in (320, 375, 768, 1024, 1280, 1440, 1920):
            with self.subTest(width=width):
                page = self.new_page(viewport={"width": width, "height": 900})
                try:
                    page.goto(f"{self.url}/")
                    page.evaluate("document.fonts.ready")
                    self.assertLessEqual(
                        page.evaluate("document.documentElement.scrollWidth"), width
                    )
                    item = page.locator(".ag-home-start aside span").first
                    lines = item.evaluate("""node => {
                        const range = document.createRange();
                        range.selectNodeContents(node);
                        return range.getClientRects().length;
                    }""")
                    if width >= 1280:
                        self.assertEqual(lines, 1, "Radio examples should fit one desktop line")
                    elif width <= 375:
                        self.assertGreater(lines, 1, "Radio examples should wrap on mobile")
                    self.assertLessEqual(
                        item.evaluate("node => node.scrollWidth"), item.evaluate("node => node.clientWidth")
                    )
                finally:
                    page.close()


if __name__ == "__main__":
    unittest.main()
