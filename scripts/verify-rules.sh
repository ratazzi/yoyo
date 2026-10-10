#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/chain/Example.app/Contents/Helpers
/usr/bin/clang Tests/Fixtures/chain-fixture.c -o build/chain/parent
/usr/bin/codesign --force --sign A5D59E9573A394C9AB54B3354913C818170B9948 build/chain/parent
cp build/chain/parent build/chain/child-one
cp build/chain/parent build/chain/grand
cp build/chain/parent build/chain/Example.app/Contents/Helpers/helper
/usr/bin/clang -fobjc-arc -ISources/Shared -framework Foundation Tests/Integration/verify-rules.m Sources/Shared/program-policy.m -o build/verify-rules
build/verify-rules
