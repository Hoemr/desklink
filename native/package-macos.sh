#!/bin/bash
set -euo pipefail

if [[ $# != 3 ]]; then
  printf 'Usage: bash native/package-macos.sh Desklink.app service output.pkg\n' >&2
  exit 2
fi

source_app="$1"
service="$2"
output="$3"
test -x "$source_app/Contents/MacOS/RustDesk"
test -x "$service"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" = com.hoemr.desklink
codesign --verify --deep --strict "$source_app"
test "$(lipo -archs "$source_app/Contents/MacOS/RustDesk")" = "$(lipo -archs "$service")"

stage=$(mktemp -d -t desklink-package)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$stage"' EXIT
app="$stage/payload/RustDesk.app"
ditto "$source_app" "$app"
install -m 755 "$service" "$app/Contents/MacOS/service"
python3 -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]); data=plistlib.loads(p.read_bytes()); data["CFBundleDisplayName"]="Desklink"; p.write_bytes(plistlib.dumps(data))' "$app/Contents/Info.plist"

for component in "$app"/Contents/Frameworks/*.framework "$app"/Contents/Frameworks/*.dylib "$app/Contents/MacOS/service"; do
  codesign --force --sign - --options 0 --timestamp=none --preserve-metadata=entitlements "$component"
done
codesign --force --sign - --options 0 --timestamp=none --preserve-metadata=entitlements "$app"
codesign --verify --deep --strict "$app"
test "$("$app/Contents/MacOS/RustDesk" --version)" = 1.5.3

# The native launchd templates expect the RustDesk install path and service names.
pkgbuild --analyze --root "$stage/payload" "$stage/components.plist"
python3 -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]); items=plistlib.loads(p.read_bytes()); assert len(items)==1 and items[0]["RootRelativeBundlePath"]=="RustDesk.app"; items[0]["BundleIsRelocatable"]=False; p.write_bytes(plistlib.dumps(items))' "$stage/components.plist"
pkgbuild --root "$stage/payload" --component-plist "$stage/components.plist" --identifier com.hoemr.desklink.desktop --version 1.5.3 --install-location /Applications "$output"
