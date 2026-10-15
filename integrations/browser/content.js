// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai for AI chat sites. Before a message is sent, and when you paste text,
// it asks the local `kai` program (through background.js) to check it
// against your Kai policy:
//
//   paste            -> secrets are cleaned as they land in the box
//   send (Enter or   -> nothing found: sends as usual
//   the send button)    something found: the message is held and you choose
//                       Redact and send / Send anyway / Edit
//                       a "block" rule: held, Edit only
//
// Every choice is recorded in Kai's audit log, which never stores the matched text.
(() => {
  if (window.__kaiLoaded) return;
  window.__kaiLoaded = true;

  const SITE = location.hostname || "local-test";
  const SEND_SELECTORS = [
    'button[data-testid="send-button"]',
    'button[data-testid="composer-send-button"]',
    'button[aria-label="Send message"]',
    'button[aria-label="Send prompt"]',
    'button[aria-label*="Send" i]',
    'button[aria-label*="Submit" i]',
    'button[type="submit"]',
  ].join(",");

  let bypass = false;       // true while Kai re-sends a message it approved
  let lastApproved = null;  // text already checked and approved
  let busy = false;

  // ---------- the composer ----------

  const isField = (el) => el && (el.tagName === "TEXTAREA" ||
    (el.tagName === "INPUT" && /^(text|search)$/i.test(el.type)));

  function composerOf(el) {
    if (!el || el.nodeType !== 1) return null;
    if (isField(el)) return el;
    const ce = el.closest('[contenteditable="true"], [contenteditable=""]');
    return ce || null;
  }

  function findComposer() {
    return composerOf(document.activeElement) ||
      document.querySelector('#prompt-textarea, div.ProseMirror[contenteditable="true"], ' +
                             'rich-textarea [contenteditable="true"], textarea, [contenteditable="true"]');
  }

  const textOf = (el) => (isField(el) ? el.value : el.innerText || "").replace(/ /g, " ");

  // Replace the composer's whole text the way a user would (so the page's
  // editor framework sees a normal input event).
  function setText(el, text) {
    el.focus();
    if (isField(el)) {
      el.select();
      if (!document.execCommand("insertText", false, text)) {
        const proto = Object.getPrototypeOf(el);
        Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
        el.dispatchEvent(new Event("input", { bubbles: true }));
      }
      return;
    }
    const range = document.createRange();
    range.selectNodeContents(el);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    document.execCommand("insertText", false, text);
  }

  function findSendButton(composer) {
    const scope = composer?.closest("form") || composer?.parentElement?.parentElement?.parentElement || document;
    return scope.querySelector(SEND_SELECTORS) || document.querySelector(SEND_SELECTORS);
  }

  function triggerSend(composer) {
    bypass = true;
    setTimeout(() => {
      const btn = findSendButton(composer);
      if (btn && !btn.disabled) {
        btn.click();
      } else {
        composer.focus();
        composer.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13,
                                                              which: 13, bubbles: true, cancelable: true }));
      }
      setTimeout(() => { bypass = false; }, 400);
    }, 60); // let the editor framework take in a just-replaced text first
  }

  // ---------- talking to kai ----------

  const ask = (msg) => new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage(msg, (r) => resolve(r || { ok: false, error: chrome.runtime.lastError?.message }));
    } catch (e) {
      resolve({ ok: false, error: String(e) }); // extension reloaded while the page stayed open
    }
  });
  const scan = (text) => ask({ type: "scan", text, site: SITE });
  const decide = (action, summary) => ask({ type: "decision", site: SITE, action, summary });

  const FRIENDLY = {
    aws_access_key: "an AWS access key", aws_secret_key: "an AWS secret key",
    github_token: "a GitHub token", gitlab_token: "a GitLab token", slack_token: "a Slack token",
    stripe_key: "a Stripe key", google_api_key: "a Google API key", openai_key: "an OpenAI key",
    anthropic_key: "an Anthropic key", openrouter_key: "an OpenRouter key", jwt: "a login token (JWT)",
    private_key_block: "a private key", db_url_with_password: "a database password",
    generic_secret_assign: "a password or secret",
  };
  function describe(hits) {
    const parts = (hits || []).map((h) => {
      const r = String(h.rule || "");
      if (r.startsWith("secret:")) return FRIENDLY[r.slice(7)] || r.slice(7).replace(/_/g, " ");
      if (r.startsWith("term:")) return `“${r.slice(5)}”`;
      return r.replace(/_/g, " ");
    });
    const uniq = [...new Set(parts)];
    if (uniq.length <= 1) return uniq[0] || "sensitive data";
    return uniq.slice(0, -1).join(", ") + " and " + uniq[uniq.length - 1];
  }

  // ---------- send ----------

  async function check(composer) {
    const text = textOf(composer).trim();
    if (!text) return;
    if (text === lastApproved) { triggerSend(composer); return; }
    busy = true;
    const r = await scan(text);
    busy = false;
    if (!r.ok) {
      // Never fail open silently: either the user said "send unchecked" in
      // the popup, or we ask on this message.
      const { kaiFailMode = "ask" } = await chrome.storage.local.get("kaiFailMode").catch(() => ({}));
      if (kaiFailMode === "send") {
        toast("warn", "Sent without a Kai check", "Kai isn't reachable on this computer.");
        lastApproved = text;
        triggerSend(composer);
        return;
      }
      panel({
        tone: "redact",
        title: "Kai can't check this message",
        body: "Kai isn't reachable on this computer, so nothing was checked. Open the Kai app, " +
              "or run its Chrome setup again.",
        actions: [
          { label: "Edit", primary: true, run: () => composer.focus() },
          { label: "Send unchecked", run: () => { lastApproved = text; triggerSend(composer); } },
        ],
      });
      return;
    }
    if (r.worst === "none" || r.worst === "allow" || r.worst === "warn") {
      if (r.worst === "warn") toast("warn", "Kai noted something", `This message mentions ${describe(r.hits)}.`);
      lastApproved = text;
      triggerSend(composer);
      return;
    }
    const what = describe(r.hits);
    if (!r.can_override) {
      decide("blocked", r.summary);
      panel({
        tone: "block",
        title: "Kai held this message",
        body: `It contains ${what}, which your policy doesn't allow to be sent.`,
        actions: [{ label: "Edit message", primary: true, run: () => composer.focus() }],
      });
      return;
    }
    panel({
      tone: "redact",
      title: `Kai found ${what}`,
      body: "Send it with the sensitive parts removed, or edit it yourself.",
      preview: r.cleaned,
      actions: [
        { label: "Redact and send", primary: true, run: () => {
            decide("redacted", r.summary);
            setText(composer, r.cleaned);
            lastApproved = r.cleaned.trim();
            triggerSend(composer);
          } },
        { label: "Send anyway", run: () => {
            decide("sent_anyway", r.summary);
            lastApproved = text;
            triggerSend(composer);
          } },
        { label: "Edit", run: () => { decide("cancelled", r.summary); composer.focus(); } },
      ],
    });
  }

  window.addEventListener("keydown", (e) => {
    if (bypass || e.key !== "Enter" || e.shiftKey || e.altKey || e.isComposing) return;
    const composer = composerOf(e.target);
    if (!composer || !textOf(composer).trim()) return;
    if (textOf(composer).trim() === lastApproved) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (!busy) check(composer);
  }, true);

  window.addEventListener("click", (e) => {
    if (bypass) return;
    const btn = e.target?.closest?.(SEND_SELECTORS);
    if (!btn) return;
    const composer = findComposer();
    if (!composer || !textOf(composer).trim() || textOf(composer).trim() === lastApproved) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (!busy) check(composer);
  }, true);

  // ---------- paste ----------

  window.addEventListener("paste", async (e) => {
    const composer = composerOf(e.target);
    const text = e.clipboardData?.getData("text/plain");
    if (!composer || !text || text.length < 8) return; // short pastes can't hold a key
    e.preventDefault();
    e.stopImmediatePropagation();
    const r = await scan(text);
    composer.focus();
    if (!r.ok) {
      // A paste stays on this computer until it's sent, and sending is
      // checked (or asked about) separately, so paste it but say so.
      document.execCommand("insertText", false, text);
      toast("warn", "Kai can't check pastes right now", "Kai isn't reachable on this computer.");
      return;
    }
    if (r.worst === "none" || r.worst === "allow" || r.worst === "warn") {
      document.execCommand("insertText", false, text);
      return;
    }
    const what = describe(r.hits);
    if (!r.can_override) {
      decide("blocked", r.summary);
      toast("block", "Kai didn't paste that", `It contains ${what}, which your policy doesn't allow.`);
      return;
    }
    document.execCommand("insertText", false, r.cleaned);
    decide("redacted", r.summary);
    toast("ok", "Kai cleaned your paste", `Removed ${what} before it reached the chat.`);
  }, true);

  // ---------- UI (in a shadow root, so the site's styles can't touch it) ----------

  const host = document.createElement("kai-guard");
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `
    <style>
      :host { all: initial; }
      .wrap { position: fixed; left: 50%; bottom: 96px; transform: translateX(-50%); z-index: 2147483647;
              width: min(560px, calc(100vw - 32px)); font: 14px/1.45 -apple-system, BlinkMacSystemFont,
              "Segoe UI", sans-serif; color: #fff; }
      .card { background: #101114; border: 1px solid #2A2C32; border-radius: 16px; padding: 16px 18px;
              box-shadow: 0 18px 50px rgba(0,0,0,.45), 0 0 0 1px rgba(255,255,255,.02); }
      .card.redact { border-color: #4A3F1E; box-shadow: 0 18px 50px rgba(0,0,0,.45), 0 0 40px rgba(255,181,71,.18); }
      .card.block, .card.blockt { border-color: #4A2A27; box-shadow: 0 18px 50px rgba(0,0,0,.45), 0 0 40px rgba(255,107,94,.22); }
      .card.ok { border-color: #3A4420; box-shadow: 0 18px 50px rgba(0,0,0,.45), 0 0 40px rgba(217,255,63,.16); }
      .head { display: flex; align-items: center; gap: 10px; font-weight: 650; font-size: 15px; }
      .dot { width: 26px; height: 26px; border-radius: 8px; display: grid; place-items: center;
             font-weight: 800; font-size: 13px; color: #101114; background: #D9FF3F; flex: none; }
      .redact .dot { background: #FFB547; } .block .dot, .blockt .dot { background: #FF6B5E; }
      .body { color: #C9CCD3; margin: 6px 0 0 36px; }
      .preview { margin: 10px 0 0 36px; background: #1C1D21; border-radius: 10px; padding: 10px 12px;
                 font: 12px/1.5 ui-monospace, Menlo, monospace; color: #E6E8EC; max-height: 120px;
                 overflow: auto; white-space: pre-wrap; word-break: break-word; }
      .actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 14px 0 0 36px; }
      button { font: inherit; font-size: 13px; font-weight: 600; border-radius: 10px; padding: 8px 14px;
               cursor: pointer; border: 1px solid #2A2C32; background: transparent; color: #fff; }
      button.primary { background: #D9FF3F; color: #101114; border-color: #D9FF3F; }
      button:focus-visible { outline: 2px solid #D9FF3F; outline-offset: 2px; }
      .brand { margin-left: auto; font-size: 11px; font-weight: 600; letter-spacing: .08em; color: #A7ABB4; }
    </style>
    <div class="wrap" role="status" aria-live="polite"></div>`;
  const wrap = root.querySelector(".wrap");
  (document.body || document.documentElement).appendChild(host);
  let toastTimer = null;

  function render({ tone, title, body, preview, actions }) {
    clearTimeout(toastTimer);
    wrap.textContent = "";
    const card = document.createElement("div");
    card.className = `card ${tone}`;
    const head = document.createElement("div");
    head.className = "head";
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.textContent = tone === "ok" ? "✓" : "!";
    const t = document.createElement("span");
    t.textContent = title;
    const brand = document.createElement("span");
    brand.className = "brand";
    brand.textContent = "KAI";
    head.append(dot, t, brand);
    card.append(head);
    if (body) {
      const b = document.createElement("div");
      b.className = "body";
      b.textContent = body;
      card.append(b);
    }
    if (preview) {
      const p = document.createElement("div");
      p.className = "preview";
      p.textContent = preview;
      card.append(p);
    }
    if (actions?.length) {
      const row = document.createElement("div");
      row.className = "actions";
      for (const a of actions) {
        const btn = document.createElement("button");
        btn.textContent = a.label;
        if (a.primary) btn.className = "primary";
        btn.addEventListener("click", () => { close(); a.run(); });
        row.append(btn);
      }
      card.append(row);
      setTimeout(() => row.querySelector("button")?.focus(), 0);
    }
    wrap.append(card);
  }

  function close() { clearTimeout(toastTimer); wrap.textContent = ""; }

  function panel(opts) { render(opts); }

  function toast(tone, title, body) {
    render({ tone: tone === "block" ? "blockt" : tone, title, body });
    toastTimer = setTimeout(close, 6000);
  }

  root.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
})();
