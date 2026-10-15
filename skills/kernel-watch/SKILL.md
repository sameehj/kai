# Kernel Watch

Use this skill to compare the running kernel with latest stable upstream versions.

## Steps
1. Determine running kernel:
   - `exec`: `uname -r`
2. Fetch latest stable references:
   - `read`: `https://www.kernel.org/`
3. Optional details:
   - `read`: latest ChangeLog URL from kernel.org links
4. Summarize mismatch and risk posture.

## Constraints
- Do not parse LKML in v0.1.
