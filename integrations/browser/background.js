// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Relays the content script's requests to the local `kai` program over
// Chrome native messaging (see src/native.c). The page never talks to kai
// directly, and kai only scans and logs: it cannot change your policy.

const HOST = "io.github.sameehj.kai";
const STATS_KEY = "kaiStats";

function ask(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
      if (chrome.runtime.lastError || !reply) {
        resolve({ ok: false, error: chrome.runtime.lastError?.message || "no reply from kai" });
      } else {
        resolve(reply);
      }
    });
  });
}

async function bump(field) {
  const { [STATS_KEY]: s = { checked: 0, cleaned: 0, held: 0 } } = await chrome.storage.local.get(STATS_KEY);
  s[field] = (s[field] || 0) + 1;
  await chrome.storage.local.set({ [STATS_KEY]: s });
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Only our own content scripts and popup talk to us.
  if (sender.id !== chrome.runtime.id) return false;
  (async () => {
    if (msg?.type === "scan") {
      const reply = await ask({ type: "scan", text: String(msg.text || ""), site: String(msg.site || "") });
      if (reply.ok) await bump("checked");
      sendResponse(reply);
    } else if (msg?.type === "decision") {
      if (msg.action === "redacted") await bump("cleaned");
      if (msg.action === "blocked" || msg.action === "cancelled") await bump("held");
      sendResponse(await ask({ type: "decision", site: String(msg.site || ""),
                               action: String(msg.action || ""), summary: String(msg.summary || "") }));
    } else if (msg?.type === "ping") {
      sendResponse(await ask({ type: "ping" }));
    } else {
      sendResponse({ ok: false, error: "unknown request" });
    }
  })();
  return true; // async response
});
