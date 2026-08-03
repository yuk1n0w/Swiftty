import Foundation

/// Tab completion for the command editor.
///
/// The shell's own completion is out of reach: its line editor never sees what
/// is typed here, so there is nothing for it to complete against. This covers
/// the two cases that matter in practice — the program name in command
/// position, and file paths everywhere else.
enum Completion {
    struct Result {
        /// The whole line, with the token under the caret expanded.
        let text: String
        /// Where the caret ends up, at the end of what was inserted.
        let caret: Int
        /// Index where the token being completed begins, so the caller can
        /// replace it in place while cycling through candidates on repeated Tab.
        let tokenStart: Int
        /// The escaped, ready-to-insert candidates, in order, for Tab-cycling.
        /// Empty when the completion was unique (nothing to cycle through).
        let insertions: [String]
    }

    /// Directory contents, however they are obtained.
    ///
    /// Local sessions read the disk; a remote session asks the shell on the far
    /// end, because the local filesystem is the wrong machine entirely.
    typealias Lister = (String) -> [String]?

    /// Expands the token ending at `caret`, or returns nil if nothing matches.
    static func complete(
        text: String,
        caret: Int,
        directory: String,
        lister: Lister? = nil
    ) -> Result? {
        let characters = Array(text)
        let caret = min(max(caret, 0), characters.count)

        // Walk back to the start of the token — but a backslash-escaped space
        // (`My\ Folder`) is part of the token, not a boundary, so a name with
        // spaces completes as one word.
        var start = caret
        while start > 0 {
            if isSeparator(characters[start - 1]), !isEscaped(characters, at: start - 1) {
                break
            }
            start -= 1
        }
        // The literal token as typed (may carry backslashes); matching is done
        // against the unescaped form, which is the real filename prefix.
        let rawToken = String(characters[start..<caret])
        let token = unescape(rawToken)

        let matches = isCommandPosition(characters, before: start)
            ? executables(matching: token, in: directory, lister: lister)
            : paths(matching: token, in: directory, lister: lister)
        guard !matches.isEmpty else { return nil }

        // With several candidates, extend as far as they agree and leave the
        // caret there — the same thing a shell does on the first Tab.
        let expansion = matches.count == 1 ? matches[0] : commonPrefix(of: matches)
        guard expansion.count >= token.count else { return nil }
        // Escape the expansion so a name with spaces (or other shell
        // metacharacters) reaches the shell as a single argument. A unique
        // directory keeps its trailing slash so the next Tab descends; a unique
        // file gets a plain trailing space that marks the end of the argument
        // and so must *not* be escaped.
        let escaped = escape(expansion)
        let insertion = matches.count == 1 && !expansion.hasSuffix("/")
            ? escaped + " "
            : escaped
        guard insertion != rawToken else { return nil }

        let replaced = String(characters[0..<start]) + insertion + String(characters[caret...])
        return Result(
            text: replaced,
            caret: start + insertion.count,
            tokenStart: start,
            // Escaped, and *without* the trailing space a unique file gets — the
            // caret stays on the name so the next Tab can replace it with the
            // following candidate.
            insertions: matches.count > 1 ? matches.map(escape) : []
        )
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
    }

