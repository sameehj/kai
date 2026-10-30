"""Builds the Chrome Web Store screenshot stage: the extension's real
popup.html/popup.js/content.js with a stand-in chrome API, on 1280x800 pages."""
import json, os, shutil  # stage for make-screenshots.sh
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../..'))
EXT = ROOT + '/integrations/browser'
T = os.environ['KAI_STORE_WORK']
S = T + '/stage'
shutil.rmtree(S, ignore_errors=True)
os.makedirs(S)
shutil.copytree(EXT + '/icons', S + '/icons')
for f in ('popup.js', 'content.js'):
    shutil.copy(EXT + '/' + f, S + '/' + f)
msg = open(T + '/msg.txt').read()
cleaned = open(T + '/cleaned.txt').read().rstrip('\n')

def popup_stub(connected):
    return '''<script>
window.chrome = {
  runtime: { lastError: undefined, sendMessage(m, cb) { setTimeout(() => cb && cb({ ok: %s }), 0); } },
  storage: {
    session: { get: async () => ({ kaiOpenPages: %s }) },
    local: {
      _d: { kaiToday: { day: new Date().toDateString(), n: %d }, kaiFailMode: "ask", kaiLast: %s },
      get(keys, cb) { const r = {}; for (const k of [].concat(keys)) r[k] = this._d[k];
                      if (cb) cb(r); return Promise.resolve(r); },
      set() { return Promise.resolve(); } } } };
</script>''' % ('true' if connected else 'false',
                '{}',
                3 if connected else 0,
                '{ site: "claude.ai", action: "redacted", ts: Date.now() - 4 * 60000 }' if connected else 'undefined')

popup = open(EXT + '/popup.html').read()
for name, conn in (('popup-on.html', True), ('popup-off.html', False)):
    open(S + '/' + name, 'w').write(popup.replace('<script src="popup.js"></script>',
                                                  popup_stub(conn) + '\n<script src="popup.js"></script>'))

BASE_CSS = '''
  * { box-sizing: border-box; }
  html, body { margin: 0; width: 1280px; height: 800px; overflow: hidden; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .hero { position: absolute; left: 72px; top: 0; bottom: 0; width: 520px; display: flex; flex-direction: column;
          justify-content: center; color: #fff; }
  .hero .logo { display: flex; align-items: center; gap: 12px; font-size: 22px; font-weight: 700; letter-spacing: .02em; }
  .hero .logo img { width: 44px; height: 44px; }
  .hero h1 { font-size: 46px; line-height: 1.12; margin: 28px 0 18px; font-weight: 750; letter-spacing: -.01em; }
  .hero h1 em { font-style: normal; color: #D9FF3F; }
  .hero p { font-size: 19px; line-height: 1.5; color: #C9CCD3; margin: 0; }
  .dark { background: radial-gradient(90% 80% at 75% 20%, rgba(217,255,63,.14), transparent 60%), #0B0C0E; }
'''

def hero(h1, p):
    return ('<div class="hero"><div class="logo"><img src="icons/kai-128.png" alt="">Kai</div>'
            '<h1>%s</h1><p>%s</p></div>' % (h1, p))

# 1) a held message, on a neutral chat page, by the real content.js
chat = '''<!doctype html><html><head><meta charset="utf-8"><style>%s
  body { background: #F6F6F4; color: #1d1d1f; }
  .bar { height: 56px; display: flex; align-items: center; padding: 0 28px; border-bottom: 1px solid #e5e5e2;
         font-weight: 650; color: #3a3a3c; background: #fff; }
  .bar span { color: #8e8e93; font-weight: 500; margin-left: 10px; }
  .thread { width: 760px; margin: 28px auto 0; display: flex; flex-direction: column; gap: 14px; }
  .b { max-width: 600px; padding: 12px 16px; border-radius: 16px; font-size: 15px; line-height: 1.5; }
  .ai { background: #fff; border: 1px solid #e5e5e2; align-self: flex-start; }
  .me { background: #E9E9E6; align-self: flex-end; }
  form { position: absolute; left: 50%%; transform: translateX(-50%%); bottom: 22px; width: 760px; display: flex;
         gap: 10px; align-items: flex-end; background: #fff; border: 1px solid #d9d9d5; border-radius: 18px; padding: 10px; }
  textarea { flex: 1; border: 0; resize: none; font: 14px/1.5 ui-monospace, Menlo, monospace; height: 66px; outline: none; }
  button.send { width: 38px; height: 38px; border-radius: 12px; border: 0; background: #1d1d1f; color: #fff; font-size: 18px; }
  .cap { position: absolute; top: 9px; right: 28px; background: #0B0C0E; color: #fff; border-radius: 12px;
         padding: 10px 14px; font-size: 14px; font-weight: 600; }
  .cap em { font-style: normal; color: #D9FF3F; }
</style></head><body>
<div class="bar">AI chat<span>any supported chat site</span></div>
<div class="cap"><em>Kai</em> checks your message before it's sent</div>
<div class="thread">
  <div class="b me">My deploy keeps failing, can you look at the script?</div>
  <div class="b ai">Sure. Paste the part of the script that runs the upload, and the error you get.</div>
</div>
<form id="f" onsubmit="return false"><textarea id="t" aria-label="Message"></textarea>
<button class="send" type="submit" aria-label="Send message">↑</button></form>
<script>
const CLEANED = %s;
window.chrome = { runtime: { lastError: undefined, sendMessage(m, cb) {
  const r = m.type === "scan"
    ? { ok: true, worst: "redact", can_override: true, hits: [{ rule: "secret:aws_access_key" }],
        cleaned: CLEANED, summary: "secret:aws_access_key x1 (redact)" }
    : { ok: true };
  setTimeout(() => cb && cb(r), 0); } },
  storage: { local: { get: async () => ({}), set: async () => {} }, session: { get: async () => ({}) } } };
</script>
<script src="content.js"></script>
<script>
const t = document.getElementById("t");
t.value = %s;
setTimeout(() => { t.focus(); t.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true, cancelable: true })); }, 300);
</script></body></html>''' % (BASE_CSS, json.dumps(cleaned), json.dumps(msg))
open(S + '/shot1-held.html', 'w').write(chat)

