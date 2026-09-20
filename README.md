# Minions

A macOS menu bar app that answers "what is running on my machine right now":
which ports are open and who owns them (process, project, or Docker container),
what your AI coding agents are spending, and which sessions are live.

Two surfaces:

- **Popover** (click the menu bar icon): system strip, ports, running containers,
  today's AI spend per agent, active sessions. Hover a row for actions.
- **Dashboard** window: sortable tables, container log tail, 30-day spend chart,
  usage by model and project, session list.

Minions has no required dependency on any single agent or tool. Every source
below is detected independently and simply doesn't show up if it's absent —
install none of them and Minions still shows you ports and Docker; install
all of them and it shows spend across all of them side by side.

## Install

Download the latest `Minions.dmg` from [Releases](../../releases), open it,
and drag Minions to Applications.

**Gatekeeper note:** this build is ad-hoc signed, not signed with a paid Apple
Developer ID, so first launch will be blocked by Gatekeeper. Right-click the
app in Applications and choose **Open**, then confirm in the dialog — you only
need to do this once. (Alternatively: `xattr -dr com.apple.quarantine
/Applications/Minions.app`.)

## Build from source

Requires Xcode 16 / macOS 14.

```bash
git clone https://github.com/<you>/minions.git
cd minions
make run          # builds build/Minions.app and opens it
make install      # copies it to /Applications
make dmg          # builds build/Minions.dmg for distribution
make test         # parser tests against saved lsof / docker / transcript fixtures
```

Headless report for scripting or sanity checks, without opening the app:

```bash
.build/release/Minions --report 30
```

## What it reads

| Panel | Source | Requires |
|---|---|---|
| Ports | `lsof -iTCP -sTCP:LISTEN` + `ps` | nothing — built into macOS |
| Docker | `docker ps` / `docker stats` JSON | the `docker` CLI on `PATH` (Docker Desktop, Colima, OrbStack); shown as "not running" otherwise |
| Claude Code usage | `~/.claude/projects/*/*.jsonl` | Claude Code, if installed |
| Codex usage | `~/.codex/sessions/**/rollout-*.jsonl` | Codex, if installed |
| Hermes usage | `~/.hermes/state.db` and every `profiles/*/state.db` | Hermes, if installed |
| Pi usage | `~/.pi/agent/sessions/**/*.jsonl` | Pi, if installed — this is also where direct DeepSeek (or any other provider Pi supports) usage shows up |
| Live marker | `lsof -sTCP:ESTABLISHED` | nothing |
| Local models | Ollama `:11434/api/ps`, LM Studio `:1234/v1/models` | either, if running |
| Pricing | bundled `models.dev` snapshot, refreshable from Settings | nothing |

Each usage source is an independent reader in [`Sources/MinionsCore/TokenUsage`](Sources/MinionsCore/TokenUsage);
adding another agent means adding one more reader, not touching the others.
Subscription lanes (Codex, ollama-cloud) bill $0 but the "notional" column
shows what the tokens would have cost at list rates.

### It's per-agent, not per-API-call

Minions has no visibility into raw API traffic — it never intercepts network
calls, and TLS means it couldn't read token counts off the wire even if it
tried. What it reads instead is the *local transcript each agent already
writes to disk*. So the rule is: **if a tool logs what it did to a file on
this machine, Minions can read it; if a piece of code calls a provider's API
directly with no such log (a raw `curl`, a one-off Python script against the
OpenAI or DeepSeek SDK), Minions has no way to know what that cost.** The one
exception is the "live" dot: `lsof` can see that *some* local process has an
open connection to `api.deepseek.com` right now, which is enough to mark an
agent as active even though it can't say how many tokens that connection is
using.

Concretely, this is why **DeepSeek** already works two ways without any
DeepSeek-specific code: used through **Hermes** it shows up under the Hermes
agent (Hermes logs `billing_provider: deepseek` per session, and the pricing
catalog already has a `deepseek` bucket); used directly through **Pi**
(`pi --provider deepseek`) it shows up under Pi, whose transcripts already
log `provider`/`model`/`usage` per message with no coupling to Hermes at all.
Neither needed a new reader — DeepSeek was already just a `provider` value
inside an existing agent's log. A raw script hitting DeepSeek's API with no
agent in front of it stays invisible until it's run through one of the agents
above (or a new reader for whatever *does* log it).

