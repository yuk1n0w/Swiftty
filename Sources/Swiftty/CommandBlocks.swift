import AppKit
import Foundation
import SwiftTerm
import SwiftUI

/// One command the user ran, with its output frozen as styled text.
///
/// Output is captured the moment the command finishes and the terminal buffer
/// is then cleared, so each block owns its text outright rather than pointing
/// into a buffer that later commands will scroll away.
struct CommandBlock: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case finished(exitCode: Int32)
        /// The shell exited while this command was still running.
        case abandoned

        var exitCode: Int32? {
            if case .finished(let code) = self { return code }
            return nil
        }

        var isRunning: Bool { self == .running }

        var failed: Bool {
            switch self {
            case .finished(let code): return code != 0
            case .abandoned: return true
            case .running: return false
            }
        }
    }

    let id = UUID()
    var command: String
    var directory: String
    /// Branch checked out when the command ran, shown in the meta line.
    var gitBranch: String?
    var startedAt: Date
    var finishedAt: Date?
    var state: State = .running

    /// The full captured output.
    var output = AttributedString()
    /// The first `outputPreviewLimit` lines, precomputed so collapsed cards do
    /// no slicing work while rendering.
    var outputPreview = AttributedString()
    var outputLineCount = 0

    /// Long output is collapsed until the user asks for the rest.
    static let outputPreviewLimit = 24

    var isTruncated: Bool { outputLineCount > Self.outputPreviewLimit }
    var hasOutput: Bool { outputLineCount > 0 }

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// Duration with just enough precision to be useful — "0.083s", "0.21s",
    /// "1m 4s" — matching how the shell itself would report it.
    var durationLabel: String? {
        guard let duration else { return nil }
        if duration >= 60 {
            return "\(Int(duration) / 60)m \(Int(duration) % 60)s"
        }
        let digits = duration < 1 ? 3 : 2
        var text = String(format: "%.\(digits)f", duration)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "s"
    }

    var directoryLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    /// The muted line above the command: where it ran, on what branch, and how
    /// long it took.
    var metaLabel: String {
        var parts = [directoryLabel]
        if let gitBranch, !gitBranch.isEmpty { parts.append("git:(\(gitBranch))") }
        if let durationLabel { parts.append("(\(durationLabel))") }
        return parts.joined(separator: " ")
    }
}

/// A command the user has run before, for the history palette and for
/// autosuggestions.
struct HistoryEntry: Identifiable, Equatable {
    var id: String { command }
    let command: String
    /// When it was last run. Absent for shells that keep no timestamps.
    var date: Date?

