# Yoyo

A native macOS menu bar app for per-program time zones. The interface is written in SwiftUI, with an Endpoint Security daemon and an injected Objective-C/C library.

## Use

Open `build/Yoyo.app`. Use **+** to add an application, executable, or path pattern. Click a program to edit its rule:

You can also drag applications or executable files onto the main window. Drop multiple programs to review their rules in sequence; dropping an existing program opens its rule instead of creating a duplicate. Other files and ordinary folders are skipped.

- **System Default** leaves the program's normal environment intact, without injection.
- **Fixed Time Zone** applies the selected IANA time zone.
- **Ask Every Launch** asks once per independent launch. Cancelling or timing out stops the launch.

**Settings → Default Time Zone** controls every new program without a matching rule. It can differ from the system time zone. Explicit System Default rules exclude programs. Children inherit the launch choice unless a new explicit rule overrides it.

The menu bar menu shows favorite time zones with their local times and lets you switch the default directly. Manage favorites in Settings. Program Overrides lists enabled rules that differ from the default, plus Ask Every Launch rules. Running applications appear first; command-line rules use the Terminal icon without a type or running-state label. Click a program to edit its rule. These are configured rules, not a report of the time zone already loaded by a running process; changes apply to subsequent launches.

When the Dock icon is shown, its flip-clock artwork displays the current hour and minute in its selected time zone, following the 12/24-hour setting. By default it follows the app's default time zone (or the system zone for System Default). It refreshes as the minute changes, including in Icon Only mode. The packaged Finder icon remains static.
**Settings → Appearance → Dock Time Zone** can independently follow the default, use the system time zone, or select a custom zone. Changes apply immediately after saving and persist across restarts; menu bar and program time zones remain controlled by their own settings.

**Settings → Show Time Zone Near Active Window** enables a mouse-through city/offset badge outside the frontmost app's focused window. It requires Accessibility access and an ES process session with confirmed hooks, matching executable and launch identity. It never substitutes a newly edited rule for a running process's launch time zone. The badge tries above, right, below, then left of the window; it stays hidden when there is no outside space, in full screen, or when the confirmed zone matches the system. **Preview Badge** shows a labeled five-second preview on Yoyo's own window without Accessibility access. The first version samples window position at 5Hz and refreshes the process session every two seconds.

Behavior logging is optional per rule and writes metadata to `build/state/behavior.jsonl`. There is no log viewer in the app. File contents, full arguments, and environment variables are not logged.

Window badge placement uses the complete on-screen window order, including windows without timezone rules and floating panels. All badges stay outside the owner window, including in Debug mode, avoiding content and titlebar controls. Screen geometry chooses a stable edge, preferring above the top-right corner. Occlusion or lack of outside space hides the badge instead of moving it to another edge or inside; moving the owner moves its anchor by the same amount.
Dock's screen-sized desktop surface is excluded from opaque coverage; its actual Dock bar and other applications' full-screen windows still block badge placement.
Actual window position or size changes hide only that window's badge; it resumes after the bounds remain stable for 300 ms. Lightweight WindowServer geometry sampling runs at 30 Hz for tracked windows. Scrolling, selection and scrollbar dragging with unchanged window bounds do not hide badges; no global mouse monitor is used.

Yoyo also provides a local process-timezone API at `127.0.0.1:47643` while the app is running. Surge rule scripts report socket metadata and a timezone argument such as `Los_Angeles`; Yoyo retrieves the owning PID's launch-session timezone and returns a match boolean. Surge selects the policy independently. Rules with behavior logging enabled also record correlated SCRIPT evaluations in `build/state/network-audit.jsonl`. See [Surge integration](docs/SurgePrototype.md) for configuration and attribution limits.

**Recently Opened Apps** uses macOS application lifecycle notifications, independently of ES. It includes regular and menu bar applications, excluding CLI executions, nested helpers and background services. App focus changes and child commands do not update launch times or reorder the list. Use **Add Rule…** to configure an app directly from history. The five newest are shown by default, with up to 100 saved by Bundle ID. On startup, running apps are seeded using their actual launch dates. Closing the window keeps monitoring active; explicitly quitting the menu app stops observation until it is reopened. Apps that both start and exit while the menu app is quit cannot be reconstructed. Behavior and execution diagnostics remain file-only.

## Build

Requires macOS, full Xcode with SwiftUI compiler plugins, and native Apple Silicon for the validated injection path. Build tasks use mise and Hola (`mise install`).

```sh
mise run test
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' mise run build-app
open build/Yoyo.app
```

Without `SIGN_IDENTITY`, the build is ad-hoc and cannot register an ES client. `ES_PROVISIONING_PROFILE` overrides the profile path. The current local development helper uses the existing Floria ES profile; see [Running and signing](docs/Running.md).

