# Clean-Mac checklist (v0.2.0-preview.1)

Run on a Mac (macOS 13 or later) that has never had Kai, signed in as an admin user, with the
**signed, notarized** package from `make release`, not the `-UNSIGNED-TEST` one. Record each row as
PASS, FAIL, NOT COVERED or INCONCLUSIVE, with the command output or a screenshot. Don't add a pass rate.

Package: `Kai-Preview-<version>.pkg` · SHA-256 from the `.sha256` file: ______ · Mac / macOS: ______ · Date: ______

## 1. Install

| # | Do | Expect | Result |
| --- | --- | --- | --- |
| 1.1 | `shasum -a 256 Kai-Preview-*.pkg` | matches the `.sha256` file | |
| 1.2 | `spctl --assess --type install -vv Kai-Preview-*.pkg` | `accepted` · `source=Notarized Developer ID` | |
| 1.3 | Double-click the package; read Welcome and Read Me | "Files protection: not included in this release" is stated; no Gatekeeper warning | |
| 1.4 | `spctl --assess --type execute -vv /Applications/Kai.app` | `accepted` · `source=Notarized Developer ID` | |
| 1.5 | `codesign --verify --deep --strict /Applications/Kai.app && echo ok` | `ok` | |
| 1.6 | `kai version` | `0.2.0-preview.1 (release build) · commit <the tagged commit>` | |

## 2. Approve the extension

| # | Do | Expect | Result |
| --- | --- | --- | --- |
| 2.1 | Open Kai from Applications; turn on Internet in Settings | macOS asks to allow the system extension | |
| 2.2 | System Settings → Privacy & Security (or General → Login Items & Extensions → Network Extensions): allow Kai; allow the content filter | | |
| 2.3 | `systemextensionsctl list` | `io.github.sameehj.kai.network` · `[activated enabled]` | |
| 2.4 | Menu bar popover header | "Internet protected" and "Files: not included in this release" | |

## 3. `kai doctor`

| # | Do | Expect | Result |
| --- | --- | --- | --- |
| 3.1 | `kai install all` | hooks installed for each agent present | |
| 3.2 | `kai doctor` | no FAIL lines; Internet verified (heartbeat) | |
| 3.3 | `kai status` | `Internet: protecting · Files: not included in this release` | |
| 3.4 | In Claude Code: ask it to `cat ~/.ssh/id_ed25519` (create a dummy key first) | denied; the agent is told why and to ask you | |

## 4. Uninstall: hooks first, then nothing left behind

| # | Do | Expect | Result |
| --- | --- | --- | --- |
| 4.1 | `kai uninstall all --purge` | hooks removed **before** `~/.kai` is removed | |
| 4.2 | `grep -l "kai hook" ~/.claude/settings.json ~/.cursor/hooks.json ~/.codex/hooks.json ~/.codex/config.toml 2>/dev/null` | no output | |
| 4.3 | `grep -l "kai:agent-instructions" ~/.claude/CLAUDE.md ~/.codex/AGENTS.md 2>/dev/null` | no output | |
| 4.4 | Quit Kai; drag `/Applications/Kai.app` to the Trash; confirm the extension removal prompt | | |
| 4.5 | `systemextensionsctl list` | no `io.github.sameehj.kai.network` (or `[terminated waiting to uninstall on reboot]`; reboot, then none) | |
| 4.6 | `sudo rm -f /usr/local/bin/kai; sudo rm -rf /usr/local/share/kai; sudo pkgutil --forget io.github.sameehj.kai.preview` | | |
| 4.7 | `ls -d ~/.kai "$HOME/Library/Group Containers/KD446VDTM2.io.github.sameehj.kai" ~/Library/Preferences/io.github.sameehj.kai.plist /usr/local/bin/kai /Applications/Kai.app 2>&1` | each "No such file or directory" (record any that remain) | |
| 4.8 | System Settings → Network → Filters | no Kai content filter | |
| 4.9 | Start Claude Code, Codex and Cursor; run one tool call each | works; no error about a missing `kai` | |

## 5. Reinstall

| # | Do | Expect | Result |
| --- | --- | --- | --- |
| 5.1 | Repeat 1.3, 2.1–2.4 and 3.1–3.3 | same results as the first install | |
| 5.2 | `kai log verify` | chain intact (a fresh log) | |

Known gaps to note, not to fail: the manual removal in 4.6 (the package has no uninstaller in this
release), and the group container in 4.7 (macOS keeps it until removed by hand).
