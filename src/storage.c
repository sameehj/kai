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
#include <sys/stat.h>

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

/* Item 3: creating a BRAND-NEW file whose name matches a secret pattern
 * (*.key, *.pem, …) but which is NOT inside a protected folder is not a secret
 * access - there's nothing there yet to read. The wall allows it (and logs it)
 * when the open creates the file (O_CREAT) and the file does not already exist.
 * Reading or overwriting an existing secret, and anything inside a protected
 * folder (~/.ssh, ~/.aws, ~/.kai, …), stays protected. */
int kai_new_secret_file(const kai_policy *p, const char *path, int o_creat) {
    if (!p || !path || !o_creat) return 0;
    char why[256];
    if (!kai_path_protected(p, path, NULL, why, sizeof why)) return 0;
    if (!kai_rule_is_name_pattern(why)) return 0;   /* a folder/path secret: always protected */
    struct stat st;
    if (stat(path, &st) == 0) return 0;             /* already exists: read/overwrite protected */
    return 1;                                        /* new name-pattern file: allow + log */
}

int kai_storage_open_allowed(const kai_policy *p, int is_agent, int write,
                             const char *path, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    /* The wall only ever constrains agents; everything else on the machine is
     * untouched. A read of a non-protected path is the common case. */
    if (!p || !is_agent || !path) return 1;
    if (!kai_path_protected(p, path, NULL, why, whylen)) return 1;
    /* Public ssh files (known_hosts, config, *.pub) are readable by agents so
     * git-over-ssh can verify a host; the private key stays protected and is
     * supplied by ssh-agent, never opened. Writes stay protected. */
    if (!write && kai_ssh_public_file(path)) { if (why && whylen) why[0] = '\0'; return 1; }
    /* Every protected path is denied to agents, reads and writes alike —
     * including Kai's own ~/.kai and the agents' hook settings. The only
     * processes allowed through are Kai's own code-signed components, which
     * the caller (the ES client) lets past before reaching here by verifying
     * the code signature — never by executable name. */
    return p->storage_mode == KAI_STORAGE_BLOCK ? 0 : 1;
}
