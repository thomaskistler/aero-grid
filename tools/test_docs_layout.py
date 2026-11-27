# SPDX-License-Identifier: GPL-2.0-only

import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from xml.etree import ElementTree

import yaml
from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[1]
PAGES = ("developer-guide/build/", "panels/metric/", "reference-guide/yaml/",
         "user-guide/model-settings/", "panels/chart/", "panels/flight-counter/",
         "panels/navigation/")


class DocumentationLayoutTests(unittest.TestCase):
    def test_installer_developer_release_checkbox_is_opt_in_and_keyboard_accessible(self):
        release_root = "https://github.com/thomaskistler/aero-grid/releases"
        developer_version = "0.4.0-dev.12+aaaaaaaa"
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
                    self.assertTrue(page.locator("[data-developer-warning]").is_hidden())
                    self.assertEqual(page.locator("[data-releases] input").count(), 1)
                    checkbox.focus()
                    page.keyboard.press("Space")
                    self.assertTrue(checkbox.is_checked())
                    self.assertEqual(page.locator("[data-releases] input").count(), 2)
                    page.locator(f'input[value="{developer_version}"]').check()
                    page.wait_for_function("document.querySelector('[data-latest]').textContent.includes('developer build')")
                    self.assertTrue(page.locator("[data-developer-warning]").is_visible())
                    self.assertIn("Use at your own risk", page.locator("[data-developer-warning]").inner_text())
                    page.wait_for_function("document.querySelector('[data-release-open]').disabled === false")
                    self.assertLessEqual(page.evaluate("document.documentElement.scrollWidth"), width)
                    page.locator("[data-release-open]").click()
                    checkbox.uncheck()
                    page.wait_for_function("document.querySelector('[data-latest]').textContent === 'v0.4.0 - latest'")
                    self.assertTrue(page.locator("[data-developer-warning]").is_hidden())
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

    def test_vector_branding_is_readable_and_header_controls_fit(self):
        svg_namespace = "{http://www.w3.org/2000/svg}"
        artwork = {}
        for name in ("aerogrid-logo.svg", "aerogrid-mark.svg"):
            artwork[name] = ElementTree.parse(ROOT / "docs/assets/branding" / name).getroot()
            self.assertGreater(len(artwork[name].findall(svg_namespace + "path")), 0)
            for tag in ("image", "text", "rect", "foreignObject"):
                self.assertEqual(artwork[name].findall(".//" + svg_namespace + tag), [])
        self.assertEqual(artwork["aerogrid-logo.svg"].find(".//*[@id='mark']").get("d"),
                         artwork["aerogrid-mark.svg"].find(".//*[@id='mark']").get("d"))
        for width in (320, 375, 450, 451, 650, 651, 768, 1280):
            for scheme in ("light", "dark"):
                with self.subTest(width=width, scheme=scheme):
                    page = self.new_page(viewport={"width": width, "height": 900},
                                         color_scheme=scheme)
                    try:
                        for path in ("", "user-guide/model-settings/"):
                            page.goto(f"{self.url}/{path}")
                            page.evaluate("document.fonts.ready")
                            logo = page.locator(".ag-brand .ag-logo")
                            image = logo.locator("img")
                            image.evaluate("image => image.decode()")
                            asset = "aerogrid-mark.svg" if width <= 450 else "aerogrid-logo.svg"
                            self.assertTrue(image.evaluate("image => image.currentSrc").endswith(asset))
                            self.assertEqual(image.get_attribute("alt"), "AeroGrid")
                            self.assertTrue(logo.is_visible())
                            self.assertEqual(
                                logo.evaluate(
                                    "node => getComputedStyle(node).backgroundColor"),
                                "rgba(0, 0, 0, 0)",
                            )
                            controls = [logo, page.get_by_role("combobox", name="Documentation version"),
                                        page.locator(".ag-search-link"), page.locator(".ag-edit-link")]
                            boxes = [control.bounding_box() for control in controls]
                            for box in boxes:
                                self.assertIsNotNone(box)
                                self.assertGreaterEqual(box["x"], 0)
                                self.assertLessEqual(box["x"] + box["width"], width)
                                self.assertGreaterEqual(box["y"], 0)
                                self.assertLessEqual(box["y"] + box["height"],
                                                     page.locator(".navbar").bounding_box()["height"])
                            for left, right in zip(boxes, boxes[1:]):
                                self.assertLessEqual(left["x"] + left["width"], right["x"])
                            self.assertLessEqual(
                                page.evaluate("document.documentElement.scrollWidth"), width)
                            self.assertEqual(page.locator(".ag-icon-rail > a").count(), 4)
                            if not path:
                                heading = page.get_by_role("heading", name="AeroGrid", exact=True)
                                self.assertTrue(heading.is_visible())
                                heading.locator("img").evaluate("image => image.decode()")
                                self.assertGreaterEqual(heading.locator("img").bounding_box()["width"], 160)
                            else:
                                logo.click()
                                self.assertEqual(page.url, f"{self.url}/")
                    finally:
                        page.close()

    def test_logo_mark_matches_panel_green_and_gap_width(self):
        palette = yaml.safe_load(
            (ROOT / "src/WIDGETS/AeroGrid/themes/modern-dark.yml").read_text())
        green = f"#{palette['colors']['green']:06x}"
        for name in ("aerogrid-logo.svg", "aerogrid-mark.svg"):
            with self.subTest(asset=name):
                artwork = ElementTree.parse(ROOT / "docs/assets/branding" / name).getroot()
                mark = artwork.find(".//*[@id='mark']")
                self.assertEqual(mark.get("fill"), green)
                polygons = re.findall(
                    r"M([\d.]+)\s+([\d.]+)H([\d.]+)L([\d.]+)\s+([\d.]+)H([\d.]+)Z",
                    mark.get("d"))
                self.assertEqual(len(polygons), 2)
                wide, narrow = [tuple(map(float, polygon)) for polygon in polygons]
                for bar in (wide, narrow):
                    self.assertAlmostEqual(bar[2] - bar[0], bar[3] - bar[5],
                                           msg="Each slash must keep a constant width")
                self.assertAlmostEqual(narrow[2] - narrow[0], narrow[0] - wide[2],
                                       msg="The narrow slash must match the top gap width")
                self.assertAlmostEqual(narrow[3] - narrow[5], narrow[5] - wide[3],
                                       msg="The narrow slash must match the bottom gap width")
                self.assertAlmostEqual((wide[0] - wide[5]) / (wide[4] - wide[1]),
                                       (narrow[0] - narrow[5]) / (narrow[4] - narrow[1]),
                                       msg="The slashes must remain parallel")

    def test_logo_a_legs_are_parallel_and_match_wordmark_weight(self):
        artwork = ElementTree.parse(ROOT / "docs/assets/branding/aerogrid-logo.svg").getroot()
        matrix = artwork.find(".//*[@id='wordmark']").get("transform")
        a, b, c, d, e, f = map(float, matrix.partition("(")[2].rstrip(")").split())

        def transform(point):
            x, y = point
            return a * x + c * y + e, b * x + d * y + f

        def line_edges(path):
            position = None
            edges = []
            for command in re.findall(r"[MLCHV][^MLCHVZ]+", path.get("d")):
                values = [float(value) for value in command[1:].replace(",", " ").split()]
                if command[0] == "H":
                    endpoint = (values[0], position[1])
                elif command[0] == "V":
                    endpoint = (position[0], values[0])
                else:
                    endpoint = tuple(values[-2:])
                if command[0] in ("L", "V"):
                    edges.append((position, endpoint))
                position = endpoint
            return edges

        def stroke_width(outer, inner):
            dx, dy = outer[1][0] - outer[0][0], outer[1][1] - outer[0][1]
            return abs(dy * (inner[0][0] - outer[0][0]) -
                       dx * (inner[0][1] - outer[0][1])) / math.hypot(dx, dy)

        reference_edges = [(transform(start), transform(end))
                           for start, end in line_edges(artwork.find(".//*[@id='letter-r-first']"))]
        self.assertGreaterEqual(len(reference_edges), 2)
        reference_edges.sort(key=lambda edge: math.dist(*edge), reverse=True)
        reference_width = stroke_width(*reference_edges[:2])
        legs = {"left": [], "right": []}
        for start, end in line_edges(artwork.find(".//*[@id='letter-a']")):
            side = "right" if (end[0] - start[0]) * (end[1] - start[1]) > 0 else "left"
            legs[side].append((transform(start), transform(end)))
        for side, edges in legs.items():
            with self.subTest(leg=side):
                self.assertEqual(len(edges), 3)
                outer, lower, upper = edges
                slope = (outer[1][0] - outer[0][0]) / (outer[1][1] - outer[0][1])
                for start, end in (lower, upper):
                    self.assertAlmostEqual(slope, (end[0] - start[0]) / (end[1] - start[1]), places=6,
                                           msg="The A's inner and outer leg edges must be parallel")
                self.assertAlmostEqual(lower[0][0] - slope * lower[0][1],
                                       upper[0][0] - slope * upper[0][1], places=5,
                                       msg="Leg thickness must be consistent across the crossbar")
                width = stroke_width(outer, upper)
                self.assertGreaterEqual(width, reference_width,
                                        "Diagonal legs must not look thinner than the r's stem")
                self.assertLessEqual(width, reference_width * 1.1,
                                     "Optical weight adjustment must not overwhelm the wordmark")

    def test_logo_lower_edges_are_flat(self):
        page = self.new_page()
        try:
            page.goto(f"{self.url}/")
            image = page.locator(".ag-home-logo img")
            image.evaluate("image => image.decode()")
            edges = image.evaluate("""image => {
                const scale = 20;
                const canvas = document.createElement('canvas');
                canvas.width = 207 * scale;
                canvas.height = 24 * scale;
                const context = canvas.getContext('2d');
                context.drawImage(image, 0, 0, canvas.width, canvas.height);
                const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
                return [['e', 70, 84], ['o', 109, 121], ['G', 135, 152], ['d', 187, 197]]
                    .map(([letter, left, right]) => {
                        const depths = [];
                        for (let x = left * scale; x < right * scale; x++) {
                            let y = canvas.height - 1;
                            while (y >= 0 && pixels[(y * canvas.width + x) * 4 + 3] < 128) y--;
                            depths.push(y);
                        }
                        return {letter, shallowest: Math.min(...depths), deepest: Math.max(...depths)};
                    });
            }""")
            for edge in edges:
                with self.subTest(letter=edge["letter"]):
                    self.assertGreater(edge["shallowest"], 0)
                    self.assertEqual(edge["shallowest"], edge["deepest"],
                                     "The straight lower edge must not contain tracing steps")
        finally:
            page.close()

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

    def test_user_guide_links_share_a_destination_separate_from_installation(self):
        destination = f"{self.url}/user-guide/add-dashboard/"
        for path in ("", "user-guide/add-dashboard/", "user-guide/installation/"):
            with self.subTest(path=path):
                page = self.new_page()
                try:
                    page.goto(f"{self.url}/{path}")
                    rail = page.get_by_role("navigation", name="Main navigation", exact=True)
                    guide = rail.get_by_role("link", name="User Guide", exact=True)
                    self.assertEqual(guide.evaluate("link => link.href"), destination)
                    install = rail.get_by_role("link", name="Install / Upgrade", exact=True)
                    self.assertEqual(install.evaluate("link => link.href"),
                                     f"{self.url}/user-guide/installation/")
                    sidebar = page.locator(".ag-guide-nav")
                    if path == "user-guide/installation/":
                        self.assertEqual(sidebar.count(), 0)
                    else:
                        guide = sidebar.get_by_role("link", name="User Guide", exact=True)
                        self.assertEqual(guide.evaluate("link => link.href"), destination)
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
