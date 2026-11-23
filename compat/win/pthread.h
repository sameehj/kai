/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Windows shim: the locks approval_store.c uses, on SRWLOCK. */
#ifndef KAI_WIN_PTHREAD_H
#define KAI_WIN_PTHREAD_H
#include "kai_win_compat.h"
typedef struct { void *p; int excl; } pthread_rwlock_t;   /* SRWLOCK + who holds it */
typedef struct { void *p; } pthread_mutex_t;
#define PTHREAD_RWLOCK_INITIALIZER {0, 0}
#define PTHREAD_MUTEX_INITIALIZER {0}
int pthread_rwlock_init(pthread_rwlock_t *l, const void *attr);
int pthread_rwlock_destroy(pthread_rwlock_t *l);
int pthread_rwlock_rdlock(pthread_rwlock_t *l);
int pthread_rwlock_wrlock(pthread_rwlock_t *l);
int pthread_rwlock_unlock(pthread_rwlock_t *l);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_unlock(pthread_mutex_t *m);
#endif
