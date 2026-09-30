#!/bin/bash
set -euo pipefail
SHIYI_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${SHIYI_SIGNING_IDENTITY:-}" ] && [ ! -f "$SHIYI_ROOT/SigningIdentity.sha1" ]; then
  echo 'Configure a stable signing identity before packaging. Ad-hoc signing is disabled.' >&2
  exit 1
fi
if [ -z "${SHIYI_SIGNING_IDENTITY:-}" ]; then
  SHIYI_SIGNING_IDENTITY="$(tr -d '[:space:]' < "$SHIYI_ROOT/SigningIdentity.sha1")"
fi
if ! [[ "$SHIYI_SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'A stable signing certificate SHA-1 fingerprint is required.' >&2
  exit 1
fi
export SHIYI_SIGNING_IDENTITY
export CLANG_MODULE_CACHE_PATH="$SHIYI_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SHIYI_ROOT/.build/module-cache"
swift build --package-path "$SHIYI_ROOT" --disable-sandbox --configuration release
SHIYI_PACKAGE_STAGE="$(mktemp -d "$SHIYI_ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$SHIYI_PACKAGE_STAGE"' EXIT
SHIYI_APP="$SHIYI_PACKAGE_STAGE/hui.app"
mkdir -p "$SHIYI_APP/Contents/MacOS" "$SHIYI_APP/Contents/Resources"
# All menu management now lives in Shiyi. Remove only obsolete build artifacts.
rm -rf "$SHIYI_APP/Contents/Helpers" "$SHIYI_APP/Contents/Frameworks" "$SHIYI_APP/Contents/XPCServices"
cp "$SHIYI_ROOT/.build/release/Shiyi" "$SHIYI_APP/Contents/MacOS/Shiyi"
if [ -f "$SHIYI_ROOT/AppIcon.png" ]; then cp "$SHIYI_ROOT/AppIcon.png" "$SHIYI_APP/Contents/Resources/"; fi
cp "$SHIYI_ROOT/AppIcon.icns" "$SHIYI_ROOT/Branding/HuiMenuBarTemplate.pdf" "$SHIYI_APP/Contents/Resources/"
cp "$SHIYI_ROOT/Vendor/MenuCoreResources/Assets.car" "$SHIYI_ROOT/Vendor/MenuCoreResources/Acknowledgements.pdf" "$SHIYI_APP/Contents/Resources/"
ditto "$SHIYI_ROOT/.build/release/Shiyi_CompactSlider.bundle" "$SHIYI_APP/Contents/Resources/Shiyi_CompactSlider.bundle"
cat > "$SHIYI_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Shiyi</string>
<key>CFBundleIdentifier</key><string>com.gonghui.shiyi</string>
<key>CFBundleName</key><string>hui</string>
<key>CFBundleDisplayName</key><string>hui</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleVersion</key><string>16</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>hui local integration. Ice menu core: Copyright Jordan Baird and contributors. Third-party licenses are included.</string>
<key>NSMicrophoneUsageDescription</key><string>按住快捷键时录音，发送到你配置的讯飞服务识别成中文。本机不保存录音。</string>
</dict></plist>
PLIST
mkdir -p "$SHIYI_APP/Contents/Resources/ThirdParty"
cp "$SHIYI_ROOT/Vendor/Ice-LICENSE" "$SHIYI_ROOT/Vendor/MaClipHistory-LICENSE" "$SHIYI_ROOT/Vendor/ThirdPartyNotices.txt" "$SHIYI_APP/Contents/Resources/ThirdParty/"
cp "$SHIYI_ROOT/Vendor/Ice-0.11.13-dev.2-source.tar.gz" "$SHIYI_APP/Contents/Resources/ThirdParty/"
for SHIYI_DEPENDENCY in AXSwift CompactSlider Ifrit LaunchAtLogin Semaphore; do
  mkdir -p "$SHIYI_APP/Contents/Resources/ThirdParty/$SHIYI_DEPENDENCY"
  for SHIYI_LICENSE in "$SHIYI_ROOT/Vendor/Dependencies/$SHIYI_DEPENDENCY"/[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*; do
    if [ -f "$SHIYI_LICENSE" ]; then cp "$SHIYI_LICENSE" "$SHIYI_APP/Contents/Resources/ThirdParty/$SHIYI_DEPENDENCY/"; fi
  done
done
cp "$SHIYI_ROOT/Vendor/Dependencies/Ifrit/Sources/Ifrit/Classes/Fuse_LICENSE" "$SHIYI_APP/Contents/Resources/ThirdParty/Ifrit/"
rm -f "$SHIYI_APP/Contents/Resources/ThirdParty/Shiyi-1.3.0-modified-source.tar.gz" "$SHIYI_APP/Contents/Resources/ThirdParty/Shiyi-1.3.1-modified-source.tar.gz" "$SHIYI_APP/Contents/Resources/ThirdParty/Shiyi-1.3.2-modified-source.tar.gz"
SHIYI_SOURCE_METADATA="$SHIYI_PACKAGE_STAGE/source-signing"
mkdir -p "$SHIYI_SOURCE_METADATA"
printf '%s\n' "$SHIYI_SIGNING_IDENTITY" > "$SHIYI_SOURCE_METADATA/SigningIdentity.sha1"
COPYFILE_DISABLE=1 tar -czf "$SHIYI_APP/Contents/Resources/ThirdParty/hui-1.5.0-modified-source.tar.gz" -C "$SHIYI_ROOT" \
  Package.swift Sources build.sh sign-app.sh make-icon.swift AppIcon.png AppIcon.icns Branding \
  Vendor/IceCore Vendor/Dependencies Vendor/MenuCoreResources Vendor/Ice-LICENSE Vendor/Ice-0.11.13-dev.2-source.tar.gz Vendor/MaClipHistory-LICENSE Vendor/ThirdPartyNotices.txt \
  -C "$SHIYI_SOURCE_METADATA" SigningIdentity.sha1
bash "$SHIYI_ROOT/sign-app.sh" "$SHIYI_APP"
mkdir -p "$SHIYI_ROOT/dist"
if [ -d "$SHIYI_ROOT/dist/hui.app" ]; then
  mv "$SHIYI_ROOT/dist/hui.app" "$SHIYI_PACKAGE_STAGE/Previous.app"
fi
if ! mv "$SHIYI_APP" "$SHIYI_ROOT/dist/hui.app"; then
  if [ -d "$SHIYI_PACKAGE_STAGE/Previous.app" ]; then
    mv "$SHIYI_PACKAGE_STAGE/Previous.app" "$SHIYI_ROOT/dist/hui.app"
  fi
  exit 1
fi
