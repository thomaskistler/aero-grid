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
PAGES = ("developer-guide/build/", "panels/metric/", "reference-guide/yaml/")


class DocumentationLayoutTests(unittest.TestCase):
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

    def test_rail_contains_only_available_pages(self):
        labels = ["Install / Upgrade", "User Guide", "Reference Guide", "Developer Guide", "Map Manager"]
        for path, active in (
            ("user-guide/installation/", "Install / Upgrade"),
            ("user-guide/add-dashboard/", "User Guide"),
            ("reference-guide/", "Reference Guide"),
            ("panels/metric/", "Reference Guide"),
            ("developer-guide/build/", "Developer Guide"),
            ("map-manager/", "Map Manager"),
        ):
            with self.subTest(path=path):
                page = self.browser.new_page()
                try:
                    page.goto(f"{self.url}/{path}")
                    rail = page.get_by_role("navigation", name="Main navigation", exact=True)
                    self.assertEqual(rail.locator(":scope > *").count(), len(labels))
                    self.assertEqual(
                        rail.get_by_role("link").evaluate_all(
                            "links => links.map(link => link.getAttribute('aria-label'))"
                        ),
                        labels,
                    )
                    self.assertTrue(
                        rail.get_by_role("link", name="Map Manager", exact=True)
                        .evaluate("link => link.href").endswith("/map-manager/")
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
                    page = self.browser.new_page(viewport={"width": width, "height": 900})
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
                page = self.browser.new_page(viewport={"width": width, "height": 900})
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
                page = self.browser.new_page(viewport={"width": width, "height": 900})
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