Stop the background service in Settings before replacing the signed bundle. Wait for the build to finish before reopening it. `make build`, `build-lab.sh`, and `scripts/build.sh` forward to `mise run build-app`. Run `mise run package-dmg` for a Release build in `build/Yoyo.dmg`; set `OUTPUT_DMG` to choose another path. Existing images are not overwritten. Tests run separately with `mise run test`. `mise run release` builds with Developer ID and Hardened Runtime, notarizes the DMG, staples the ticket and verifies Gatekeeper acceptance. Release builds use the logged-in user’s `~/Library/Application Support/Yoyo` directory instead of the build machine’s paths. See [CI release setup](docs/Running.md#github-releases).

Local builds default to `BUILD_CONFIGURATION=Debug`. In Settings → Appearance, **Always Show Badge (Debug)** keeps clearly labeled badges on visible normal application windows with a validated non-system launch time zone, including unfocused windows and sessions whose hooks are not confirmed. System-default and unknown sessions have no badge. Badges are removed for closed/minimized, fully covered and other-desktop windows. Placement avoids higher windows and falls back inside an uncovered part of the owning window when no outside space is available. Normal mode still requires Accessibility access and follows only the focused window. Set `BUILD_CONFIGURATION=Release` to omit the switch and ignore its saved preference.

## Project layout

```text
Sources/
  App/             SwiftUI dashboard, rule editor, settings, launch prompt
  Daemon/          Endpoint Security event handling and startup injection
  Injection/       In-process time zone and localtime file hooks
  Shared/          Policy model, rule matching, authenticated control channel
Resources/         Bundle metadata and daemon entitlements
Tests/
  Unit/            Policy matching, defaults and inheritance
  Integration/     Real process-chain acceptance drivers
  Fixtures/        CLI probes and test executables
  Legacy/          Original feasibility controls
scripts/           Bundle build, signing and acceptance commands
docs/              Running instructions and archived research
build/             Generated app, test binaries, configuration and logs
```

The UI stores validated policy and sends launch answers. The daemon owns process sessions, rule decisions, deadlines and log files. Hooks enforce the selected time zone in the target process. The app never changes the host's system time zone.

## Verification

The current ES launch path writes `TZ` directly and requests dynamic library injection through `DYLD_INSERT_LIBRARIES`. It rewrites the target startup environment through `task_for_pid`, so protected targets require SIP debugging restrictions to be disabled. Actual library loading is separately confirmed by the hooks; preparing the environment alone is not proof of injection. If the target refuses to load the library, `TZ` can still affect APIs that honor it, but timezone locking, `/etc/localtime` virtualization and the confirmed-hook window badge require the hooks. Relaunch existing targets to use the newly enabled injection path. `scripts/verify-system-cli.sh` checks the configured Tokyo `/bin/date` rule.

`make verify-late-rule` tests adding an app rule after its parent process is already running, then repeats both unruled-at-launch and ruled-at-launch cases across UI restarts. The existing unruled parent and its direct children outside the app bundle keep their original timezone; a newly launched helper inside the bundle matches the new rule, and its descendants inherit that choice. UI restarts must keep the daemon PID unchanged. Child launches deliberately supply a conflicting `TZ` so normal environment inheritance cannot hide a lost daemon session. The test requires this build of Yoyo open, its signed ES service running, and System Default as the global default. It adds only a temporary fixture rule and removes that rule on completion, retaining other policy settings.

`make verify-daemon-restart` requires sudo and tests both launch histories across actual service restarts using `launchctl kickstart -k`. It first stops the registered service normally, rebuilds the signed app, and starts it again. Only the launchctl operations run as root; the fixtures, policy writes and signed process diagnostics run as the original user. Service restarts must change the daemon PID while preserving the parent's session identity, launch-time zone and confirmation state. Output is saved to `build/evidence/daemon-restart.log`. `make test` also checks disk session recovery, including rejection of stale process identities and preservation of a launch choice and original TZ baseline after its rule changes.

Service restart guarantees apply after the service reports `listening` again. Launches during the stopped interval cannot be authorized or rewritten by ES.

```sh
make test
zsh scripts/verify-lab.sh
zsh scripts/verify-live.sh
zsh scripts/verify-rules.sh
```

Live acceptance requires the signed ES service, its permissions, and the existing Tokyo rules for the test fixtures and `/bin/date`. The rules acceptance driver temporarily changes the policy and restores it on completion; it also briefly exercises the global default.

To test a real Terminal process chain, configure a fixed time zone for Terminal, build the signed app, enable ES, then launch an independent Terminal instance:

```sh
open -n -a /System/Applications/Utilities/Terminal.app "$PWD/scripts/terminal-chain-test.command"
```

The test checks confirmed injection and a shared launch session through 1, 3 and 8 nested bash processes, including 8 layers with an empty environment and a conflicting `TZ`. It runs the original `/bin/date`, temporarily disables only exact date rules to isolate inheritance, then restores them to check explicit child precedence. Cleanup restores the tagged rules without replacing unrelated settings. Avoid editing date rules during the test. Reports and per-process metadata are saved under `build/terminal-chain.*`; `build/terminal-chain-last-run` identifies the latest run. The signed app also provides a read-only `--inspect-process PID` diagnostic.

Startup confirmation uses a random receipt bound to the socket peer's kernel audit generation. Retries reuse that receipt and do not duplicate confirmation logs. The constructor makes up to five attempts within a 500ms total budget, normally returning as soon as the daemon acknowledges. Process diagnostics distinguish `confirmed`, `unconfirmed` and `not_requested`; an exhausted budget does not mean injection failed. A request already received by the daemon can still confirm later. Ordinary timezone-call logs are best effort and do not wait for replies. The verification suite covers delayed handling, lost and invalid replies, fragmentation, signal interruption, unavailable services and bounded timeouts.

## Scope

Validated on this SIP-disabled Apple Silicon host: original system `/bin/date`, empty-environment CLI launches, 80 concurrent startup checks, application subdirectories, child overrides, global defaults and system exclusions. This remains an experimental app: arbitrary protected processes, Rosetta and shared XPC chains are not universally guaranteed. Launcher mode without ES is deferred. Production installation/permission hardening and lossless auditing are unfinished. See [Running](docs/Running.md) and [archived feasibility evidence](docs/research/feasibility.md).
