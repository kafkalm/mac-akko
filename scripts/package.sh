#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
zsh "$repo_dir/scripts/build.sh"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_dir/Resources/Info.plist")
mkdir -p "$repo_dir/dist"
archive="mac-akko-v${version}-macOS-arm64.zip"
ditto -c -k --norsrc --keepParent "$repo_dir/build/mac-akko.app" "$repo_dir/dist/$archive"
cd "$repo_dir/dist"
shasum -a 256 "$archive" > SHA256SUMS.txt
cat SHA256SUMS.txt
