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

**Settings → Show Time Zone Near Active Window** enables a mouse-through city/offset badge outside the frontmost app's focused window. It requires Accessibility access and an ES process session with confirmed hooks, matching executable and launch identity. It never substitutes a newly edited rule for a running process's launch time zone. The badge tries above, right, below, then left of the window; it stays hidden when there is no outside space, in full screen, or when the confirmed zone matches the system. **Preview Badge** shows a labeled five-second preview on Yoyo's own window without Accessibility access. The first version samples window position at 5Hz and refreshes the process session every two seconds.

Behavior logging is optional per rule and writes metadata to `build/state/behavior.jsonl`. There is no log viewer in the app. File contents, full arguments, and environment variables are not logged.

**Recently Opened Apps** uses macOS application lifecycle notifications, independently of ES. It includes regular and menu bar applications, excluding CLI executions, nested helpers and background services. App focus changes and child commands do not update launch times or reorder the list. Use **Add Rule…** to configure an app directly from history. The five newest are shown by default, with up to 100 saved by Bundle ID. On startup, running apps are seeded using their actual launch dates. Closing the window keeps monitoring active; explicitly quitting the menu app stops observation until it is reopened. Apps that both start and exit while the menu app is quit cannot be reconstructed. Behavior and execution diagnostics remain file-only.

## Build

Requires macOS, full Xcode with SwiftUI compiler plugins, and native Apple Silicon for the validated injection path. No third-party build dependencies are required.

```sh
make test
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' make build
open build/Yoyo.app
```

Without `SIGN_IDENTITY`, the build is ad-hoc and cannot register an ES client. `ES_PROVISIONING_PROFILE` overrides the profile path. The current local development helper uses the existing Floria ES profile; see [Running and signing](docs/Running.md).

Stop the background service in Settings before replacing the signed bundle. Wait for the build to finish before reopening it. `build-lab.sh` remains a compatibility entry point for `scripts/build.sh`.

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

The current ES launch path applies the selected zone directly through `TZ`, without requesting dynamic library injection. It still rewrites the target startup environment through `task_for_pid`, so protected targets require SIP debugging restrictions to be disabled. This sets defaults for APIs that honor `TZ`; it does not lock timezone changes or virtualize `/etc/localtime`. Hook confirmation and the confirmed-hook window badge are unavailable for these launches. The hook-based live/rules acceptance scripts below describe the earlier injection path and are not acceptance tests for this TZ-only path; `scripts/verify-system-cli.sh` checks the configured Tokyo `/bin/date` rule.

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
