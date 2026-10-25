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
#include <sys/fcntl.h>

int kai_open_is_write(int fflag) {
    /* Endpoint Security's open event carries `fflag` in the kernel's file-flags
     * convention (FREAD/FWRITE), where the access mode is the open(2) mode + 1:
     * O_RDONLY -> FREAD, O_WRONLY -> FWRITE, O_RDWR -> FREAD|FWRITE. A read-only
     * open therefore has the FWRITE bit CLEAR but FREAD set. Masking with
     * O_ACCMODE and comparing to O_RDONLY (as a naive translation would) flags
     * every read as a write, which is what blocked Kai's own policy read and
     * failed every prompt closed (the Oct 25 S0 incident). The other O_ flags
     * (O_CREAT/O_TRUNC/O_APPEND) are preserved verbatim in fflag. */
    return (fflag & FWRITE) != 0 || (fflag & (O_CREAT | O_TRUNC | O_APPEND)) != 0;
}

int kai_storage_open_allowed(const kai_policy *p, int is_agent, int write,
                             const char *path, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    /* The wall only ever constrains agents; everything else on the machine is
     * untouched. A read of a non-protected path is the common case. */
    if (!p || !is_agent || !path) return 1;
    if (!kai_path_protected(p, path, NULL, why, whylen)) return 1;
    (void)write;
    /* Every protected path is denied to agents, reads and writes alike —
     * including Kai's own ~/.kai and the agents' hook settings. The only
     * processes allowed through are Kai's own code-signed components, which
     * the caller (the ES client) lets past before reaching here by verifying
     * the code signature — never by executable name. */
    return p->storage_mode == KAI_STORAGE_BLOCK ? 0 : 1;
}
