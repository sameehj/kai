<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Pre-S1 fix 2 — menu bar interim (live test)

Interim tidy of the menu-bar popover before the full S5 redesign. Four changes:

1. **Headline from observed wall state only (U1).** `StatusHero` and the menu
   glow now show what the walls are *measured* to be doing, never the configured
   policy. Running state comes from the OS extension objects the app already
   tracks (`StorageWall.isOn`, `NetworkWall.isOn`); the storage health snapshot
   distinguishes block from log. Strings: "Protected" (both enforcing), "Partly
   protected: storage is logging" / "… is off" / "network is off", "Not
   protected" (both off). A Kai problem (policy unreadable, audit tampered) still
   takes precedence.
   - Note: the network extension emits no health snapshot yet (M0.4 TODO), so its
     *running* state is read from the OS (reliable) but its log-vs-block mode is
     not distinguished here. Honest wording: "network is off" only when the OS
     says it is not running.
2. **Per-agent toggles moved to Settings.** The menu's protection section shows
   the two system walls only, with an "Agents →" link to Settings → General
   (which already manages agents; agents are on by default). No more per-agent
   cards in the menu.
3. **Identical items grouped with counts.** Active grants collapse by
   agent+resource+op+scope with "×N" and a single "Revoke all"
   (`GrantManager.grantGroups`); recent incidents collapse by
   agent+rule+target+decision with "×N" (`AppModel.importantEventGroups`).
4. **Each grant shows expiry and status.** Grant rows show a live countdown
   ("12m left" / "expired"); the interim lifecycle label is the countdown, with
   "received by wall / used" to be added in S6.

## Automated tests

No C changes in this fix; `make test` remains green (exit 0) from the trust-store
commit. The menu logic is pure Swift view-model code; the repo has no Swift test
target, so item 1's headline derivation and the grouping are verified by review
and the live (visual) test below. (Logic sanity check against the current live
status: storage extension not active and network reported not-running →
`observedHeadline` = "Not protected", which is correct.)

## Live test (human) — visual, in the menu-bar popover

1. **Observed headline.** With the storage wall OFF (current state), the popover
   reads **"Not protected"** (coral), not "Protection on". Activate the storage
   wall in Block and the network wall; it should read **"Protected"** (lime).
   Set storage to log (via the two-step pending flow) and it should read
   **"Partly protected: storage is logging"** — matching what the walls are
   actually doing, regardless of the configured policy.
   - Expected: headline tracks observed enforcement. Result: ______
2. **Agents not in the menu.** The popover's protection section shows only the
   Network and Storage walls plus an "Agents" link; per-agent toggles are in
   Settings → General.
   - Expected: no per-agent toggles in the menu. Result: ______
3. **Grouping + expiry.** With two identical grants active (e.g. approve the same
   resource twice), the menu shows one row "… ×2" with "Revoke all" and a live
   countdown. Repeated identical blocks in Recent show one line with "×N".
   - Expected: grouped rows with counts; grant shows a countdown. Result: ______

### Results (filled after the live run)

- [ ] 1 headline reflects observed enforcement (not / partly / protected) —
- [ ] 2 no per-agent toggles in the menu; Agents link opens Settings —
- [ ] 3 identical grants and recent items grouped with counts; grant countdown —
