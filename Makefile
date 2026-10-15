# Kai — Makefile. Builds the `kai` binary and libkai.a.
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial

CC      ?= cc
PREFIX  ?= /usr/local
CSTD    ?= -std=c11
WARN     = -Wall -Wextra -Wno-unused-parameter
HARDEN   = -D_FORTIFY_SOURCE=2 -fstack-protector-strong
OPT     ?= -O2
CFLAGS  ?= $(CSTD) $(WARN) $(OPT) $(HARDEN)
CFLAGS  += -Iinclude -Ithird_party/cjson -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE
LDLIBS   =

CORE = src/util.c src/policy.c src/scan.c src/sha256.c src/audit.c \
       third_party/cjson/cJSON.c
APP  = src/main.c src/hooks.c src/install.c

OBJ      = $(CORE:.c=.o) $(APP:.c=.o)
COREOBJ  = $(CORE:.c=.o)

all: kai libkai.a

kai: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDLIBS)

libkai.a: $(COREOBJ)
	$(AR) rcs $@ $(COREOBJ)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Address/UB sanitizer build used in CI
asan: CFLAGS += -fsanitize=address,undefined -g -O1
asan: clean kai test

test: kai
	$(CC) $(CFLAGS) -o tests/run_tests tests/run_tests.c $(CORE) $(LDLIBS)
	./tests/run_tests
	sh tests/hooks/run_hook_tests.sh ./kai

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 kai $(DESTDIR)$(PREFIX)/bin/kai

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/kai

clean:
	rm -f $(OBJ) kai libkai.a tests/run_tests

.PHONY: all asan test install uninstall clean
