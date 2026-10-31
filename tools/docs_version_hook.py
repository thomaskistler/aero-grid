# SPDX-License-Identifier: GPL-2.0-only
"""Record page routes for navigation between documentation versions."""
import json
from pathlib import Path


def on_post_build(config):
    site = Path(config["site_dir"])
    paths = []
    for page in site.rglob("*.html"):
        path = page.relative_to(site).as_posix()
        if config["use_directory_urls"] and page.name == "index.html":
            path = path.removesuffix("index.html")
        paths.append(path)
    (site / "pages.json").write_text(json.dumps(sorted(paths)) + "\n")
