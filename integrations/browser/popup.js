// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
const $ = (id) => document.getElementById(id);

chrome.runtime.sendMessage({ type: "ping" }, (r) => {
  const ok = r && r.ok;
  $("state").textContent = ok ? `Protecting AI chats · kai ${r.version}` : "Not connected to Kai";
  $("state").className = ok ? "ok" : "bad";
  $("help").style.display = ok ? "none" : "block";
});

chrome.storage.local.get("kaiFailMode", ({ kaiFailMode = "ask" }) => {
  $("failmode").value = kaiFailMode;
});
$("failmode").addEventListener("change", (e) => {
  chrome.storage.local.set({ kaiFailMode: e.target.value });
});

chrome.storage.local.get("kaiStats", ({ kaiStats: s = {} }) => {
  $("checked").textContent = s.checked || 0;
  $("cleaned").textContent = s.cleaned || 0;
  $("held").textContent = s.held || 0;
});
