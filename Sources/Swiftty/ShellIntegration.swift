import Foundation

/// The shell-side half of the blocks feature.
///
/// Swiftty learns where each command begins and ends from OSC 133 semantic
/// prompt markers — the same protocol iTerm2, VS Code, WezTerm, Kitty and
/// Ghostty use, and the one Warp builds its blocks on. The shell emits:
///
///     OSC 133 ; P ; <hex>    the working directory (a Swiftty extension)
///     OSC 133 ; A            a prompt is about to be drawn
///     OSC 133 ; E ; <hex>    the command line, hex encoded
///     OSC 133 ; C            the command started; output begins on the next row
///     OSC 133 ; D ; <code>   the command finished with this exit status
///
/// `P` exists because Swiftty clears the terminal buffer between blocks, which
/// also clears the directory SwiftTerm tracked from OSC 7. Reporting it in band
/// keeps each block labelled with the directory it actually ran in.
///
/// The snippets below only *add* hooks. They never touch PROMPT, never disable
/// ZLE, and never change the tty modes, so the user's prompt theme, completion,
/// history and full-screen programs such as vim or htop keep working exactly as
/// they do in any other terminal.
enum ShellIntegration {
    /// Shells Swiftty knows how to instrument.
    enum Flavor {
        case zsh
        case bash

        init?(shellPath: String) {
            switch (shellPath as NSString).lastPathComponent {
            case "zsh": self = .zsh
            case "bash", "sh": self = .bash
            default: return nil
            }
        }
    }

    /// Environment overrides and argv that make `shellPath` load our hooks.
    struct Injection {
        var environment: [String: String] = [:]
        /// When non-empty, replaces the launcher's default arguments.
        var arguments: [String] = []
        /// When set, replaces the launcher's default `argv[0]`. Needed for
        /// bash, which ignores `--rcfile` if argv[0] marks it as a login shell.
        var execName: String?
    }

    /// Writes the integration files for one terminal tab and returns the
    /// environment/argument changes needed to load them.
    ///
    /// Returns `nil` for shells we do not instrument; the caller should launch
    /// the shell untouched in that case. The terminal still works, it just does
    /// not produce blocks.
    static func prepare(shellPath: String, tabID: UUID) -> Injection? {
        guard let flavor = Flavor(shellPath: shellPath) else { return nil }
        guard let directory = makeSupportDirectory(tabID: tabID) else { return nil }

        switch flavor {
        case .zsh:
            return prepareZsh(in: directory)
        case .bash:
            return prepareBash(in: directory)
        }
    }

    // MARK: - Subshells

    /// The line a user adds to the shell config on a remote host or inside a
    /// container, so sessions there produce blocks too.
    ///
    /// It announces "a shell just finished sourcing its rc file"; Swiftty
    /// answers by typing `subshellBootstrap` into the session. Nothing has to
    /// be installed on the far end — the hooks arrive over the connection that
    /// is already open.
    static func handshakeSnippet(for flavor: Flavor) -> String {
        switch flavor {
        case .zsh:
            return #"printf '\e]133;S;zsh\a'"#
        case .bash:
            return #"printf '\e]133;S;bash\a'"#
        }
    }

