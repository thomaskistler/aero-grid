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
                self.assertIn("LICENSE", names)
                assets = {name.split("/")[-1] for name in names if "/assets/" in name}
                self.assertEqual(assets, release.ASSETS)
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
