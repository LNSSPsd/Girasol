SWIFTLINT ?= swiftlint
SWIFTFORMAT ?= swiftformat

.PHONY: lint lint-fix analyze format format-check ipa publish clean

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
# Linux IPA build: `make ipa` (make_ipa.sh is the macOS/Xcode path).
#
# Needs a theos tree with the Swift 5.8 iOS toolchain and an iPhoneOS SDK:
#   $(THEOS)/toolchain/swift-5.8/linux/iphone/bin/{swiftc,ldid,bitcode_strip}
#   $(THEOS)/sdks/iPhoneOS14.*.sdk
# Output: build/Opaline_<version>.ipa, ad-hoc signed with ldid for AppSync /
# TrollStore installs, same bundle id and entitlements as make_ipa.sh.
# APPEX=0 leaves out the "Open in Opaline" share-sheet extension.
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
BUNDLE_ID      ?= com.verback.YTLite
VERSION        ?= $(shell sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Opaline.xcodeproj/project.pbxproj | head -1)
BUILD_NUMBER   ?= 1
APP_MANIFEST_URL ?= https://raw.githubusercontent.com/verback2308/ytlite/main/source/apps.json
TEAM_ID        := 4RAT6786W6
APPEX          ?= 1
# Compiler threads, and parallel Objective-C compiles.
JOBS           ?= 16
MAKEFLAGS      += -j$(JOBS)
PUBLISH_ROOT   ?= /srv/http/files
PUBLISH_DIR    := $(PUBLISH_ROOT)/opaline
LOCAL_IP       := $(shell ip addr | sed -n "s/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\)[ \/].*/\1/p" | grep -v '^127\.' | head -1)
COMMIT_HASH    := $(shell git rev-parse --short HEAD 2>/dev/null)

SWIFTC := $(SWIFT_TC)/bin/swiftc
LDID   := $(SWIFT_TC)/bin/ldid
# The bundled swift-driver links against libncurses.so.6, which some distros
# only ship as libncursesw; the integrated legacy driver needs neither.
export SWIFT_USE_OLD_DRIVER := 1

SWIFTFLAGS := -resource-dir $(SWIFT_TC)/lib/swift -tools-directory $(SWIFT_TC)/bin \
	-target arm64-apple-ios$(MIN_OS) -sdk $(SDKROOT) -swift-version 5 \
	-wmo -num-threads $(JOBS) -suppress-warnings \
	-Xfrontend -disable-autolink-framework -Xfrontend AVFAudio \
	-Xlinker -no_implicit_dylibs
# AVFAudio is a top-level framework only from iOS 14.5; before that it lives
# inside AVFoundation. Both layouts re-export it from AVFoundation, so the
# binary binds its symbols there instead of loading the new path directly,
# which dyld fails to find on older systems.
ifeq ($(DEBUG),1)
SWIFTFLAGS += -Onone -g -DDEBUG
else
SWIFTFLAGS += -O
endif

