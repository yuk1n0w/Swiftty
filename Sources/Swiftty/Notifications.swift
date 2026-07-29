import AppKit
import SwiftUI
import UserNotifications

/// Posts native macOS banners for background command completions.
///
/// Best-effort: authorization is asked for once, and every call is guarded so a
/// machine or build where notifications are unavailable (ad-hoc signing, no
/// bundle id) simply gets no banner rather than a crash. The in-app bell is the
/// reliable channel; this is the nicety on top for when the app is hidden.
@MainActor
enum SystemNotifier {
    private static let center: UNUserNotificationCenter? = {
        // `current()` traps if the process has no bundle identifier, which a
        // bare SwiftPM binary run outside a .app does not have.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    private static var requestedAuthorization = false

    static func post(_ notification: SwifttyNotification) {
        guard let center else { return }

        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let content = UNMutableNotificationContent()
        content.title = notification.command
        content.body = notification.detail
        content.sound = notification.isError ? .defaultCritical : .default

        let request = UNNotificationRequest(
            identifier: notification.id.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}

/// The bell in the toolbar: a badge counting unread notifications, opening a
/// popover that lists them and jumps to the tab a command finished in.
struct NotificationBell: View {
    @EnvironmentObject private var store: TerminalStore
    @State private var showing = false

    var body: some View {
        ChromeButton(systemName: "bell", help: "Notifications") {
            showing.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if store.unreadNotificationCount > 0 {
                Text("\(min(store.unreadNotificationCount, 99))")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(Circle().fill(Color.red))
                    .offset(x: 5, y: -3)
                    .allowsHitTesting(false)
            }
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            NotificationList()
                .environmentObject(store)
                .frame(width: 320)
                // Opening the bell is acknowledgement enough to clear the badge.
                .onAppear { store.markAllNotificationsRead() }
        }
        .animation(.easeOut(duration: 0.15), value: store.unreadNotificationCount)
    }
}

private struct NotificationList: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !store.notifications.isEmpty {
                    Button("Clear") { store.clearNotifications() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }

            if store.notifications.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Nothing yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Long or failed commands that finish in a tab you're not watching show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.notifications) { note in
                            NotificationRow(note: note)
                                .onTapGesture { store.revealTab(note.tabID, pane: note.paneID) }
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
    }
}

private struct NotificationRow: View {
    let note: SwifttyNotification
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: note.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(note.isError
                    ? Color(red: 0.94, green: 0.38, blue: 0.42)
                    : Color(red: 0.35, green: 0.78, blue: 0.52))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.command)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    Text(note.detail)
                    if !note.groupName.isEmpty {
                        Text("·")
                        Text(note.groupName)
                    }
                    Text("·")
                    Text(note.relativeLabel)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovered ? Color.white.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
