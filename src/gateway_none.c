/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Builds without the MCP gateway (Windows, phase 1): no Internet wall yet. */
#include "internal.h"
#include <stdio.h>

int kai_gateway_run(const char *listen_addr, int port) {
    (void)listen_addr; (void)port;
    fprintf(stderr, "kai gateway: not available in this build (no Internet wall on Windows yet).\n");
    return 2;
}
