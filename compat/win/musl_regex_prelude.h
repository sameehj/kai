/* SPDX-License-Identifier: MIT */
/* Force-included into third_party/musl-regex/*.c on MSVC: the few musl-isms. */
#define hidden
#include <malloc.h>
#ifndef alloca
#define alloca _alloca
#endif
#ifndef CHARCLASS_NAME_MAX
#define CHARCLASS_NAME_MAX 14
#endif
#ifndef RE_DUP_MAX
#define RE_DUP_MAX 255
#endif