    /// "just now", "37 min ago", "2 days ago".
    var relativeLabel: String? {
        guard let date else { return nil }
        if Date().timeIntervalSince(date) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Turns one terminal's OSC 133 markers into `CommandBlock`s.
///
/// Everything runs on the main actor: SwiftTerm feeds PTY data on
/// `DispatchQueue.main`, so the OSC handler is already main-isolated and can
/// read the cursor synchronously. That matters — the row the cursor sits on at
/// the instant a marker arrives *is* the block boundary. Sample it a run loop
/// turn later and the next prompt has already been drawn over it.
@MainActor
final class BlockTracker: ObservableObject {
    /// Finished blocks, oldest first. The command currently running is not in
    /// here — it is live in the terminal, and `runningBlock` describes it.
    @Published private(set) var blocks: [CommandBlock] = []
    /// The command executing right now, if any.
    ///
    /// `runningVisible` trails it: a command has to run for a moment before the
    /// terminal expands to show it live. Most commands finish in well under
    /// that, so they append their block without the live view ever flashing —
    /// which is what stopped every command flickering the layout on submit.
    @Published private(set) var runningBlock: CommandBlock? {
        didSet {
            runningVisibleTask?.cancel()
            if runningBlock == nil {
                runningVisible = false
                endInteractiveWatch()
            } else if oldValue == nil {
                beginInteractiveWatch()
                runningVisibleTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(160))
                    guard !Task.isCancelled, let self, self.runningBlock != nil else { return }
                    self.runningVisible = true
                    // The terminal only takes the keyboard once it is actually
                    // on screen, so the composer keeps focus for the quick
                    // commands that never reach this point.
                    self.focusTerminal()
                }
            }
            updateInteractive()
        }
    }
    /// True once a running command has lasted long enough to be worth showing
    /// live, rather than just letting it finish into a block.
    @Published private(set) var runningVisible = false
    private var runningVisibleTask: Task<Void, Never>?
    @Published var selectedBlockID: CommandBlock.ID?
    /// True once the shell has sent a marker, i.e. the integration is live.
    @Published private(set) var isIntegrationActive = false
    /// True while a full-screen program (vim, htop, less) owns the screen.
    @Published private(set) var isAlternateScreen = false
    /// True while the running program is interactive — it put the tty into raw
    /// mode to read keystrokes itself (every TUI: vim, htop, Claude Code…), or
    /// took the alternate screen. A batch command like `brew install` leaves the
    /// tty canonical. The composer stays at the bottom for batch commands and
    /// hides only for interactive ones.
    ///
    /// Raw mode is the reliable tell: the terminal-mode flags are not, because
    /// zsh turns bracketed paste on at its own prompt. And it is checked only
    /// while a command runs — the shell's own line editor is raw too, but that
    /// is not a running command.
    @Published private(set) var isInteractive = false
    /// True while an interactive TUI should own the whole view — it is in raw
    /// mode or the alternate screen now, or was until a moment ago. The trailing
    /// grace is what lets a batch command's brief prompt (Homebrew's proceed
    /// `[y/n]`, which flips the tty raw to read one key) take the keyboard for
    /// that question without the composer staying gone once the command drops
    /// back to streaming output — while still not flickering for a TUI that dips
    /// to canonical for an instant.
    @Published private(set) var interactiveTakeover = false
    /// True once a running command has *settled* into plain canonical output for
    /// long enough to be judged a batch job — an install, a build — rather than
    /// a TUI still starting up or mid-prompt. Claude Code, for one, does not
    /// switch the tty to raw until roughly a second after launch, so committing
    /// to the composer-at-bottom layout the instant a command appears would
    /// wrongly show it for a TUI. Only when this is set does the composer sit at
    /// the bottom below the command's output.
    @Published private(set) var batchConfirmed = false
    private var interactiveWatch: Task<Void, Never>?
    /// 200ms ticks the current command has been running, and consecutive ticks
    /// it has been canonical (non-raw). `sawInteractive` gates the takeover's
    /// trailing grace so a command that has never been raw drops to batch at once.
    private var runTicks = 0
    private var canonicalStreak = 0
    private var sawInteractive = false
    /// Canonical ticks before the takeover yields back to the composer (~1s), and
    /// running ticks before a still-canonical command is called a batch job
    /// (~1.6s, comfortably past a TUI's raw-mode start-up window).
    private let canonicalDropTicks = 5
    private let batchStartupTicks = 8
    /// Set while a subshell — an SSH session, a container — is producing
    /// blocks of its own, and labelled with the shell that answered.
    @Published private(set) var subshell: String?
    /// True between submitting a command and the shell reporting it started.
    ///
    /// The editor has to come off screen for this window, short as it is. It
    /// reclaims focus from the terminal whenever it updates, so leaving it up
    /// means it snatches the keyboard back before the command starts — and a
    /// full-screen program then launches with the editor focused, where arrow
    /// keys just beep.
    @Published private(set) var isSubmitting = false
    /// Directory the next prompt will run in.
    @Published private(set) var currentDirectory =
        FileManager.default.homeDirectoryForCurrentUser.path
    /// Branch checked out in `currentDirectory`, if any.
    @Published private(set) var gitBranch: String?
    /// Called with each finished block, so the store can decide whether it is
    /// worth a notification. The tracker itself has no idea whether its tab is
    /// on screen — that is the store's call.
    var onCommandFinished: ((CommandBlock) -> Void)?
    /// Height the live terminal needs while sitting at a prompt.
    @Published private(set) var idleTerminalHeight: CGFloat = 44

    /// Directory listings fetched from the far end, keyed by absolute path.
    ///
    /// Completion and the file explorer read local disk, which is the wrong
    /// machine entirely once a session is remote. The shell on the other end
    /// answers these instead.
    @Published private(set) var remoteListings: [String: [String]] = [:]
    private var pendingListings: Set<String> = []
    /// The local working directory captured on entering a subshell, restored on
    /// leaving it.
    private var localDirectory: String?
    private var subshellWatch: Task<Void, Never>?
    private var gitBranchCache: [String: String?] = [:]
    private weak var terminalView: SwifttyTerminalView?
    private var pendingCommand: String?
    /// Absolute row the current prompt starts on.
    private var promptRow = 0
    /// Absolute row the running command's output starts on.
    private var outputStartRow: Int?
    /// Unbalanced command starts. `ssh host` opens one that stays open for the
    /// whole remote session; remote commands balance their own. Back to zero
    /// means the local prompt.
    private var commandDepth = 0

    /// Cap on both retained blocks and captured lines per block, so a runaway
    /// command cannot grow the model without bound.
    private let maximumBlocks = 500
    private let maximumCapturedLines = 5000

    // MARK: - Wiring

    func attach(to view: SwifttyTerminalView) {
        terminalView = view
        view.blockTracker = self

        view.terminal?.registerOscHandler(code: 133) { [weak self] payload in
            // Already on the main queue; see the type comment for why this must
            // stay synchronous.
            MainActor.assumeIsolated {
                self?.handleMarker(String(bytes: payload, encoding: .utf8) ?? "")
            }
        }
    }

    /// Called by the terminal view on every repaint.
    func terminalStateChanged() {
        guard let view = terminalView, let terminal = view.terminal else { return }

        let alternate = terminal.isCurrentBufferAlternate
        if alternate != isAlternateScreen {
            isAlternateScreen = alternate
            // Entering the alternate screen means a full-screen program is
            // taking over and needs every keystroke.
            if alternate { focusTerminal() }
        }

        updateInteractive()
        updateIdleHeight(view: view)
    }

