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
# libcurl (gateway) and pthreads. On macOS link Apple's libcurl from the SDK
# explicitly, so a Homebrew/static libcurl in /usr/local can't shadow it.
ifeq ($(shell uname -s),Darwin)
SDK     := $(shell xcrun --show-sdk-path 2>/dev/null)
CFLAGS  += -I$(SDK)/usr/include
LDLIBS   = $(SDK)/usr/lib/libcurl.tbd -lpthread -framework Security -framework CoreFoundation
else
LDLIBS   = -lcurl -lpthread
endif

CORE = src/util.c src/policy.c src/scan.c src/sha256.c src/audit.c \
       src/net.c src/proc.c src/gateway.c third_party/cjson/cJSON.c
APP  = src/main.c src/hooks.c src/install.c src/manage.c

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
	sh tests/cli/run_cli_tests.sh ./kai
	sh tests/gateway/run_gateway_tests.sh ./kai

# macOS menu-bar app -> build/Kai.app (needs Xcode or the Swift toolchain)
app: kai
	sh app/macos/build-app.sh

install-app: app
	rm -rf /Applications/Kai.app
	cp -R build/Kai.app /Applications/Kai.app

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 kai $(DESTDIR)$(PREFIX)/bin/kai

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/kai

clean:
	rm -f $(OBJ) kai libkai.a tests/run_tests
	rm -rf build app/macos/.build

.PHONY: all asan test app install-app install uninstall clean
