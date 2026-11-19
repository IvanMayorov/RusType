#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -m)" == arm64 ]] || { echo "Нужен Mac с Apple Silicon."; exit 1; }
[[ ! -e "RusType.app" ]] || { echo "RusType.app уже есть в этой папке."; exit 1; }
stage=$(mktemp -d "$PWD/.prepare.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/RusType.app"
ditto Contents "$stage/RusType.app/Contents"
bash runtime.sh "$stage/RusType.app/Contents/Resources" "${1:-}"
codesign --verify --deep --strict "$stage/RusType.app"
mv -n "$stage/RusType.app" .
[[ ! -e "$stage/RusType.app" ]] || exit 1
echo "Готово. Перенесите RusType.app в «Программы»."
