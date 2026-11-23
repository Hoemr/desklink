#!/bin/bash
set -euo pipefail

if [[ $# != 4 ]]; then
  printf 'Usage: bash native/package-macos.sh Desklink.app liblibrustdesk.dylib service output.pkg\n' >&2
  exit 2
fi

source_app="$1"
engine="$2"
service="$3"
output="$4"
test -x "$source_app/Contents/MacOS/RustDesk"
test -x "$service"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" = com.hoemr.desklink
codesign --verify --deep --strict "$source_app"
arch=$(lipo -archs "$source_app/Contents/MacOS/RustDesk")
test "$(lipo -archs "$engine")" = "$arch"
test "$(lipo -archs "$service")" = "$arch"

stage=$(mktemp -d -t desklink-package)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$stage"' EXIT
app="$stage/payload/Desklink.app"
ditto "$source_app" "$app"
mv "$app/Contents/MacOS/RustDesk" "$app/Contents/MacOS/Desklink"
install -m 755 "$engine" "$app/Contents/Frameworks/liblibrustdesk.dylib"
install -m 755 "$service" "$app/Contents/MacOS/service"
info="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Desklink' -c 'Set :CFBundleName Desklink' \
  -c 'Set :CFBundleURLTypes:0:CFBundleURLName com.hoemr.desklink' \
  -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 desklink' "$info"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Desklink' "$info"
else
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Desklink' "$info"
fi

for component in "$app"/Contents/Frameworks/*.framework "$app"/Contents/Frameworks/*.dylib "$app/Contents/MacOS/service"; do
  codesign --force --sign - --options 0 --timestamp=none --preserve-metadata=entitlements "$component"
done
codesign --force --sign - --options 0 --timestamp=none --preserve-metadata=entitlements "$app"
codesign --verify --deep --strict "$app"
test "$("$app/Contents/MacOS/Desklink" --version)" = 1.5.3

pkgbuild --analyze --root "$stage/payload" "$stage/components.plist"
python3 -c '
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
assert len(components) == 1 and components[0]["RootRelativeBundlePath"] == "Desklink.app"
components[0]["BundleIsRelocatable"] = False
path.write_bytes(plistlib.dumps(components))
' "$stage/components.plist"
pkgbuild --root "$stage/payload" --component-plist "$stage/components.plist" --identifier com.hoemr.desklink.host --version 1.5.3 --install-location /Applications "$output"