    /// The hooks, collapsed onto one line so they can be typed into a session
    /// that has no Swiftty rc file of its own.
    ///
    /// This mirrors the rc-file hooks above and has to stay in step with them;
    /// it is separate because a remote shell can only be fed a single line, and
    /// collapsing the multi-line version automatically would break on its
    /// `if`/`fi` blocks.
    static func subshellBootstrap(for flavor: Flavor) -> String {
        switch flavor {
        case .zsh:
            return [
                #"__swiftty_mark() { builtin printf '\e]133;%s\a' "$1"; }"#,
                #"__swiftty_hex() { builtin printf '%s' "$1" | command od -An -v -tx1 | command tr -d ' \n'; }"#,
                #"__swiftty_capture_status() { __swiftty_status=$?; }"#,
                #"__swiftty_precmd() { if [[ -n "$__swiftty_running" ]]; then __swiftty_mark "D;${__swiftty_status:-0}"; unset __swiftty_running; fi; __swiftty_mark "P;$(__swiftty_hex "$PWD")"; __swiftty_ls "$PWD"; __swiftty_mark "A"; }"#,
                #"__swiftty_preexec() { case "$1" in *__swiftty_*) return ;; esac; __swiftty_running=1; __swiftty_mark "P;$(__swiftty_hex "$PWD")"; __swiftty_mark "E;$(__swiftty_hex "$1")"; __swiftty_mark "C"; }"#,
                #"__swiftty_ls() { __swiftty_mark "L;$(__swiftty_hex "$1")|$(__swiftty_hex "$(command ls -1Ap -- "$1" 2>/dev/null | head -400)")"; }"#,
                #"autoload -Uz add-zsh-hook"#,
                #"precmd_functions=(__swiftty_capture_status $precmd_functions)"#,
                #"add-zsh-hook precmd __swiftty_precmd"#,
                #"add-zsh-hook preexec __swiftty_preexec"#,
            ].joined(separator: "; ")

        case .bash:
            return [
                #"__swiftty_mark() { printf '\e]133;%s\a' "$1"; }"#,
                #"__swiftty_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }"#,
                #"__swiftty_preexec() { [ -n "$COMP_LINE" ] && return 0; [ -n "$__swiftty_running" ] && return 0; case "$BASH_COMMAND" in __swiftty_*|*__swiftty_precmd*) return 0 ;; esac; __swiftty_running=1; __swiftty_mark "P;$(__swiftty_hex "$PWD")"; __swiftty_mark "E;$(__swiftty_hex "$BASH_COMMAND")"; __swiftty_mark "C"; return 0; }"#,
                #"__swiftty_precmd() { local s=$?; if [ -n "$__swiftty_running" ]; then __swiftty_mark "D;$s"; unset __swiftty_running; fi; __swiftty_mark "P;$(__swiftty_hex "$PWD")"; __swiftty_ls "$PWD"; __swiftty_mark "A"; }"#,
                #"__swiftty_ls() { __swiftty_mark "L;$(__swiftty_hex "$1")|$(__swiftty_hex "$(command ls -1Ap -- "$1" 2>/dev/null | head -400)")"; }"#,
                #"PROMPT_COMMAND="__swiftty_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}""#,
                #"trap '__swiftty_preexec' DEBUG"#,
            ].joined(separator: "; ")
        }
    }

    /// Both bootstraps behind a runtime shell test, for sessions where the far
    /// end's shell is unknown — an SSH host, a container.
    ///
    /// Each branch has to *parse* under the other shell even though only one
    /// runs, which is why both stick to syntax the two have in common.
    static var portableSubshellBootstrap: String {
        let zsh = subshellBootstrap(for: .zsh)
        let bash = subshellBootstrap(for: .bash)
        return "if [ -n \"$ZSH_VERSION\" ]; then \(zsh); "
            + "elif [ -n \"$BASH_VERSION\" ]; then \(bash); fi"
    }

    /// Removes the per-tab integration directory once its shell has exited.
    static func cleanUp(tabID: UUID) {
        try? FileManager.default.removeItem(at: supportDirectoryURL(tabID: tabID))
    }

    // MARK: - zsh

