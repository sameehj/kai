/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Storage wall: which files an agent process may open.
 *
 * The decision is here, in plain C, with no OS involved, so it is fully
 * testable without Apple's Endpoint Security entitlement. The OS layer (a
 * macOS ES client, see app/macos/Storage, built only when the entitlement is
 * present) does nothing but gather the three facts this needs — is the opening
 * process an agent, is it opening for write, and the real path — and ask.
 *
 * It reuses kai_path_protected, so the storage wall and the hooks protect
 * exactly the same paths: ~/.ssh, .env, cloud keys, and (always, whatever the
 * allow list says) Kai's own files and the agents' hook settings.
 */
#include "internal.h"

#include <string.h>

int kai_storage_open_allowed(const kai_policy *p, int is_agent, int write,
                             const char *path, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    /* The wall only ever constrains agents; everything else on the machine is
     * untouched. A read of a non-protected path is the common case. */
    if (!p || !is_agent || !path) return 1;
    if (!kai_path_protected(p, path, NULL, why, whylen)) return 1;
    /* Kai's own control/config files (~/.kai, the agents' hook settings) are
     * not secret: agents may READ them, but must not WRITE them (that's how an
     * agent would disable Kai). Blocking reads here would also stop Kai's own
     * tools and any reader from loading the policy. Real secrets (the user's
     * protect rules, e.g. ~/.ssh) are denied both ways. */
    if (!write && kai_rule_is_builtin(why)) return 1;
    /* Protected. Off / log: allow (the caller logs why). Block: deny. */
    return p->storage_mode == KAI_STORAGE_BLOCK ? 0 : 1;
}
