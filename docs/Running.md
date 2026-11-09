# Running Yoyo

Yoyo's main bundle identifier is `yoyo.hola.ac`; its launchd label is `yoyo.hola.ac.daemon`. This development rename does not migrate old settings, rules or injection paths automatically. Relaunch configured applications before testing the renamed build. Archived feasibility documents retain the old experimental name.

## Local signed build

The tested identity is `Developer ID Application: jingsong zhao (74526N936A)`, fingerprint `A5D59E9573A394C9AB54B3354913C818170B9948`.

```sh
SIGN_IDENTITY=A5D59E9573A394C9AB54B3354913C818170B9948 mise run build-app
open build/Yoyo.app
```

The build defaults to `/Applications/Xcode.app/Contents/Developer`; `DEVELOPER_DIR` can override it. Full Xcode is needed for the SwiftUI macro plugins. Native C/Objective-C/C++ use clang; the UI uses swiftc and an Objective-C bridging header.

The ES provisioning profile defaults to `/Users/ratazzi/workspace/floria/provisioning/Floria_Endpoint_Security_Developer_ID.provisionprofile`. Set `ES_PROVISIONING_PROFILE` for another location. The helper retains that profile's `floria.hola.ac.endpoint-security` identifier and Team ID; the main app is `yoyo.hola.ac`, with launchd label `yoyo.hola.ac.daemon`. Floria itself is not modified or replaced.

## GitHub releases

The `Release` workflow runs `mise run release` on macOS ARM64. Pushing a `vMAJOR.MINOR.PATCH` tag creates a draft GitHub release containing a signed update appcast; publish that draft as the latest release to offer it to stable users. Nightly builds run daily at 18:00 UTC or on manual dispatch from `master` and update the `nightly` prerelease. Only a signed, notarized, stapled and Gatekeeper-verified DMG is uploaded. CI runs unit tests, release feed tests and an application typecheck with Sparkle.

Configure these repository Actions secrets (the same certificate and notary credentials as Floria):

- `DEVELOPER_ID_CERTIFICATE_P12`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_IDENTITY`, `APPLE_TEAM_ID`
- `ES_PROVISIONING_PROFILE_BASE64`: the base64-encoded Endpoint Security Developer ID profile, matching `Resources/Daemon.entitlements` and the helper identifier.
- `NOTARIZE_APPLE_ID`, `NOTARIZE_PASSWORD`
- `SPARKLE_PRIVATE_KEY`: the exported Sparkle Ed25519 private key (base64 text), used only by the signing step.

Also configure the repository Actions **variable** `SPARKLE_PUBLIC_KEY` with its matching public key. Release builds require it and embed it as `SUPublicEDKey`; the feed generator verifies the DMG signature against this public key before uploading anything.

For local signing, store `SPARKLE_PUBLIC_KEY` and `SPARKLE_PRIVATE_KEY` in the `[env]` section of `mise.local.toml`. This file is ignored by Git; keep its permissions at `0600`. Mise supplies these values to build and appcast tasks. Keep a protected backup and reuse this pair for future releases. GitHub Actions still requires its corresponding variable and secret; it cannot read the local file.

The build downloads pinned Sparkle 2.10.1 with `gh` and verifies its SHA-256 before extracting it. Follow [Sparkle's key setup](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures) once on a trusted Mac:

```sh
zsh scripts/release/fetch-sparkle.sh
build/dependencies/sparkle/bin/generate_keys --account yoyo
build/dependencies/sparkle/bin/generate_keys --account yoyo -p | gh variable set SPARKLE_PUBLIC_KEY
```

Export the key using `generate_keys --account yoyo -x <private-file>` into a protected temporary file, pass that file to `gh secret set SPARKLE_PRIVATE_KEY < <private-file>`, and remove the exported file afterward. Keep a protected backup of the key; do not commit or print it. The public key is not a secret. The workflow never generates replacement keys.

The profile is decoded only for the build and removed afterward. Signed code uses Hardened Runtime and secure timestamps. `mise run notarize-dmg path/to/Yoyo.dmg` retries notarization without rebuilding, using the same notary environment variables.

Release builds store state in `~/Library/Application Support/Yoyo`; the UI creates this directory before enabling the service. The daemon resolves the home of the logged-in console user at startup. Switching users while the service is running requires restarting it for the new user. Service stdout/stderr go to `/var/log/yoyo-stdout.txt` and `/var/log/yoyo-stderr.txt`.

## Automatic updates

**Settings → Updates** selects Stable or Nightly and controls automatic checks; changes apply when saved. The menu has a single **Check for Updates…** action for manual checks. Fresh nightly installations default to Nightly; explicit user selection persists across upgrades. Stable uses `https://github.com/ratazzi/yoyo/releases/latest/download/appcast.xml`; Nightly uses `https://github.com/ratazzi/yoyo/releases/download/nightly/appcast.xml`. Both use Sparkle's install confirmation UI; automatic background installation is disabled.

