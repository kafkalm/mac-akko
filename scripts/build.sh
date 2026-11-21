#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
app_dir="$repo_dir/build/Mac-Akko.app"
cache_dir="${TMPDIR:-/tmp}/mac-akko-swift-cache"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/"
cp "$repo_dir/THIRD-PARTY-NOTICES.txt" "$app_dir/Contents/Resources/"
xcrun swiftc -O -target arm64-apple-macos14.0 -module-cache-path "$cache_dir" \
  "$repo_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/MacAkko"
"$app_dir/Contents/MacOS/MacAkko" --self-test
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built: $app_dir"
