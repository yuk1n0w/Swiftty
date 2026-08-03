import Foundation

/// What the composer should do with a line of input.
enum InputIntent {
    /// Run it in the shell — the default, and everything ambiguous.
    case command
    /// Send it to the AI agent as a natural-language request.
    case agent
}

/// A small, local, dependency-free classifier that decides whether text typed
/// into the command composer is a shell command or a natural-language request
/// for the AI. This is the heuristic behind Warp-style input interception: as
/// you type, the composer can tell you Return will "ask AI" instead of running a
/// command, and route it accordingly.
///
/// It is deliberately conservative. It only returns `.agent` on a positive
/// natural-language signal, and a program name in command position always wins,
/// so a real command is never swallowed. Anything it is unsure about runs as a
/// command, exactly as it would have before the feature existed.
enum IntentClassifier {
    /// Words that, at the very start of a multi-word line, read as a request
    /// rather than a command. Many double as real programs (`find`, `make`,
    /// `show`)  — that is fine, because a known command in first position is
    /// checked *before* this set and takes precedence.
    private static let requestOpeners: Set<String> = [
        "how", "what", "why", "when", "where", "who", "which", "whats", "hows",
        "whys", "wheres", "whos", "can", "could", "should", "would", "is",
        "are", "am", "do", "does", "did", "will", "please", "explain",
        "summarize", "summarise", "tell", "give", "teach", "describe",
        "suggest", "recommend", "convert", "translate", "generate", "show",
        "list", "create", "write", "build", "find", "fix", "help", "add",
        "remove", "delete", "install", "update", "set", "open", "close",
        "start", "stop", "enable", "disable", "check", "get", "search", "look",
        "count", "rename", "move", "copy", "compare", "refactor", "debug",
        "optimize", "optimise", "improve", "make", "run", "undo", "figure",
        "walk", "draft", "name", "pick", "i", "im", "id", "ive", "my", "we",
        "lets", "let", "turn",
        // Conversational openers — someone talking to the agent, not a program.
        "hello", "hi", "hey", "yo", "sup", "hola", "greetings", "thanks",
        "thank", "ok", "okay", "yeah", "yep", "please", "so", "well",
    ]

    /// Question words. Unlike an opener, one of these anywhere in a multi-word
    /// line reads as a spoken question — "hello how are you", "so what broke".
    /// A genuine `which`/`where` command is a program in *first* position and
    /// is caught by the known-command check before this ever runs.
    private static let interrogatives: Set<String> = [
        "how", "what", "why", "who", "whom", "whose", "where", "when", "which",
    ]

    /// Little English function words that pepper ordinary prose but almost
    /// never stand alone as tokens in a shell command. One of these in a
    /// multi-word line whose first word is *not* a program name is a strong
    /// sign the line is a sentence, not a command — "undo my last commit",
    /// "the build keeps failing", "kill whatever's on that port".
    ///
    /// Kept to articles, pronouns and negations on purpose: prepositions like
    /// "to"/"in"/"on" turn up as bare arguments too often to be safe here.
    private static let proseMarkers: Set<String> = [
        "the", "a", "an", "my", "me", "mine", "your", "yours", "our", "ours",
        "their", "its", "it", "that", "this", "these", "those", "there",
        // Pronouns — "how are you", "can we", "tell them".
        "you", "youre", "youve", "we", "they", "theyre", "them", "us",
        "he", "she", "him", "her", "im", "ive",
        "whatever", "whichever", "something", "everything", "anything",
        "please", "isnt", "arent", "wasnt", "werent", "wont", "cant",
        "couldnt", "doesnt", "dont", "didnt", "shouldnt", "wouldnt", "about",
    ]

    /// Characters that only appear in shell syntax — a strong command signal.
    /// Note `?` is absent: it is a glob character but also ends questions, and is
    /// handled with more care below.
    private static let shellOperators: Set<Character> = [
        "|", ">", "<", "&", ";", "$", "`", "*", "(", ")", "{", "}", "=", "\\",
    ]

    static func classify(
        _ raw: String,
        isKnownCommand: (String) -> Bool = Completion.isKnownCommand
    ) -> InputIntent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .command }

        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let first = words[0]

        // --- Hard shell signals: never intercept. ---------------------------
        if text.contains(where: { shellOperators.contains($0) }) { return .command }
        if first.hasPrefix("/") || first.hasPrefix("./") || first.hasPrefix("../")
            || first.hasPrefix("~") || first.hasPrefix("-") { return .command }
        // A single token is a command (or a typo the shell will complain about),
        // never a request — real requests are phrases.
        if words.count == 1 { return .command }
        // A program in command position outranks any prose reading, so
        // "make build", "find . -name x" and "git status" stay commands. This
        // also keeps a glob like "ls a?" from looking like a question.
        if isKnownCommand(first) { return .command }

        // --- Natural-language signals (all require more than one word). ------
        // A trailing question mark is the plainest one.
        if text.hasSuffix("?") { return .agent }

        // Compared apostrophe-blind, so "what's" reads as "whats" and "isn't"
        // as "isnt" without a second spelling in every set.
        let normalized = words.map(Self.normalize)
        // A plain-English opener in first position.
        if let opener = normalized.first, requestOpeners.contains(opener) { return .agent }
        // A question word anywhere in the line — the first word not being a
        // program means the shell could not have run this regardless.
        if normalized.contains(where: { interrogatives.contains($0) }) { return .agent }
        // Otherwise, an article / pronoun / negation anywhere in a line that
        // does not begin with a program name. The first word being unknown
        // means the shell could not have run this line regardless, so handing
        // a sentence-shaped one to the agent never costs a would-be command.
        if normalized.contains(where: { proseMarkers.contains($0) }) { return .agent }

        return .command
    }

    /// Lower-cased and stripped of apostrophes and trailing sentence
    /// punctuation, so contractions and end-of-line words match the word sets.
    private static func normalize(_ word: String) -> String {
        var scalars = word.lowercased().unicodeScalars.filter { $0 != "'" && $0 != "\u{2019}" }
        while let last = scalars.last, ".,!?;:".unicodeScalars.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
