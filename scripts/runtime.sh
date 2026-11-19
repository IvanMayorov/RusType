#!/bin/bash
# Copy the two recognition components from the pinned upstream disk image.
set -euo pipefail
dest=${1:?Specify a destination for the runtime}
image=${2:-}
mkdir -p "$dest"
temp=$(mktemp -d)
mounted=false
cleanup() {
  if "$mounted"; then hdiutil detach "$temp/disk" -quiet || return; fi
  rm -rf "$temp"
}
trap cleanup EXIT
if [[ -z "$image" ]]; then
  image="$temp/Golosok.dmg"
  curl --fail --location --retry 3 --output "$image" https://github.com/Berliner187/Golosok/releases/download/v1.13.11/Golosok.dmg
fi
expected=154428f531155c8f915e0ca4c69a610ab40036df1a1d97f8770d4e77573ac8d7
if [[ "$(shasum -a 256 "$image" | cut -d' ' -f1)" != "$expected" ]]; then
  echo "Контрольная сумма образа не совпадает." >&2
  exit 1
fi
mkdir "$temp/disk"
hdiutil attach -readonly -nobrowse -mountpoint "$temp/disk" "$image" >/dev/null
mounted=true
resources="$temp/disk/Golosok.app/Contents/Resources"
cp -p "$resources/gigaam.gguf" "$resources/transcribe-cli" "$dest/"
