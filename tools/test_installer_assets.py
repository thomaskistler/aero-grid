# SPDX-License-Identifier: GPL-2.0-only
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

import installer_assets as installer

spec = importlib.util.spec_from_file_location("package_release", Path(__file__).with_name("package-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def release_metadata(version="1.2.3"):
    return {
        "tag_name": f"v{version}", "draft": False, "prerelease": False,
        "assets": [
            {"name": f"AeroGrid-{version}.zip{suffix}",
             "browser_download_url": f"https://github.com/{installer.REPOSITORY}/releases/download/v{version}/AeroGrid-{version}.zip{suffix}"}
            for suffix in ("", ".sha256")
        ],
    }


def archive(entries=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as bundle:
        for name, data in entries or [
            ("WIDGETS/AeroGrid/main.lua", b"return {}"),
            ("WIDGETS/AeroGrid/lib/package.lua", b'return {\nversion = "1.2.3",\n}'),
            ("LICENSE", b"GPL"),
        ]:
            bundle.writestr(name, data)
    return output.getvalue()


def checksum(data):
    return hashlib.sha256(data).hexdigest() + "  AeroGrid-1.2.3.zip\n"


class InstallerAssetsTests(unittest.TestCase):
    def test_developer_version_accepts_eight_hex_digits_and_legacy_releases(self):
        for suffix in ("0fe9d3d9", "g" + "a" * 40):
            with self.subTest(suffix=suffix):
                self.assertIsNotNone(installer.DEVELOPER_VERSION.fullmatch(f"1.2.3-dev.12+{suffix}"))
        for suffix in ("0fe9d3d", "0fe9d3d98", "0FE9D3D9", "g0fe9d3d9", "a" * 40):
            with self.subTest(suffix=suffix):
                self.assertIsNone(installer.DEVELOPER_VERSION.fullmatch(f"1.2.3-dev.12+{suffix}"))

    def test_developer_build_is_mirrored_under_dev_without_changing_latest_stable(self):
        responses = self.catalog_fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = release.package(release.ROOT / "src/WIDGETS/AeroGrid", root / "package", "12." + "a" * 40)
            version = release.version(release.ROOT / "src/WIDGETS/AeroGrid").split("-")[0] + "-dev.12+aaaaaaaa"
            developer = {
                "tag_name": "dev", "name": f"AeroGrid {version} (developer build)",
                "draft": False, "prerelease": True,
                "assets": [
                    {"name": name, "browser_download_url":
                     f"https://github.com/{installer.REPOSITORY}/releases/download/dev/{name}"}
                    for name in ("AeroGrid-dev.zip", "AeroGrid-dev.zip.sha256")
                ],
            }
            page = f"{installer.RELEASES_URL}?per_page=100&page=1"
            responses[page] = json.dumps([developer, *json.loads(responses[page])]).encode()
            _, urls = installer.release_assets(developer)
            responses[urls[0]] = path.read_bytes()
            responses[urls[1]] = path.with_name(path.name + ".sha256").read_bytes()
            output = root / "site"
            catalog = installer.publish_catalog(output, lambda url, limit, api=False: responses[url])
            self.assertEqual(catalog["latest"], "1.2.3")
            self.assertEqual(catalog["releases"][-1]["version"], version)
            manifest = json.loads((output / "releases/dev/manifest.json").read_text())
            self.assertEqual(manifest["version"], version)
            self.assertTrue(manifest["release"].endswith("/tag/dev"))
            self.assertEqual(json.loads((output / "latest.json").read_text())["version"], "1.2.3")
            self.assertFalse((output / "releases" / version).exists())
            developer["name"] = "AeroGrid 1.2.3 (developer build)"
            with self.assertRaises(ValueError):
                installer.release_assets(developer)

    def catalog_fixture(self):
        latest = release_metadata()
        older = release_metadata("1.0.0")
        missing = release_metadata("1.1.0")
        missing["assets"] = []
        beta = release_metadata("2.0.0-beta.1")
        beta["prerelease"] = True
        draft = release_metadata("3.0.0")
        draft["draft"] = True
        responses = {
            installer.API_URL: json.dumps(latest).encode(),
            f"{installer.RELEASES_URL}?per_page=100&page=1": json.dumps([older, beta, missing, latest, draft]).encode(),
        }
        for version, item in [("1.2.3", latest), ("1.0.0", older)]:
            data = archive([
                ("WIDGETS/AeroGrid/main.lua", b"return {}"),
                ("WIDGETS/AeroGrid/lib/package.lua", f'return {{\nversion = "{version}",\n}}'.encode()),
            ])
            _, urls = installer.release_assets(item)
            responses[urls[0]] = data
            responses[urls[1]] = (hashlib.sha256(data).hexdigest() + f"  AeroGrid-{version}.zip\n").encode()
        return responses

    def test_catalog_lists_stable_history_and_publishes_only_available_releases(self):
        responses = self.catalog_fixture()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            catalog = installer.publish_catalog(output, lambda url, limit, api=False: responses[url])
            self.assertEqual(catalog["latest"], "1.2.3")
            self.assertEqual([entry["version"] for entry in catalog["releases"]], ["1.2.3", "1.1.0", "1.0.0"])
            self.assertFalse(catalog["releases"][1]["available"])
            self.assertIn("checksum", catalog["releases"][1]["reason"])
            self.assertFalse((output / "releases/1.1.0").exists())
            self.assertEqual(json.loads((output / "latest.json").read_text())["version"], "1.2.3")
            self.assertEqual(json.loads((output / "releases/1.0.0/manifest.json").read_text())["version"], "1.0.0")
            self.assertEqual(json.loads((output / "releases.json").read_text()), catalog)

    def test_corrupt_historical_payload_fails_instead_of_becoming_installable(self):
        responses = self.catalog_fixture()
        url = installer.release_assets(release_metadata("1.0.0"))[1][0]
        responses[url] = b"corrupt ZIP"
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(ValueError, "checksum"):
            installer.publish_catalog(Path(directory), lambda url, limit, api=False: responses[url])
        responses = self.catalog_fixture()
        latest = json.loads(responses[installer.API_URL])
        latest["assets"] = []
        responses[installer.API_URL] = json.dumps(latest).encode()
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(ValueError, "missing a valid"):
            installer.publish_catalog(Path(directory), lambda url, limit, api=False: responses[url])

    def test_catalog_paginates_and_rejects_duplicate_versions(self):
        responses = self.catalog_fixture()
        page = f"{installer.RELEASES_URL}?per_page=100&page=1"
        draft = release_metadata("9.0.0")
        draft["draft"] = True
        responses[f"{installer.RELEASES_URL}?per_page=100&page=2"] = responses[page]
        responses[page] = json.dumps([draft] * 100).encode()
        with tempfile.TemporaryDirectory() as directory:
            catalog = installer.publish_catalog(Path(directory), lambda url, limit, api=False: responses[url])
            self.assertEqual(len(catalog["releases"]), 3)
        responses[page] = json.dumps([release_metadata(), release_metadata()]).encode()
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(ValueError, "Duplicate"):
            installer.publish_catalog(Path(directory), lambda url, limit, api=False: responses[url])

    def test_published_manifest_and_contents_match_real_release_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = release.package(release.ROOT / "src/WIDGETS/AeroGrid", root / "package")
            version = release.version(release.ROOT / "src/WIDGETS/AeroGrid")
            manifest = installer.publish(
                release_metadata(version), path.read_bytes(),
                path.with_name(path.name + ".sha256").read_text(), root / "site"
            )
            self.assertEqual(json.loads((root / "site/latest.json").read_text()), manifest)
            self.assertGreater(len(manifest["files"]), 40)
            self.assertFalse((root / "site/LICENSE").exists())
            for entry in manifest["files"]:
                data = (root / "site/releases" / version / entry["path"]).read_bytes()
                self.assertEqual(len(data), entry["size"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"])
            with self.assertRaisesRegex(ValueError, "already exists"):
                installer.publish(release_metadata(version), path.read_bytes(),
                                  path.with_name(path.name + ".sha256").read_text(), root / "site")

    def test_latest_stable_must_have_exact_assets(self):
        for key, value in [("prerelease", True), ("draft", True), ("tag_name", "v1.2.3-beta.1"),
                           ("tag_name", "v01.2.3"), ("assets", [])]:
            data = release_metadata()
            data[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                installer.release_assets(data)
        data = release_metadata()
        data["assets"][0]["browser_download_url"] = "https://example.com/fake.zip"
        with self.assertRaisesRegex(ValueError, "missing a valid"):
            installer.release_assets(data)

    def test_rejects_checksum_and_metadata_mismatch(self):
        data = archive()
        with self.assertRaisesRegex(ValueError, "checksum"):
            installer.unpack("1.2.3", data, "0" * 64 + "  AeroGrid-1.2.3.zip")
        data = archive([("WIDGETS/AeroGrid/main.lua", ""),
                        ("WIDGETS/AeroGrid/lib/package.lua", 'version = "9.9.9"')])
        with self.assertRaisesRegex(ValueError, "version"):
            installer.unpack("1.2.3", data, checksum(data))

    def test_rejects_unsafe_archive_entries(self):
        bad_names = [
            "../RADIO/radio.yml", "/RADIO/radio.yml", "WIDGETS/AeroGrid/../main.lua",
            "WIDGETS\\AeroGrid\\main.lua", "WIDGETS/Other/main.lua",
            "WIDGETS/AeroGrid/lib/main.luac", "WIDGETS/AeroGrid/readme.txt",
            "WIDGETS/AeroGrid/../../AEROGRID/layouts/test.yaml",
        ]
        for name in bad_names:
            data = archive([(name, b"bad")])
            with self.subTest(name=name), self.assertRaises(ValueError):
                installer.unpack("1.2.3", data, checksum(data))

    def test_rejects_duplicates_case_collisions_and_symlinks(self):
        for names in [
            ["main.lua", "MAIN.lua"],
            ["lib/a.lua", "LIB/b.lua"],
            ["lib.lua", "lib.lua/a.lua"],
            ["main.lua", "main.lua"],
        ]:
            data = archive([(installer.PREFIX + name, b"x") for name in names])
            with self.subTest(names=names), self.assertRaises(ValueError):
                installer.unpack("1.2.3", data, checksum(data))
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as bundle:
            entry = zipfile.ZipInfo(installer.PREFIX + "main.lua")
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            bundle.writestr(entry, "../../RADIO/radio.yml")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            installer.unpack("1.2.3", output.getvalue(), checksum(output.getvalue()))

    def test_rejects_missing_required_files_and_size_limits(self):
        for entries in [
            [("LICENSE", b"GPL")],
            [(installer.PREFIX + "main.lua", b"x" * (installer.MAX_FILE + 1))],
        ]:
            data = archive(entries)
            with self.assertRaises(ValueError):
                installer.unpack("1.2.3", data, checksum(data))


if __name__ == "__main__":
    unittest.main()
