---
layout: post
title: Why a storage wall matters
description: The difference between checking an agent command and authorizing the file it actually opens.
category: Architecture
---

Imagine an agent asks to run a script. The hook sees the request to run that script. If the script constructs a sensitive file path later, the hook may never see that path. This is a limit of the information the agent gives the hook, even if the hook's command parser is careful.

## Checking the operation itself

The planned Kai storage wall would use macOS Endpoint Security authorization events. Instead of guessing which files a command may touch, it would evaluate an agent process when it actually tries to open a file. The design also calls for tracking agent child processes, so a shell or helper launched by an agent keeps the right identity.

That can address several entries in the [escape suite](https://github.com/sameehj/kai/blob/master/docs/ESCAPES.md): paths assembled from variables, file access inside a script, and some ways of reaching a file indirectly. The design must also distinguish commands you type yourself from commands an agent starts.

## Still a design, not a shipped control

Kai does not have this extension today. Building and distributing it requires Apple's Endpoint Security entitlement, careful testing of file operations, and clear behavior when the extension is unavailable. The [wall design](https://github.com/sameehj/kai/blob/master/docs/WALLS.md) describes the intended approach; it is not evidence that the storage wall is active.

Until then, protected paths are enforced through supported agent hooks. They are valuable checks, but they cannot cover file operations hidden inside arbitrary programs.
