#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="Lumen Browser"
MODE="${1:-run}"
SWIFT_PRODUCT_NAME="MeridianBrowser"
LEGACY_EXECUTABLE_NAMES=("Bare Browser" "MeridianBrowser")
EXECUTABLE_NAME="$PRODUCT_NAME"
# Application identity is compatibility-stable across the public rebrand so
# existing WebKit data stores, permissions, preferences, and Keychain ACLs survive.
BUNDLE_ID="app.barebrowser.BareBrowser"
MIN_SYSTEM_VERSION="26.0"
SWIFT_CONFIGURATION="debug"
APP_ICON_NAME="LumenLogo"
APP_ICON_FILE="$APP_ICON_NAME.icon"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$PRODUCT_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
BUILD_STAMP="$DIST_DIR/.LumenBrowserBuildConfiguration"
LEGACY_APP_BUNDLE="$DIST_DIR/Bare Browser.app"
LEGACY_BUILD_STAMP="$DIST_DIR/.BareBrowserBuildConfiguration"
APP_ICON_SOURCE="$ROOT_DIR/Resources/$APP_ICON_FILE"
APP_ICON_PARTIAL_PLIST="$DIST_DIR/AppIconPartialInfo.plist"
APP_ICON_ACTOOL_OUTPUT="$DIST_DIR/AppIconActoolOutput.plist"
# Keep the established local certificate for the same continuity guarantees as
# the stable bundle identifier. This is a development implementation detail.
DEV_SIGNING_IDENTITY="Bare Browser Local Development"
DEV_SIGNING_DIR="$DIST_DIR/Signing"
DEV_SIGNING_KEYCHAIN="$DEV_SIGNING_DIR/BareBrowserLocalDevelopment.keychain-db"
DEV_SIGNING_KEYCHAIN_PASSWORD="bare-browser-local-development"

cd "$ROOT_DIR"

case "$MODE" in
  --release|release|--verify-release|verify-release|--profile-swiftui|profile-swiftui|--profile-hitches|profile-hitches|--profile-time|profile-time)
    SWIFT_CONFIGURATION="release"
    ;;
esac

build_stamp_value() {
  printf '%s|%s|%s|%s\n' "$SWIFT_CONFIGURATION" "$BUNDLE_ID" "$PRODUCT_NAME" "$SWIFT_PRODUCT_NAME"
}

app_bundle_is_current() {
  local source_paths=("$ROOT_DIR/Package.swift" "$ROOT_DIR/Sources" "$ROOT_DIR/Resources" "$ROOT_DIR/script/build_and_run.sh")
  local newest_source

  [[ "${LUMEN_BROWSER_FORCE_BUILD:-0}" != "1" ]] || return 1
  [[ -x "$APP_BINARY" && -f "$INFO_PLIST" && -f "$BUILD_STAMP" ]] || return 1
  [[ "$(cat "$BUILD_STAMP")" == "$(build_stamp_value)" ]] || return 1
  [[ -f "$ROOT_DIR/Package.resolved" ]] && source_paths+=("$ROOT_DIR/Package.resolved")

  newest_source="$(find "${source_paths[@]}" -type f -newer "$APP_BINARY" -print -quit)"
  [[ -z "$newest_source" ]]
}

reuse_current_app_if_possible() {
  app_bundle_is_current || return 1

  echo "Reusing current signed app bundle. Set LUMEN_BROWSER_FORCE_BUILD=1 to rebuild."
  case "$MODE" in
    run|--release|release)
      /usr/bin/open -n "$APP_BUNDLE"
      ;;
    --debug|debug)
      lldb -- "$APP_BINARY"
      ;;
    --logs|logs)
      /usr/bin/open -n "$APP_BUNDLE"
      /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
      ;;
    --subsystem-logs|subsystem-logs|--telemetry|telemetry)
      /usr/bin/open -n "$APP_BUNDLE"
      /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
      ;;
    --verify|verify|--verify-release|verify-release)
      /usr/bin/open -n "$APP_BUNDLE"
      sleep 1
      pgrep -x "$EXECUTABLE_NAME" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac

  exit 0
}

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
for legacy_executable_name in "${LEGACY_EXECUTABLE_NAMES[@]}"; do
  [[ "$legacy_executable_name" == "$EXECUTABLE_NAME" ]] \
    || pkill -x "$legacy_executable_name" >/dev/null 2>&1 \
    || true
