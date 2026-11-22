/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#ifndef KAI_WIN_PWD_H
#define KAI_WIN_PWD_H
#include "kai_win_compat.h"
struct passwd { char *pw_name; char *pw_dir; uid_t pw_uid; };
/* The current user (name from GetUserNameW, dir = %USERPROFILE%) for any uid. */
struct passwd *getpwuid(uid_t uid);
#endif
