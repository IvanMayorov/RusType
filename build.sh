#!/bin/zsh
set -eu
cd "${0:A:h}"
app=build/RusType.app/Contents
mkdir -p "$app/MacOS" "$app/Resources" build/swift-cache
swiftc -swift-version 5 -O -module-cache-path build/swift-cache -target arm64-apple-macos14.0 Sources/*.swift -o "$app/MacOS/RusType"
cp Info.plist "$app/"
cp -p Runtime/{gigaam.gguf,transcribe-cli} "$app/Resources/"
# Pin the same signer and application identity across local updates.
signer=${RUSTYPE_SIGN_IDENTITY:-1EBB24D20F160A212E27FA39915DD199223106DF}
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Info.plist)
requirement="designated => identifier \"$identifier\" and certificate leaf = H\"$signer\""
if [[ "$signer" == "-" ]]; then
  codesign --force --sign - build/RusType.app
else
  codesign --force --sign "$signer" --timestamp=none --requirements "=$requirement" build/RusType.app
fi
codesign --verify --deep --strict build/RusType.app
