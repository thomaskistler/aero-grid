// SPDX-License-Identifier: GPL-2.0-only
for (const connect of document.querySelectorAll("[data-connect]")) {
  const actions = document.createElement("div");
  actions.className = "ag-radio-connect-actions";
  connect.before(actions);
  actions.append(connect);

  const help = document.createElement("button");
  help.type = "button";
  help.className = "ag-radio-help-button";
  help.setAttribute("aria-label", "Install over USB help");
  help.title = "Install over USB help";
  help.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3m.08 4h.01"/></svg>';

  const popover = document.createElement("div");
  popover.id = connect.id ? `${connect.id}-help` : "ag-radio-connect-help";
  popover.className = "ag-radio-help-popover";
  popover.setAttribute("popover", "auto");
  popover.setAttribute("role", "region");
  popover.setAttribute("aria-label", "Radio connection help");
  popover.innerHTML = `
    <h3>Install over USB</h3>
    <p>Use <strong>desktop Google Chrome or Microsoft Edge</strong>. Safari and Opera do not support USB access.</p>
    <p>Power on the radio, connect its <strong>data USB port</strong> using a USB cable that supports data, and choose <strong>USB Storage</strong> if prompted.</p>
    <p>Click <strong>Connect Radio</strong> and select the <strong>SD-card root</strong>: the folder containing <code>RADIO</code>, <code>MODELS</code>, and <code>WIDGETS</code>, not the <code>WIDGETS</code> folder itself.</p>
    <p>The connection stays available between pages in this tab. <strong>Disconnect Radio</strong> clears it.</p>
    <p>Back up your SD card and model configuration before making changes. AeroGrid requires a color-screen radio running EdgeTX 2.11.0 or later.</p>`;
  const close = document.createElement("button");
  close.type = "button";
  close.className = "ag-radio-button";
  close.textContent = "Close";
  close.addEventListener("click", () => {
    popover.hidePopover();
    help.focus();
  });
  popover.append(close);
  help.setAttribute("popovertarget", popover.id);
  const host = connect.closest("[data-radio-installer], [data-radio-connection]");
  actions.prepend(help);
  host.append(popover);
}
