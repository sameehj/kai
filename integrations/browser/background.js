// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Relays the content script's requests to the local `kai` program over
// Chrome native messaging (see src/native.c). The page never talks to kai
// directly, and kai only scans and logs: it cannot change your policy.

const HOST = "io.github.sameehj.kai";
const STATS_KEY = "kaiStats";
const SITE_STATS_KEY = "kaiSiteStats";

// The AI-chat sites Kai knows about (mirrors manifest content_scripts matches).
// Used to group open chat pages by site for the "AI chats" status report.
const CHAT_HOSTS = [
  "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com",
  "chat.deepseek.com", "perplexity.ai", "copilot.microsoft.com",
  "chat.mistral.ai", "grok.com", "poe.com",
];

const OPEN_KEY = "kaiOpenPages";   // tab id -> site, in session storage

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

// Spec §6: today's "secrets kept out" and the last event, for the popup.
const TODAY_KEY = "kaiToday", LAST_KEY = "kaiLast";
// Spec v2.1 A.7 outcomes: n = redacted before sending, nc = not checked
// (Kai unreachable and sent anyway). Nothing is noticed after sending.
async function bumpToday(field) {
  const day = new Date().toDateString();
  const { [TODAY_KEY]: t = { day, n: 0, nc: 0 } } = await chrome.storage.local.get(TODAY_KEY);
  const today = t.day === day ? { n: 0, nc: 0, ...t } : { day, n: 0, nc: 0 };
  today[field] = (today[field] || 0) + 1;
  await chrome.storage.local.set({ [TODAY_KEY]: today });
}
async function keptOut(site, action) { await bumpToday("n"); }
async function rememberLast(site, action, summary) {
  await chrome.storage.local.set({ [LAST_KEY]: { site, action, summary, ts: Date.now() } });
}

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

// Which chat pages are open: each chat page's script says hello when it loads
// and goodbye when it goes away, so Kai needs no "tabs" permission (which
// would show users "Read your browsing history"). Kept in session storage so a
// restarted service worker still knows. A closed tab is dropped on onRemoved,
// which fires without that permission.
async function openPages() {
  try { return (await chrome.storage.session.get(OPEN_KEY))[OPEN_KEY] || {}; } catch { return {}; }
}
async function setPage(tabId, site) {
  const pages = await openPages();
  if (site) pages[tabId] = site; else delete pages[tabId];
  try { await chrome.storage.session.set({ [OPEN_KEY]: pages }); } catch { /* best effort */ }
  scheduleReport();
}

// Tell Kai which AI-chat sites are open and their per-site redaction/override
// counts. Site only — never a full URL and never any chat text. This is the one
// source for the "AI chats" section; the network wall never watches browsers.
let reportTimer = null;
async function reportStatus() {
  const pages = await openPages();
  const { [SITE_STATS_KEY]: ss = {} } = await chrome.storage.local.get(SITE_STATS_KEY);
  const openBySite = {};
  for (const site of Object.values(pages)) openBySite[site] = (openBySite[site] || 0) + 1;
  // Union of sites that are open and sites we have counts for, so a closed site
  // reports open_tabs:0 instead of lingering at its last value.
  const seen = new Set([...Object.keys(openBySite), ...Object.keys(ss)]);
  const sites = [...seen].map((site) => ({
    site,
    open_tabs: openBySite[site] || 0,
    redactions: ss[site]?.redactions || 0,
    overrides: ss[site]?.overrides || 0,
  }));
  // The version lets Kai tell a copy Chrome hasn't reloaded ("reload the Kai
  // extension in Chrome"). Version only.
  ask({ type: "status", version: chrome.runtime.getManifest().version, sites });
}

function scheduleReport() {
  if (reportTimer) return;
  reportTimer = setTimeout(() => { reportTimer = null; reportStatus(); }, 1000);
}

// A closed tab takes its chat page with it.
chrome.tabs.onRemoved.addListener((tabId) => { setPage(tabId, null); });

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Only our own content scripts and popup talk to us.
  if (sender.id !== chrome.runtime.id) return false;
  (async () => {
    if (msg?.type === "page") {           // a chat page loaded (open) or went away
      const tabId = sender.tab?.id;
      const site = chatSiteOf("https://" + String(msg.site || ""));
      if (tabId !== undefined) await setPage(tabId, msg.open && site ? site : null);
      sendResponse({ ok: true });
    } else if (msg?.type === "scan") {
      const reply = await ask({ type: "scan", text: String(msg.text || ""), site: String(msg.site || "") });
      if (reply.ok) await bump("checked");
      sendResponse(reply);
    } else if (msg?.type === "decision") {
      const site = String(msg.site || "");
      if (msg.action === "redacted" || msg.action === "blocked") await keptOut(site, msg.action);
      if (msg.action === "redacted") { await bump("cleaned"); await bumpSite(site, "redactions"); }
      if (msg.action === "sent_anyway") await bumpSite(site, "overrides");
      if (msg.action === "blocked" || msg.action === "cancelled") await bump("held");
      if (msg.action === "redacted" || msg.action === "blocked")
        await rememberLast(site, msg.action, String(msg.summary || ""));
      const reply = await ask({ type: "decision", site, action: String(msg.action || ""),
                                summary: String(msg.summary || "") });
      scheduleReport();
      sendResponse(reply);
    } else if (msg?.type === "not_checked") {
      await bumpToday("nc");
      sendResponse({ ok: true });
    } else if (msg?.type === "not_secret") {   // from the popup's last event
      const { [LAST_KEY]: last } = await chrome.storage.local.get(LAST_KEY);
      if (!last) { sendResponse({ ok: false, error: "nothing to report" }); return; }
      const reply = await ask({ type: "decision", site: last.site, action: "not_a_secret", summary: last.summary || "" });
      if (reply.ok) await chrome.storage.local.set({ [LAST_KEY]: { ...last, reported: true } });
      sendResponse(reply);
    } else if (msg?.type === "ping") {
      sendResponse(await ask({ type: "ping" }));
    } else {
      sendResponse({ ok: false, error: "unknown request" });
    }
  })();
  return true; // async response
});
