SWIFTLINT ?= swiftlint
SWIFTFORMAT ?= swiftformat

.PHONY: lint lint-fix analyze format format-check ipa deb publish release clean

lint:
	$(SWIFTLINT) lint --strict

lint-fix:
	$(SWIFTLINT) lint --fix --strict

analyze:
	$(SWIFTLINT) analyze --strict --compiler-log-path build.log

format:
	$(SWIFTFORMAT) .

format-check:
	$(SWIFTFORMAT) . --lint

# ---------------------------------------------------------------------------
# The build: `make ipa` on Linux.
#
# Needs a theos tree with the Swift 5.8 iOS toolchain and an iPhoneOS SDK:
#   $(THEOS)/toolchain/swift-5.8/linux/iphone/bin/{swiftc,ldid,bitcode_strip}
#   $(THEOS)/sdks/iPhoneOS14.*.sdk
# Output: build/Girasol_<version>.ipa, ad-hoc signed with ldid for AppSync /
# TrollStore installs.
# `make publish` copies it to $(PUBLISH_DIR) with an index.html whose link
# installs it through TrollStore.
#
# Targets iOS 14 only (built and tested for 14.3). No Xcode formats: images
# and icons are plain PNGs in Girasol/Resources, the strings plain files,
# and the launch screen comes from Info.plist's UILaunchScreen.
# ---------------------------------------------------------------------------

THEOS          ?= $(HOME)/theos
SWIFT_TC       ?= $(THEOS)/toolchain/swift-5.8/linux/iphone
# The iOS 14 SDK: a newer one makes the Swift overlays bind symbols that
# iOS 14's /usr/lib/swift does not have (e.g. URLQueryItem's metadata).
SDKROOT        ?= $(firstword $(wildcard $(THEOS)/sdks/iPhoneOS14.*.sdk))
SDK_VERSION    := $(patsubst iPhoneOS%.sdk,%,$(notdir $(SDKROOT)))
MIN_OS         ?= 14.0
BUNDLE_ID      ?= app.girasol
# What Opaline (and this fork before its rename) was installed as: Girasol
# imports its settings, sign-ins and files (OPOpalineImport).
OPALINE_ID     ?= com.verback.YTLite
# Untracked local settings (e.g. USE_UPSTREAM_SOLVER = 1); CI has none.
-include local.mk

# USE_UPSTREAM_SOLVER=1: the solver server Opaline's developer runs becomes
# the default (Settings → Debug → Solver server can always name another).
# Off by default and never in releases or CI: it is their server.
USE_UPSTREAM_SOLVER ?= 0
UPSTREAM_SOLVER := https://ytlite-solver.wonderfulpond-77505dfd.westus2.azurecontainerapps.io
ifeq ($(USE_UPSTREAM_SOLVER),1)
DEFAULT_SOLVER := $(UPSTREAM_SOLVER)
else
DEFAULT_SOLVER :=
endif

# The version lives in VERSION; CI publishes a release whenever it names one
# that has none yet (.github/workflows/build.yml).
VERSION        ?= $(strip $(shell cat VERSION))
BUILD_NUMBER   ?= 1
TEAM_ID        := 4RAT6786W6
# Opaline's Keychain items live in its default group, its application
# identifier; an upstream build may carry another team id.
OPALINE_KEYCHAIN_GROUP ?= $(TEAM_ID).$(OPALINE_ID)
# SANDBOX=1: a sandboxed build (no TrollStore-only entitlements, e.g. for
# AppSync or sideloading). It cannot read Opaline's data, so the import is
# off; its IPA is named Girasol_<version>_sandboxed.ipa. Built only when
# asked for, or by `make release` (both kinds).
SANDBOX ?= 0
ifeq ($(SANDBOX),1)
OPALINE_IMPORT := NO
IPA_SUFFIX     := _sandboxed
ENTITLEMENTS_EXTRA :=
else
OPALINE_IMPORT := YES
IPA_SUFFIX     :=
ENTITLEMENTS_EXTRA := '<key>com.apple.private.security.no-sandbox</key><true/>' \
	'<key>keychain-access-groups</key><array>' \
	'<string>$(TEAM_ID).$(BUNDLE_ID)</string><string>$(OPALINE_KEYCHAIN_GROUP)</string>' \
	'</array>'
endif
# Compiler threads, and parallel Objective-C compiles.
JOBS           ?= 16
MAKEFLAGS      += -j$(JOBS)
PUBLISH_ROOT   ?= /srv/http/files
PUBLISH_DIR    := $(PUBLISH_ROOT)/girasol
LOCAL_IP       := $(shell ip addr | sed -n "s/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\)[ \/].*/\1/p" | grep -v '^127\.' | head -1)
COMMIT_HASH    := $(shell git rev-parse --short HEAD 2>/dev/null)

SWIFTC := $(SWIFT_TC)/bin/swiftc
LDID   := $(SWIFT_TC)/bin/ldid
# The bundled swift-driver links against libncurses.so.6, which some distros
# only ship as libncursesw; the integrated legacy driver needs neither.
export SWIFT_USE_OLD_DRIVER := 1