done

if reuse_current_app_if_possible; then
  exit 0
fi

swift build -c "$SWIFT_CONFIGURATION"
BUILD_BINARY="$(swift build -c "$SWIFT_CONFIGURATION" --show-bin-path)/$SWIFT_PRODUCT_NAME"

rm -rf "$APP_BUNDLE" "$LEGACY_APP_BUNDLE"
rm -f "$LEGACY_BUILD_STAMP"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ ! -d "$APP_ICON_SOURCE" ]]; then
  echo "error: missing app icon source: $APP_ICON_SOURCE" >&2
  exit 1
fi

if ! xcrun actool \
  --compile "$APP_RESOURCES" \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --app-icon "$APP_ICON_NAME" \
  --output-partial-info-plist "$APP_ICON_PARTIAL_PLIST" \
  "$APP_ICON_SOURCE" >"$APP_ICON_ACTOOL_OUTPUT"; then
  cat "$APP_ICON_ACTOOL_OUTPUT" >&2
  exit 1
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleIconName</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Web URLs</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>http</string>
        <string>https</string>
      </array>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.html</string>
        <string>public.xhtml</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeDescription</key>
      <string>Lumen Browser Sidebar Space Identifier</string>
      <key>UTTypeIdentifier</key>
      <string>app.lumenbrowser.sidebar-space-id</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.mime-type</key>
        <string>application/x-lumen-browser-sidebar-space-id</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

keychain_search_list() {
  security list-keychains -d user \
    | sed -e 's/^[[:space:]]*"//' -e 's/"$//'
}

restore_keychain_search_list() {
  local keychains=("$@")
  if [[ "${#keychains[@]}" -gt 0 ]]; then
    security list-keychains -d user -s "${keychains[@]}" >/dev/null
  fi
}

identity_in_keychain() {
  local keychain="$1"
  local identity_name="$2"
  local original_keychains=()
  local existing_identity
  local saved_errexit=0
  local listed_keychain

  case "$-" in
    *e*) saved_errexit=1 ;;
  esac

  while IFS= read -r listed_keychain; do
    [[ -n "$listed_keychain" ]] && original_keychains+=("$listed_keychain")
  done < <(keychain_search_list)

  set +e
  security unlock-keychain -p "$DEV_SIGNING_KEYCHAIN_PASSWORD" "$keychain" >/dev/null 2>&1
  security list-keychains -d user -s "$keychain" "${original_keychains[@]}" >/dev/null 2>&1
  existing_identity="$(
    security find-identity -p codesigning -v 2>/dev/null \
      | awk -F '"' -v name="$identity_name" '$2 == name { print $2; exit }'
  )"
  restore_keychain_search_list "${original_keychains[@]}" >/dev/null 2>&1
  if [[ "$saved_errexit" -eq 1 ]]; then
    set -e
  fi

  echo "$existing_identity"
}

