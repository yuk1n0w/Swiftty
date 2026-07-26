# Swiftty

[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](Info.plist)
[![Platform](https://img.shields.io/badge/platform-macOS%2026.0%2B-black.svg)](Package.swift)
[![Swift](https://img.shields.io/badge/swift-6.0-orange.svg)](Package.swift)

Swiftty is a native macOS terminal built with SwiftUI, AppKit, and Metal. Instead of an endless scrollback, it structures shell execution into Warp-style command blocks — each command and its output a discrete, navigable unit — with GPU rendering and a text-editor command line.

> [!NOTE]
> Swiftty requires macOS 26.0 or later and the Swift 6.0 toolchain.

---

## Features

- **Warp-style command blocks** — OSC 133 semantic prompt markers group each command with its output, execution time, working directory, and exit status. Failures are tinted, long output folds past 24 lines, and any block can be copied or re-run.
- **A real command editor** — the prompt is a text editor, not a raw terminal line: click-to-place cursor, multi-line via ⇧Return, history browsing, autosuggestions from your shell history, Tab completion against `PATH` and the filesystem, and syntax highlighting. Your shell's own line editor stays untouched, so aliases, functions, and prompt themes keep working.
- **Metal GPU acceleration** — SwiftTerm renders through Metal in `.perRowPersistent` mode (only changed rows are rebuilt), with an on-demand draw loop, so an idle prompt uses no CPU.
- **Blocks over SSH and in containers** — an interactive `ssh` is detected automatically and the block hooks are injected into the remote session; no daemon or install on the far end. Completion and the file explorer follow you onto the remote host.
- **Tab groups** — one window holds several named groups of tabs, kept apart (a project's tabs from a server's, say), and switching groups never kills a shell.
- **AI integrations** — OpenAI, Anthropic, OpenRouter, Ollama, LM Studio, and any OpenAI-compatible endpoint, with keys stored in the macOS Keychain.
- **Native look** — window translucency and background blur over the desktop, adjustable opacity, and a compact block mode.

---

## Prerequisites

- **Operating system**: macOS 26.0 or higher
- **Toolchain**: Swift 6.0+ (Xcode 16+ or the command line tools)

---

## Quick Start

```bash
git clone https://github.com/yuk1n0w/Swiftty.git
cd Swiftty
./scripts/build-app.sh
open build/Swiftty.app
```

`build-app.sh` compiles a release binary, assembles `build/Swiftty.app`, compiles SwiftTerm's Metal shaders into `Contents/Resources/default.metallib` so the app is self-contained, and ad-hoc signs the bundle so it launches on any Mac.

> [!IMPORTANT]
> Swiftty runs unsandboxed by design: it owns local login shells and Unix PTYs, which a sandbox would require security-scoped access to reach.

---

## Key Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘T` | New tab |
| `⌘W` | Close tab |
| `⌘1`–`⌘9` | Select tab by number |
| `⌃Tab` / `⌃⇧Tab` | Cycle tabs |
| `⇧⌘T` | New tab group |
| `⇧⌘[` / `⇧⌘]` | Cycle tab groups |
| `⌘+` / `⌘-` / `⌘0` | Font size up / down / reset |
| `⌘F` | Find in blocks |
| `⌘K` | Clear block history |
| `⌘S` | Toggle file explorer |
| `⌘I` | Toggle AI agent |
| `⇧⌘E` | Enable blocks in the current session (manual warpify) |

Double-click a tab to rename it.

---

## Architecture & Shell Integration

Swiftty delimits commands with OSC 133 semantic prompt markers:

```
133;A (prompt drawn) → 133;E (command line) → 133;C (output begins) → 133;D (finished, exit code)
```

- **Local bootstrap** — `ShellIntegration` layers hooks over your own config for `zsh` (via `ZDOTDIR`) and `bash` (via `--rcfile`) without replacing your prompt, completion, or theme. Other shells run uninstrumented (the terminal works, there are simply no blocks).
- **Remote adoption** — when an interactive `ssh` is identified, Swiftty waits for the remote prompt to settle and types the hook definitions into the session. It checks for a prompt rather than a password/passphrase question before doing so.
- **Alternate screen** — full-screen programs (`vim`, `htop`, `tmux`) take over the whole view and blocks resume when they exit.

For the full design, see [`PORTING.md`](PORTING.md).

---

## Configuration

Open Settings (`⌘,`):

- **General** — window opacity, background blur, compact blocks, and the remote-session snippet for warpifying hosts you SSH into often.
- **Terminal** — font size, blinking vs. steady cursor, and shell path.
- **Models / Agents** — pick a provider, set the base URL, store the API key in the Keychain, and choose the agent persona.
