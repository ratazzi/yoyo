#!/bin/zsh
set -eu
cd "${0:A:h:h}"
base="$PWD/build/tests/late-rule"
mkdir -p "$base/LateRule.app/Contents/MacOS" "$base/LateRule.app/Contents/Helpers"
/usr/bin/clang Tests/Fixtures/late-rule-fixture.c -o "$base/LateRule.app/Contents/MacOS/parent"
/usr/bin/codesign --force --sign "${SIGN_IDENTITY:-A5D59E9573A394C9AB54B3354913C818170B9948}" "$base/LateRule.app/Contents/MacOS/parent"
cp "$base/LateRule.app/Contents/MacOS/parent" "$base/LateRule.app/Contents/Helpers/helper"
cp "$base/LateRule.app/Contents/MacOS/parent" "$base/outside"
/usr/bin/clang -fobjc-arc -fblocks -framework Foundation -framework AppKit Tests/Integration/verify-late-rule.m -o "$base/verify-late-rule"
[[ "${1:-}" == --build-only ]] && exit 0
"$base/verify-late-rule"
"$base/verify-late-rule" --restart-ui
"$base/verify-late-rule" --rule-before-launch --restart-ui
