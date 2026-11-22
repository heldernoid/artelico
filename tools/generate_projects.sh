#!/bin/sh
# Generates Artelico.xcodeproj and UGenProbe.xcodeproj (Hailo Studio) from their project.yml with XcodeGen.
#
#   DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.yourname tools/generate_projects.sh
#
# DEVELOPMENT_TEAM: your Apple developer team ID (Xcode > Settings > Accounts, or developer.apple.com >
#   Membership). Leave it out for builds that are not signed (CODE_SIGNING_ALLOWED=NO, e.g. a compile check).
# BUNDLE_ID_PREFIX: the start of the apps' bundle identifiers. Bundle identifiers are unique across Apple,
#   so use your own (e.g. com.yourname); the default only suits unsigned builds.
#
# The projects are generated files: change project.yml, not the .xcodeproj, and run this again.
# Needs XcodeGen (brew install xcodegen).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
export BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-io.ugenkit}"
command -v xcodegen > /dev/null || { echo "XcodeGen is needed: brew install xcodegen"; exit 1; }
for app in Artelico UGenProbe; do
  (cd "$ROOT/$app" && xcodegen generate --quiet)
  echo "$app/$app.xcodeproj (team: ${DEVELOPMENT_TEAM:-none}, bundle prefix: $BUNDLE_ID_PREFIX)"
done
