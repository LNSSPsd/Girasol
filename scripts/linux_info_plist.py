#!/usr/bin/env python3
"""Write a bundle's final Info.plist for the Linux build (see Makefile).

Xcode builds the plist from the target's INFOPLIST_FILE plus the
GENERATE_INFOPLIST_FILE keys and the standard bundle keys it fills in
itself. The Linux build has no Xcode, so this does the same merge.
"""
import argparse
import plistlib
import re

ORIENTATIONS_PHONE = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]
ORIENTATIONS_PAD = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]


def substitute(value, variables):
    if isinstance(value, str):
        return re.sub(
            r"\$\((\w+)\)", lambda m: variables.get(m.group(1), ""), value
        )
    if isinstance(value, list):
        return [substitute(v, variables) for v in value]
    if isinstance(value, dict):
        return {k: substitute(v, variables) for k, v in value.items()}
    return value


def app_keys(info):
    """The INFOPLIST_KEY_* settings of the Opaline target, plus the icon
    and launch screen keys that the asset catalog and storyboard would
    have produced (neither can be compiled on Linux)."""
    info.setdefault("CFBundleDisplayName", "Opaline")
    info["UIApplicationSupportsIndirectInputEvents"] = True
    info["UISupportedInterfaceOrientations"] = ORIENTATIONS_PHONE
    info["UISupportedInterfaceOrientations~iphone"] = ORIENTATIONS_PHONE
    info["UISupportedInterfaceOrientations~ipad"] = ORIENTATIONS_PAD
    # iOS 14+ draws this instead of a launch storyboard; earlier versions
    # need the storyboard to run full screen.
    info["UILaunchScreen"] = {"UIImageName": "SplashMark"}
    info["UIDeviceFamily"] = [1, 2]
    for key, files in (
        ("CFBundleIcons", ["AppIcon20x20", "AppIcon29x29", "AppIcon40x40",
                           "AppIcon60x60"]),
        ("CFBundleIcons~ipad", ["AppIcon20x20", "AppIcon29x29",
                                "AppIcon40x40", "AppIcon76x76",
                                "AppIcon83.5x83.5"]),
    ):
        icons = info.setdefault(key, {})
        icons["CFBundlePrimaryIcon"] = {
            "CFBundleIconFiles": files,
            "CFBundleIconName": "AppIcon",
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--min-os", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--var", action="append", default=[],
                        help="NAME=VALUE for $(NAME) in the source plist")
    args = parser.parse_args()

    variables = dict(v.split("=", 1) for v in args.var)
    variables.setdefault("PRODUCT_MODULE_NAME", args.executable)
    variables.setdefault("PRODUCT_BUNDLE_IDENTIFIER", args.bundle_id)
    with open(args.source, "rb") as f:
        info = substitute(plistlib.load(f), variables)

    info.update({
        "CFBundleDevelopmentRegion": info.get(
            "CFBundleDevelopmentRegion", "en"),
        "CFBundleExecutable": args.executable,
        "CFBundleIdentifier": args.bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": args.executable,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": args.version,
        "CFBundleVersion": args.build,
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "MinimumOSVersion": args.min_os,
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": args.sdk_version,
        "DTSDKName": f"iphoneos{args.sdk_version}",
        "UIRequiredDeviceCapabilities": ["arm64"],
    })
    app_keys(info)

    with open(args.output, "wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)


if __name__ == "__main__":
    main()
