#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build
/usr/bin/clang Tests/Fixtures/cli-fixture.c -o build/cli-fixture
/usr/bin/clang Tests/Fixtures/cli-start-paths.c -o build/cli-start-paths
if [[ "${1:-}" == --control ]]; then
    /usr/bin/clang -fobjc-arc -Wno-deprecated-declarations -ISources/Shared -arch arm64 -arch arm64e -dynamiclib -framework Foundation -framework CoreFoundation -licucore Sources/Injection/enforced.m Sources/Injection/timezone-files.c Sources/Injection/runtime-trace.c -o build/libenforced.dylib
    PROCESS_TIMEZONE=Asia/Tokyo DYLD_INSERT_LIBRARIES="$PWD/build/libenforced.dylib" ./build/cli-fixture
else
    # A passing result requires a separately running automatic injector.
    # This driver supplies no injection environment to clean-environment cases.
    ./build/cli-start-paths "$PWD/build/cli-fixture"
fi
