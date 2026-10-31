# SPDX-License-Identifier: GPL-2.0-only
"""Mirror validated stable and rolling developer releases into a documentation site."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import urllib.request
import zipfile

REPOSITORY = "thomaskistler/aero-grid"
API_URL = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
RELEASES_URL = f"https://api.github.com/repos/{REPOSITORY}/releases"
STABLE_VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)")
DEVELOPER_VERSION = re.compile(STABLE_VERSION.pattern + r"-dev\.[1-9]\d*\+(?:[a-f0-9]{8}|g[a-f0-9]{40})")
PREFIX = "WIDGETS/AeroGrid/"
MAX_DOWNLOAD = 16 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MAX_FILE = 2 * 1024 * 1024
MAX_FILES = 1500


def fetch(url, limit, api=False):
    headers = {"User-Agent": "AeroGrid-documentation-installer"}
    if api and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Download exceeds size limit: {url}")
    return data


def release_assets(release):
    tag = release.get("tag_name", "")
    version = tag.removeprefix("v")
    developer = tag == "dev"
    if developer:
        match = re.fullmatch(r"AeroGrid (.+) \(developer build\)", release.get("name", ""))
        version = match[1] if match else ""
    if (release.get("draft") is not False
            or (developer and (not DEVELOPER_VERSION.fullmatch(version)
                              or release.get("prerelease") is not True))
            or (not developer and (not STABLE_VERSION.fullmatch(version) or tag != f"v{version}"
                                   or release.get("prerelease") is not False))):
        raise ValueError("Release must be a published stable vX.Y.Z release or a valid dev prerelease")
    archive = f"AeroGrid-{'dev' if developer else version}.zip"
    urls = []
    for name in (archive, archive + ".sha256"):
        matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
        expected = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"
        if len(matches) != 1 or matches[0].get("browser_download_url") != expected:
            raise ValueError(f"Release is missing a valid {name} asset")
        urls.append(expected)
    return version, urls


def unpack(version, archive, checksum):
    archive_version = "dev" if DEVELOPER_VERSION.fullmatch(version) else version
    match = re.fullmatch(
        rf"([a-fA-F0-9]{{64}})  AeroGrid-{re.escape(archive_version)}\.zip\s*", checksum
    )
    digest = hashlib.sha256(archive).hexdigest()
    if not match or match[1].lower() != digest:
        raise ValueError("Release ZIP checksum mismatch")
    files = {}
    seen = set()
    directories = {}
    total = 0
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        entries = bundle.infolist()
        if not entries or len(entries) > MAX_FILES:
            raise ValueError("Unexpected archive entry count")
        for entry in entries:
            name = entry.filename
            parts = name.split("/")
            if (not name or len(name) > 240 or "\\" in name
                    or any(not re.fullmatch(r"[A-Za-z0-9_.-]+", part)
                           or part in (".", "..") for part in parts)
                    or name.casefold() in seen or entry.is_dir()
                    or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG)
                    or entry.flag_bits & 1 or entry.file_size > MAX_FILE):
                raise ValueError(f"Unsafe archive entry: {name}")
            seen.add(name.casefold())
            for index in range(1, len(parts)):
                directory = "/".join(parts[:index])
                previous = directories.get(directory.casefold())
                if previous and previous != directory:
                    raise ValueError(f"Case-colliding directory: {directory}")
                directories[directory.casefold()] = directory
            total += entry.file_size
            if total > MAX_TOTAL:
                raise ValueError("Installation exceeds total size limit")
            if name == "LICENSE":
                continue
            if not name.startswith(PREFIX):
                raise ValueError(f"Unexpected archive entry: {name}")
            relative = name[len(PREFIX):]
            if (not relative or relative.endswith(".luac")
                    or (not relative.endswith(".lua")
                        and parts[2] not in ("assets", "themes", "layouts"))):
                raise ValueError(f"Unexpected widget file: {name}")
            files[relative] = bundle.read(entry)
    for name in ("main.lua", "lib/package.lua"):
        if name not in files:
            raise ValueError(f"Missing required widget file: {name}")
    metadata = files["lib/package.lua"].decode("utf-8")
    versions = re.findall(r'\bversion\s*=\s*"([^"]+)"', metadata)
    if versions != [version]:
        raise ValueError("Release version does not match lib/package.lua")
    paths = {name.casefold() for name in files}
    if seen.intersection(directories):
        raise ValueError("Archive file/directory collision")
    for name in files:
        parents = name.split("/")[:-1]
        if any("/".join(parents[:index]).casefold() in paths
               for index in range(1, len(parents) + 1)):
            raise ValueError(f"File/directory collision: {name}")
    return files, digest


def publish(release, archive, checksum, output, latest=True):
    version, _ = release_assets(release)
    files, digest = unpack(version, archive, checksum)
    developer = release["tag_name"] == "dev"
    target = output / "releases" / ("dev" if developer else version)
    if target.exists():
        raise ValueError(f"Installer output already exists: {target}")
    manifest = {
        "schema": 1,
        "version": version,
        "release": f"https://github.com/{REPOSITORY}/releases/tag/{release['tag_name']}",
        "archiveSha256": digest,
        "files": [
            {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in sorted(files.items())
        ],
    }
    for name, data in files.items():
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    (target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if latest and not developer:
        (output / "latest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def publish_catalog(output, fetcher=fetch):
    latest = json.loads(fetcher(API_URL, 1024 * 1024, api=True))
    latest_version, _ = release_assets(latest)
    releases = []
    for page in range(1, 21):
        batch = json.loads(fetcher(f"{RELEASES_URL}?per_page=100&page={page}", 8 * 1024 * 1024, api=True))
        if not isinstance(batch, list):
            raise ValueError("Invalid GitHub release list")
        releases.extend(batch)
        if len(batch) < 100:
            break
    else:
        raise ValueError("Release history exceeds pagination limit")
    stable = {}
    for item in releases:
        tag = item.get("tag_name", "")
        version = tag.removeprefix("v")
        if (item.get("draft") is not False or item.get("prerelease") is not False
                or tag != f"v{version}" or not STABLE_VERSION.fullmatch(version)):
            continue
        if version in stable:
            raise ValueError(f"Duplicate release version: {version}")
        stable[version] = item
    if latest_version not in stable:
        raise ValueError("Latest stable release is missing from release history")
    # Use the latest endpoint's validated snapshot for the default selection.
    stable[latest_version] = latest
    entries = []
    for version in sorted(stable, key=lambda value: tuple(map(int, value.split("."))), reverse=True):
        item = stable[version]
        entry = {
            "version": version,
            "name": item.get("name") or f"AeroGrid {version}",
            "release": f"https://github.com/{REPOSITORY}/releases/tag/v{version}",
            "available": True,
            "reason": None,
        }
        try:
            _, urls = release_assets(item)
        except ValueError:
            if version == latest_version:
                raise
            entry.update(available=False, reason="No compatible installation ZIP and checksum published.")
        else:
            publish(item, fetcher(urls[0], MAX_DOWNLOAD),
                    fetcher(urls[1], 1024).decode("ascii"), output, latest=version == latest_version)
        entries.append(entry)
    developers = [item for item in releases if item.get("tag_name") == "dev" and item.get("draft") is False]
    if len(developers) > 1:
        raise ValueError("Duplicate developer release")
    for item in developers:
        version, urls = release_assets(item)
        publish(item, fetcher(urls[0], MAX_DOWNLOAD),
                fetcher(urls[1], 1024).decode("ascii"), output, latest=False)
        entries.append({
            "version": version, "name": item["name"],
            "release": f"https://github.com/{REPOSITORY}/releases/tag/dev",
            "available": True, "reason": None,
        })
    catalog = {"schema": 1, "latest": latest_version, "releases": entries}
    (output / "releases.json").write_text(json.dumps(catalog, indent=2) + "\n")
    return catalog


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        catalog = publish_catalog(args.output)
        print(f"Published {sum(item['available'] for item in catalog['releases'])} installation releases; latest AeroGrid {catalog['latest']}")
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
