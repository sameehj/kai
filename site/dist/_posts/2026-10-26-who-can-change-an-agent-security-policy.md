---
layout: post
title: Who can change an agent security policy?
description: Why blocking a command is easier than proving who approved a change to the blocker.
category: Engineering notes
---

An agent denied access to a file has another possible move: ask the security tool to change its own policy. A command such as `kai policy add allow …` is still a real Kai command when an agent launches it. The executable's signature says which program ran; it does not say a person approved the change.

This is the control-plane problem: **who is allowed to weaken the rules, and how does Kai know?**

## What exists, and where

The published `master` branch still lets the CLI write policy directly. In a newer development branch, the CLI checks whether a policy-changing process belongs to a recognized agent tree and refuses that call. A loosening change requested from outside a recognized agent tree is held as a pending proposal for confirmation in Kai's app. The app has a separate path for signing access grants. The storage extension can deny agent access to Kai's control files when that extension is active and enforcing. These development changes are not a released control service.

Those are useful barriers, but they do not make the control plane complete. The current CLI and app coordinate through files under `~/.kai`; there is no authenticated XPC service that owns every policy and grant write. Process ancestry can be uncertain, and a direct file write is a different path from invoking the CLI. Storage protection depends on the extension's *observed* state, not a toggle's requested state. We have not established that UI automation cannot trigger an approval.

## The design we want to test

One dedicated writer would own policy and grant changes. Other components would submit requests to it. The writer would authenticate the actual peer using operating-system identity and a specific code-signing requirement, then check whether the caller belongs to an agent session. A request to loosen protection with uncertain ancestry would wait for explicit user approval; an agent would never approve its own request. An authorized tightening request need not wait merely because it was detached from its parent process.

This distinction is easy to miss: **a signed Kai CLI can be under an agent's control**. A Team ID alone is also too broad a test for a privileged writer. Apple documents [XPC peer requirement APIs](https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_entitlement_matches_value_requirement(_:_:_:)); the exact API and macOS 14 availability need checking before choosing the implementation.

The user interface has work to do here. A pending change should show the old and new rule, who requested it, what becomes reachable, and an explicit approve or reject action. It should then show whether the running extension loaded the new policy. “Saved to disk” is not the same as “enforced.”

## What would count as evidence

We would test the genuine signed CLI launched by an agent, a direct write to the control store, a detached process, an unsigned imitation of Kai, and an `osascript` attempt to drive the app's approval UI. Each test needs the resulting policy file, audit record and extension health snapshot. The extension must also be tested in Log, Block and Off, because its protection cannot be assumed after it is disabled or removed.

For now, this is **development work and an unfinished design**, not a claim that Kai has authenticated control over every write path. The public branch has the more basic CLI path; the newer safeguards still need live tests and a deliberate release before we can claim the approval loop works end to end.
