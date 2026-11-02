#!/bin/zsh
set -eu
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "${0:A:h:h}"
mkdir -p build/tests
/usr/bin/clang -fobjc-arc -ISources/Shared -framework Foundation Tests/Unit/policy-tests.m Sources/Shared/program-policy.m -o build/tests/policy-tests
build/tests/policy-tests
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library Sources/App/RecentApps.swift Tests/Unit/recent-apps-tests.swift -o build/tests/recent-apps-tests
build/tests/recent-apps-tests
/usr/bin/clang -c Sources/Shared/timezone-display.c -o build/tests/timezone-display.o
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library -import-objc-header Sources/Shared/timezone-display.h -licucore Sources/App/Models.swift Sources/App/DisplayPreferences.swift Sources/App/MenuProgramOverrides.swift Sources/App/MenuTimeZone.swift Tests/Unit/display-preferences-tests.swift build/tests/timezone-display.o -o build/tests/display-preferences-tests
build/tests/display-preferences-tests
/usr/bin/swiftc -D DEBUG -module-cache-path build/tests/ModuleCache -parse-as-library -import-objc-header Sources/Shared/timezone-display.h -licucore Sources/App/Models.swift Sources/App/DisplayPreferences.swift Sources/App/MenuProgramOverrides.swift Sources/App/MenuTimeZone.swift Tests/Unit/display-preferences-tests.swift build/tests/timezone-display.o -o build/tests/display-preferences-debug-tests
build/tests/display-preferences-debug-tests
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library -framework AppKit Sources/App/MenuRowView.swift Tests/Unit/menu-program-row-tests.swift -o build/tests/menu-program-row-tests
build/tests/menu-program-row-tests
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library Sources/App/WindowBadgeModel.swift Tests/Unit/window-badge-tests.swift -o build/tests/window-badge-tests
build/tests/window-badge-tests
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library Sources/App/SurgeTimezoneRouting.swift Tests/Unit/surge-timezone-routing-tests.swift -o build/tests/surge-timezone-routing-tests
build/tests/surge-timezone-routing-tests
/usr/bin/swiftc -module-cache-path build/tests/ModuleCache -parse-as-library Sources/App/SurgeNetworkAudit.swift Tests/Unit/surge-network-audit-tests.swift -o build/tests/surge-network-audit-tests
build/tests/surge-network-audit-tests
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/Shared/program-policy.m -o build/tests/program-policy.o
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/Shared/control-channel.m -o build/tests/control-channel.o
/usr/bin/clang++ -std=c++20 -fobjc-arc -fblocks -ISources/Shared -framework Foundation -framework Security -lbsm -lEndpointSecurity Sources/Daemon/es-daemon.mm Sources/Daemon/startup-injector.cpp build/tests/program-policy.o build/tests/control-channel.o -o build/tests/daemon-self-test
build/tests/daemon-self-test --self-test
