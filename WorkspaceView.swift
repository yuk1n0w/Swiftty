import SwiftUI

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let handle = TerminalHandle()
    let currentDirectory: String
    let title: String
    let subtitle: String

    init(currentDirectory: String, ordinal: Int) {
        self.currentDirectory = currentDirectory
        self.title = TerminalSession.displayPath(currentDirectory)
        self.subtitle = ordinal == 1 ? "zsh" : "zsh · session \(ordinal)"
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?

    private let currentDirectory: String

    init(currentDirectory: String) {
        self.currentDirectory = currentDirectory
        addSession()
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    func addSession() {
        let session = TerminalSession(currentDirectory: currentDirectory, ordinal: sessions.count + 1)
        sessions.append(session)
        selectedID = session.id
    }
}

struct WorkspaceView: View {
    @StateObject private var sessionStore: TerminalSessionStore
    @State private var sidebarSearch = ""
    @State private var commandText = ""

    private let workspaceDirectory: String

    init() {
        let project = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Swiftty", isDirectory: true)
        let directory = FileManager.default.fileExists(atPath: project.path)
            ? project.path
            : FileManager.default.homeDirectoryForCurrentUser.path

        self.workspaceDirectory = directory
        _sessionStore = StateObject(wrappedValue: TerminalSessionStore(currentDirectory: directory))
    }

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar(
                sessions: sessionStore.sessions,
                selectedID: $sessionStore.selectedID,
                searchText: $sidebarSearch,
                onNewSession: sessionStore.addSession
            )
            .frame(width: 326)

            Rectangle()
                .fill(Color.swLine)
                .frame(width: 1)

            TerminalWorkspace(
                sessions: sessionStore.sessions,
                selectedID: sessionStore.selectedID,
                commandText: $commandText
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1_000, minHeight: 700)
        .background(Color.swCanvas)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct SessionSidebar: View {
    let sessions: [TerminalSession]
    @Binding var selectedID: UUID?
    @Binding var searchText: String
    let onNewSession: () -> Void

    private var filteredSessions: [TerminalSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.subtitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.swMuted)
                        TextField("Search tabs...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.swText)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .glassEffect(.clear, in: .rect(cornerRadius: 8))

                    SmallIconButton(systemName: "slider.horizontal.3", help: "Filter tabs") { }
                    SmallIconButton(systemName: "plus", help: "New terminal", tint: .swText, action: onNewSession)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .background(Color.swSidebar)

            Rectangle()
                .fill(Color.swLine)
                .frame(height: 1)

            if filteredSessions.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.swDim)
                    Text("No sessions")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.swMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSessions) { session in
                            SessionRow(
                                session: session,
                                selected: selectedID == session.id
                            ) {
                                selectedID = session.id
                                session.handle.focus()
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Color.swSidebar)
    }
}

private struct SessionRow: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.swRaised : Color(hex: 0x202020))
                    Text(">_")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? Color.swMint : Color.swMuted)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(selected ? Color.swText : Color.swMuted)
                        .lineLimit(1)
                    Text(session.subtitle)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(selected ? Color.swMuted : Color.swDim)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .frame(height: 76)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.swRaised.opacity(0.58) : .clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.swLine.opacity(selected ? 0.8 : 0.55))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ifSelectedGlass(selected)
    }
}

private extension View {
    @ViewBuilder
    func ifSelectedGlass(_ selected: Bool) -> some View {
        if selected {
            self.glassEffect(.regular.tint(Color.white.opacity(0.025)), in: .rect(cornerRadius: 8))
        } else {
            self
        }
    }
}

private struct TerminalWorkspace: View {
    let sessions: [TerminalSession]
    let selectedID: UUID?
    @Binding var commandText: String

    private var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                ForEach(sessions) { session in
                    TerminalSurface(
                        currentDirectory: session.currentDirectory,
                        handle: session.handle
                    )
                    .opacity(selectedID == session.id ? 1 : 0.001)
                    .allowsHitTesting(selectedID == session.id)
                    .zIndex(selectedID == session.id ? 1 : 0)
                }
            }
            .background(Color.black)

            if let selectedSession {
                CommandInputBar(
                    commandText: $commandText,
                    session: selectedSession
                ) {
                    selectedSession.handle.send(commandText + "\n")
                    commandText = ""
                }
            }
        }
        .background(Color.black)
    }
}

private struct CommandInputBar: View {
    @Binding var commandText: String
    @ObservedObject var session: TerminalSession
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.swLine)
                .frame(height: 1)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    PromptChip(systemName: nil, text: ">_", tint: .swText)
                    PromptChip(systemName: "folder", text: session.title, tint: .swMuted)
                    PromptChip(systemName: "terminal", text: "zsh", tint: .swMint)

                    TextField("Run a command...", text: $commandText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.swText)
                        .onSubmit(submit)

                    Button(action: submit) {
                        Image(systemName: "return")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.swMuted)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 11)
            }

            HStack(spacing: 5) {
                Text("⌘")
                    .foregroundStyle(Color.swMuted)
                Text("↵")
                    .foregroundStyle(Color.swDim)
                Text("send command to shell")
                    .foregroundStyle(Color.swDim)
                Spacer()
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .padding(.horizontal, 20)
            .padding(.bottom, 13)
            .padding(.top, 7)
        }
        .background(Color.swPanel.opacity(0.96))
    }
}

private struct PromptChip: View {
    let systemName: String?
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .foregroundStyle(tint)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .glassEffect(.clear, in: .rect(cornerRadius: 6))
    }
}
