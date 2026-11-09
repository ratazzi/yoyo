#!/bin/zsh
set -eu
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
root=build/dependencies
archive="$root/Sparkle-$version.tar.xz"
mkdir -p "$root"
if [[ ! -f "$archive" ]]; then
  gh release download "$version" --repo sparkle-project/Sparkle --pattern "Sparkle-$version.tar.xz" --dir "$root"
fi
print -r -- "$checksum  $archive" | shasum -a 256 -c -
mkdir -p "$root/sparkle"
tar -xf "$archive" -C "$root/sparkle"
