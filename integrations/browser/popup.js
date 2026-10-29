// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Spec §6: one sentence of status, today's count, the last event with "Not a
// secret", and what Kai checks. Same words as the app: "kept out" for secrets.
const $ = (id) => document.getElementById(id);

function ago(ts) {
  const s = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}

async function openChats() {
  try {
    const { kaiOpenPages: pages = {} } = await chrome.storage.session.get("kaiOpenPages");
    return Object.keys(pages).length;
  } catch { return 0; }
}

chrome.runtime.sendMessage({ type: "ping" }, async (r) => {
  const ok = r && r.ok;
  const n = await openChats();
  $("status").textContent = !ok ? "Kai isn't connected"
    : n === 0 ? "Kai checks your AI chats" : `Kai is checking ${n} chat${n === 1 ? "" : "s"}`;
  $("help").hidden = !!ok;
});

chrome.storage.local.get(["kaiToday", "kaiLast"], ({ kaiToday: t, kaiLast: last }) => {
  const n = t && t.day === new Date().toDateString() ? t.n : 0;
  $("today").textContent = n ? `${n} secret${n === 1 ? "" : "s"} kept out today` : "Nothing kept out today";
  if (!last) return;
  $("last").hidden = false;
  $("lastText").innerHTML = "";
  const b = document.createElement("b");
  b.textContent = last.site;
  $("lastText").append(b, last.action === "redacted" ? ": Kai removed a secret before sending."
                                                    : ": Kai held a message with a secret.");
  $("lastAgo").textContent = ago(last.ts);
  if (last.reported) { $("notSecret").textContent = "Reported"; $("notSecret").disabled = true; }
});

$("notSecret").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "not_secret" }, (r) => {
    $("notSecret").textContent = r && r.ok ? "Reported" : "Couldn't report";
    $("notSecret").disabled = !!(r && r.ok);
    if (r && r.ok) $("lastAgo").textContent = "Thanks. Kai keeps checking it; use Send anyway when it's safe.";
  });
});

chrome.storage.local.get("kaiFailMode", ({ kaiFailMode = "ask" }) => { $("failmode").value = kaiFailMode; });
$("failmode").addEventListener("change", (e) => { chrome.storage.local.set({ kaiFailMode: e.target.value }); });
