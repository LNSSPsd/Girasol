SWIFTLINT ?= swiftlint
SWIFTFORMAT ?= swiftformat

.PHONY: lint lint-fix analyze format format-check ipa publish release clean

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
# Targets iOS 14 only (built and tested for 14.3). Without actool and
# ibtool, assets ship as loose PNGs and the launch screen comes from
# Info.plist's UILaunchScreen.
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
APP_SRCS  := $(shell find Opaline -name '*.swift')
# Objective-C sources compile with clang and reach Swift through the
# bridging header; their objects go straight to the linker, since swiftc
# refuses extra inputs in a multi-threaded whole-module build.
OBJC_SRCS := $(shell find Opaline -name '*.m')
OBJC_HDRS := $(shell find Opaline -name '*.h')
OBJC_OBJS := $(patsubst %.m,$(OUT)/objc/%.o,$(OBJC_SRCS))
BRIDGING_HEADER := Opaline/Opaline-Bridging-Header.h
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
	--var OP_OPALINE_KEYCHAIN_GROUP=$(OPALINE_KEYCHAIN_GROUP) --var OP_OPALINE_IMPORT=$(OPALINE_IMPORT)

$(OUT)/objc/%.o: %.m $(OBJC_HDRS) Makefile
	@mkdir -p $(@D)
	$(CLANG) $(OBJCFLAGS) -c $< -o $@

$(OUT)/Opaline: $(APP_SRCS) $(OBJC_OBJS) $(OBJC_HDRS) Makefile
	@mkdir -p $(OUT)/obj-app
	@python3 scripts/swift_output_map.py $(CURDIR)/$(OUT)/obj-app $(addprefix $(CURDIR)/,$(APP_SRCS))
	cd $(OUT)/obj-app && $(SWIFTC) $(SWIFTFLAGS) $(APP_SWIFTMODE) -module-name Opaline \
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
ipa: $(OUT)/Opaline $(OUT)/app.entitlements
	rm -rf $(OUT)/Payload
	mkdir -p $(APP)
	# Resources: localizations, asset-catalog images as loose PNGs, icons.
	for d in Opaline/*.lproj; do \
		[ "$$d" = Opaline/Base.lproj ] || cp -r "$$d" $(APP)/; done
	cp Opaline/Assets.xcassets/*.imageset/*.png Opaline/AltIcons/*.png $(APP)/
	for f in $(APP)/*@1x.png; do mv "$$f" "$${f%@1x.png}.png"; done
	set -e; I=Opaline/Assets.xcassets/AppIconGirasol.appiconset; \
	for s in 20 29 40 60; do for x in 2 3; do \
		cp $$I/Icon-$$s@$${x}x.png $(APP)/AppIcon$${s}x$$s@$${x}x.png; done; done; \
	for s in 20 29 40 76; do \
		cp $$I/Icon-$$s@1x.png $(APP)/AppIcon$${s}x$$s~ipad.png; \
		cp $$I/Icon-$$s@2x.png $(APP)/AppIcon$${s}x$$s@2x~ipad.png; done; \
	cp $$I/Icon-83.5@2x.png $(APP)/AppIcon83.5x83.5@2x~ipad.png
	$(PLIST) --source Opaline/Info.plist --output $(APP)/Info.plist \
		--executable Girasol --bundle-id $(BUNDLE_ID)
	printf 'APPL????' > $(APP)/PkgInfo
	# Binaries and signatures; iOS 14 has the Swift runtime built in.
	cp $(OUT)/Opaline $(APP)/Girasol
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

# Both kinds, one after the other (they share the build tree; only the
# Info.plist and the entitlements differ).
release:
	$(MAKE) ipa SANDBOX=0
	$(MAKE) ipa SANDBOX=1

clean:
	rm -rf build/linux build/linux_debug build/Opaline_*.ipa build/Girasol_*.ipa
