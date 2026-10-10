#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/evidence
if actual="$(/usr/bin/env -i /bin/date -r 0 '+%F %T %z' 2> build/evidence/system-date.stderr)"; then
    print -r -- "$actual" > build/evidence/system-date.txt
else
    print -u2 'System CLI could not execute; inspect build/state/exec-events.jsonl'
    exit 1
fi
[[ "$actual" == '1970-01-01 09:00:00 +0900' ]] || {
    print -u2 "System CLI returned an unexpected timezone: $actual"
    exit 1
}
print -r -- 'Original /bin/date, empty environment, automatic ES injection: PASS'