    /// Refreshes `isInteractive` from the pty's line-discipline mode, and lets a
    /// TUI seize the takeover the instant it goes raw (rather than waiting for the
    /// next poll tick). Interactive only means anything while a command runs, so a
    /// quiet prompt — where the shell's own line editor is raw — reads as not
    /// interactive.
    func updateInteractive() {
        // What counts as "interactive" (terminal takes the keyboard, composer
        // steps aside) while a command runs:
        //   • locally, raw mode or the alternate screen — the reliable tell for a
        //     TUI (vim, htop, and programs like anipy-cli that read keys raw
        //     without switching to the alternate screen);
        //   • inside a swiftified subshell (SSH, a container) *any* running
        //     command, because the ssh/exec client holds the local tty raw for
        //     the whole session, so raw mode can no longer tell a remote batch
        //     command from a remote TUI. Handing the terminal the keyboard is the
        //     safe default there: an interactive remote program then gets its
        //     input (otherwise the composer swallows it), while a plain remote
        //     `ls` simply finishes with the terminal focused. The batch composer
        //     stays a local-only nicety.
        let interactive: Bool
        if runningBlock == nil {
            interactive = false
        } else if isAlternateScreen {
            interactive = true
        } else if subshell != nil {
            interactive = true
        } else {
            interactive = terminalIsRaw()
        }
        if interactive != isInteractive { isInteractive = interactive }
        if interactive {
            sawInteractive = true
            canonicalStreak = 0
            if !interactiveTakeover { interactiveTakeover = true }
            // A TUI outed itself: it is not sitting there as a batch job.
            if batchConfirmed { batchConfirmed = false }
        }
    }

