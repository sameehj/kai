# Publishing the Kai browser extension

The extension can't work alone: it asks the Kai program on the user's computer
(Chrome native messaging) to check each message. Publish it **unlisted** first,
for testers who already have Kai installed.

## 1. Build the upload

```sh
make chrome-zip        # build/kai-chrome-<version>.zip
```

The package drops the manifest's `key` (the store assigns its own ID), the local
test page and its `file://` match. It fails if the manifest asks for more than
`nativeMessaging` and `storage`.

## 2. First upload, then connect the store ID to Kai

1. Developer dashboard → **New item** → upload the zip. The item gets an ID.
2. Put that ID in `KAI_STORE_EXTENSION_ID` (`src/internal.h`), rebuild, and
   ship that Kai. `kai install chrome` then lets both the unpacked extension and
   the store one talk to Kai, and `kai status` recognizes either.
3. Optional: copy the item's public key (dashboard → Package → View public key)
   into `manifest.json` `key`, so unpacked development builds use the store ID too.

Until step 2 ships, a store-installed copy shows a red "!" (not connected) and
holds every message for the user's decision.

## 3. Listing

**Name:** Kai

**Summary (132 chars max):** Checks what you send to AI chats for secrets and company data, using your local Kai policy. Nothing leaves your computer.

**Description:**

> Kai checks the text you paste or send in AI chats (ChatGPT, Claude.ai, Gemini, DeepSeek, Perplexity, Copilot, Mistral, Grok, Poe) against the policy of the Kai app on your computer. API keys and passwords are cleaned out as you paste; a message with something sensitive waits for you: send it cleaned, send it anyway, or edit it.
>
> Requires the free, open-source Kai app (github.com/sameehj/kai). The check happens on your computer: the extension sends text only to Kai, never to us or anyone else, and Kai's log records which rules matched, never your message. If Kai isn't reachable, the toolbar icon shows "!" and messages wait for your decision.
>
> Kai is a developer preview. It catches the formats it recognizes; it is not a guarantee that nothing sensitive is sent.

**Category:** Developer Tools (or Productivity).

**Single purpose:** Check messages typed or pasted into AI chat sites for secrets and company data, using the user's local Kai policy, before they are sent.

**Permission justifications:**

| Permission | Why |
|---|---|
| `nativeMessaging` | Sends the message text to the Kai program on the user's own computer, which checks it against the user's policy. This is the extension's only way to check anything. |
| `storage` | Keeps three local counters shown in the popup and the user's setting for when Kai isn't reachable. |
| Content scripts on the nine chat sites | Reads the chat box on those sites only, to check what the user pastes or sends there. |

**Remote code:** none. All code is in the package.

**Data use disclosures** (Privacy practices tab): the extension handles *website content* (the text typed into the chat box) only to provide its single purpose, on the user's device. It doesn't sell or transfer data, doesn't use it for anything unrelated, and doesn't use it for creditworthiness or lending. Tick the three certifications.

**Privacy policy URL:** https://sameehj.github.io/kai/privacy/

**Screenshots (1280×800):** the popup ("Protecting AI chats"); a held message with Redact and send / Send anyway / Edit; the red "!" when Kai isn't running.

## 4. Before submitting, check by hand

- [ ] Load the zip's contents unpacked in a clean Chrome profile with Kai running: the popup says "Protecting AI chats", pasting a fake key (`ghp_` + 36 letters) is cleaned.
- [ ] Quit or move Kai: the icon turns to a red "!" on the next message, the message is held, and nothing is sent silently.
- [ ] Reinstall Kai (or move it back) and send again: the "!" clears without reloading the extension.
- [ ] Each of the nine sites: the paste and send paths still work (chat editors change; see `content.js`).