### Pricing is self-contained

Minions ships its own snapshot of the [models.dev](https://models.dev) price
catalog inside the app bundle, so cost numbers work on a machine with none of
the above tools installed. Load order, most authoritative first:

1. Minions' own cache in `~/Library/Application Support/Minions/models_dev.json`,
   written when you click **Refresh from models.dev** in Settings.
2. The snapshot bundled inside the app.
3. As a last, purely opportunistic fallback: a cache another local tool has
   already downloaded (e.g. Hermes keeps one at `~/.hermes/models_dev_cache.json`).
   Minions reads this if it's there and nothing else is, but never requires it.

A model with no published price shows as `?`, never as a silent `$0`.

Nothing needs sudo. No agent's own files are ever written to — only read.
Minions' own state (usage cursors, priced records, its pricing cache) lives
entirely under `~/Library/Application Support/Minions/`.

## Settings

Menu bar text (spend, port count, both), poll intervals, daily budget (icon
turns to a warning when exceeded), and a watched-port list that warns when a
browser or system process grabs a port you use for dev.

## Layout

```
Sources/MinionsCore/        pure Swift, no UI, unit-tested
  Collectors/                Ports, Docker, Project/Git, SystemStats
  TokenUsage/                Pricing, ClaudeCode/Codex/Hermes/Pi readers, LocalServers, UsageStore
  Resources/                 bundled models.dev pricing snapshot
Sources/MinionsApp/          SwiftUI: MenuBarExtra popover, dashboard window, settings
  Resources/                 menu bar template icon (see Resources/brand/)
Resources/brand/             source logos; regenerate app + menu bar icons from these
Tests/MinionsCoreTests/      fixtures captured from a real machine
scripts/bundle.sh            assembles build/Minions.app (LSUIElement, ad-hoc signed)
scripts/dmg.sh               packages build/Minions.app into build/Minions.dmg
scripts/generate_icons.py    regenerates AppIcon.icns + MenuBarIcon*.png from Resources/brand/
.github/workflows/ci.yml     build + test on every push/PR
.github/workflows/release.yml builds and attaches a DMG when you push a `vX.Y.Z` tag
```

## Releasing

Tagging a version pushes a DMG to GitHub Releases automatically:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Changelog

### v0.1.1

Fixed a crash-on-launch that affected every CI-built release, including the
original v0.1.0 download. SwiftPM's synthesized `Bundle.module` resource
accessor looks for a bundled resource next to `Bundle.main`'s own root —
correct for a bare CLI binary, wrong for a macOS `.app`, where resources live
under `Contents/Resources/` — and its only fallback is an absolute path baked
in at compile time on the machine that built the binary, which cannot exist
on any other machine. Both the bundled pricing snapshot and the menu bar
icon used it, so the app crashed the instant its first view rendered on any
machine other than the one that built it.

Caught by actually installing the released DMG to `/Applications` rather than
trusting a green CI run: 5/5 launches crashed before the fix, 5/5 succeeded
after, re-verified against the real CI-built, freshly downloaded artifact.
Resource loading now goes through [`AppResources`](Sources/MinionsCore/BundleResources.swift),
which resolves paths from the running app's own bundle instead, and a
regression test fails the build if `Bundle.module` reappears anywhere outside it.

### v0.1.0

Initial release: ports, Docker, and AI agent token usage (Claude Code, Codex,
Hermes, Pi) in a macOS menu bar app, with self-contained pricing and no
required dependency on any single agent.

## Contributing an agent reader

To support another coding agent or local model runner, add a reader under
`Sources/MinionsCore/TokenUsage/` that produces `UsageRecord` values (see
`ClaudeCodeReader.swift` for the smallest example), wire it into `UsageStore.refresh()`,
and add a fixture-based test in `Tests/MinionsCoreTests`. No other reader needs
to change.
