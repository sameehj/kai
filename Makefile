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
LDLIBS   = -lcurl -lpthread -lm
endif

CORE = src/util.c src/policy.c src/scan.c src/sha256.c src/audit.c \
       src/net.c src/storage.c src/storage_prof.c src/grant.c src/approval_store.c src/proc.c src/shell.c src/gateway.c src/session.c third_party/cjson/cJSON.c
APP  = src/main.c src/hooks.c src/install.c src/manage.c src/browser.c src/native.c src/report.c src/health.c src/storaged.c src/grant_cli.c

OBJ      = $(CORE:.c=.o) $(APP:.c=.o)
COREOBJ  = $(CORE:.c=.o)

all: kai libkai.a

kai: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDLIBS)

libkai.a: $(COREOBJ)
	$(AR) rcs $@ $(COREOBJ)

%.o: %.c include/kai.h src/internal.h
	$(CC) $(CFLAGS) -c -o $@ $<

# Random malformed input against the hook handlers (run after `make asan`
# to catch memory errors)
fuzz: kai
	ASAN_OPTIONS=detect_leaks=0 python3 -I tests/fuzz/fuzz_hooks.py ./kai 3000

# Address/UB sanitizer build used in CI
asan: CFLAGS += -fsanitize=address,undefined -g -O1
asan: clean kai test

# The storage suite exercises the policy-change engine (kai_policy_dispatch in
# manage.c), so it links the app sources too, minus main.c (it has its own).
STORAGE_TEST_SRC = $(CORE) $(filter-out src/main.c,$(APP))

test: kai
	$(CC) $(CFLAGS) -o tests/run_tests tests/run_tests.c $(CORE) $(LDLIBS)
	./tests/run_tests
	$(CC) $(CFLAGS) -o tests/storage/run_storage_tests tests/storage/run_storage_tests.c $(STORAGE_TEST_SRC) $(LDLIBS)
	./tests/storage/run_storage_tests
	sh tests/hooks/run_hook_tests.sh ./kai
	# Suites that SET UP policy via `kai policy ...` use a throwaway binary built
	# with the test seam (KAI_TEST_DIRECT_POLICY): the suites run inside the
	# dev's agent tree and set loosening switches, both of which the production
	# refusal + pending-hold (correctly) block. The seam is never in the product
	# or signed build; the refusal and pending-hold are covered by
	# run_storage_tests. Suites that don't touch policy use the real ./kai.
	$(CC) $(CFLAGS) -DKAI_TEST_DIRECT_POLICY -o tests/cli/kai-test $(CORE) $(APP) $(LDLIBS)
	sh tests/cli/run_cli_tests.sh tests/cli/kai-test
	sh tests/gateway/run_gateway_tests.sh tests/cli/kai-test
	sh tests/browser/run_native_tests.sh tests/cli/kai-test
	python3 -I tests/corpus/run_corpus.py ./kai
	python3 -I tests/escape/run_escape.py ./kai

# Escape suite: what agents can still get past. Also regenerates docs/ESCAPES.md
# and docs/SECURITY-VALIDATION.md (with the last tests/network/results.json).
escape: kai
	python3 -I tests/escape/run_escape.py ./kai --markdown docs/ESCAPES.md --validation docs/SECURITY-VALIDATION.md

validation: escape

# Chrome Web Store upload (no "key", no local test page): build/kai-chrome-<version>.zip
chrome-zip:
	python3 -I scripts/package-chrome.py

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

# Build the app AND the Endpoint Security storage extension (needs the ES
# development entitlement on your team). Generates from the storage.yml overlay
# so the normal project, CI and distribution never include it. The extension
# defaults to notify mode (observe/log, never blocks).
app-storage: kai
	@test -n "$(KAI_TEAM)" || { echo "set KAI_TEAM to your Apple team ID"; exit 1; }
	cd app/macos && KAI_TEAM=$(KAI_TEAM) xcodegen generate --quiet --spec storage.yml
	xcodebuild $(XCODE_FLAGS) -allowProvisioningUpdates DEVELOPMENT_TEAM=$(KAI_TEAM) $(XCODE_EXTRA) -quiet build
	xcodebuild -project app/macos/Kai.xcodeproj -scheme KaiStorage -configuration Release \
	  -derivedDataPath build/dd -allowProvisioningUpdates DEVELOPMENT_TEAM=$(KAI_TEAM) $(XCODE_EXTRA) -quiet build
	@echo "Built KaiStorage (mode set by XCODE_EXTRA). See docs/WALLS.md before local activation."

# Build the app WITH the storage extension embedded, install to /Applications,
# and open it, so the storage wall can be activated from the menu. Development
# only (needs the ES dev entitlement); the extension is approved once in
# System Settings. Keep `storage` at log first; switch to block only after.
try-app-storage: kai
	@test -n "$(KAI_TEAM)" || { echo "set KAI_TEAM to your Apple team ID"; exit 1; }
	cd app/macos && KAI_TEAM=$(KAI_TEAM) xcodegen generate --quiet --spec storage.yml
	xcodebuild $(XCODE_FLAGS) -allowProvisioningUpdates DEVELOPMENT_TEAM=$(KAI_TEAM) $(XCODE_EXTRA) -quiet build
	@pkill -x Kai || true
	rm -rf build/Kai.app && cp -R build/dd/Build/Products/Release/Kai.app build/Kai.app
	$(MAKE) install-app
	open /Applications/Kai.app
	@echo "Approve the storage extension in System Settings, keep storage=log, then watch Activity."

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
	install -d $(DESTDIR)$(PREFIX)/share/kai/browser/icons
	install -m 0644 integrations/browser/*.js integrations/browser/*.json \
	  integrations/browser/popup.html $(DESTDIR)$(PREFIX)/share/kai/browser/
	install -m 0644 integrations/browser/icons/*.png $(DESTDIR)$(PREFIX)/share/kai/browser/icons/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/kai

clean:
	rm -f $(OBJ) kai libkai.a tests/run_tests tests/storage/run_storage_tests tests/cli/kai-test
	rm -rf build app/macos/Kai.xcodeproj

.PHONY: all asan fuzz test escape validation chrome-zip app app-dev app-storage try-app-storage try-app install-app install uninstall clean
