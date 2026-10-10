#!/bin/zsh
set -eu
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "${0:A:h:h}"
lab_root="$PWD"
lab_app="$lab_root/build/TimezoneLab.app"
lab_resources="$lab_app/Contents/Resources"
lab_helper="$lab_app/Contents/Library/LaunchServices/TimezoneLabDaemon.app"
mkdir -p "$lab_resources/bin" "$lab_app/Contents/MacOS" "$lab_helper/Contents/MacOS" "$lab_app/Contents/Library/LaunchDaemons" build/state
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/Shared/program-policy.m -o build/program-policy.o
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/Shared/control-channel.m -o build/control-channel.o
/usr/bin/clang -fobjc-arc -fblocks -ISources/Shared -c Sources/App/AppBridge.m -o build/app-bridge.o
/usr/bin/swiftc -parse-as-library -import-objc-header Sources/App/AppBridge.h -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Security Sources/App/*.swift build/program-policy.o build/control-channel.o build/app-bridge.o -o "$lab_app/Contents/MacOS/TimezoneLab"
/usr/bin/clang++ -std=c++20 -fobjc-arc -fblocks -ISources/Shared -framework Foundation -framework Security -lbsm -lEndpointSecurity Sources/Daemon/es-daemon.mm Sources/Daemon/startup-injector.cpp build/program-policy.o build/control-channel.o -o "$lab_helper/Contents/MacOS/timezone-es-daemon"
/usr/bin/clang -fobjc-arc -ISources/Shared -framework Foundation Tests/Unit/policy-tests.m Sources/Shared/program-policy.m -o build/policy-tests
build/policy-tests
/usr/bin/clang -fobjc-arc -Wno-deprecated-declarations -ISources/Shared -framework Foundation -framework CoreFoundation Tests/Fixtures/timezone-probe.m -o "$lab_resources/bin/timezone-probe"
/usr/bin/clang Tests/Fixtures/cli-fixture.c -o "$lab_resources/bin/cli-fixture"
/usr/bin/clang Tests/Fixtures/cli-start-paths.c -o "$lab_resources/bin/cli-start-paths"
/usr/bin/clang -Wno-deprecated-declarations Tests/Fixtures/file-hook-check.c -o "$lab_resources/bin/file-hook-check"
/usr/bin/clang -fobjc-arc -Wno-deprecated-declarations -ISources/Shared -arch arm64 -arch arm64e -dynamiclib -framework Foundation -framework CoreFoundation -licucore Sources/Injection/enforced.m Sources/Injection/timezone-files.c Sources/Injection/runtime-trace.c -o "$lab_resources/libenforced.dylib"
cp Resources/Info.plist "$lab_app/Contents/Info.plist"
cat > "$lab_helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>floria.hola.ac.endpoint-security</string>
<key>CFBundleExecutable</key><string>timezone-es-daemon</string>
<key>CFBundleName</key><string>Timezone Lab ES Daemon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
# plutil writes values without interpolating shell strings into JSON/XML.
lab_config="$lab_resources/lab-config.json"
print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$lab_config"
/usr/bin/plutil -insert zone -string "${TIMEZONE_LAB_ZONE:-Asia/Tokyo}" "$lab_config"
/usr/bin/plutil -insert app_bundle_relative_paths -bool YES "$lab_config"
/usr/bin/plutil -insert library -string Contents/Resources/libenforced.dylib "$lab_config"
/usr/bin/plutil -insert state_directory -string "$lab_root/build/state" "$lab_config"
/usr/bin/plutil -insert targets -array "$lab_config"
for target in Contents/Resources/bin/timezone-probe Contents/Resources/bin/cli-fixture "$lab_root/build/timezone-probe" "$lab_root/build/cli-fixture"; do
    /usr/bin/plutil -insert targets -string "$target" -append "$lab_config"
done
/usr/bin/plutil -convert json "$lab_config"
lab_service="$lab_app/Contents/Library/LaunchDaemons/dev.timezone.lab.daemon.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$lab_service"
/usr/bin/plutil -insert Label -string dev.timezone.lab.daemon "$lab_service"
/usr/bin/plutil -insert BundleProgram -string Contents/Library/LaunchServices/TimezoneLabDaemon.app/Contents/MacOS/timezone-es-daemon "$lab_service"
/usr/bin/plutil -insert ProgramArguments -array "$lab_service"
/usr/bin/plutil -insert ProgramArguments -string timezone-es-daemon -append "$lab_service"
/usr/bin/plutil -insert ProgramArguments -string --bundle-config -append "$lab_service"
/usr/bin/plutil -insert RunAtLoad -bool YES "$lab_service"
/usr/bin/plutil -insert KeepAlive -dictionary "$lab_service"
/usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool NO "$lab_service"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$lab_service"
/usr/bin/plutil -insert StandardOutPath -string "$lab_root/build/state/service-stdout.txt" "$lab_service"
/usr/bin/plutil -insert StandardErrorPath -string "$lab_root/build/state/service-stderr.txt" "$lab_service"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    lab_profile="${ES_PROVISIONING_PROFILE:-/Users/ratazzi/workspace/floria/provisioning/Floria_Endpoint_Security_Developer_ID.provisionprofile}"
    [[ -f "$lab_profile" ]] || { print -u2 'ES provisioning profile not found'; exit 1; }
    cp "$lab_profile" "$lab_helper/Contents/embedded.provisionprofile"
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --entitlements Resources/Daemon.entitlements "$lab_helper"
    for binary in "$lab_resources"/bin/* "$lab_resources/libenforced.dylib"; do
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$binary"
    done
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$lab_app"
else
    # Ad-hoc builds are usable for CLI controls and UI; they cannot become an ES client.
    rm -f "$lab_helper/Contents/embedded.provisionprofile"
    /usr/bin/codesign --force --sign - "$lab_helper"
    /usr/bin/codesign --force --sign - "$lab_app"
    print -u2 'Ad-hoc build: ES requires a real SIGN_IDENTITY and its provisioning profile.'
fi
/usr/bin/codesign --verify --deep --strict "$lab_app"
"$lab_helper/Contents/MacOS/timezone-es-daemon" --self-test
print -r -- "$lab_app"
