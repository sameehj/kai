<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Next preview: UI

The first item for the preview after 0.2.0-preview.2. Done in 0.2.0-preview.2 (Nov 2 UI fixes) is marked so;
everything else is open.

## Open (deferred from the Nov 2 UI fixes)

1. **One agent list in Agent Control.** Merge "Coverage now", "What each agent can reach" and "Working now"
   into one list: each detected agent with its checks state, its sessions and what it can reach.
2. **Popover order.** Headline "N agents checked · N actions stopped today", then Needs you, Recent stops,
   working agents, and one coverage line that links to Settings (the full coverage list moves there).
3. **Notification action buttons: Why?** Card notifications already carry Allow for this task and Keep
   blocked; add Why? (opens the card in the popover with its reason and decision ID).
4. **Decision suggestions.** A model that suggests the decision for a card (allow for this task, keep
   blocked) from the task's context, shown as a suggestion the user confirms, never applied on its own.

## Done in 0.2.0-preview.2

- Only agents detected on this Mac in coverage; the rest under a collapsed "Other supported agents" in
  Settings, not in the popover.
- Status words: Checking / Watching, not blocking / Not included, explanations behind an info button,
  one line per row; colours by state (green checking, neutral watching, grey not included, red only for a
  real problem).
- Notifications: permission requested on first launch; a popover banner with Turn on when they're off;
  Allow for this task and Keep blocked on each card notification.
- Session names "project · Terminal tab N"; tty behind Details.
- Copy on every card (Needs you, Recent, Activity, session detail): `doc.on.doc` top right, visible on hover,
  VoiceOver "Copy details", a checkmark for 1.5 s; a plain-text brief (what happened, where, why, decision ID
  and time, what you can do; for Needs-you requests who requested it and what turning protection down would
  change). Never secret values or file contents.
- Needs-you protection-lowering cards in plain words with the real requester, Keep protection recommended,
  the raw rule behind Details, identical requests merged.

## Notes for the open items

- The copy brief for Needs-you access cards names the requesting agent and its signature; a session and
  Terminal tab aren't in the request yet (the network extension knows the session id, not the tab).
- "Unknown requester" appears when a protection-lowering request's caller chain names no agent and isn't
  the Kai app or a terminal `kai`.
