/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Windows shim: flock over LockFileEx. */
#ifndef KAI_WIN_SYS_FILE_H
#define KAI_WIN_SYS_FILE_H
#include "../kai_win_compat.h"
#define LOCK_SH 1
#define LOCK_EX 2
#define LOCK_NB 4
#define LOCK_UN 8
int flock(int fd, int op);
#endif
