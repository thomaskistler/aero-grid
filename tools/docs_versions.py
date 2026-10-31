# SPDX-License-Identifier: GPL-2.0-only
"""Maintain versioned MkDocs snapshots and export a complete Pages artifact."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import zipfile

from jinja2 import Environment
import yaml

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:beta|rc)\.(?:0|[1-9]\d*))?")
TRAILER = "\n\nCo-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
SHARED_ASSETS = ("stylesheets/versions.css", "javascripts/versions.mjs")
REDIRECT = ROOT / "docs/overrides/version-redirect.html"


def run(repo, *args):
    env = os.environ.copy()
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "")
    return subprocess.check_output(args, cwd=repo, env=env, text=True)


def mike(repo, branch, command, *args):
    options = ["--branch", branch, "--ignore-remote-status"]
    if command != "list":
        options += ["--message", f"Update versioned documentation ({command}){TRAILER}"]
    return run(repo, "mike", command, *options, *args)


def extract_revision(repo, ref, destination, *paths):
    archive = subprocess.check_output(
        ["git", "archive", "--format=zip", ref, *paths], cwd=repo
    )
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for name in bundle.namelist():
            if name.startswith("/") or ".." in Path(name).parts:
                raise ValueError(f"Unsafe documentation archive path: {name}")
        bundle.extractall(destination)


def prepare_config(source, destination, version):
    config = yaml.safe_load((source / "mkdocs.yml").read_text())
    current_config = yaml.safe_load((ROOT / "mkdocs.yml").read_text())
    config["theme"]["analytics"] = current_config["theme"]["analytics"]
    docs = destination / "docs"
    shutil.copytree(source / config.get("docs_dir", "docs"), docs)
    overrides = destination / "overrides"
    custom_dir = config["theme"].get("custom_dir")
    if custom_dir:
        shutil.copytree(source / custom_dir, overrides)
    else:
        overrides.mkdir()
    main = overrides / "main.html"
    original = main.read_text() if main.exists() else ""
    # Historical releases retain their own content and layout, with shared navigation.
    if 'include "version-selector.html"' not in original:
        parent = "base.html"
        if original:
            parent = "original-main.html"
            main.rename(overrides / parent)
        main.write_text(
            '{% extends "' + parent + '" %}\n'
            '{% block site_name %}{{ super() }}'
            '{% include "version-selector.html" %}{% endblock %}\n'
            '{% block extrahead %}{{ super() }}'
            '<meta name="aerogrid-site-root" content="{{ config.extra.docs_root }}">'
            '{% endblock %}\n'
        )
    shutil.copyfile(ROOT / "docs/overrides/version-selector.html",
                    overrides / "version-selector.html")
    for asset in SHARED_ASSETS:
        target = docs / asset
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "docs" / asset, target)
    config["docs_dir"] = str(docs)
    config["site_dir"] = str(destination / "site")
    config["theme"]["custom_dir"] = str(overrides)
    config["strict"] = True
    config.setdefault("extra_css", [])
    if SHARED_ASSETS[0] not in config["extra_css"]:
        config["extra_css"].append(SHARED_ASSETS[0])
    javascript = config.setdefault("extra_javascript", [])
    if not any((entry.get("path") if isinstance(entry, dict) else entry) == SHARED_ASSETS[1]
               for entry in javascript):
        javascript.append({"path": SHARED_ASSETS[1], "type": "module"})
    config["hooks"] = [str(ROOT / "tools/docs_version_hook.py")]
    plugins = config.get("plugins", ["search"])
    if isinstance(plugins, dict):
        plugins = [{name: options} for name, options in plugins.items()]
    config["plugins"] = [
        entry for entry in plugins
        if (entry if isinstance(entry, str) else next(iter(entry))) != "mike"
    ] + [{"mike": {"version_selector": False, "alias_type": "redirect"}}]
    root = urlsplit(config["site_url"]).path
    if not root.endswith("/"):
        raise ValueError("Documentation site_url must end with a slash")
    config.setdefault("extra", {}).update({
        "docs_root": root,
        "docs_version": version,
        "docs_title": "main (unreleased)" if version == "main" else f"v{version}",
    })
    if version != "main":
        config["edit_uri"] = ""
    target = destination / "mkdocs.yml"
    target.write_text(yaml.safe_dump(config, sort_keys=False))
    return target


def deploy_version(repo, branch, version, ref=None):
    if version != "main" and not VERSION.fullmatch(version):
        raise ValueError(f"Invalid documentation version: {version}")
    with tempfile.TemporaryDirectory() as temp:
        temporary = Path(temp)
        source = repo
        if ref is not None:
            source = temporary / "source"
            extract_revision(repo, ref, source, "docs", "mkdocs.yml")
        config = prepare_config(source, temporary / "build", version)
        print(f"Building documentation for {version} from {ref or 'the checkout'}", flush=True)
        print(mike(repo, branch, "deploy", "--config-file", str(config), version), end="")


def release_versions(releases, latest):
    versions = {}
    for release in releases:
        if release["draft"]:
            continue
        tag = release["tag_name"]
        if tag == "dev" and release["prerelease"] is True:
            continue
        version = tag.removeprefix("v")
        if tag != f"v{version}" or not VERSION.fullmatch(version):
            raise ValueError(f"Unsupported published release tag: {tag}")
        if release["prerelease"] != ("-" in version):
            raise ValueError(f"Release prerelease flag does not match {tag}")
        if version in versions:
            raise ValueError(f"Duplicate release version: {version}")
        versions[version] = tag
    latest_version = latest["tag_name"].removeprefix("v")
    if (latest["draft"] or latest["prerelease"] or "-" in latest_version
            or latest_version not in versions):
        raise ValueError("Default documentation must be a published stable release")
    return versions, latest_version


def update_installers(output, versions):
    main = output / "main/user-guide/installation/index.html"
    if not main.exists() or "data-radio-installer" not in main.read_text():
        return
    dialog_pattern = r'<dialog\b[^>]*\bdata-release-dialog\b[^>]*>.*?</dialog>'
    dialog = re.search(dialog_pattern, main.read_text(), re.DOTALL)
    if not dialog:
        raise ValueError("Current installer is missing its release dialog")
    for entry in versions:
        if entry["version"] == "main":
            continue
        root = output / entry["version"]
        page = root / "user-guide/installation/index.html"
        if not page.exists() or "data-radio-installer" not in page.read_text():
            continue
        html, count = re.subn(dialog_pattern, lambda _: dialog[0], page.read_text(), flags=re.DOTALL)
        if count != 1:
            raise ValueError(f"Expected one release dialog in {page}")
        page.write_text(html)
        for name in ("radio-installer.mjs", "radio-panel.mjs", "radio-storage.mjs"):
            shutil.copyfile(output / "main/javascripts" / name, root / "javascripts" / name)


def export_site(repo, branch, output, latest_version):
    if output.exists():
        raise ValueError(f"Pages output already exists: {output}")
    extract_revision(repo, branch, output)
    latest_pages = json.loads((output / latest_version / "pages.json").read_text())
    versions = json.loads((output / "versions.json").read_text())
    update_installers(output, versions)
    paths = set()
    reserved = {"latest", "installer", *(entry["version"] for entry in versions)}
    for entry in versions:
        paths.update(json.loads((output / entry["version"] / "pages.json").read_text()))
        if entry["version"] == "main":
            paths.update(entry.get("properties", {}).get("legacy_pages", []))
    template = Environment(autoescape=True).from_string(REDIRECT.read_text())
    for path in sorted(paths):
        if not path or path == "404.html":
            continue
        if Path(path).parts[0] in reserved:
            raise ValueError(f"Documentation page conflicts with a site directory: {path}")
        redirect = output / path
        if path.endswith("/"):
            redirect /= "index.html"
        target = output / "latest" / (path if path in latest_pages else "")
        href = os.path.relpath(target, redirect.parent).replace(os.sep, "/")
        if path not in latest_pages or path.endswith("/"):
            href += "/"
        if path not in latest_pages:
            href += "?docs-page-missing=1"
        redirect.parent.mkdir(parents=True, exist_ok=True)
        redirect.write_text(template.render(href=href) + "\n")


def publish(repo, branch, releases, latest, output):
    versions, latest_version = release_versions(releases, latest)
    catalog = json.loads(mike(repo, branch, "list", "--json"))
    deployed = {entry["version"] for entry in catalog}
    legacy_pages = set()
    for entry in catalog:
        if entry["version"] == "main":
            legacy_pages.update(entry.get("properties", {}).get("legacy_pages", []))
            legacy_pages.update(json.loads(run(repo, "git", "show", f"{branch}:main/pages.json")))
    for version, tag in versions.items():
        if version not in deployed:
            deploy_version(repo, branch, version, tag)
    deploy_version(repo, branch, "main")
    if legacy_pages:
        print(mike(repo, branch, "props", "main", "--set",
                   "legacy_pages=" + json.dumps(sorted(legacy_pages))), end="")
    print(mike(repo, branch, "alias", "--update-aliases", "--alias-type", "redirect",
               "--template", str(REDIRECT), latest_version, "latest"), end="")
    print(mike(repo, branch, "set-default", "--template", str(REDIRECT), "latest"), end="")
    export_site(repo, branch, output, latest_version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branch", default="gh-pages")
    parser.add_argument("--output", type=Path, default=ROOT / "build/pages")
    args = parser.parse_args()
    repository = "thomaskistler/aero-grid"
    batches = json.loads(run(ROOT, "gh", "api", "--paginate", "--slurp",
                             f"repos/{repository}/releases?per_page=100"))
    latest = json.loads(run(ROOT, "gh", "api", f"repos/{repository}/releases/latest"))
    publish(ROOT, args.branch, [release for batch in batches for release in batch],
            latest, args.output.resolve())


if __name__ == "__main__":
    main()
