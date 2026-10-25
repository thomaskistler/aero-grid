// SPDX-License-Identifier: GPL-2.0-only

document.querySelectorAll(".ag-article table").forEach((table) => {
  const region = document.createElement("div");
  region.className = "ag-table-scroll";
  region.tabIndex = 0;
  region.setAttribute("role", "region");
  region.setAttribute("aria-label", "Scrollable table");
  table.before(region);
  region.append(table);
});
