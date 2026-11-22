/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#ifndef KAI_WIN_SYS_TIME_H
#define KAI_WIN_SYS_TIME_H
#include "../kai_win_compat.h"
#ifndef _TIMEVAL_DEFINED
#define _TIMEVAL_DEFINED
struct timeval { long tv_sec; long tv_usec; };
#endif
int gettimeofday(struct timeval *tv, void *tz);
#endif
