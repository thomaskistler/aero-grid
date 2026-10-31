# SPDX-License-Identifier: GPL-2.0-only
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from playwright.sync_api import sync_playwright
import yaml

import docs_versions


def release(version, draft=False):
    return {"tag_name": f"v{version}", "draft": draft, "prerelease": "-" in version}


class ReleaseVersionTests(unittest.TestCase):
    def test_drafts_are_excluded_and_prereleases_do_not_set_the_default(self):
        versions, latest = docs_versions.release_versions(
            [release("0.1.0"), release("0.2.0-beta.1"), release("0.3.0", draft=True)],
            release("0.1.0"),
        )
        self.assertEqual(versions, {"0.1.0": "v0.1.0", "0.2.0-beta.1": "v0.2.0-beta.1"})
        self.assertEqual(latest, "0.1.0")
        with self.assertRaisesRegex(ValueError, "published stable"):
            docs_versions.release_versions(
                [release("0.2.0-beta.1")], release("0.2.0-beta.1")
            )

    def test_invalid_tags_flags_and_missing_defaults_fail_explicitly(self):
        for releases, latest in (
            ([release("../main")], release("../main")),
            ([{**release("0.1.0"), "prerelease": True}], release("0.1.0")),
            ([release("0.1.0"), release("0.1.0")], release("0.1.0")),
            ([release("0.1.0")], release("0.2.0")),
        ):
            with self.subTest(releases=releases, latest=latest):
                with self.assertRaises(ValueError):
                    docs_versions.release_versions(releases, latest)


class VersionedDocumentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.repo = Path(cls.temp.name) / "repository"
        cls.repo.mkdir()
        cls.git("init", "--quiet", "--initial-branch=main")
        cls.git("config", "user.name", "Documentation tests")
        cls.git("config", "user.email", "docs-tests@example.invalid")
        docs = cls.repo / "docs"
        docs.mkdir()
        (cls.repo / "mkdocs.yml").write_text(
            "site_name: AeroGrid\n"
            "site_url: https://thomaskistler.github.io/aero-grid/\n"
            "theme:\n  name: mkdocs\n"
            "plugins:\n  - search\n"
        )
        (docs / "index.md").write_text("# Released one\n\nOnly first-release features.\n")
        cls.commit("First release", "v0.1.0")
        config_path = cls.repo / "mkdocs.yml"
        config_path.write_text(config_path.read_text().replace(
            "  name: mkdocs\n", "  name: mkdocs\n  analytics:\n    gtag: G-OLDTEST123\n"
        ))
        (docs / "index.md").write_text("# Released two\n\nSecond-release features.\n")
        (docs / "guide.md").write_text("# Guide\n\n## Details\n\nRelease-specific guide.\n")
        cls.commit("Second release", "v0.2.0")
        (docs / "index.md").write_text("# Prerelease\n\nExperimental features.\n")
        cls.commit("Prerelease", "v0.3.0-beta.1")
        (docs / "index.md").write_text("# Main\n\nUnreleased features.\n")
        (docs / "development-only.md").write_text("# Development only\n\nUnreleased page.\n")
        cls.releases = [release("0.3.0-beta.1"), release("0.2.0"), release("0.1.0")]
        cls.site = Path(cls.temp.name) / "site"
        docs_versions.publish(cls.repo, "gh-pages", cls.releases, release("0.2.0"),
                              cls.site / "aero-grid")
        cls.server = ThreadingHTTPServer(
            ("127.0.0.1", 0),
            functools.partial(SimpleHTTPRequestHandler, directory=str(cls.site)),
        )
        cls.addClassCleanup(cls.server.server_close)
        thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        thread.start()
        cls.addClassCleanup(thread.join)
        cls.addClassCleanup(cls.server.shutdown)
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/aero-grid"
        cls.playwright = sync_playwright().start()
        cls.addClassCleanup(cls.playwright.stop)
        cls.browser = cls.playwright.chromium.launch()
        cls.addClassCleanup(cls.browser.close)
        cls.context = cls.browser.new_context()
        cls.addClassCleanup(cls.context.close)
        cls.context.route("https://www.googletagmanager.com/**", lambda route: route.abort())

    @classmethod
    def git(cls, *args):
        return subprocess.check_output(["git", *args], cwd=cls.repo, text=True).strip()

    @classmethod
    def commit(cls, message, tag):
        cls.git("add", ".")
        cls.git("commit", "--quiet", "-m", message)
        cls.git("tag", tag)

    def page(self, path):
        page = self.context.new_page()
        self.addCleanup(page.close)
        page.goto(f"{self.url}/{path}")
        page.wait_for_function(
            "() => !document.querySelector('[data-docs-version]').disabled"
        )
        return page

    def test_default_and_legacy_links_preserve_queries_and_anchors(self):
        for path, destination in (
            ("?source=bookmark", "/0.2.0/?source=bookmark"),
            ("guide/?source=bookmark#details", "/0.2.0/guide/?source=bookmark#details"),
        ):
            with self.subTest(path=path):
                page = self.page(path)
                self.assertEqual(page.url, self.url + destination)

    def test_released_content_search_and_canonical_urls_are_version_specific(self):
        for version, title in (("0.1.0", "Released one"), ("0.2.0", "Released two"),
                               ("0.3.0-beta.1", "Prerelease"), ("main", "Main")):
            with self.subTest(version=version):
                page = self.page(f"{version}/")
                self.assertEqual(page.locator("h1").inner_text(), title)
                self.assertEqual(page.locator("link[rel='canonical']").get_attribute("href"),
                                 f"https://thomaskistler.github.io/aero-grid/{version}/")
                index = json.loads((self.site / "aero-grid" / version
                                    / "search/search_index.json").read_text())
                self.assertEqual(index["docs"][0]["title"], title)
                self.assertEqual(page.locator("[data-docs-version]").count(), 1)

    def test_selector_lists_releases_prereleases_and_main(self):
        page = self.page("0.2.0/guide/")
        picker = page.get_by_role("combobox", name="Documentation version")
        self.assertEqual(picker.input_value(), "0.2.0")
        self.assertEqual(
            picker.locator("option").all_text_contents(),
            ["v0.3.0-beta.1 (prerelease)", "v0.2.0 (latest)", "v0.1.0", "main (unreleased)"],
        )

    def test_every_versioned_page_uses_current_google_analytics(self):
        config = yaml.safe_load((docs_versions.ROOT / "mkdocs.yml").read_text())
        tracking_id = config["theme"]["analytics"]["gtag"]
        for version in ("0.1.0", "0.2.0", "0.3.0-beta.1", "main"):
            for path in (self.site / "aero-grid" / version).rglob("*.html"):
                with self.subTest(version=version, page=path.name):
                    html = path.read_text()
                    self.assertEqual(
                        html.count(f"https://www.googletagmanager.com/gtag/js?id={tracking_id}"),
                        1,
                    )
                    self.assertEqual(html.count(f"gtag('config', {json.dumps(tracking_id)});"), 1)
                    self.assertNotIn("G-OLDTEST123", html)

    def test_switching_preserves_the_page_query_and_anchor(self):
        for path in ("guide/", "guide/index.html"):
            with self.subTest(path=path):
                page = self.page(f"0.2.0/{path}?source=bookmark#details")
                page.get_by_role("combobox", name="Documentation version").select_option("main")
                page.wait_for_url(f"{self.url}/main/guide/?source=bookmark#details")
                self.assertEqual(page.locator("h1").inner_text(), "Guide")

    def test_missing_page_opens_the_selected_home_with_an_explanation(self):
        page = self.page("main/guide/#details")
        page.get_by_role("combobox", name="Documentation version").select_option("0.1.0")
        page.wait_for_url(f"{self.url}/0.1.0/?docs-page-missing=1")
        self.assertEqual(page.locator("h1").inner_text(), "Released one")
        page.get_by_role("status").filter(has_text="not available").wait_for()

    def test_failed_switch_stays_on_the_current_page_and_reports_the_error(self):
        page = self.page("0.2.0/guide/")
        page.route("**/0.1.0/pages.json", lambda route: route.fulfill(status=503))
        picker = page.get_by_role("combobox", name="Documentation version")
        picker.select_option("0.1.0")
        page.get_by_role("status").filter(has_text="could not be loaded").wait_for()
        self.assertEqual(page.url, f"{self.url}/0.2.0/guide/")
        self.assertEqual(picker.input_value(), "0.2.0")
        self.assertTrue(picker.is_enabled())

    def test_invalid_catalog_leaves_the_current_version_visible(self):
        page = self.context.new_page()
        self.addCleanup(page.close)
        page.route("**/versions.json", lambda route: route.fulfill(json=[{"version": "../main"}]))
        page.goto(f"{self.url}/0.2.0/")
        page.get_by_role("status").filter(has_text="could not be loaded").wait_for()
        picker = page.get_by_role("combobox", name="Documentation version")
        self.assertEqual(picker.input_value(), "0.2.0")
        self.assertTrue(picker.is_disabled())

    def test_invalid_page_catalog_does_not_masquerade_as_a_missing_page(self):
        for catalog in ([], {}, ["guide/"]):
            with self.subTest(catalog=catalog):
                page = self.page("0.2.0/guide/")
                page.route("**/0.1.0/pages.json", lambda route: route.fulfill(json=catalog))
                picker = page.get_by_role("combobox", name="Documentation version")
                picker.select_option("0.1.0")
                page.get_by_role("status").filter(has_text="could not be loaded").wait_for()
                self.assertEqual(page.url, f"{self.url}/0.2.0/guide/")
                self.assertEqual(picker.input_value(), "0.2.0")

    def test_selector_is_visible_without_expanding_the_mobile_navigation(self):
        page = self.page("0.2.0/")
        page.set_viewport_size({"width": 320, "height": 900})
        picker = page.get_by_role("combobox", name="Documentation version")
        self.assertTrue(picker.is_visible())
        self.assertLessEqual(page.evaluate("document.documentElement.scrollWidth"), 320)
        picker.focus()
        self.assertTrue(picker.evaluate("node => node === document.activeElement"))

    def test_republication_preserves_snapshots_and_uses_the_latest_stable_endpoint(self):
        before = self.git("rev-parse", "gh-pages:0.2.0")
        (self.repo / "docs/index.md").write_text("# New main\n\nMore unreleased features.\n")
        (self.repo / "docs/development-only.md").unlink()
        output = Path(self.temp.name) / "second-site"
        docs_versions.publish(self.repo, "gh-pages", self.releases, release("0.1.0"), output)
        self.assertEqual(self.git("rev-parse", "gh-pages:0.2.0"), before)
        catalog = json.loads((output / "versions.json").read_text())
        self.assertEqual(next(entry["version"] for entry in catalog
                              if "latest" in entry["aliases"]), "0.1.0")
        self.assertIn("New main", (output / "main/index.html").read_text())
        self.assertIn("docs-page-missing=1", (output / "guide/index.html").read_text())
        self.assertIn("docs-page-missing=1", (output / "development-only/index.html").read_text())
        main = next(entry for entry in catalog if entry["version"] == "main")
        self.assertIn("development-only/", main["properties"]["legacy_pages"])
        self.assertIn("Co-authored-by: Copilot App", self.git("log", "-1", "--format=%B", "gh-pages"))
        with self.assertRaisesRegex(ValueError, "already exists"):
            docs_versions.export_site(self.repo, "gh-pages", output, "0.1.0")


if __name__ == "__main__":
    unittest.main()