SWIFTFLAGS := -resource-dir $(SWIFT_TC)/lib/swift -tools-directory $(SWIFT_TC)/bin \
	-target arm64-apple-ios$(MIN_OS) -sdk $(SDKROOT) -swift-version 5 \
	-suppress-warnings \
	-Xfrontend -disable-autolink-framework -Xfrontend AVFAudio \
	-Xlinker -no_implicit_dylibs
# AVFAudio is a top-level framework only from iOS 14.5; before that it lives
# inside AVFoundation. Both layouts re-export it from AVFoundation, so the
# binary binds its symbols there instead of loading the new path directly,
# which dyld fails to find on older systems.
# The app builds incrementally: one object per Swift file in obj-app, and
# only the files changed (and those that depend on them) recompile — a
# one-file change takes seconds instead of the whole module's minute.
# WMO=1 builds the whole module at once instead (cross-file optimisation).
WMO ?= 0
ifeq ($(WMO),1)
APP_SWIFTMODE := -wmo -num-threads $(JOBS)
else
APP_SWIFTMODE = -incremental -enable-batch-mode -j $(JOBS) \
	-output-file-map $(CURDIR)/$(OUT)/obj-app/files.json
endif
# DEBUG=1: unoptimized; its objects go to their own folder (an incremental
# build never mixes them with optimized ones) and the IPA is named
# …_debug.ipa. No -g: it makes swiftc run dsymutil after linking, which the
# toolchain does not have (the binary is not stripped, so crash logs still
# name functions).
ifeq ($(DEBUG),1)
SWIFTFLAGS += -Onone -DDEBUG
DEBUG_SUFFIX := _debug
else
SWIFTFLAGS += -O
endif

OUT       := build/linux$(DEBUG_SUFFIX)
APP       := $(OUT)/Payload/Girasol.app
IPA       := build/Girasol_$(VERSION)$(IPA_SUFFIX)$(DEBUG_SUFFIX).ipa
APP_SRCS  := $(shell find Girasol -name '*.swift')
# Objective-C sources compile with clang and reach Swift through the
# bridging header; their objects go straight to the linker, since swiftc
# refuses extra inputs in a multi-threaded whole-module build.
OBJC_SRCS := $(shell find Girasol -name '*.m')
OBJC_HDRS := $(shell find Girasol -name '*.h')
OBJC_OBJS := $(patsubst %.m,$(OUT)/objc/%.o,$(OBJC_SRCS))
BRIDGING_HEADER := Girasol/Girasol-Bridging-Header.h
CLANG := $(SWIFT_TC)/bin/clang
# No autolinking: importing AVFoundation would add AVFAudio.framework as a
# load command (see SWIFTFLAGS), and dyld refuses to start the app on iOS
# 14.3. The frameworks the Objective-C code uses come from the Swift side.
OBJCFLAGS := -target arm64-apple-ios$(MIN_OS) -isysroot $(SDKROOT) \
	-fobjc-arc -fmodules -fno-autolink -O2 -Wall -Wno-unused-parameter
# What only the Objective-C code uses, linked by name instead.
OBJC_FRAMEWORKS := WebKit
PLIST := python3 scripts/linux_info_plist.py --version $(VERSION) \
	--build $(BUILD_NUMBER) --min-os $(MIN_OS) --sdk-version $(SDK_VERSION) \
	--var OP_KEYCHAIN_GROUP=$(TEAM_ID).$(BUNDLE_ID) --var OP_OPALINE_ID=$(OPALINE_ID) \
	--var OP_OPALINE_KEYCHAIN_GROUP=$(OPALINE_KEYCHAIN_GROUP) --var OP_OPALINE_IMPORT=$(OPALINE_IMPORT) \
	--var OP_DEFAULT_SOLVER=$(DEFAULT_SOLVER)

$(OUT)/objc/%.o: %.m $(OBJC_HDRS) Makefile
	@mkdir -p $(@D)
	$(CLANG) $(OBJCFLAGS) -c $< -o $@

$(OUT)/Girasol: $(APP_SRCS) $(OBJC_OBJS) $(OBJC_HDRS) Makefile
	@mkdir -p $(OUT)/obj-app
	@python3 scripts/swift_output_map.py $(CURDIR)/$(OUT)/obj-app $(addprefix $(CURDIR)/,$(APP_SRCS))
	cd $(OUT)/obj-app && $(SWIFTC) $(SWIFTFLAGS) $(APP_SWIFTMODE) -module-name Girasol \
		-import-objc-header $(CURDIR)/$(BRIDGING_HEADER) \
		$(addprefix $(CURDIR)/,$(APP_SRCS)) \
		$(foreach o,$(OBJC_OBJS),-Xlinker $(CURDIR)/$(o)) \
		$(foreach f,$(OBJC_FRAMEWORKS),-Xlinker -framework -Xlinker $(f)) \
		-o $(CURDIR)/$@
	@if $(SWIFT_TC)/bin/otool -L $@ | grep -q AVFAudio.framework; then \
		echo "error: $@ loads AVFAudio.framework, which iOS 14.3 does not have"; rm -f $@; exit 1; fi

