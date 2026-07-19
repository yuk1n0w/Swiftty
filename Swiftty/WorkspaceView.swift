import SwiftUI

struct WorkspaceView: View {
  @StateObject private var sessionStore: TerminalSessionStore
  @State private var sidebarSearch = ""
  @State private var commandText = ""

  private let workspaceDirectory: String

  init() {
    let project = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Projects/Swiftty", isDirectory: true)
    let directory =
      FileManager.default.fileExists(atPath: project.path)
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
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.subtitle.localizedCaseInsensitiveContains(searchText)
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

          SmallIconButton(systemName: "slider.horizontal.3", help: "Filter tabs") {}
          SmallIconButton(
            systemName: "plus", help: "New terminal", tint: .swText, action: onNewSession)
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

extension View {
  @ViewBuilder
  fileprivate func ifSelectedGlass(_ selected: Bool) -> some View {
    if selected {
      self.glassEffect(.regular.tint(Color.white.opacity(0.025)), in: .rect(cornerRadius: 8))
    } else {
      self
    }
  }
}

private struct SessionWorkspaceView: View {
  @ObservedObject var session: TerminalSession

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 8) {
            Spacer()
            ForEach(session.blocks) { block in
              CommandBlockView(block: block, session: session)
                .id(block.id)
            }
          }
          .frame(minHeight: geometry.size.height - 20, alignment: .bottom)
          .padding(.top, 16)
        }
        .onChange(of: session.blocks) { oldValue, newValue in
          if let lastBlock = newValue.last {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(lastBlock.id, anchor: .bottom)
            }
          }
        }
        .onChange(of: session.scrollTrigger) { oldValue, newValue in
          if let lastBlock = session.blocks.last {
            withAnimation(.easeOut(duration: 0.15)) {
              proxy.scrollTo(lastBlock.id, anchor: .bottom)
            }
          }
        }
        .onChange(of: session.scrollToBlockID) { oldValue, newValue in
          if let target = newValue {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(target.id, anchor: target.anchor == .top ? .top : .bottom)
            }
            session.scrollToBlockID = nil
          }
        }
        .onAppear {
          if let lastBlock = session.blocks.last {
            proxy.scrollTo(lastBlock.id, anchor: .bottom)
          }
        }
      }
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
    VStack(spacing: 0) {
      ZStack {
        ForEach(sessions) { session in
          SessionWorkspaceView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.swCanvas)
            .opacity(selectedID == session.id ? 1 : 0)
            .zIndex(selectedID == session.id ? 1 : 0)
            .allowsHitTesting(selectedID == session.id)
        }
      }
      .background(Color.black)

      if let selectedSession, !selectedSession.blocks.contains(where: { $0.isRunning }) {
        CommandInputBar(
          commandText: $commandText,
          session: selectedSession
        ) {
          let cmd = commandText
          commandText = ""
          selectedSession.runCommand(cmd)
        }
      }
    }
    .background(Color.black)
  }
}
