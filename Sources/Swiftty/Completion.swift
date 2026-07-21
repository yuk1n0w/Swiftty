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
        /// Every candidate, when the token was ambiguous and only partly
        /// extended. Empty when the completion was unique.
        let candidates: [String]
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

        var start = caret
        while start > 0, !isSeparator(characters[start - 1]) { start -= 1 }
        let token = String(characters[start..<caret])

        let matches = isCommandPosition(characters, before: start)
            ? executables(matching: token, in: directory, lister: lister)
            : paths(matching: token, in: directory, lister: lister)
        guard !matches.isEmpty else { return nil }

        // With several candidates, extend as far as they agree and leave the
        // caret there — the same thing a shell does on the first Tab.
        let expansion = matches.count == 1 ? matches[0] : commonPrefix(of: matches)
        guard expansion.count >= token.count else { return nil }
        // A unique directory gets a trailing slash so the next Tab descends.
        let insertion = matches.count == 1 && !expansion.hasSuffix("/")
            ? expansion + " "
            : expansion
        guard insertion != token else { return nil }

        let replaced = String(characters[0..<start]) + insertion + String(characters[caret...])
        return Result(
            text: replaced,
            caret: start + insertion.count,
            candidates: matches.count == 1 ? [] : matches
        )
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
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

    private static func commonPrefix(of candidates: [String]) -> String {
        guard var prefix = candidates.first else { return "" }
        for candidate in candidates.dropFirst() {
            prefix = String(prefix.commonPrefix(with: candidate))
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
