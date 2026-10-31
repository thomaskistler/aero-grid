# SPDX-License-Identifier: GPL-2.0-only
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("package_release", Path(__file__).with_name("package-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_developer_package_has_fixed_name_and_unique_metadata_without_editing_source(self):
        source = release.ROOT / "src/WIDGETS/AeroGrid"
        original = (source / "lib/package.lua").read_bytes()
        commit = "a" * 40
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            path = release.package(source, output, f"12.{commit}")
            self.assertEqual(path.name, "AeroGrid-dev.zip")
            first = path.read_bytes()
            with zipfile.ZipFile(path) as bundle:
                metadata = bundle.read("WIDGETS/AeroGrid/lib/package.lua").decode()
                base = release.version(source).split("-")[0]
                self.assertIn(f'version = "{base}-dev.12+g{commit}"', metadata)
            self.assertEqual(release.package(source, output, f"12.{commit}").read_bytes(), first)
            release.package(source, output, f"13.{commit}")
            self.assertNotEqual(path.read_bytes(), first)
            self.assertEqual(sorted(file.name for file in output.iterdir()),
                             ["AeroGrid-dev.zip", "AeroGrid-dev.zip.sha256"])
            self.assertTrue(path.with_name(path.name + ".sha256").read_text().endswith("  AeroGrid-dev.zip\n"))
            for build in ("0." + commit, "12.short", "../bad", "12." + "A" * 40):
                with self.subTest(build=build), self.assertRaisesRegex(ValueError, "Developer build"):
                    release.package(source, output, build)
        self.assertEqual((source / "lib/package.lua").read_bytes(), original)

    def test_package_contents_and_reproducibility(self):
        source = release.ROOT / "src/WIDGETS/AeroGrid"
        with tempfile.TemporaryDirectory() as directory:
            archive = release.package(source, Path(directory))
            first = archive.read_bytes()
            with zipfile.ZipFile(archive) as bundle:
                names = bundle.namelist()
                layouts = {name.split("/")[-1] for name in names if "/layouts/" in name}
                self.assertEqual(layouts, release.LAYOUTS)
                self.assertIn("WIDGETS/AeroGrid/main.lua", names)
                self.assertIn("WIDGETS/AeroGrid/themes/modern-dark.yml", names)
                self.assertIn("WIDGETS/AeroGrid/themes/modern-light.yml", names)
                self.assertIn("LICENSE", names)
                assets = {name.split("/")[-1] for name in names if "/assets/" in name}
                self.assertEqual(assets, release.ASSETS)
                self.assertEqual(
                    {name for name in assets if name.startswith("menu-")},
                    {f"menu-{icon}-{color}-{size}.png" for icon in ("model", "theme")
                     for color in ("black", "white") for size in (36, 45, 62)}
                    | {"menu-title.svg", *(f"menu-title-{size}.png" for size in (36, 45, 62))},
                )
                self.assertTrue({
                    "satellite.png", "satellite-light.png", "satellite.svg",
                    "satellite-light.svg", "material-symbols-LICENSE.txt",
                }.issubset(assets))
                self.assertFalse(any(name.endswith(".luac") or "/RADIO/" in name or "/MODELS/" in name
                                     for name in names))
                for name in names:
                    if name.startswith("WIDGETS/AeroGrid/"):
                        self.assertEqual(bundle.read(name), (source / name.removeprefix("WIDGETS/AeroGrid/")).read_bytes())
            self.assertEqual(release.package(source, Path(directory)).read_bytes(), first)
            checksum = archive.with_name(archive.name + ".sha256").read_text().split()[0]
            self.assertEqual(checksum, hashlib.sha256(first).hexdigest())

    def test_version_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "lib").mkdir()
            for value in ("1.2.3", "0.11.0-beta.1", "1.0.0-rc.2"):
                (source / "lib/package.lua").write_text(f'return {{ version = "{value}" }}')
                self.assertEqual(release.version(source), value)
            for value in ("01.2.3", "1.2", "1.2.3-beta.0", "bad"):
                (source / "lib/package.lua").write_text(f'return {{ version = "{value}" }}')
                with self.assertRaises(ValueError):
                    release.version(source)
