# Surge → Yoyo launch-timezone lookup

Surge reports connection metadata and its timezone argument to Yoyo. Yoyo identifies one live socket owner
and queries that PID's authenticated daemon launch session. It returns a
`timezone` containing the complete startup timezone, such as `America/Los_Angeles`.
Yoyo matches its last component against the argument and returns `matched`.
The script forwards that boolean to Surge. Surge's SCRIPT rule independently
chooses the policy: `argument=Paris` can be paired with `SCRIPT,yoyo-paris,France`.
No timezone-to-policy mapping is needed. Domain-only test matching has been removed.

## Run and configure

Open Yoyo. The built-in receiver starts automatically in Debug and Release on
`127.0.0.1:47643`; `GET /health` checks availability and `GET /v1/surge/latest`
returns the latest diagnostic report. Closing the main window leaves it running;
quitting Yoyo stops it. Keep the ES background service enabled for session lookup.
Stop any old standalone prototype before starting the integrated application.
`mise run dev:surge` remains available only as a development tool;
it uses the signed Yoyo binary's `--inspect-process` command to query the daemon.

Manually create the `Paris` and `Singapore` policies in Surge, then merge
`scripts/surge/timezone-routing.example.conf` into your profile. Place its two
SCRIPT rules before fallback rules and replace the old domain-test SCRIPT rules.
Each named script has its own timezone argument. Surge caches results by script
name for a request, so the two rules need distinct script names.
The script continues only when `$environment.system` is `macOS`; other or missing
platform identifiers immediately complete unmatched without calling Yoyo.

No mapping file is needed. Script arguments must match the final timezone component verbatim, including
case and underscores; policy names are independent. A rule script returns only
a match boolean; its static SCRIPT rule supplies the original request's policy.
The report's `$httpClient` policy applies only to the reporting POST.

Unknown or ambiguous PID, absent/default launch session, stale process identity,
invalid timezone, reporting error and timeout all return
unmatched and continue through the existing rules. The choice comes from the
daemon's launch session, rather than the current rule or an app's later timezone
override. Injection confirmation is exposed separately in diagnostics.

## Attribution and limits

The receiver enumerates readable processes with the exact executable path and
inspects TCP/UDP socket descriptors with libproc. It verifies source port,
protocol and source IP, plus either the loopback proxy listener endpoint or a
destination IP/port supplied by Surge. It does not resolve domains itself.
Only one verified owner with no same-path inspection failures yields a PID.

Before routing, it checks process birth time, executable path, daemon PID/exec
generation via `proc_pidpath_audittoken`, and the live socket's generation and
endpoints again. Shared sockets and closed connections do not select a policy.
Session lookups have a bounded 0.5-second cache, with identity revalidated for
every decision. Reporting waits approximately 450ms at most.

Protected processes, missing source metadata, helper paths, pooled connections,
remote clients and already-closed sockets can prevent attribution. This remains
a feasibility prototype, not universal attribution for Enhanced Mode or QUIC.
The latest diagnostic report is held in memory. Loopback reporting requests are
excluded to prevent recursion.

## Network audit

Enable behavior logging on the relevant Yoyo rule to write `network-audit.jsonl`
in Yoyo's state directory (currently `build/state`). Each JSON line records one
SCRIPT evaluation: receipt time, argument, domain and socket endpoints, trusted
PID/exec identity, recorded parent PID, launch-session ID, rule ID, timezone and
match result. The session ID correlates requests with the process-chain launch
choice; this is not a full reconstructed ancestor list or proof of a completed
network request. Unmatched arguments are also audited when attribution succeeds.
Unconfirmed process identities and rules with behavior logging disabled are not
written. URLs and User-Agent are excluded.

Writing uses a separate bounded queue and does not gate the match response. The
file has owner-only permissions, rotates at 5 MiB, and retains one backup. Audit
write failures or overload are reported to stderr and do not change routing.
Multiple SCRIPT rules may report the same connection; these are separate
evaluations, not independent connections. Ruleset scoping still determines which
requests reach the script, so this is not an audit of all system network traffic.

## Verification

Chrome profile attribution was tested with two profiles under one temporary
user-data directory and two separate temporary user-data directories. The shared
profiles used the same Network Service socket PID; separate data directories
used distinct Network Service PIDs. Yoyo's socket lookup agreed with independent
`lsof` ownership for all four connections. Thus profile-directory selection alone
does not isolate timezone-based network routing. Reproduce with
`mise run verify:chrome-profiles`;
evidence is written to `build/evidence/chrome-profiles/result.json`.

A real Surge HTTP-proxy curl request returned the independently recorded PID
7481 with `socket_unique` and `proxy_tuple` evidence; the report is at
`build/evidence/surge/real-curl.json`.

`mise run verify:surge` adds isolated temporary CLI rules,
launches signed native socket fixtures under real daemon sessions, and removes
its rules afterward. Paris, Singapore and Los Angeles launch-session timezones are checked,
including TCP/UDP ownership and unmatched missing-port/shared/closed controls.
Run it with `mise run verify:surge`.
Unit tests cover stale/mismatched sessions, timezone naming conventions and invalid zones;
`Tests/Integration/surge-rule-script-tests.js` covers timezone arguments, failures,
timeouts and recursion. Full Surge policy routing requires the user's profile
configuration and real connection traffic; `surge-cli rule match` alone does not
create an attributable socket.

References: [Surge rule scripts](https://manual.nssurge.com/scripting/rule.html)
and [Surge scripting API](https://manual.nssurge.com/scripting/api.html).
