#!/bin/bash
set -euo pipefail

if [[ $# != 4 && ( $# != 3 || ${1-} != sign ) ]]; then
  printf '%s\n' \
    'Usage: bash native/package-macos.sh Desklink.app liblibrustdesk.dylib service test.pkg' \
    '       bash native/package-macos.sh sign test.pkg output.pkg' >&2
  exit 2
fi

stage=$(mktemp -d -t desklink-package)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$stage"' EXIT
app="$stage/payload/Desklink.app"
signing_args=(--sign -)
if [[ $# == 3 ]]; then
  identity=${DESKLINK_MACOS_SIGNING_IDENTITY:-}
  if [[ ! $identity =~ ^[[:xdigit:]]{40}$ ]]; then
    printf 'Set DESKLINK_MACOS_SIGNING_IDENTITY to the fixed certificate SHA-1 fingerprint (40 hex digits)\n' >&2
    exit 2
  fi
  signing_args=(--sign "$identity")
  if [[ -n ${DESKLINK_MACOS_SIGNING_KEYCHAIN:-} ]]; then
    signing_args+=(--keychain "$DESKLINK_MACOS_SIGNING_KEYCHAIN")
  fi
  requirement="identifier \"com.hoemr.desklink\" and certificate leaf = H\"$identity\""
  output="$3"
  pkgutil --expand-full "$2" "$stage/input"
  codesign --verify --deep --strict "$stage/input/Payload/Desklink.app"
  ditto "$stage/input/Payload/Desklink.app" "$app"
else
  source_app="$1"
  engine="$2"
  service="$3"
  output="$4"
  codesign --verify --deep --strict "$source_app"
  arch=$(lipo -archs "$source_app/Contents/MacOS/RustDesk")
  test "$(lipo -archs "$engine")" = "$arch"
  test "$(lipo -archs "$service")" = "$arch"
  ditto "$source_app" "$app"
  mv "$app/Contents/MacOS/RustDesk" "$app/Contents/MacOS/Desklink"
  install -m 755 "$engine" "$app/Contents/Frameworks/liblibrustdesk.dylib"
  install -m 755 "$service" "$app/Contents/MacOS/service"
fi

info="$app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = com.hoemr.desklink
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Desklink' -c 'Set :CFBundleName Desklink' \
  -c 'Set :CFBundleURLTypes:0:CFBundleURLName com.hoemr.desklink' \
  -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 desklink' "$info"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Desklink' "$info"
else
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Desklink' "$info"
fi

for component in "$app"/Contents/Frameworks/*.framework "$app"/Contents/Frameworks/*.dylib "$app/Contents/MacOS/service"; do
  codesign --force "${signing_args[@]}" --options 0 --timestamp=none --preserve-metadata=entitlements "$component"
done
if [[ $# == 3 ]]; then
  signing_args+=(--requirements "=designated => $requirement")
fi
codesign --force "${signing_args[@]}" --options 0 --timestamp=none --preserve-metadata=entitlements "$app"
codesign --verify --deep --strict "$app"
if [[ $# == 3 ]]; then
  codesign --verify --strict -R "=$requirement" "$app"
fi
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
