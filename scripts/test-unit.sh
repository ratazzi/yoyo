#!/bin/zsh
set -eu
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "${0:A:h:h}"
mkdir -p build/tests
/usr/bin/clang -fobjc-arc -ISources/Shared -framework Foundation Tests/Unit/policy-tests.m Sources/Shared/program-policy.m -o build/tests/policy-tests
build/tests/policy-tests
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library Sources/App/RecentApps.swift Tests/Unit/recent-apps-tests.swift -o build/tests/recent-apps-tests
build/tests/recent-apps-tests
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/Shared/program-policy.m -o build/tests/program-policy.o
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/Shared/control-channel.m -o build/tests/control-channel.o
/usr/bin/clang++ -std=c++20 -fobjc-arc -fblocks -ISources/Shared -framework Foundation -framework Security -lbsm -lEndpointSecurity Sources/Daemon/es-daemon.mm Sources/Daemon/startup-injector.cpp build/tests/program-policy.o build/tests/control-channel.o -o build/tests/daemon-self-test
build/tests/daemon-self-test --self-test
