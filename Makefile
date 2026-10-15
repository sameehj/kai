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

# macOS app (menu bar + network system extension), via XcodeGen + Xcode.
#   make app                  ad-hoc signed; menu bar works, the network wall
#                             can't load (CI, quick local builds)
#   make app-dev KAI_TEAM=..  signed with your Apple team; network wall works
#   make install-app          copy build/Kai.app to /Applications
XCODE_FLAGS = -project app/macos/Kai.xcodeproj -scheme Kai -configuration Release \
              -derivedDataPath build/dd
app: kai
	cd app/macos && xcodegen generate --quiet
	xcodebuild $(XCODE_FLAGS) CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
	  DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= $(XCODE_EXTRA) -quiet build
	rm -rf build/Kai.app && cp -R build/dd/Build/Products/Release/Kai.app build/Kai.app

app-dev: kai
	@test -n "$(KAI_TEAM)" || { echo "set KAI_TEAM to your Apple team ID"; exit 1; }
	cd app/macos && KAI_TEAM=$(KAI_TEAM) xcodegen generate --quiet
	xcodebuild $(XCODE_FLAGS) -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=$(KAI_TEAM) \
	  $(XCODE_EXTRA) -quiet build
	rm -rf build/Kai.app && cp -R build/dd/Build/Products/Release/Kai.app build/Kai.app

# Build signed, install to /Applications, quit any running copy, and open it.
try-app: app-dev
	@pkill -x Kai || true
	$(MAKE) install-app
	open /Applications/Kai.app

install-app:
	@test -d build/Kai.app || { echo "build it first: make app or make app-dev"; exit 1; }
	rm -rf /Applications/Kai.app
	cp -R build/Kai.app /Applications/Kai.app

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 kai $(DESTDIR)$(PREFIX)/bin/kai

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/kai

clean:
	rm -f $(OBJ) kai libkai.a tests/run_tests
	rm -rf build app/macos/Kai.xcodeproj

.PHONY: all asan test app app-dev try-app install-app install uninstall clean