# 2) the popup, connected
def popup_page(name, src, h1, p, badge):
    return '''<!doctype html><html><head><meta charset="utf-8"><style>%s
  .browser { position: absolute; right: 72px; top: 170px; width: 520px; height: 460px; background: #1B1C20;
             border: 1px solid #2A2C32; border-radius: 14px; overflow: hidden; box-shadow: 0 30px 80px rgba(0,0,0,.55); }
  .toolbar { height: 48px; display: flex; align-items: center; gap: 10px; padding: 0 14px; background: #232429;
             border-bottom: 1px solid #2A2C32; }
  .url { flex: 1; height: 30px; border-radius: 15px; background: #16171A; }
  .ext { position: relative; width: 30px; height: 30px; border-radius: 8px; background: #2E3036; display: grid; place-items: center; }
  .ext img { width: 18px; height: 18px; }
  .ext b { position: absolute; right: -5px; bottom: -4px; min-width: 16px; height: 16px; border-radius: 8px;
           background: #d64545; color: #fff; font-size: 11px; font-weight: 800; display: grid; place-items: center; padding: 0 4px; }
  iframe { position: absolute; right: 14px; top: 56px; width: 300px; height: 360px; border: 1px solid #2A2C32;
           border-radius: 12px; background: #101114; box-shadow: 0 18px 50px rgba(0,0,0,.5); }
</style></head><body class="dark">%s
<div class="browser"><div class="toolbar"><div class="url"></div><div class="ext"><img src="icons/kai-32.png" alt="">%s</div></div>
<iframe src="%s" scrolling="no"></iframe></div></body></html>''' % (BASE_CSS, hero(h1, p), badge, src)

open(S + '/shot2-popup.html', 'w').write(popup_page('2', 'popup-on.html',
    'Secrets stay <em>out of AI chats</em>',
    'Kai checks what you paste and send on supported AI chat sites, on your computer, using your own Kai policy. '
    'Found a key or a password? Send it redacted, or edit it first.', ''))
open(S + '/shot3-offline.html', 'w').write(popup_page('3', 'popup-off.html',
    'You always know <em>when Kai isn\'t checking</em>',
    'If Kai on your Mac isn\'t reachable, the toolbar icon shows a red “!” and Kai asks before anything is sent: '
    'never a silent pass. The popup says how to fix it.', '<b>!</b>'))

# promo tile 440x280
tile = '''<!doctype html><html><head><meta charset="utf-8"><style>
  html, body { margin: 0; width: 440px; height: 280px; overflow: hidden; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #fff;
         background: radial-gradient(90% 90% at 80% 0%, rgba(217,255,63,.20), transparent 60%), #0B0C0E;
         display: flex; flex-direction: column; justify-content: center; padding: 0 36px; box-sizing: border-box; }
  .logo { display: flex; align-items: center; gap: 12px; font-size: 30px; font-weight: 750; }
  .logo img { width: 54px; height: 54px; }
  p { font-size: 21px; line-height: 1.3; margin: 18px 0 0; font-weight: 650; }
  p em { font-style: normal; color: #D9FF3F; }
</style></head><body><div class="logo"><img src="icons/kai-128.png" alt="">Kai</div>
<p>Keeps secrets <em>out of AI chats</em>.</p></body></html>'''
open(S + '/tile-440x280.html', 'w').write(tile)
print('stage ok:', sorted(os.listdir(S)))