# no-sandbox (TrollStore: keeps the app's own data container) lets the
# Opaline import read Opaline's container; the second Keychain group, its
# sign-ins. Girasol's own items stay in the first group (OPKeychainGroup).
# Rewritten every build: SANDBOX changes it without touching the Makefile.
.PHONY: $(OUT)/app.entitlements
$(OUT)/app.entitlements:
	@mkdir -p $(@D)
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>application-identifier</key><string>$(TEAM_ID).$(BUNDLE_ID)</string>' \
		'<key>com.apple.developer.team-identifier</key><string>$(TEAM_ID)</string>' \
		'<key>get-task-allow</key><true/>' \
		$(ENTITLEMENTS_EXTRA) \
		'</dict></plist>' > $@

# Packaging is cheap, so it always reruns.
ipa: $(OUT)/Girasol $(OUT)/app.entitlements
	rm -rf $(OUT)/Payload
	mkdir -p $(APP)
	# Resources, as they ship: images and icons loose in the bundle (named as
	# UIImage(named:) and Info.plist look them up), the strings in en.lproj
	# (where iOS looks them up; English is the only language).
	cp Girasol/Resources/Images/*.png Girasol/Resources/AppIcon/*.png $(APP)/
	mkdir -p $(APP)/en.lproj
	cp Girasol/Resources/Strings/* $(APP)/en.lproj/
	$(PLIST) --source Girasol/Info.plist --output $(APP)/Info.plist \
		--executable Girasol --bundle-id $(BUNDLE_ID)
	printf 'APPL????' > $(APP)/PkgInfo
	# Binaries and signatures; iOS 14 has the Swift runtime built in.
	cp $(OUT)/Girasol $(APP)/Girasol
	$(LDID) -S$(OUT)/app.entitlements $(APP)/Girasol
	rm -f $(IPA)
	cd $(OUT) && zip -qry $(CURDIR)/$(IPA) Payload
	@echo "Built $(IPA)"

publish: ipa
	@mkdir -p $(PUBLISH_DIR)
	cp $(IPA) $(PUBLISH_DIR)/Girasol.ipa
	@printf '%s\n' \
		'<html><head><meta name=viewport content="width=device-width,initial-scale=1">' \
		'<title>Girasol</title><style>a{font-size:80px}p{font-size:40px}</style></head><body>' \
		'<a href="apple-magnifier://install?url=http%3A%2F%2F$(LOCAL_IP)%2Ffiles%2Fgirasol%2FGirasol.ipa">Install</a>' \
		'<p>Girasol $(VERSION) ($(COMMIT_HASH))</p>' \
		'<p>Latest Update: $(shell date)</p></body></html>' \
		> $(PUBLISH_DIR)/index.html
	@echo "Published: http://$(LOCAL_IP)/files/girasol/  (tap Install -> TrollStore)"

# Jailbreak packages of the TrollStore build, written by scripts/make_deb.py
# (Python only: no dpkg-deb, tar, ar or Theos): rootful (/Applications,
# iphoneos-arm, iOS 14+) and rootless (/var/jb/Applications, iphoneos-arm64,
# iOS 15+, untested). Same time stamp for every file (the commit's), so a
# commit always gives the same bytes.
DEB_PACKAGE := $(BUNDLE_ID)
DEB_HOMEPAGE := https://github.com/LNSSPsd/Girasol
DEB_ICON := https://raw.githubusercontent.com/LNSSPsd/Girasol/main/Girasol/Resources/AppIcon/AppIcon60x60@3x.png
DEB_MTIME := $(shell git log -1 --format=%ct 2>/dev/null || echo 0)
DEB := python3 scripts/make_deb.py --app $(APP) --package $(DEB_PACKAGE) --name Girasol \
	--version $(VERSION) --maintainer Girasol --homepage $(DEB_HOMEPAGE) --icon $(DEB_ICON) \
	--summary "YouTube Music and YouTube for iOS 14" \
	--description "A music player in the style of YouTube Music and a YouTube video app in one, without Shorts." \
	--mtime $(DEB_MTIME)

deb: ipa
	$(DEB) --arch iphoneos-arm --prefix "" --min-firmware 14.0 \
		--output build/Girasol_$(VERSION)_iphoneos-arm$(DEBUG_SUFFIX).deb
	$(DEB) --arch iphoneos-arm64 --prefix /var/jb --min-firmware 15.0 \
		--output build/Girasol_$(VERSION)_iphoneos-arm64$(DEBUG_SUFFIX).deb

# Every release file, one after the other (they share the build tree; only
# the Info.plist and the entitlements differ): the TrollStore IPA and the
# debs from it, then the sandboxed IPA.
release:
	$(MAKE) deb SANDBOX=0 USE_UPSTREAM_SOLVER=0
	$(MAKE) ipa SANDBOX=1 USE_UPSTREAM_SOLVER=0

clean:
	rm -rf build/linux build/linux_debug build/Opaline_*.ipa build/Girasol_*.ipa build/Girasol_*.deb