All releases use the same Release workflow's `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT` as `CFBundleVersion` (including the helper) and appcast version. Stable display versions come from tags; nightly display versions include the build number. Retries receive distinct versions and archive names. Switching to Stable waits for a stable release with a higher build number; it never downgrades. Preserve this workflow's run sequence when migrating workflows, or explicitly choose a higher build-number scheme.

Nightly archives use unique filenames and remain available for clients with cached feeds. Publication uploads the archive before replacing `appcast.xml`, serializes releases, and rejects older queued nightly builds. Do not delete old nightly DMGs while feeds may still reference them. Stable drafts do not affect the stable feed until published as latest. Before the first stable release, stable checks have no feed; use Nightly during that bootstrap period.

During installation Yoyo waits for its registered background service to unregister before allowing Sparkle to terminate the app. A persisted recovery flag restores the service on next launch if the user's policy still enables it, including after an interrupted update. macOS may briefly reject re-registration after unregister completes; recovery retries only ServiceManagement's temporary EPERM error after 1, 2 and 4 seconds. Other errors and exhausted retries are reported, keeping the recovery flag for the next launch. Failure to unregister cancels termination. Closing Yoyo normally continues to leave the service running. Launches during installation do not receive new timezone injection; existing processes retain their launch-time behavior.

Local builds without `SPARKLE_PUBLIC_KEY` do not start the updater. Use `OUTPUT_APP=build/update-test/Yoyo.app mise run build-app` to validate embedding/signing without replacing the normal development bundle. The first Sparkle-enabled release must be installed manually because earlier versions contain no updater. Verify a real signed upgrade and service restart on a test Mac before promoting the first stable release.

## Service setup

Open Settings and enable **Background Service**. Approve Login Items and Full Disk Access if macOS requires them. The helper bundle is:

`build/Yoyo.app/Contents/Library/LaunchServices/YoyoDaemon.app`

The service runs as root. Its status is shown in Settings; the main toolbar has no status badge. Closing or quitting the UI leaves the daemon running; unanswered Ask Every Launch requests will expire and be denied. Stop the service in Settings before rebuilding. Reopen the app only after signing finishes so the running process passes the daemon's signature check.

## Defaults and precedence

On a clean install, the default is **System Default**, no rules are added, and ES is off. Existing legacy target lists migrate into exact Fixed Time Zone rules.

With a custom default, unmatched new launches are injected with that zone. A System Default rule explicitly excludes a program. Parent sessions are inherited before the global fallback: an excluded parent's unruled descendants remain excluded, and an explicitly configured parent's descendants keep its choice.

Matching precedence: exact CLI > CLI glob > application subtree. More specific matches win; equal specificity uses list order. `*` does not cross `/`. A previously encountered application rule does not undo a deeper explicit override.

