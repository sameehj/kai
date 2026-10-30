# Chrome Web Store images

For the Kai listing (see [docs/CHROME_STORE.md](../../../docs/CHROME_STORE.md)). Regenerate with
`sh integrations/browser/store/make-screenshots.sh` after `make kai`.

| File | Size | Shows |
|---|---|---|
| `kai-store-1-held-message.png` | 1280×800 | A message with a key held before sending: Redact and send / Send anyway / Edit, with the redacted preview. The extension's real `content.js` on a neutral chat page; the redaction is real `kai` output. |
| `kai-store-2-popup.png` | 1280×800 | The popup: "Checking AI chats when you open one", today's count, the last event with "Not a secret". |
| `kai-store-3-not-connected.png` | 1280×800 | The red "!" when Kai isn't reachable, and the popup's fix-it text. |
| `kai-store-promo-440x280.png` | 440×280 | Small promo tile. |

The chat page is generic (no chat service's name or look). The key is AWS's documentation example key. The
screenshots use the extension's own code with a stand-in Chrome API, so the wording is exactly what users see.
