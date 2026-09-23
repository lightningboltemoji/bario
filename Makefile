# bario build entry points: the Swift build + test loop, and the app bundle the bar ships in.

# --- Swift Testing toolchain wiring -----------------------------------------------------------
# Under a full Xcode or a swift.org toolchain, `swift test` runs Swift Testing out of the box.
# A CommandLineTools-only install ships Testing.framework + libTestingMacros.dylib but doesn't
# wire them into SwiftPM's explicit-module test build, so we load the macro plugin and add the
# framework/interop rpaths explicitly. We detect that case by probing for the CLT plugin; when
# it's absent (i.e. Xcode is active) TEST_FLAGS stays empty and `swift test` runs unmodified.
DEVDIR          := $(shell xcode-select -p 2>/dev/null)
TESTING_PLUGIN  := $(DEVDIR)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
TESTING_FWK     := $(DEVDIR)/Library/Developer/Frameworks
TESTING_INTEROP := $(DEVDIR)/Library/Developer/usr/lib

ifeq ($(wildcard $(TESTING_PLUGIN)),)
  TEST_FLAGS :=
else
  TEST_FLAGS := -Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN) \
                -Xlinker -rpath -Xlinker $(TESTING_FWK) \
                -Xlinker -rpath -Xlinker $(TESTING_INTEROP)
endif

# --- Linker search-path noise -------------------------------------------------------------------
# The same CLT-only install makes SwiftPM pass `-F $(DEVDIR)/Developer/Library/Frameworks` (and a
# matching `-L .../Developer/usr/lib` for executable products) on every link. That subtree only
# exists inside Xcode.app, so ld warns once per target — lines that bury real diagnostics. The
# flags are SwiftPM's own, not ours: nothing in Package.swift can drop them, and nothing we link
# lives there, so the paths are pure noise.
#
# So filter, narrowly: only `search path ... not found` lines naming that one directory, and only on
# stderr. Every other diagnostic still passes through; `swift build` writes its progress to stdout,
# which is left alone so it keeps its tty (in-place progress line, colors); and a redirect — as
# opposed to a pipe — leaves the exit status intact, so a failed build still fails the target.
# Requires bash for `>(...)`; make's default /bin/sh would not do.
SHELL   := /bin/bash
LD_NOISE = ld: warning: search path '$(DEVDIR)/Developer/.*' not found
QUIET    = 2> >(grep -vE "$(LD_NOISE)" >&2)

.PHONY: build release test clean app zip dist install uninstall print-version
build:
	swift build $(QUIET)

release:
	swift build -c release $(QUIET)

test:
	swift test $(TEST_FLAGS) $(QUIET)

clean:
	swift package clean
	rm -rf $(DIST)

# --- Version -------------------------------------------------------------------------------------
# The git tag is the only version authority; nothing in the tree carries a number. A tagged commit
# builds `0.2.0`, anything else builds what `git describe` says, and outside a checkout `0.0.0`.
# `app` stamps both keys into the bundle's *copy* of the plist, never the source, and `barioVersion`
# reads them back out at runtime — so an unbundled build reports `dev`, which is what it is.
GIT_DESCRIBE := $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null)
VERSION      ?= $(if $(GIT_DESCRIBE),$(patsubst v%,%,$(GIT_DESCRIBE)),0.0.0)
BUILD        ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

print-version:
	@echo $(VERSION)

# --- bario.app -------------------------------------------------------------------------------
# The bundle exists so Screen Recording permission attaches to a stable bundle identifier rather
# than to whichever terminal launched the binary — grant it to a terminal and you have granted it
# to everything that terminal ever runs. It is also the only way macOS will show the Location
# prompt the wifi module needs for an SSID. Assembled by hand rather than by Xcode because there
# is no GUI to build: SwiftPM produces the executable and this copies it next to an Info.plist.
#
# `Resources/Info.plist` is the source of every key including the bundle identifier, which is why
# `codesign` is not told one — it reads `CFBundleIdentifier` from the plist it just copied, so the
# identity is stated once. The version is stamped into the bundle's *copy*, never the source.
#
# **Signing defaults to ad-hoc (`--sign -`)**, which is enough for the permission to stick to this
# identifier across rebuilds as long as the identifier does not change. A machine that cannot sign
# at all still gets a bundle that runs, so that failure is a warning rather than an error;
# `CODESIGN_IDENTITY` overrides it with a Developer ID, which brings the hardened runtime and a
# secure timestamp with it, and is asked for deliberately enough that failing it should fail.
#
# The bundle is `Bario.app` while the executable inside it stays `bario`: the file name is what Finder
# and the Homebrew cask show, the executable is what a script calls. It is built into $(DIST), the one
# directory the release workflow reads from.
APP_NAME := bario
DIST     := dist
BUNDLE   := $(DIST)/Bario.app
CONTENTS := $(BUNDLE)/Contents
RELEASE  := .build/release

CODESIGN_IDENTITY ?= -
ifeq ($(CODESIGN_IDENTITY),-)
  SIGN_FLAGS :=
  # SwiftPM ad-hoc signs the binary it builds, so codesign always has a signature to replace and
  # always says so. Nothing to act on, and the fallback below says the only thing worth reading.
  SIGN_FALLBACK := >/dev/null 2>&1 || echo "  (could not codesign; permissions may be re-requested after each build)"
else
  SIGN_FLAGS    := --options runtime --timestamp
  SIGN_FALLBACK :=
endif

app: release
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(CONTENTS)/Info.plist
	cp $(RELEASE)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGN_FLAGS) $(BUNDLE) $(SIGN_FALLBACK)
	@echo "built $(BUNDLE) — version $(VERSION) ($(BUILD))"

# --- The release archive -------------------------------------------------------------------------
# `ditto`, not `zip`: a bundle carries symlinks, xattrs and a signature that plain zip mangles, and
# it is the format `notarytool` takes. `zip` does not depend on `app` because notarization runs
# between them and a re-sign would discard the stapled ticket — `make dist` is the ordinary path.
ZIP_NAME ?= $(APP_NAME)-$(VERSION).zip
ZIP      := $(DIST)/$(ZIP_NAME)

zip:
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP)

dist: app zip

# Into /Applications, because that is where a permission grant should point: TCC records the
# bundle's path alongside its identity, so granting from a build directory breaks the moment it
# is cleaned.
install: app
	rm -rf /Applications/Bario.app
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/Bario.app"
	@echo "run it with: open -a Bario  (or /Applications/Bario.app/Contents/MacOS/$(APP_NAME) --run)"

uninstall:
	rm -rf /Applications/Bario.app
