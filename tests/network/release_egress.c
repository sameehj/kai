/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 * 0.5.1: built with -DKAI_RELEASE by `make test`. In a release build
 * "Watch + block my list" is effective and strict "only allowed hosts"
 * (egress block) is still clamped to Watch (G6 open). Policy entries only:
 * a release build ignores KAI_HOME, so this test never writes rules. */
#include "kai.h"
#include <stdio.h>
#include <string.h>

static int fails = 0, checks = 0;
#define CHECK(cond, msg) do { checks++; if (!(cond)) { printf("  FAIL: %s\n", msg); fails++; } \
                              else printf("  ok   %s\n", msg); } while (0)

int main(void) {
    printf("== release build: Internet modes ==\n");
    char err[256], why[256];
    CHECK(kai_internet_protect_available() == 0, "strict Protect is compiled out of release builds");
    kai_policy *b = kai_policy_from_string("egress block\n", err, sizeof err);
    CHECK(b && kai_policy_egress_requested(b) == KAI_EGRESS_BLOCK, "egress block parses");
    CHECK(b && kai_policy_egress_mode(b) == KAI_EGRESS_LOG, "egress block is clamped to Watch (log)");
    kai_policy_free(b);
    kai_policy *l = kai_policy_from_string("egress blocklist\negress_block kai-release-test.invalid 203.0.113.0/24\n",
                                           err, sizeof err);
    CHECK(l && kai_policy_egress_mode(l) == KAI_EGRESS_BLOCKLIST, "egress blocklist is effective");
    CHECK(l && kai_egress_blocklist_drop(l, "claude", "x.kai-release-test.invalid", "192.0.2.1", 443, why, sizeof why),
          "a listed site is refused for an agent");
    CHECK(l && kai_egress_blocklist_drop(l, "claude", NULL, "203.0.113.4", 443, why, sizeof why),
          "a listed range is refused for an agent");
    CHECK(l && !kai_egress_blocklist_drop(l, NULL, "kai-release-test.invalid", "192.0.2.1", 443, why, sizeof why),
          "non-agent flows are never refused");
    kai_policy_free(l);
    printf("\n%d checks, %d failures\n", checks, fails);
    return fails ? 1 : 0;
}
