#!/bin/zsh
# Builds the Mac (Mac Catalyst) Release versions of Artelico and Hailo Studio and packs each into a
# drag-to-Applications disk image in dist/.
#
#     tools/make_dmg.sh            # both
#     tools/make_dmg.sh artelico   # one of them (artelico | hailo)
#
# Signed with the team's certificate as configured in Xcode. With an "Apple Development" certificate the
# apps run only on this team's registered Macs; to give them to anyone, sign with "Developer ID
# Application" and notarize (xcrun notarytool submit dist/<name>.dmg --wait, then xcrun stapler staple).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p dist

build() {   # build <project folder> <xcodeproj> <scheme> <app name> <dmg name>
  local folder=$1 project=$2 scheme=$3 app=$4 name=$5
  echo "Building $app…"
  (cd "$folder" && xcodebuild -project "$project" -scheme "$scheme" -configuration Release \
      -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build-mac-release \
      -allowProvisioningUpdates build | grep -E "error:|BUILD (SUCCEEDED|FAILED)")
  local built="$folder/build-mac-release/Build/Products/Release-maccatalyst/$app.app"
  codesign --verify --deep --strict "$built"
  local version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$built/Contents/Info.plist")
  local stage=$(mktemp -d)
  ditto "$built" "$stage/$app.app"
  ln -s /Applications "$stage/Applications"
  local out="dist/$name-$version.dmg"
  rm -f "$out"
  hdiutil create -volname "$app" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$out" >/dev/null
  rm -rf "$stage"
  echo "$out ($(du -h "$out" | cut -f1))"
}

case "${1:-all}" in
  artelico) build Artelico Artelico.xcodeproj Artelico "Artelico" "Artelico" ;;
  hailo) build UGenProbe UGenProbe.xcodeproj UGenProbe "Hailo Studio" "Hailo-Studio" ;;
  all)
    build Artelico Artelico.xcodeproj Artelico "Artelico" "Artelico"
    build UGenProbe UGenProbe.xcodeproj UGenProbe "Hailo Studio" "Hailo-Studio" ;;
esac
