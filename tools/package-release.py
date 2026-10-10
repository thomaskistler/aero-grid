# SPDX-License-Identifier: GPL-2.0-only
"""Build a deterministic, source-only AeroGrid installation archive."""
import argparse
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r'(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:beta|rc)\.[1-9]\d*)?')
LAYOUTS = {"Default.yaml", "Empty.yaml", "Diagnostics.yaml", "Palette.yaml"}
ASSETS = {"editor-configure.png", "editor-configure.svg", "LICENSE.txt"}
THEMES = {"modern-dark.yml", "modern-light.yml"}


def version(source):
    text = (source / "lib/package.lua").read_text()
    matches = re.findall(r'\bversion\s*=\s*"([^"]+)"', text)
    if len(matches) != 1 or not VERSION.fullmatch(matches[0]):
        raise ValueError("Package version must be X.Y.Z, X.Y.Z-beta.N, or X.Y.Z-rc.N")
    return matches[0]


def package(source, output):
    release = version(source)
    for name in LAYOUTS:
        if not (source / "layouts" / name).is_file():
            raise ValueError(f"Missing bundled layout: {name}")
    for name in ASSETS:
        if not (source / "assets" / name).is_file():
            raise ValueError(f"Missing bundled asset: {name}")
    for name in THEMES:
        if not (source / "themes" / name).is_file():
            raise ValueError(f"Missing bundled theme: {name}")
    files = []
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Package source must not contain symlinks: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(source)
        if relative.parts[0] == "layouts":
            if relative.as_posix() not in {f"layouts/{name}" for name in LAYOUTS}:
                continue
        elif relative.parts[0] == "themes":
            if path.suffix != ".yml":
                raise ValueError(f"Unexpected runtime theme file: {relative}")
        elif relative.parts[0] == "assets":
            if relative.as_posix() not in {f"assets/{name}" for name in ASSETS}:
                raise ValueError(f"Unexpected runtime asset: {relative}")
        elif path.suffix != ".lua":
            raise ValueError(f"Unexpected runtime file: {relative}")
        files.append((path, relative))
    if not (source / "main.lua").is_file():
        raise ValueError("Missing widget main.lua")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"AeroGrid-{release}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path, relative in files:
            entry = zipfile.ZipInfo("WIDGETS/AeroGrid/" + relative.as_posix(), (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            bundle.writestr(entry, path.read_bytes())
        for name in ("LICENSE",):
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            bundle.writestr(entry, (ROOT / name).read_bytes())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "build/release")
    args = parser.parse_args()
    try:
        source = ROOT / "src/WIDGETS/AeroGrid"
        print(version(source) if args.version_only else package(source, args.output))
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
