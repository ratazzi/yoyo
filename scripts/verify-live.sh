#!/bin/zsh
set -eu
cd "${0:A:h:h}"
lab_bin="$PWD/build/Yoyo.app/Contents/Resources/bin"
[[ "$(/usr/bin/plutil -extract status raw -o - build/state/daemon-state.json)" == listening ]]
[[ "$(/usr/bin/plutil -extract zone raw -o - build/state/daemon-state.json)" == Asia/Tokyo ]] || {
    print -u2 'Apply Asia/Tokyo in the app before running this acceptance test'
    exit 1
}
mkdir -p build/evidence/live
/usr/bin/env -u DYLD_INSERT_LIBRARIES -u PROCESS_TIMEZONE -u TZ -u TZFILE \
    "$lab_bin/timezone-probe" --expect Asia/Tokyo --require-injected --require-files --attack --scan-zoneinfo \
    > build/evidence/live/probe.json 2> build/evidence/live/probe.stderr
zsh scripts/verify-system-cli.sh
typeset -a children
for iteration in {1..20}; do
    /usr/bin/env -u DYLD_INSERT_LIBRARIES -u PROCESS_TIMEZONE -u TZ -u TZFILE \
        "$lab_bin/cli-start-paths" "$lab_bin/cli-fixture" \
        > "build/evidence/live/paths-$iteration.txt" 2> "build/evidence/live/paths-$iteration.stderr" &
    children+=("$!")
done
failures=0
for child in "${children[@]}"; do
    if ! wait "$child"; then failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]] || { print -u2 "$failures concurrent acceptance runs failed"; exit 1; }
print -r -- 'Automatic ES injection: 20 concurrent runs × 4 CLI startup paths = 80/80 PASS'
print -r -- 'Full timezone probe and original system date: PASS'
print -r -- 'Timezone names, path resolution, metadata and TZif bytes: MATCH'
