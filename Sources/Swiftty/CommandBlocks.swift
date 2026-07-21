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
    @Published private(set) var runningBlock: CommandBlock?
    @Published var selectedBlockID: CommandBlock.ID?
    /// True once the shell has sent a marker, i.e. the integration is live.
    @Published private(set) var isIntegrationActive = false
    /// True while a full-screen program (vim, htop, less) owns the screen.
    @Published private(set) var isAlternateScreen = false
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
    /// Height the live terminal needs while sitting at a prompt.
    @Published private(set) var idleTerminalHeight: CGFloat = 44

    private var gitBranchCache: [String: String?] = [:]
    private weak var terminalView: SwifttyTerminalView?
    private var pendingCommand: String?
    /// Absolute row the current prompt starts on.
    private var promptRow = 0
    /// Absolute row the running command's output starts on.
    private var outputStartRow: Int?

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

        updateIdleHeight(view: view)
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
        // Ctrl-U first, to kill anything already sitting in the shell's line
        // buffer. Stray keystrokes should never reach it now that the editor
        // holds focus, but if any ever do they would silently prefix the
        // command, and that failure is invisible until the shell rejects it.
        view.send(txt: "\u{15}" + command + "\n")
        focusTerminal()
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

    /// The shell's working directory as an absolute path, for completing
    /// relative paths against.
    var workingDirectory: String { currentDirectory }

    /// What the tab shows: the running command while one is executing, the
    /// current folder otherwise — the same thing a normal terminal reports.
    var tabLabel: String {
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
        case "P":
            if let directory = argument.flatMap(Self.decodeHex),
               !directory.isEmpty,
               directory != currentDirectory {
                currentDirectory = directory
                refreshGitBranch(for: directory)
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

    /// `S` arrives from a shell that has just sourced its rc file somewhere we
    /// do not control — over SSH, or inside a container.
    ///
    /// Nothing is installed on the far end. The hooks are typed into the
    /// session that is already open, so the remote shell starts emitting the
    /// same markers the local one does and its commands become blocks. The
    /// echoed setup line is cleaned up by the reset on the next prompt.
    private func adoptSubshell(named argument: String?) {
        let name = (argument?.isEmpty == false ? argument! : "sh")
        guard let flavor = ShellIntegration.Flavor(shellPath: name),
              let view = terminalView else { return }

        subshell = name
        // The command that opened the subshell — `ssh host` — never returns to
        // a local prompt, so its block would otherwise stay running forever and
        // hold the composer off screen for the whole session.
        runningBlock = nil
        isSubmitting = false

        // Leading space so shells with HIST_IGNORE_SPACE keep it out of history.
        view.send(txt: " " + ShellIntegration.subshellBootstrap(for: flavor) + "\n")
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
        focusTerminal()

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
    }

    private static func clearsHistory(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return trimmed == "clear" || trimmed == "cls"
    }

    /// Closes out a running command when the shell exits without a `D` marker.
    func shellExited() {
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
