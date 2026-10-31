// SPDX-License-Identifier: GPL-2.0-only
const picker = document.querySelector("[data-docs-version]");

if (picker?.dataset.docsRoot) {
  const status = picker.parentElement.querySelector("[role='status']");
  const root = new URL(picker.dataset.docsRoot, location.href);
  const current = picker.dataset.docsVersion;
  const versionPattern = /^(main|(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:beta|rc)\.(?:0|[1-9]\d*))?)$/;

  async function readJSON(url) {
    const response = await fetch(url, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status} loading ${url.pathname}`);
    return response.json();
  }

  function report(error) {
    console.error("[AeroGrid documentation] Version navigation failed.", error);
    status.textContent = "Documentation versions could not be loaded. Please reload to try again.";
  }

  async function initialize() {
    if (root.origin !== location.origin || !root.pathname.endsWith("/")) {
      throw new Error("Invalid documentation root");
    }
    const versions = await readJSON(new URL("versions.json", root));
    if (!Array.isArray(versions) || !versions.length || versions.some((entry) =>
      !versionPattern.test(entry.version) || !Array.isArray(entry.aliases))) {
      throw new Error("Invalid documentation version catalog");
    }
    if (!versions.some((entry) => entry.version === current)) {
      throw new Error("Current documentation version is missing from the catalog");
    }
    picker.replaceChildren();
    for (const entry of [...versions.filter((entry) => entry.version !== "main"),
      ...versions.filter((entry) => entry.version === "main")]) {
      const option = document.createElement("option");
      option.value = entry.version;
      option.textContent = entry.version === "main" ? "main (unreleased)"
        : `v${entry.version}${entry.aliases.includes("latest") ? " (latest)"
          : entry.version.includes("-") ? " (prerelease)" : ""}`;
      picker.append(option);
    }
    picker.value = current;
    picker.disabled = false;
    if (new URL(location.href).searchParams.has("docs-page-missing")) {
      status.textContent = "This page is not available in this version. Showing its home page.";
    }
    picker.addEventListener("change", async () => {
      const version = picker.value;
      picker.disabled = true;
      status.textContent = "";
      try {
        if (!versions.some((entry) => entry.version === version)) {
          throw new Error("Unknown documentation version");
        }
        const target = new URL(`${version}/`, root);
        const pages = await readJSON(new URL("pages.json", target));
        if (!Array.isArray(pages) || !pages.includes("")
          || pages.some((path) => typeof path !== "string")) {
          throw new Error("Invalid documentation page catalog");
        }
        const source = new URL(`${current}/`, root);
        if (!location.pathname.startsWith(source.pathname)) {
          throw new Error("Current page is outside its documentation version");
        }
        let path = location.pathname.slice(source.pathname.length);
        if (path === "index.html" || path.endsWith("/index.html")) {
          path = path.slice(0, -"index.html".length);
        }
        if (pages.includes(path)) {
          target.pathname += path;
          target.search = location.search;
          target.searchParams.delete("docs-page-missing");
          target.hash = location.hash;
        } else {
          target.searchParams.set("docs-page-missing", "1");
        }
        location.assign(target.href);
      } catch (error) {
        picker.value = current;
        picker.disabled = false;
        report(error);
      }
    });
  }

  initialize().catch(report);
}
