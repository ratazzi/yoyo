#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
/usr/bin/clang -fobjc-arc -c Sources/App/SurgeSocketPrototype.m -o build/surge-socket-prototype.o
/usr/bin/swiftc -D SURGE_BRIDGE_STANDALONE -parse-as-library -import-objc-header Sources/App/SurgeSocketPrototype.h \
    Sources/App/SurgeBridge.swift Sources/App/SurgeTimezoneRouting.swift Sources/App/SurgeNetworkAudit.swift build/surge-socket-prototype.o -o build/surge-bridge-prototype
exec build/surge-bridge-prototype "${1:-47643}"
