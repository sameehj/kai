// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Spec v2.1 A.7: one status sentence, today's redactions before sending, the
// last event with "Not a secret". Three outcomes, never mixed: redacted before
// sending, noticed after sending (this version never does), not checked.
const $ = (id) => document.getElementById(id);
// Sites the Chats coverage matrix proves (docs/COVERAGE.md). Empty until the
// manual runs are recorded; others say "not yet verified".
const VERIFIED_SITES = [];

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
    return Object.values(pages);
  } catch { return []; }
}

chrome.runtime.sendMessage({ type: "ping" }, async (r) => {
  const ok = r && r.ok;
  const pages = await openChats();
  const sites = [...new Set(pages)];
  const unverified = sites.filter((s) => !VERIFIED_SITES.includes(s));
  $("status").textContent = !ok ? "Not checking: Kai isn't connected"
    : sites.length === 0 ? "Checking AI chats when you open one"
    : `Checking ${pages.length} chat${pages.length === 1 ? "" : "s"} on ${sites.join(", ")}`
      + (unverified.length ? " (not yet verified on these sites)" : "");
  $("help").hidden = !!ok;
});

chrome.storage.local.get(["kaiToday", "kaiLast"], ({ kaiToday: t, kaiLast: last }) => {
  const today = t && t.day === new Date().toDateString();
  const n = today ? t.n || 0 : 0, nc = today ? t.nc || 0 : 0;
  $("today").textContent = `Today: ${n} redacted before sending` + (nc ? ` · ${nc} sent not checked` : "");
  if (!last) return;
  $("last").hidden = false;
  $("lastText").innerHTML = "";
  const b = document.createElement("b");
  b.textContent = last.site;
  $("lastText").append(b, last.action === "redacted" ? ": a secret was redacted before sending."
                                                    : ": a message with a secret was held before sending.");
  $("lastAgo").textContent = ago(last.ts);
  if (last.reported) { $("notSecretBtn").textContent = "Reported"; $("notSecretBtn").disabled = true; }
});

$("notSecretBtn").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "not_secret" }, (r) => {
    $("notSecretBtn").textContent = r && r.ok ? "Reported" : "Couldn't report";
    $("notSecretBtn").disabled = !!(r && r.ok);
    if (r && r.ok) $("lastAgo").textContent = "Thanks. Kai keeps checking it; use Send anyway when it's safe.";
  });
});

chrome.storage.local.get("kaiFailMode", ({ kaiFailMode = "ask" }) => { $("failmode").value = kaiFailMode; });
$("failmode").addEventListener("change", (e) => { chrome.storage.local.set({ kaiFailMode: e.target.value }); });
