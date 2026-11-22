/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Windows shim: opendir/readdir over FindFirstFileW (UTF-8 names). */
#ifndef KAI_WIN_DIRENT_H
#define KAI_WIN_DIRENT_H
#include "kai_win_compat.h"
#define DT_UNKNOWN 0
#define DT_DIR 4
#define DT_REG 8
#define DT_LNK 10
struct dirent {
    unsigned char d_type;
    char d_name[NAME_MAX * 3 + 1];
};
typedef struct kai_win_dir DIR;
DIR *opendir(const char *path);
struct dirent *readdir(DIR *d);
int closedir(DIR *d);
#endif