create_local_signing_identity() {
  local tmp_dir
  tmp_dir="$(mktemp -d "$DIST_DIR/local-signing.XXXXXX")"
  mkdir -p "$DEV_SIGNING_DIR"
  chmod 700 "$DEV_SIGNING_DIR"

  cat >"$tmp_dir/openssl.cnf" <<CERTCONFIG
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[ req_distinguished_name ]
CN = $DEV_SIGNING_IDENTITY

[ v3_codesign ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CERTCONFIG

  openssl req \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$tmp_dir/key.pem" \
    -x509 \
    -days 3650 \
    -out "$tmp_dir/cert.pem" \
    -config "$tmp_dir/openssl.cnf" >/dev/null 2>&1

  openssl pkcs12 \
    -legacy \
    -export \
    -inkey "$tmp_dir/key.pem" \
    -in "$tmp_dir/cert.pem" \
    -out "$tmp_dir/identity.p12" \
    -passout "pass:$DEV_SIGNING_KEYCHAIN_PASSWORD" >/dev/null 2>&1

  rm -f "$DEV_SIGNING_KEYCHAIN"
  security create-keychain -p "$DEV_SIGNING_KEYCHAIN_PASSWORD" "$DEV_SIGNING_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$DEV_SIGNING_KEYCHAIN"
  security unlock-keychain -p "$DEV_SIGNING_KEYCHAIN_PASSWORD" "$DEV_SIGNING_KEYCHAIN"
  security import "$tmp_dir/identity.p12" \
    -k "$DEV_SIGNING_KEYCHAIN" \
    -P "$DEV_SIGNING_KEYCHAIN_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$DEV_SIGNING_KEYCHAIN" \
    "$tmp_dir/cert.pem" >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$DEV_SIGNING_KEYCHAIN_PASSWORD" \
    "$DEV_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true

  rm -rf "$tmp_dir"
}

ensure_local_signing_identity() {
  local identity

  if [[ -f "$DEV_SIGNING_KEYCHAIN" ]]; then
    security unlock-keychain -p "$DEV_SIGNING_KEYCHAIN_PASSWORD" "$DEV_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
    identity="$(identity_in_keychain "$DEV_SIGNING_KEYCHAIN" "$DEV_SIGNING_IDENTITY")"
    if [[ -n "$identity" ]]; then
      echo "$identity"
      return
    fi
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo ""
    return
  fi

  create_local_signing_identity
  identity="$(identity_in_keychain "$DEV_SIGNING_KEYCHAIN" "$DEV_SIGNING_IDENTITY")"
  echo "$identity"
}

sign_with_local_identity() {
  local identity="$1"
  local original_keychains=()
  local keychain
  local status

  while IFS= read -r keychain; do
    [[ -n "$keychain" ]] && original_keychains+=("$keychain")
  done < <(keychain_search_list)

  security unlock-keychain -p "$DEV_SIGNING_KEYCHAIN_PASSWORD" "$DEV_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  security list-keychains -d user -s "$DEV_SIGNING_KEYCHAIN" "${original_keychains[@]}" >/dev/null

  set +e
  codesign --force \
    --keychain "$DEV_SIGNING_KEYCHAIN" \
    --sign "$identity" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE"
  status=$?
  set -e

  restore_keychain_search_list "${original_keychains[@]}"
  return "$status"
}

sign_app() {
  local identity="${LUMEN_BROWSER_CODESIGN_IDENTITY:-}"

  if [[ -z "$identity" ]]; then
    identity="$(
      security find-identity -p codesigning -v 2>/dev/null \
        | awk -F '"' '/"[^"]+"/ { print $2; exit }'
    )"
  fi

  if [[ -n "$identity" && "$identity" != "-" ]]; then
    codesign --force --sign "$identity" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
    return
  fi

  identity="$(ensure_local_signing_identity)"
  if [[ -n "$identity" ]]; then
    sign_with_local_identity "$identity"
    return
  fi

  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
  echo "warning: no valid code-signing identity found and local signing identity creation failed; using ad-hoc signing. Keychain Always Allow may not persist across rebuilt app binaries." >&2
}

sign_app
build_stamp_value >"$BUILD_STAMP"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

profile_app() {
  local template="$1"
  local output_name="$2"
  local time_limit="${3:-20s}"
  local output_path="$DIST_DIR/$output_name"

  rm -rf "$output_path"
  open_app
  sleep 1

  local pid
  pid="$(pgrep -x "$EXECUTABLE_NAME" | head -n 1)"
  if [[ -z "$pid" ]]; then
    echo "error: $EXECUTABLE_NAME is not running" >&2
    exit 1
  fi

  echo "Recording $template for $time_limit. Reproduce the sidebar swipe now."
  xcrun xctrace record \
    --template "$template" \
    --attach "$pid" \
    --time-limit "$time_limit" \
    --output "$output_path" \
    --no-prompt
  echo "Trace written to $output_path"
}

case "$MODE" in
  run)
    open_app
    ;;
  --release|release)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --subsystem-logs|subsystem-logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --telemetry|telemetry)
    echo "warning: --telemetry is deprecated; use --subsystem-logs for local developer diagnostics" >&2
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  --verify-release|verify-release)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  --profile-swiftui|profile-swiftui)
    profile_app "SwiftUI" "sidebar-swiftui.trace" "20s"
    ;;
  --profile-hitches|profile-hitches)
    profile_app "Animation Hitches" "sidebar-hitches.trace" "20s"
    ;;
  --profile-time|profile-time)
    profile_app "Time Profiler" "sidebar-time-profiler.trace" "20s"
    ;;
  *)
    echo "usage: $0 [run|--release|--debug|--logs|--subsystem-logs|--verify|--verify-release|--profile-swiftui|--profile-hitches|--profile-time]" >&2
    exit 2
    ;;
esac