Ask Every Launch choices are never saved as the next launch's answer. Each new root asks again; unruled descendants inherit the answer. The timeout is at most 20 seconds, shortened to fit the ES authorization deadline. Cancel, timeout or unavailable UI denies the launch.

## Files

The development build uses `build/state/`:

- `policy.plist`: XML property list containing validated rules, ES enabled flag, and app default. On first launch, a valid legacy `policy.json` is migrated if no plist exists; the JSON remains as a backup. Once present, the plist takes precedence, including when it is invalid.
- `daemon-state.json`: health and latest launch outcome.
- `behavior.jsonl`: optional metadata logs, rotated at 4 MiB with four archives.
- `recent-apps.json`: UI-owned application launch history, up to 100 regular/menu bar apps by Bundle ID. Uses Workspace lifecycle notifications and actual launch dates; CLI, helpers, background agents and focus changes do not refresh it. Works without ES. The previous experimental `recent-launches.json` is left untouched and no longer used.
- `active-sessions.json`: process-session recovery metadata, including only the original TZ/TZFILE environment values needed for restoration; this is not a behavior log.
- `control.sock`: authenticated local UI and hook communication.
- `trace-*.flag`: shared live logging switches, cleaned up after tracked processes exit.

The UI has no activity or log viewer. Settings can open the log folder. Default-mode programs have ES metadata only; timezone-function records require the hook. File events cover operations such as open/mmap/write, not every individual read. Hook tracing uses bounded waits and is best effort.

Temporary execution diagnostics are separate from app history and opt-in behavior logs. `execution-diagnostics-config.json` enables a bounded capture using a UUID `run_id` and absolute `expires_at`; the daemon caps the remaining duration at ten minutes and stops automatically. `execution-diagnostics-<UUID>.jsonl` contains exec identities, parent/responsible audit identities and cached ancestry, with no arguments, environment variables or file content. `mise run diagnose:executions <input.jsonl> [report.md]` summarizes the resulting file. The completed sampling sessions are disabled; enabling a new capture requires a new unexpired configuration.

## Validation and limitations

The optional window badge uses a nonactivating, mouse-through panel and Accessibility window geometry. It requires a confirmed hook session for the actual foreground app PID, executable and launch time. It tries outside positions above/right/below/left, hides when there is no room or the window is minimized/full screen/on another Space, and keeps the launch session's zone after rule edits or removal. Window positions are sampled at 5Hz; process metadata is refreshed every two seconds. `Preview Badge` does not require Accessibility access.

`mise run build:badge-fixture` creates an isolated AppKit test application. Give it a temporary fixed-zone rule and use its **Test** menu for edges, maximization, full screen, minimization and display switching. For test-only snapshots, launch the UI with `open -na build/Yoyo.app --env TIMEZONE_LAB_WINDOW_BADGE_DIAGNOSTICS=1`; snapshots contain coordinates, visibility, PID, zone and panel flags, with no window titles or content. Launch with the variable set to `0` to disable capture. The completed manual run covered 17 snapshots across two real displays, including restoring windows and removing the rule while the injected process remained running; all checks passed. Evidence is in `build/window-badge-qa/summary.json`.

`mise run test` exercises policy decisions and startup stack preservation. `mise run verify:lab` covers positive/negative controls, timezone mutation and file-hook compatibility. `mise run verify:live` checks automatic injection, names/data and 80 concurrent CLI launches. `mise run verify:rules` checks real process chains, globs, application subdirectories, global defaults, System Default exclusions and metadata-only logging.

The project has not implemented a launcher fallback, universally reliable shared XPC association, Rosetta support, guaranteed hook loading for every protected binary, lossless log delivery or production installation hardening. Current binaries and configuration live in a user-writable development directory. Do not interpret the tested user-space hooks as a universal anti-bypass or isolation boundary. Stopping ES cannot unload hooks from running processes; restart those processes to remove them.

Earlier detailed evidence is archived in [lab running notes](research/lab-running.md).
