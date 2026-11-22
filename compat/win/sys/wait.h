/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Windows shim: waitpid over process handles started by kai_plat_spawn. */
#ifndef KAI_WIN_SYS_WAIT_H
#define KAI_WIN_SYS_WAIT_H
#include "../kai_win_compat.h"
#define WNOHANG 1
#define WIFEXITED(s) 1
#define WEXITSTATUS(s) ((s) & 0xff)
#define WIFSIGNALED(s) 0
#define WTERMSIG(s) 0
pid_t waitpid(pid_t pid, int *status, int options);
#endif