    /// Whether the character at `index` is preceded by an odd run of backslashes,
    /// i.e. it is escaped.
    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        var count = 0
        var i = index - 1
        while i >= 0, characters[i] == "\\" { count += 1; i -= 1 }
        return count % 2 == 1
    }

    /// Drops the backslashes a user (or a previous completion) put in front of
    /// shell metacharacters, recovering the real filename prefix to match on.
    private static func unescape(_ token: String) -> String {
        var out = ""
        var escaped = false
        for ch in token {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        if escaped { out.append("\\") }
        return out
    }

    /// Backslash-escapes the shell metacharacters in a completed path, leaving
    /// the structural `/` and a leading `~` alone so paths and tilde expansion
    /// still work.
    private static func escape(_ path: String) -> String {
        let special = Set(" \t\"'\\$`&|;<>()*?[]{}")
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// True when the token being completed is a program name rather than an
    /// argument — the start of the line, or just after a pipe or separator.
    private static func isCommandPosition(_ characters: [Character], before start: Int) -> Bool {
        var index = start - 1
        while index >= 0, isSeparator(characters[index]) { index -= 1 }
        guard index >= 0 else { return true }
        return "|&;".contains(characters[index])
    }

    // MARK: - Paths

    private static func paths(
        matching token: String,
        in directory: String,
        lister: Lister? = nil
    ) -> [String] {
        let expanded = (token as NSString).expandingTildeInPath
        let isAbsolute = expanded.hasPrefix("/")

        // Split the token into the directory to look in and the prefix to match.
        let lastSlash = expanded.lastIndex(of: "/")
        let searchPrefix = lastSlash.map { String(expanded[expanded.index(after: $0)...]) } ?? expanded
        let searchDirectory: String
        if let lastSlash {
            let head = String(expanded[..<lastSlash])
            searchDirectory = head.isEmpty ? "/" : head
        } else {
            searchDirectory = directory
        }

        let resolved = isAbsolute || lastSlash != nil
            ? searchDirectory
            : directory
        // A remote lister already marks directories with a trailing slash;
        // the local branch has to stat for it below.
        let remote = lister?(resolved)
        guard let entries = remote
            ?? (try? FileManager.default.contentsOfDirectory(atPath: resolved)) else {
            return []
        }

        // A leading dot has to be typed explicitly, as in any shell.
        let showsHidden = searchPrefix.hasPrefix(".")
        let manager = FileManager.default

        return entries
            .filter { $0.hasPrefix(searchPrefix) && (showsHidden || !$0.hasPrefix(".")) }
            .map { entry -> String in
                var entry = entry
                var suffix = ""
                if remote != nil {
                    // `ls -p` already appended the slash.
                    if entry.hasSuffix("/") {
                        entry.removeLast()
                        suffix = "/"
                    }
                } else {
                    var isDirectory: ObjCBool = false
                    let full = (resolved as NSString).appendingPathComponent(entry)
                    manager.fileExists(atPath: full, isDirectory: &isDirectory)
                    suffix = isDirectory.boolValue ? "/" : ""
                }

                // Rebuild the candidate in the shape the user typed it, so a
                // relative token stays relative and `~` stays `~`.
                if let lastSlash {
                    let head = String(token[..<token.index(
                        token.startIndex,
                        offsetBy: expanded.distance(from: expanded.startIndex, to: lastSlash)
                            - (expanded.count - token.count)
                    )])
                    return head + "/" + entry + suffix
                }
                return entry + suffix
            }
            .sorted()
    }

    // MARK: - Commands

    private static func executables(
        matching token: String,
        in directory: String,
        lister: Lister?
    ) -> [String] {
        guard !token.isEmpty else { return [] }
        // A token that looks like a path is a path, even in command position.
        if token.contains("/") || token.hasPrefix("~") || token.hasPrefix(".") {
            return paths(matching: token, in: directory, lister: lister)
        }
        // The local PATH says nothing about what is installed on a remote host,
        // so a remote session offers no command completion rather than a list
        // of programs that are not there.
        guard lister == nil else { return [] }
        return commandNames.filter { $0.hasPrefix(token) }.sorted()
    }

    /// Everything executable on PATH, gathered once per launch.
    private static let commandNames: Set<String> = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let manager = FileManager.default
        var names: Set<String> = []

        for directory in path.split(separator: ":") {
            let directory = String(directory)
            guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where manager.isExecutableFile(
                atPath: (directory as NSString).appendingPathComponent(entry)
            ) {
                names.insert(entry)
            }
        }
        // Shell keywords have no file on disk but are worth completing.
        names.formUnion([
            "cd", "echo", "export", "alias", "unalias", "source", "exit",
            "history", "jobs", "kill", "pwd", "set", "unset", "which",
        ])
        return names
    }()

    /// Whether `token` names something runnable — a program on PATH or a shell
    /// builtin. Natural-language detection uses this so a real command in the
    /// first position (`make`, `find`, `git`) is never mistaken for prose.
    static func isKnownCommand(_ token: String) -> Bool {
        commandNames.contains(token)
    }

    private static func commonPrefix(of candidates: [String]) -> String {
        guard var prefix = candidates.first else { return "" }
        for candidate in candidates.dropFirst() {
            prefix = String(prefix.commonPrefix(with: candidate))
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
