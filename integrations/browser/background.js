// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Relays the content script's requests to the local `kai` program over
// Chrome native messaging (see src/native.c). The page never talks to kai
// directly, and kai only scans and logs: it cannot change your policy.

const HOST = "io.github.sameehj.kai";
const STATS_KEY = "kaiStats";
const SITE_STATS_KEY = "kaiSiteStats";

// The AI-chat sites Kai knows about (mirrors manifest content_scripts matches).
// Used to group open tabs by site for the "AI chats" status report.
const CHAT_HOSTS = [
  "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com",
  "chat.deepseek.com", "perplexity.ai", "copilot.microsoft.com",
  "chat.mistral.ai", "grok.com", "poe.com",
];

function chatSiteOf(url) {
  let host;
  try { host = new URL(url).hostname; } catch { return null; }
  return CHAT_HOSTS.find((h) => host === h || host.endsWith("." + h)) || null;
}

// Every request starts Kai's helper afresh, so there is no connection to
// lose: once Kai is back (reinstalled, moved, updated), the next request
// works. What the user needs is to see when it isn't there: a red "!" on the
// toolbar icon until a request succeeds again.
function showConnected(ok, error) {
  chrome.action.setBadgeText({ text: ok ? "" : "!" });
  if (!ok) chrome.action.setBadgeBackgroundColor({ color: "#d64545" });
  chrome.action.setTitle({
    title: ok ? "Kai: connected"
              : `Kai: not connected (${error}). Messages wait for your decision until Kai is back.`,
  });
}

function ask(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
      if (chrome.runtime.lastError || !reply) {
        const error = chrome.runtime.lastError?.message || "no reply from kai";
        showConnected(false, error);
        resolve({ ok: false, error });
      } else {
        showConnected(true);
        resolve(reply);
      }
    });
  });
}

// Check as soon as the browser (re)starts the extension, not at the first send.
chrome.runtime.onStartup.addListener(() => { ask({ type: "ping" }); reportStatus(); });
chrome.runtime.onInstalled.addListener(() => { ask({ type: "ping" }); reportStatus(); });

async function bump(field) {
  const { [STATS_KEY]: s = { checked: 0, cleaned: 0, held: 0 } } = await chrome.storage.local.get(STATS_KEY);
  s[field] = (s[field] || 0) + 1;
  await chrome.storage.local.set({ [STATS_KEY]: s });
}

async function bumpSite(site, field) {
  if (!site) return;
  const { [SITE_STATS_KEY]: ss = {} } = await chrome.storage.local.get(SITE_STATS_KEY);
  const row = ss[site] || { redactions: 0, overrides: 0 };
  row[field] = (row[field] || 0) + 1;
  ss[site] = row;
  await chrome.storage.local.set({ [SITE_STATS_KEY]: ss });
}

// Tell Kai which AI-chat sites are open and their per-site redaction/override
// counts. Site only — never a full URL and never any chat text. This is the one
// source for the "AI chats" section; the network wall never watches browsers.
let reportTimer = null;
async function reportStatus() {
  let tabs;
  try { tabs = await chrome.tabs.query({}); } catch { return; }
  const { [SITE_STATS_KEY]: ss = {} } = await chrome.storage.local.get(SITE_STATS_KEY);
  const openBySite = {};
  for (const t of tabs) {
    const site = t.url ? chatSiteOf(t.url) : null;
    if (site) openBySite[site] = (openBySite[site] || 0) + 1;
  }
  // Union of sites that are open and sites we have counts for, so a closed site
  // reports open_tabs:0 instead of lingering at its last value.
  const seen = new Set([...Object.keys(openBySite), ...Object.keys(ss)]);
  const sites = [...seen].map((site) => ({
    site,
    open_tabs: openBySite[site] || 0,
    redactions: ss[site]?.redactions || 0,
    overrides: ss[site]?.overrides || 0,
  }));
  ask({ type: "status", sites });
}

function scheduleReport() {
  if (reportTimer) return;
  reportTimer = setTimeout(() => { reportTimer = null; reportStatus(); }, 1000);
}

// Opening, closing or navigating a tab can change which chat sites are open.
chrome.tabs.onCreated.addListener(scheduleReport);
chrome.tabs.onRemoved.addListener(scheduleReport);
chrome.tabs.onUpdated.addListener((_id, info) => { if (info.url || info.status === "complete") scheduleReport(); });

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Only our own content scripts and popup talk to us.
  if (sender.id !== chrome.runtime.id) return false;
  (async () => {
    if (msg?.type === "scan") {
      const reply = await ask({ type: "scan", text: String(msg.text || ""), site: String(msg.site || "") });
      if (reply.ok) await bump("checked");
      sendResponse(reply);
    } else if (msg?.type === "decision") {
      const site = String(msg.site || "");
      if (msg.action === "redacted") { await bump("cleaned"); await bumpSite(site, "redactions"); }
      if (msg.action === "sent_anyway") await bumpSite(site, "overrides");
      if (msg.action === "blocked" || msg.action === "cancelled") await bump("held");
      const reply = await ask({ type: "decision", site, action: String(msg.action || ""),
                                summary: String(msg.summary || "") });
      scheduleReport();
      sendResponse(reply);
    } else if (msg?.type === "ping") {
      sendResponse(await ask({ type: "ping" }));
    } else {
      sendResponse({ ok: false, error: "unknown request" });
    }
  })();
  return true; // async response
});
