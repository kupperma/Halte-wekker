#!/usr/bin/env python3
"""Writes the SideStore / AltStore source for Haltewekker (source.json), so new versions show up as updates.

Run by CI after a release: make-source.py <version> <build> <ipa> <Info.plist of the built app> <owner/repo> <out>
The download points at the versioned release (ios-v<version>), which is kept. Format:
https://faq.altstore.io/developers/make-a-source
"""
import datetime
import json
import os
import plistlib
import sys


def main():
    version, build, ipa, info_plist, repo, out = sys.argv[1:7]
    with open(info_plist, "rb") as f:
        info = plistlib.load(f)
    privacy = {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription")}
    raw = f"https://raw.githubusercontent.com/{repo}/main"
    source = {
        "name": "Haltewekker",
        "subtitle": "Wakes you before your stop",
        "description": "Haltewekker plans your trip to school and back and wakes you before your stop.",
        "iconURL": f"{raw}/ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "website": f"https://github.com/{repo}",
        "tintColor": "#3B44B0",
        "apps": [{
            "name": "Haltewekker",
            "bundleIdentifier": info.get("CFBundleIdentifier", "nl.haltewekker.app"),
            "developerName": "Haltewekker",
            "subtitle": "Wakes you before your stop",
            "localizedDescription": "Plans your trip to school and back by bus and train, shows where they really are, "
                                    "and wakes you before your stop.",
            "iconURL": f"{raw}/ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            "tintColor": "#3B44B0",
            "category": "utilities",
            "versions": [{
                "version": version,
                "buildVersion": build,
                "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "downloadURL": f"https://github.com/{repo}/releases/download/ios-v{version}/Haltewekker.ipa",
                "size": os.path.getsize(ipa),
                "minOSVersion": info.get("MinimumOSVersion", "17.0"),
                "localizedDescription": f"Version {version}. What changed: https://github.com/{repo}/releases/tag/ios-v{version}",
            }],
            # the build is unsigned, so it carries no entitlements of its own; the privacy keys are its Info.plist's
            "appPermissions": {"entitlements": [], "privacy": privacy},
        }],
        "news": [],
    }
    with open(out, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