OUT       := build/linux
APP       := $(OUT)/Payload/Opaline.app
APPEX_DIR := $(APP)/PlugIns/OpalineOpenIn.appex
IPA       := build/Opaline_$(VERSION).ipa
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
# Shared with the app target, as in the Xcode project.
APPEX_SRCS := $(wildcard OpalineOpenIn/*.swift) Opaline/Core/Common/YouTubeLinkParser.swift
PLIST := python3 scripts/linux_info_plist.py --version $(VERSION) \
	--build $(BUILD_NUMBER) --min-os $(MIN_OS) --sdk-version $(SDK_VERSION)

ifeq ($(APPEX),1)
APPEX_BIN := $(OUT)/OpalineOpenIn
APPEX_PARTS := $(APPEX_BIN) $(OUT)/appex.entitlements
endif

$(OUT)/objc/%.o: %.m $(OBJC_HDRS) Makefile
	@mkdir -p $(@D)
	$(CLANG) $(OBJCFLAGS) -c $< -o $@

$(OUT)/Opaline: $(APP_SRCS) $(OBJC_OBJS) $(OBJC_HDRS) Makefile
	@mkdir -p $(OUT)/obj-app
	cd $(OUT)/obj-app && $(SWIFTC) $(SWIFTFLAGS) -module-name Opaline \
		-import-objc-header $(CURDIR)/$(BRIDGING_HEADER) \
		$(addprefix $(CURDIR)/,$(APP_SRCS)) \
		$(foreach o,$(OBJC_OBJS),-Xlinker $(CURDIR)/$(o)) \
		$(foreach f,$(OBJC_FRAMEWORKS),-Xlinker -framework -Xlinker $(f)) \
		-o $(CURDIR)/$@
	@if $(SWIFT_TC)/bin/otool -L $@ | grep -q AVFAudio.framework; then \
		echo "error: $@ loads AVFAudio.framework, which iOS 14.3 does not have"; rm -f $@; exit 1; fi

$(OUT)/OpalineOpenIn: $(APPEX_SRCS) Makefile
	@mkdir -p $(OUT)/obj-appex
	cd $(OUT)/obj-appex && $(SWIFTC) $(SWIFTFLAGS) -module-name OpalineOpenIn \
		-application-extension -Xlinker -e -Xlinker _NSExtensionMain \
		$(addprefix $(CURDIR)/,$(APPEX_SRCS)) -o $(CURDIR)/$@

$(OUT)/app.entitlements:
	@mkdir -p $(@D)
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>application-identifier</key><string>$(TEAM_ID).$(BUNDLE_ID)</string>' \
		'<key>com.apple.developer.team-identifier</key><string>$(TEAM_ID)</string>' \
		'<key>get-task-allow</key><true/>' \
		'</dict></plist>' > $@

$(OUT)/appex.entitlements: $(OUT)/app.entitlements
	sed 's|$(BUNDLE_ID)<|$(BUNDLE_ID).OpenIn<|' $< > $@

# Packaging is cheap, so it always reruns: that way switching APPEX takes
# effect without a clean.
ipa: $(OUT)/Opaline $(OUT)/app.entitlements $(APPEX_PARTS)
	rm -rf $(OUT)/Payload
	mkdir -p $(APP)
	# Resources: localizations, asset-catalog images as loose PNGs, icons.
	for d in Opaline/*.lproj; do \
		[ "$$d" = Opaline/Base.lproj ] || cp -r "$$d" $(APP)/; done
	cp Opaline/Assets.xcassets/*.imageset/*.png Opaline/AltIcons/*.png $(APP)/
	for f in $(APP)/*@1x.png; do mv "$$f" "$${f%@1x.png}.png"; done
	set -e; I=Opaline/Assets.xcassets/AppIconOpaline.appiconset; \
	for s in 20 29 40 60; do for x in 2 3; do \
		cp $$I/Icon-$$s@$${x}x.png $(APP)/AppIcon$${s}x$$s@$${x}x.png; done; done; \
	for s in 20 29 40 76; do \
		cp $$I/Icon-$$s@1x.png $(APP)/AppIcon$${s}x$$s~ipad.png; \
		cp $$I/Icon-$$s@2x.png $(APP)/AppIcon$${s}x$$s@2x~ipad.png; done; \
	cp $$I/Icon-83.5@2x.png $(APP)/AppIcon83.5x83.5@2x~ipad.png
	$(PLIST) --kind app --source Opaline/Info.plist --output $(APP)/Info.plist \
		--executable Opaline --bundle-id $(BUNDLE_ID) \
		--var APP_MANIFEST_URL=$(APP_MANIFEST_URL)
	printf 'APPL????' > $(APP)/PkgInfo
	# Binaries and signatures; iOS 14 has the Swift runtime built in.
	cp $(OUT)/Opaline $(APP)/Opaline
ifeq ($(APPEX),1)
	mkdir -p $(APPEX_DIR)
	for d in OpalineOpenIn/*.lproj; do cp -r "$$d" $(APPEX_DIR)/; done
	$(PLIST) --kind appex --source OpalineOpenIn/Info.plist \
		--output $(APPEX_DIR)/Info.plist --executable OpalineOpenIn \
		--bundle-id $(BUNDLE_ID).OpenIn
	cp $(APPEX_BIN) $(APPEX_DIR)/OpalineOpenIn
	$(LDID) -S$(OUT)/appex.entitlements $(APPEX_DIR)/OpalineOpenIn
endif
	$(LDID) -S$(OUT)/app.entitlements $(APP)/Opaline
	rm -f $(IPA)
	cd $(OUT) && zip -qry $(CURDIR)/$(IPA) Payload
	@echo "Built $(IPA)"

publish: ipa
	@mkdir -p $(PUBLISH_DIR)
	cp $(IPA) $(PUBLISH_DIR)/Opaline.ipa
	@printf '%s\n' \
		'<html><head><meta name=viewport content="width=device-width,initial-scale=1">' \
		'<title>Opaline</title><style>a{font-size:80px}p{font-size:40px}</style></head><body>' \
		'<a href="apple-magnifier://install?url=http%3A%2F%2F$(LOCAL_IP)%2Ffiles%2Fopaline%2FOpaline.ipa">Install</a>' \
		'<p>Opaline $(VERSION) ($(COMMIT_HASH))</p>' \
		'<p>Latest Update: $(shell date)</p></body></html>' \
		> $(PUBLISH_DIR)/index.html
	@echo "Published: http://$(LOCAL_IP)/files/opaline/  (tap Install -> TrollStore)"

clean:
	rm -rf build/linux build/Opaline_*.ipa
