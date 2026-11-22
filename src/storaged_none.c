/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Builds without the storage (Files wall) helper: Windows, phase 1. */
#include "internal.h"
#include <stdio.h>

int kai_cmd_storaged(int argc, char **argv) {
    (void)argc; (void)argv;
    fprintf(stderr, "kai storaged: not available in this build (no Files wall on Windows yet).\n");
    return 2;
}