    /// Resets interactivity state for a fresh command and starts polling the tty
    /// mode a few times a second while it runs.
    ///
    /// A repaint is not a dependable trigger for spotting raw mode. Claude Code
    /// flips the tty to raw about a second after launch and then rests on a
    /// static screen — no repaint follows to notice the change, so relying on
    /// `terminalStateChanged` alone leaves it stuck in the batch layout. And the
    /// poll is what times the *exits* from raw: a command has to be canonical for
    /// a sustained stretch before the composer returns, so Homebrew's momentary
    /// `[y/n]` does not leave the composer gone for the rest of the download. The
    /// tcgetattr is a handful of times a second and stops the moment the command
    /// ends.
    private func beginInteractiveWatch() {
        runTicks = 0
        canonicalStreak = 0
        sawInteractive = false
        interactiveTakeover = false
        batchConfirmed = false
        interactiveWatch?.cancel()
        interactiveWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runningBlock != nil else { return }
                self.interactiveTick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// One poll tick: sample the tty mode and recompute the takeover / batch
    /// classification with hysteresis on both edges.
    private func interactiveTick() {
        updateInteractive()
        runTicks += 1
        if isInteractive {
            canonicalStreak = 0
        } else {
            canonicalStreak += 1
        }

        // Hold the takeover through a brief return to canonical (a batch job's
        // prompt, a TUI shelling out) and only yield once canonical has held.
        let takeover = isInteractive
            || (sawInteractive && canonicalStreak < canonicalDropTicks)
        if takeover != interactiveTakeover { interactiveTakeover = takeover }

        // Not (any longer) a takeover, and it has been running plainly for a
        // beat: it is a batch job, so seat the composer at the bottom.
        let batch = !takeover && runTicks >= batchStartupTicks
        if batch != batchConfirmed { batchConfirmed = batch }
    }

    private func endInteractiveWatch() {
        interactiveWatch?.cancel()
        interactiveWatch = nil
        interactiveTakeover = false
        batchConfirmed = false
        isInteractive = false
    }

    /// Whether the tty is in raw mode — canonical input off. On a pty the master
    /// reflects the slave's mode, so tcgetattr on our end sees what the child
    /// program set.
    private func terminalIsRaw() -> Bool {
        guard let fd = terminalView?.process?.childfd, fd >= 0 else { return false }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { return false }
        return (settings.c_lflag & tcflag_t(ICANON)) == 0
    }

    /// Sizes the live terminal to the prompt it is actually showing, so an idle
    /// shell is a compact input line rather than a half-empty pane.
    ///
    /// Only done between commands. Resizing changes the row count, and while
    /// that is safe for block bookkeeping — a height-only resize never reflows
    /// lines, and trimming preserves scroll-invariant row indices — there is no
    /// reason to send a running program a stream of SIGWINCHs.
    private func updateIdleHeight(view: SwifttyTerminalView) {
        guard runningBlock == nil else { return }

        let used = max(1, (cursorRow() ?? promptRow) - promptRow + 1)
        let rows = min(max(used, Self.minimumIdleRows), Self.maximumIdleRows)
        let height = CGFloat(rows) * view.cellHeight
        if abs(height - idleTerminalHeight) > 0.5 { idleTerminalHeight = height }
    }

    private static let minimumIdleRows = 2
    private static let maximumIdleRows = 10

    // MARK: - Actions

    /// Sends `command` to the shell as if the user had typed it.
    ///
    /// The shell's line editor is still running and receives this the way it
    /// would a paste, so aliases, functions and multi-line constructs behave
    /// exactly as they would if the characters had been typed at the prompt.
    func submit(_ command: String) {
        guard let view = terminalView else { return }
        isSubmitting = true
        // A space, then Ctrl-U, to kill anything already sitting in the shell's
        // line buffer. Stray keystrokes should never reach it now that the editor
        // holds focus, but if any ever do they would silently prefix the command,
        // and that failure is invisible until the shell rejects it. The leading
        // space is what stops the alert sound on every send: Ctrl-U on an *empty*
        // line — the normal case, since the editor holds the command — is an
        // error readline answers with a bell, but with a space to discard there
        // is always something to kill, so it clears the line silently. The space
        // is killed along with any stray input, so the command still runs clean
        // and unprefixed (and is not treated as a HIST_IGNORE_SPACE line).
        view.send(txt: " \u{15}" + command + "\n")
        // Focus is not handed to the terminal here: the composer stays put and
        // keeps the keyboard, so a quick command never disturbs it. The
        // terminal takes over only once the command has run long enough to be
        // shown live (see runningBlock's didSet) or a full-screen program takes
        // the alternate screen.
    }

    /// Gives the keyboard to the terminal, for a command that is starting or a
    /// full-screen program taking the screen.
    ///
    /// Driven from the markers rather than from a SwiftUI view: the view that
    /// used to decide this does not observe the tracker, so it never re-rendered
    /// when a command started and the focus change simply did not happen.
    func focusTerminal() {
        guard let view = terminalView else { return }
        view.window?.makeFirstResponder(view)
    }

    func rerun(_ command: String) {
        guard !command.isEmpty else { return }
        submit(command)
    }

    /// Commands available to the up-arrow and to autosuggestions, most recent
    /// first: this session's blocks, then the shell's own history file so
    /// suggestions are useful from the very first prompt.
    var commandHistory: [HistoryEntry] {
        var seen = Set<String>()
        var result: [HistoryEntry] = []

        for block in blocks.reversed() where !block.command.isEmpty {
            if seen.insert(block.command).inserted {
                result.append(HistoryEntry(command: block.command, date: block.startedAt))
            }
        }
        for entry in Self.shellHistory where !entry.command.isEmpty {
            if seen.insert(entry.command).inserted { result.append(entry) }
        }
        return result
    }

    /// The best completion for what has been typed so far, or nil.
    func suggestion(for prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        guard let match = commandHistory.first(where: {
            $0.command.hasPrefix(prefix) && $0.command.count > prefix.count
        }) else { return nil }
        return String(match.command.dropFirst(prefix.count))
    }

    /// The shell's history file, read once per launch.
    ///
    /// zsh writes `: <timestamp>:<elapsed>;<command>` when extended history is
    /// on and a bare line when it is not, so both shapes are handled. The
    /// timestamp is what lets old commands carry a date in the history palette.
    private static let shellHistory: [HistoryEntry] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [".zsh_history", ".bash_history"].map(home.appendingPathComponent)

        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            // History files routinely contain bytes that are not valid UTF-8.
            let text = String(decoding: data, as: UTF8.self)
            let commands = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line -> HistoryEntry in
                    guard line.hasPrefix(":"), let marker = line.firstIndex(of: ";") else {
                        return HistoryEntry(command: String(line).trimmingCharacters(in: .whitespaces))
                    }
                    let command = String(line[line.index(after: marker)...])
                        .trimmingCharacters(in: .whitespaces)

                    // ": 1690000000:0;cmd" — the seconds sit between the colons.
                    let head = line[line.index(after: line.startIndex)..<marker]
                    let seconds = head
                        .split(separator: ":", maxSplits: 1)
                        .first
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .flatMap(TimeInterval.init)
                    return HistoryEntry(
                        command: command,
                        date: seconds.map { Date(timeIntervalSince1970: $0) }
                    )
                }
                .filter { !$0.command.isEmpty }
            guard !commands.isEmpty else { continue }
            return Array(commands.reversed().prefix(2000))
        }
        return []
    }()

    func select(_ id: CommandBlock.ID?) {
        selectedBlockID = id
    }

    /// Moves the selection one block earlier or later.
    func moveSelection(by offset: Int) {
        guard !blocks.isEmpty else { return }
        guard let current = selectedBlockID.flatMap({ id in
            blocks.firstIndex { $0.id == id }
        }) else {
            selectedBlockID = blocks[offset < 0 ? blocks.count - 1 : 0].id
            return
        }
        let next = min(max(current + offset, 0), blocks.count - 1)
        selectedBlockID = blocks[next].id
    }

    var selectedBlock: CommandBlock? {
        guard let selectedBlockID else { return nil }
        return blocks.first { $0.id == selectedBlockID }
    }

    func clearHistory() {
        blocks.removeAll()
        selectedBlockID = nil
    }

    /// Resets the terminal emulator to a clean slate — the cure for a screen left
    /// garbled by a crashed full-screen program (wrong colours, a hidden cursor,
    /// a stuck alternate buffer). It does not signal the shell, so a running
    /// program keeps running; it just repairs how the terminal draws.
    func resetTerminal() {
        if let view = terminalView {
            view.terminal?.resetToInitialState()
            view.setNeedsDisplay(view.bounds)
        }
        clearHistory()
    }

    /// The shell's working directory as an absolute path, for completing
    /// relative paths against.
    var workingDirectory: String { currentDirectory }

    /// What the tab shows: the running command while one is executing, the
    /// current folder otherwise — the same thing a normal terminal reports.
    /// A name the user pinned to this tab, if any. Once set it wins over the
    /// automatic label; clearing it hands the label back to the shell.
    @Published var customName: String?

    var tabLabel: String {
        if let customName, !customName.isEmpty { return customName }
        if let running = runningBlock,
           let first = running.command.split(separator: " ").first {
            return String(first)
        }
        let name = (currentDirectory as NSString).lastPathComponent
        if currentDirectory == FileManager.default.homeDirectoryForCurrentUser.path {
            return "~"
        }
        return name.isEmpty ? currentDirectory : name
    }

    /// True when the tab is showing a name the user set, not the shell's.
    var hasCustomName: Bool { !(customName ?? "").isEmpty }

    /// The working directory, shown on the prompt line above the editor. The
    /// shell draws its own prompt into the terminal, which is hidden while
    /// typing, so this stands in for it.
    var directoryLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = currentDirectory
        if path == home {
            path = "~"
        } else if path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Plain text of a block's output, for the clipboard.
    func plainOutput(for block: CommandBlock) -> String {
        String(block.output.characters)
    }

    // MARK: - Markers

    private func handleMarker(_ payload: String) {
        isIntegrationActive = true

        // Payload is everything after "133;" — "A", "D;1", "E;6c73".
        let separator = payload.firstIndex(of: ";")
        let kind = separator.map { String(payload[payload.startIndex..<$0]) } ?? payload
        let argument = separator.map { String(payload[payload.index(after: $0)...]) }

        switch kind {
        case "S":
            adoptSubshell(named: argument)
        case "L":
            receiveListing(argument)
        case "P":
            if let directory = argument.flatMap(Self.decodeHex),
               !directory.isEmpty,
               directory != currentDirectory {
                currentDirectory = directory
                refreshGitBranch(for: directory)
                // The cwd listing arrives on its own from precmd; no need to
                // ask for it and double up the query.
            }
        case "A":
            beginPrompt()
        case "E":
            pendingCommand = argument.flatMap(Self.decodeHex)
        case "C":
            beginOutput()
        case "D":
            endCommand(exitCode: argument.flatMap { Int32($0) } ?? 0)
        default:
            break
        }
    }

    /// Asks the far end what is in `path`, unless it is already known or in
    /// flight. Answers arrive as an `L` marker.
    func requestRemoteListing(_ path: String) {
        guard subshell != nil, let view = terminalView else { return }
        guard remoteListings[path] == nil, !pendingListings.contains(path) else { return }
        // Never interrupt a running command with a query.
        guard runningBlock == nil, !isSubmitting else { return }

        pendingListings.insert(path)
        let quoted = path.replacingOccurrences(of: "'", with: "'\\''")
        view.send(txt: " __swiftty_ls '\(quoted)'\n")

        // A query can be lost — sent before `__swiftty_ls` was defined on a
        // slow link, or dropped in a busy session. Without this the path would
        // sit in `pendingListings` forever and never be asked for again, which
        // is why completion would work once and then go dead. Time it out so a
        // later request retries.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if self.remoteListings[path] == nil {
                self.pendingListings.remove(path)
            }
        }
    }

    /// Entries the far end reported for `path`, if it has answered yet.
    func remoteEntries(for path: String) -> [String]? {
        remoteListings[path]
    }

    private func receiveListing(_ argument: String?) {
        guard let argument, let separator = argument.firstIndex(of: "|") else { return }
        let path = Self.decodeHex(String(argument[argument.startIndex..<separator]))
        let body = Self.decodeHex(String(argument[argument.index(after: separator)...]))
        guard let path, let body else { return }

        pendingListings.remove(path)
        remoteListings[path] = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Watches an SSH session for a prompt, then installs the hooks itself.
    ///
    /// The `133;S` handshake below is the reliable path, but it needs a line
    /// added to the shell config on every host you connect to. Most of the time
    /// nobody has done that, so this covers the common case without any remote
    /// setup: wait for the output to go quiet on something that looks like a
    /// shell prompt, then type the hooks in.
    ///
    /// It waits for quiet, and checks the line looks like a prompt rather than
    /// a question, specifically so it cannot type a page of shell functions
    /// into a password or passphrase prompt.
    private func watchForSubshell(command: String) {
        subshellWatch?.cancel()
        guard let host = Self.interactiveSSHHost(command) else { return }

        subshellWatch = Task { [weak self] in
            var previous: String?
            // Up to a minute, not twelve seconds: logging in to a remote host can
            // take a while — a slow link, a password or 2FA prompt typed by hand,
            // a long MOTD — and the old ceiling gave up before the remote prompt
            // ever appeared, so the session never got swiftified. The watcher is
            // cancelled the moment the command ends, so this only runs while an
            // interactive session is genuinely still opening.
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, self.subshell == nil else { return }

                // A full-screen program owns the alternate screen (mosh, or a TUI
                // launched right after ssh); typing hooks into it would only
                // litter its display and achieve nothing, since it does not
                // forward our markers. Leave it be.
                if self.isAlternateScreen { return }

                let line = self.lastVisibleLine()
                // Two identical samples means output has stopped arriving; the
                // prompt check keeps the hooks out of a password or yes/no prompt.
                if line == previous, Self.looksLikePrompt(line) {
                    self.installSubshellHooks(named: host)
                    return
                }
                previous = line
            }
        }
    }

    /// The host `ssh host` opens an interactive session to, or nil. Nil for a
    /// one-off like `ssh host -- some command`, which runs and exits without ever
    /// presenting a prompt. A `user@` prefix is dropped so the chip reads as the
    /// host — or the SSH-config alias — alone: `ssh yukino@rhel` shows as `rhel`.
    ///
    /// Only plain ssh, deliberately: mosh (and tmux/screen) re-render the remote
    /// screen on the alternate buffer rather than forwarding the byte stream, so
    /// the OSC 133 markers blocks are built on never arrive. Typing the hooks into
    /// such a session does nothing useful — it just litters the remote line — so
    /// they are left as a plain full-screen terminal instead.
    static func interactiveSSHHost(_ command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first, first == "ssh" else { return nil }
        // Flags and their values, then exactly one host, is the interactive
        // form. Anything trailing the host is a remote command.
        var operands: [String] = []
        var index = 1
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("-") {
                // Flags that take a value swallow the next word.
                if "bcDEeFIiJLlmOopQRSWw".contains(word.dropFirst().prefix(1)), word.count == 2 {
                    index += 1
                }
            } else {
                operands.append(word)
            }
            index += 1
        }
        guard operands.count == 1, let host = operands.first else { return nil }
        return host.split(separator: "@").last.map(String.init) ?? host
    }

    /// Prompt-ending characters. The plain-shell set (`$ % # >`) plus the
    /// glyphs the popular prompt themes end with — Starship and pure use `❯`,
    /// oh-my-zsh `➜`, others `» λ →`. Missing these meant a remote host with a
    /// themed prompt never got warpified, so its commands never became blocks.
    private static let promptEndings: Set<Character> = [
        "$", "%", "#", ">", "❯", "➜", "»", "λ", "→", "✗", "❱",
    ]

    private static func looksLikePrompt(_ line: String?) -> Bool {
        guard let line else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        // A question is not a prompt. Typing into one would send a page of
        // shell functions somewhere it must never go.
        let lowered = trimmed.lowercased()
        for probe in ["password", "passphrase", "(yes/no", "verification code", "otp"]
        where lowered.contains(probe) {
            return false
        }
        return promptEndings.contains(last)
    }

    /// The last row of the terminal that has anything on it.
    private func lastVisibleLine() -> String? {
        guard let terminal = terminalView?.terminal else { return nil }
        let buffer = terminal.buffer
        let cursor = buffer.totalLinesTrimmed + buffer.yDisp + buffer.y
        for row in stride(from: cursor, through: max(0, cursor - 4), by: -1) {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return nil
    }

    /// Types the hooks into whatever shell is on the other end.
    private func installSubshellHooks(named name: String? = nil) {
        guard let view = terminalView else { return }
        if subshell == nil {
            localDirectory = currentDirectory
            // Entering a remote session is a fresh start: wipe the local blocks
            // (the `ssh` command and everything before it) so the tab shows only
            // the remote session, the way opening a new terminal would.
            blocks.removeAll()
            selectedBlockID = nil
        }
        remoteListings.removeAll()
        pendingListings.removeAll()
        subshell = name ?? "ssh"
        runningBlock = nil
        isSubmitting = false
        subshellWatch?.cancel()

        // Leading space so shells with HIST_IGNORE_SPACE keep it out of history.
        view.send(txt: " " + ShellIntegration.portableSubshellBootstrap + "\n")
    }

    /// `S` arrives from a shell that has just sourced its rc file somewhere we
    /// do not control — over SSH, or inside a container.
    ///
    /// Nothing is installed on the far end. The hooks are typed into the
    /// session that is already open, so the remote shell starts emitting the
    /// same markers the local one does and its commands become blocks. The
    /// echoed setup line is cleaned up by the reset on the next prompt.
    private func adoptSubshell(named argument: String?) {
        // The command that opened the subshell — `ssh host` — never returns to
        // a local prompt, so its block would otherwise stay running forever and
        // hold the composer off screen for the whole session.
        installSubshellHooks(named: argument?.isEmpty == false ? argument : nil)
    }

    /// Installs the hooks on demand, for a session the watcher did not catch —
    /// a container, or a host whose prompt does not look like one. If an `ssh`
    /// command is the one still running, its host names the chip.
    func warpifySession() {
        let sshHost = runningBlock.flatMap { Self.interactiveSSHHost($0.command) }
        installSubshellHooks(named: subshell ?? sshHost ?? "shell")
    }

    /// `A` arrives from precmd, before the prompt is printed.
    ///
    /// This is where the terminal is wiped: the block that just finished has
    /// already been captured by `endCommand`, and clearing now — rather than at
    /// `D` — means the fresh prompt is drawn *after* the reset instead of being
    /// erased by it.
    private func beginPrompt() {
        isSubmitting = false
        terminalView?.terminal?.resetToInitialState()
        promptRow = cursorRow() ?? 0
        outputStartRow = nil
    }

    /// `C` arrives from preexec: the command line is on screen and output is
    /// about to start.
    private func beginOutput() {
        isSubmitting = false
        commandDepth += 1
        watchForSubshell(command: pendingCommand ?? "")

        let row = outputBoundaryRow() ?? promptRow
        outputStartRow = row

        runningBlock = CommandBlock(
            command: pendingCommand ?? "",
            directory: currentDirectory,
            gitBranch: gitBranch,
            startedAt: Date()
        )
        pendingCommand = nil
    }

    /// `D` arrives from the next precmd, after the output and before the next
    /// prompt is drawn.
    private func endCommand(exitCode: Int32) {
        subshellWatch?.cancel()
        commandDepth = max(0, commandDepth - 1)

        // The subshell ends only when the command that opened it -- the `ssh`
        // itself -- finishes and depth returns to zero. A command finishing
        // *inside* the session, a remote `cd` above all, emits its own D marker
        // but leaves depth >= 1, and must not flip the explorer back to local.
        if commandDepth == 0, subshell != nil {
            if let localDirectory {
                currentDirectory = localDirectory
                refreshGitBranch(for: localDirectory)
            }
            localDirectory = nil
            subshell = nil
            remoteListings.removeAll()
            pendingListings.removeAll()
        }

        guard var block = runningBlock else { return }
        runningBlock = nil

        // `clear` cannot do anything useful to a screen made of frozen blocks —
        // the terminal buffer it wipes only ever holds the command in progress.
        // What the user means is "wipe the history", so that is what it does.
        if Self.clearsHistory(block.command) {
            blocks.removeAll()
            selectedBlockID = nil
            outputStartRow = nil
            return
        }

        finish(&block, state: .finished(exitCode: exitCode))
        append(block)
        onCommandFinished?(blocks.last ?? block)
    }

    private static func clearsHistory(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return trimmed == "clear" || trimmed == "cls"
    }

    /// Closes out a running command when the shell exits without a `D` marker.
    func shellExited() {
        commandDepth = 0
        subshell = nil
        guard var block = runningBlock else { return }
        runningBlock = nil

        finish(&block, state: .abandoned)
        append(block)
    }

    private func finish(_ block: inout CommandBlock, state: CommandBlock.State) {
        let start = outputStartRow ?? promptRow
        let captured = capture(from: start, to: outputBoundaryRow() ?? start)

        block.state = state
        block.finishedAt = Date()
        block.output = captured.text
        block.outputPreview = captured.preview
        block.outputLineCount = captured.lineCount
        outputStartRow = nil
    }

    private func append(_ block: CommandBlock) {
        blocks.append(block)
        guard blocks.count > maximumBlocks else { return }
        let excess = blocks.count - maximumBlocks
        if let selectedBlockID,
           blocks.prefix(excess).contains(where: { $0.id == selectedBlockID }) {
            self.selectedBlockID = nil
        }
        blocks.removeFirst(excess)
    }

    // MARK: - Git

    /// Looks up the branch for a directory off the main actor, caching by path
    /// so switching back and forth costs nothing. Running `git` in the shell's
    /// own precmd hook would put this latency in front of every prompt.
    private func refreshGitBranch(for directory: String) {
        if let cached = gitBranchCache[directory] {
            gitBranch = cached
            return
        }

        gitBranch = nil
        Task.detached(priority: .utility) {
            let branch = Self.readGitBranch(in: directory)
            await MainActor.run {
                self.gitBranchCache[directory] = branch
                // Ignore a result the user has already navigated away from.
                guard self.currentDirectory == directory else { return }
                self.gitBranch = branch
            }
        }
    }

    private nonisolated static func readGitBranch(in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let branch = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    // MARK: - Capture

    /// The cursor's absolute (scroll invariant) row.
    private func cursorRow() -> Int? {
        guard let terminal = terminalView?.terminal else { return nil }
        let buffer = terminal.buffer
        return buffer.totalLinesTrimmed + buffer.yDisp + buffer.y
    }

    /// The absolute row that bounds a command's output, rounded past a row the
    /// cursor is only part way through.
    ///
    /// Used for both ends of the range. At the start it steps off the command
    /// line when the shell has not yet emitted its newline, so the command is
    /// not duplicated into its own output. At the end it keeps a final line
    /// that never got a trailing newline — `printf 'x'` would otherwise be
    /// dropped.
    private func outputBoundaryRow() -> Int? {
        guard let terminal = terminalView?.terminal, let row = cursorRow() else { return nil }
        return terminal.buffer.x > 0 ? row + 1 : row
    }

    private struct Capture {
        var text = AttributedString()
        var preview = AttributedString()
        var lineCount = 0
    }

    /// Reads rows `start..<end` out of the terminal buffer as styled text,
    /// dropping the blank rows commands tend to leave behind.
    private func capture(from start: Int, to end: Int) -> Capture {
        guard let terminal = terminalView?.terminal, end > start else { return Capture() }

        var lines: [AttributedString] = []
        for row in start..<min(end, start + maximumCapturedLines) {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            lines.append(Self.attributed(line: line))
        }
        while let last = lines.last, last.characters.isEmpty { lines.removeLast() }

        var capture = Capture(lineCount: lines.count)
        capture.text = Self.joined(lines)
        capture.preview = lines.count > CommandBlock.outputPreviewLimit
            ? Self.joined(Array(lines.prefix(CommandBlock.outputPreviewLimit)))
            : capture.text
        return capture
    }

    private static func joined(_ lines: [AttributedString]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(line)
        }
        return result
    }

    /// Converts one terminal line to styled text, coalescing neighbouring cells
    /// that share an attribute into a single run.
    private static func attributed(line: BufferLine) -> AttributedString {
        var result = AttributedString()
        var column = 0

        while column < line.count {
            let attribute = line[column].attribute
            var text = ""

            while column < line.count, line[column].attribute == attribute {
                let character = line[column].getCharacter()
                text.append(character == "\0" ? " " : character)
                column += 1
            }

            var foreground = color(for: attribute.fg)
            var background = color(for: attribute.bg)
            if attribute.style.contains(.inverse) { swap(&foreground, &background) }

            // Trailing spaces on the last run are padding, not content — unless
            // they carry a background color worth showing.
            if column >= line.count, background == nil {
                while text.hasSuffix(" ") { text.removeLast() }
            }

            guard !text.isEmpty, !attribute.style.contains(.invisible) else { continue }

            var run = AttributedString(text)
            if let foreground { run.foregroundColor = foreground }
            if let background { run.backgroundColor = background }

            var intent: InlinePresentationIntent = []
            if attribute.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if attribute.style.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if attribute.style.contains(.underline) { run.underlineStyle = .single }
            if attribute.style.contains(.crossedOut) { run.strikethroughStyle = .single }

            result.append(run)
        }

        return result
    }

    private static func color(for color: Attribute.Color) -> SwiftUI.Color? {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .trueColor(let red, let green, let blue):
            return SwiftUI.Color(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255
            )
        case .ansi256(let code):
            return ansiColor(code)
        }
    }

    private static func ansiColor(_ code: UInt8) -> SwiftUI.Color {
        switch code {
        case 0...15:
            return TerminalPalette.ansi[Int(code)]
        case 16...231:
            // The xterm 6×6×6 color cube.
            let index = Int(code) - 16
            let steps: [Double] = [0, 95, 135, 175, 215, 255]
            return SwiftUI.Color(
                red: steps[index / 36] / 255,
                green: steps[(index / 6) % 6] / 255,
                blue: steps[index % 6] / 255
            )
        default:
            // 232...255: the grayscale ramp.
            let level = Double(8 + (Int(code) - 232) * 10) / 255
            return SwiftUI.Color(red: level, green: level, blue: level)
        }
    }

    private static func decodeHex(_ hex: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// The 16 base ANSI colors, matched to the terminal's dark background.
enum TerminalPalette {
    static let ansi: [SwiftUI.Color] = [
        SwiftUI.Color(red: 0.16, green: 0.17, blue: 0.20),  // black
        SwiftUI.Color(red: 0.94, green: 0.38, blue: 0.42),  // red
        SwiftUI.Color(red: 0.47, green: 0.83, blue: 0.51),  // green
        SwiftUI.Color(red: 0.94, green: 0.75, blue: 0.36),  // yellow
        SwiftUI.Color(red: 0.40, green: 0.66, blue: 0.96),  // blue
        SwiftUI.Color(red: 0.76, green: 0.55, blue: 0.96),  // magenta
        SwiftUI.Color(red: 0.35, green: 0.80, blue: 0.83),  // cyan
        SwiftUI.Color(red: 0.85, green: 0.87, blue: 0.90),  // white
        SwiftUI.Color(red: 0.42, green: 0.45, blue: 0.50),  // bright black
        SwiftUI.Color(red: 1.00, green: 0.50, blue: 0.53),  // bright red
        SwiftUI.Color(red: 0.60, green: 0.90, blue: 0.63),  // bright green
        SwiftUI.Color(red: 1.00, green: 0.84, blue: 0.48),  // bright yellow
        SwiftUI.Color(red: 0.55, green: 0.76, blue: 1.00),  // bright blue
        SwiftUI.Color(red: 0.85, green: 0.67, blue: 1.00),  // bright magenta
        SwiftUI.Color(red: 0.50, green: 0.89, blue: 0.91),  // bright cyan
        SwiftUI.Color(red: 0.98, green: 0.99, blue: 1.00),  // bright white
    ]
}
