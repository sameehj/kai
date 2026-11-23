/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#ifndef KAI_WIN_READPASSPHRASE_H
#define KAI_WIN_READPASSPHRASE_H
#include <stddef.h>
#define RPP_ECHO_OFF 0x00
#define RPP_REQUIRE_TTY 0x02
char *readpassphrase(const char *prompt, char *buf, size_t n, int flags);
#endif
