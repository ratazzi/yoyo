#!/bin/zsh
set -eu
cd "${0:A:h:h}"
[[ "$EUID" == 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || {
    print -u2 'Run: sudo zsh scripts/verify-daemon-restart.sh'
    exit 2
}
test_user="$SUDO_USER"
base="$PWD/build/tests/late-rule"
/usr/bin/sudo -u "$test_user" mkdir -p build/evidence
exec > >(/usr/bin/sudo -u "$test_user" /usr/bin/tee build/evidence/daemon-restart.log) 2>&1
[[ "$(/usr/bin/plutil -extract status raw -o - build/state/daemon-state.json)" == listening ]] || {
    print -u2 'Enable the Yoyo background service before running this test'
    exit 2
}

# Stop before replacing the signed bundle; leave the launchd registration intact.
trap '/bin/launchctl kickstart system/yoyo.hola.ac.daemon >/dev/null 2>&1 || true' EXIT
/bin/launchctl kill SIGTERM system/yoyo.hola.ac.daemon
for attempt in {1..100}; do
    [[ "$(/usr/bin/plutil -extract status raw -o - build/state/daemon-state.json)" == stopped ]] && break
    sleep 0.1
done
[[ "$(/usr/bin/plutil -extract status raw -o - build/state/daemon-state.json)" == stopped ]]
/usr/bin/sudo -u "$test_user" /usr/bin/env "SIGN_IDENTITY=${SIGN_IDENTITY:-A5D59E9573A394C9AB54B3354913C818170B9948}" zsh scripts/build.sh
/bin/launchctl kickstart system/yoyo.hola.ac.daemon
/usr/bin/sudo -u "$test_user" zsh scripts/verify-late-rule.sh --build-only

run_case() {
    coproc /usr/bin/sudo -u "$test_user" "$base/verify-late-rule" "$@" --restart-daemon
    local runner="$!" line
    while IFS= read -r -p line; do
        if [[ "$line" == YOYO_TEST_RESTART_DAEMON ]]; then
            if /bin/launchctl kickstart -k system/yoyo.hola.ac.daemon; then
                print -p R
            else
                print -p F
            fi
        else
            print -r -- "$line"
        fi
    done
    wait "$runner"
}
run_case
run_case --rule-before-launch
print -r -- 'Daemon restart recovery, both launch histories: PASS'