    /// zsh has no "extra rc file" flag, so we point ZDOTDIR at a directory of
    /// our own whose startup files source the user's real ones first and then
    /// append our hooks. ZDOTDIR is restored before control reaches the user's
    /// shell so nested shells and `exec zsh` behave normally.
    private static func prepareZsh(in directory: URL) -> Injection? {
        let originalZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // zsh reads .zshenv, .zprofile, .zshrc and .zlogin from ZDOTDIR. Each
        // of ours forwards to the matching user file; only .zshrc adds hooks,
        // since that is the one that runs for interactive shells.
        let forwarding = """
        [ -f "$SWIFTTY_ZDOTDIR/%@" ] && source "$SWIFTTY_ZDOTDIR/%@"
        """

        let zshenv = """
        SWIFTTY_ZDOTDIR="\(shellQuoted(originalZDOTDIR))"
        \(String(format: forwarding, ".zshenv", ".zshenv"))
        """

        let zshrc = """
        \(String(format: forwarding, ".zshrc", ".zshrc"))

        \(zshHooks)

        # Hand the user's own ZDOTDIR back so nested shells load their config
        # normally instead of re-entering Swiftty's bootstrap directory.
        ZDOTDIR="$SWIFTTY_ZDOTDIR"
        """

        let files: [String: String] = [
            ".zshenv": zshenv,
            ".zprofile": String(format: forwarding, ".zprofile", ".zprofile"),
            ".zshrc": zshrc,
            ".zlogin": String(format: forwarding, ".zlogin", ".zlogin"),
        ]

        for (name, contents) in files {
            do {
                try contents.write(
                    to: directory.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                return nil
            }
        }

        return Injection(environment: ["ZDOTDIR": directory.path])
    }

    private static let zshHooks = """
    # --- Swiftty blocks (OSC 133 semantic prompt markers) ---
    if [[ -z "$SWIFTTY_BLOCKS_LOADED" ]]; then
      SWIFTTY_BLOCKS_LOADED=1

      __swiftty_mark() { builtin printf '\\e]133;%s\\a' "$1" }

      __swiftty_hex() {
        builtin printf '%s' "$1" | command od -An -v -tx1 | command tr -d ' \\n'
      }

      # zsh hands $? to the *first* precmd hook only; every later hook sees the
      # status of the hook before it. Prompt themes install their own precmd, so
      # we grab the real exit status in a hook forced to the front of the list
      # and emit the marker from one appended to the back — that way the D
      # marker lands immediately before the prompt is drawn.
      __swiftty_capture_status() { __swiftty_status=$?; }

      __swiftty_precmd() {
        if [[ -n "$__swiftty_running" ]]; then
          __swiftty_mark "D;${__swiftty_status:-0}"
          unset __swiftty_running
        fi
        __swiftty_mark "P;$(__swiftty_hex "$PWD")"
        __swiftty_mark "A"
      }

      __swiftty_preexec() {
        __swiftty_running=1
        __swiftty_mark "P;$(__swiftty_hex "$PWD")"
        __swiftty_mark "E;$(__swiftty_hex "$1")"
        __swiftty_mark "C"
      }

      autoload -Uz add-zsh-hook
      precmd_functions=(__swiftty_capture_status $precmd_functions)
      add-zsh-hook precmd __swiftty_precmd
      add-zsh-hook preexec __swiftty_preexec
    fi
    """

    // MARK: - bash

    /// bash does have an extra-rc-file flag, so this one is simple: --rcfile
    /// with a file that sources the user's config and then adds the hooks.
    private static func prepareBash(in directory: URL) -> Injection? {
        let home = shellQuoted(FileManager.default.homeDirectoryForCurrentUser.path)

        // bash only honours --rcfile for interactive *non-login* shells, so we
        // give up login mode and replay what it would have done: /etc/profile
        // (which runs path_helper on macOS) and then the user's own files.
        let rc = """
        [ -f /etc/profile ] && source /etc/profile
        for __swiftty_rc in "\(home)/.bash_profile" "\(home)/.bash_login" "\(home)/.profile"; do
          if [ -f "$__swiftty_rc" ]; then
            source "$__swiftty_rc"
            break
          fi
        done
        [ -f "\(home)/.bashrc" ] && source "\(home)/.bashrc"
        unset __swiftty_rc

        \(bashHooks)
        """

        let url = directory.appendingPathComponent("swiftty.bash")
        do {
            try rc.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        return Injection(
            arguments: ["--rcfile", url.path, "-i"],
            execName: "bash"
        )
    }

    private static let bashHooks = """
    # --- Swiftty blocks (OSC 133 semantic prompt markers) ---
    if [ -z "$SWIFTTY_BLOCKS_LOADED" ]; then
      SWIFTTY_BLOCKS_LOADED=1

      __swiftty_mark() { printf '\\e]133;%s\\a' "$1"; }

      __swiftty_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \\n'; }

      # The DEBUG trap fires before every simple command, not just the ones the
      # user typed — it also sees each part of PROMPT_COMMAND and anything a
      # completion function runs. These guards narrow it to one C marker per
      # real command.
      __swiftty_preexec() {
        [ -n "$COMP_LINE" ] && return 0
        [ -n "$__swiftty_running" ] && return 0
        case "$BASH_COMMAND" in
          __swiftty_*|*__swiftty_precmd*) return 0 ;;
        esac
        __swiftty_running=1
        __swiftty_mark "P;$(__swiftty_hex "$PWD")"
        __swiftty_mark "E;$(__swiftty_hex "$BASH_COMMAND")"
        __swiftty_mark "C"
        return 0
      }

      __swiftty_precmd() {
        local status=$?
        if [ -n "$__swiftty_running" ]; then
          __swiftty_mark "D;$status"
          unset __swiftty_running
        fi
        __swiftty_mark "P;$(__swiftty_hex "$PWD")"
        __swiftty_mark "A"
      }

      # Order matters: install the trap last, or it fires on the assignment
      # below and reports PROMPT_COMMAND itself as the first command.
      PROMPT_COMMAND="__swiftty_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
      trap '__swiftty_preexec' DEBUG
    fi
    """

    // MARK: - Support files

    private static func supportDirectoryURL(tabID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Swiftty-Shell-\(tabID.uuidString)", isDirectory: true)
    }

    private static func makeSupportDirectory(tabID: UUID) -> URL? {
        let url = supportDirectoryURL(tabID: tabID)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Escapes a path for embedding inside a double-quoted shell string.
    private static func shellQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
