# Native terminal port

Swiftty is the native macOS replacement for the terminal surface currently in `terax-ai`.

## Current slice

- SwiftUI window and native AppKit terminal view
- SwiftTerm VT100/xterm engine with CoreText and Metal rendering
- Real Unix PTY-backed login shell
- Persistent terminal tabs with Cmd-T, Cmd-W, and native glass controls
- OSC 7 working-directory updates and terminal title updates
- Process exit reporting
- Native text selection, clipboard, mouse reporting, hyperlinks, search, and ANSI color handling through SwiftTerm

## Port map

| Terax subsystem | Native replacement | State |
| --- | --- | --- |
| `TerminalStack` and tab visibility | `TerminalWorkspace` and `TerminalStore` | Started |
| `xterm.js` renderer | SwiftTerm AppKit renderer with Metal | Started |
| `portable-pty` session | `LocalProcessTerminalView` | Started |
| OSC 7 cwd tracking | `LocalProcessTerminalViewDelegate` | Started |
| `PaneTreeView` splits | `HSplitView` / `VSplitView` session tree | Next |
| shell integration scripts and OSC 133 | native shell bootstrapper | Next |
| command blocks and history | Swift terminal buffer model | Next |
| renderer pool and dormant ring | bounded native session registry | Next |
| agent signals and background jobs | native process services | Later |

## Build and run

```bash
swift build --disable-sandbox
./scripts/build-app.sh
open build/Swiftty.app
```

The app is deliberately unsandboxed while it owns local shells. A sandboxed target would need explicit security-scoped access and would not behave like the current terminal.
