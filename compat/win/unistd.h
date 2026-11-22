/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Windows shim: see kai_win_compat.h (force-included before this). */
#ifndef KAI_WIN_UNISTD_H
#define KAI_WIN_UNISTD_H
#include "kai_win_compat.h"
#define F_OK 0
#define W_OK 2
#define R_OK 4
#define X_OK 0   /* _access has no execute bit: existence */
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define fsync _commit
#define ftruncate _chsize_s
unsigned int kai_win_sleep(unsigned int s);
#define sleep kai_win_sleep
int kai_win_usleep(unsigned long us);
#define usleep kai_win_usleep
#endif
