import AppKit
import Combine
import Foundation
import Security
import SwiftUI
import SwiftTerm

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case terminal
    case models
    case agents
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .terminal: return "Terminal"
        case .models: return "Models"
        case .agents: return "Agents"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .models: return "sparkles"
        case .agents: return "person.2"
        case .about: return "info.circle"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case openRouter = "OpenRouter"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case compatible = "OpenAI Compatible"

    var id: Self { self }

    var isLocal: Bool {
        self == .ollama || self == .lmStudio
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .openRouter:
            return true
        case .ollama, .lmStudio, .compatible:
            return false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .compatible: return "http://localhost:1234/v1"
        }
    }

    var keychainAccount: String {
        "api-key-\(rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let hint: String

    init(_ id: String, _ name: String = "", _ hint: String = "") {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.hint = hint
    }

    var label: String {
        hint.isEmpty ? name : "\(name) · \(hint)"
    }
}

struct AIMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    let role: Role
    /// What the bubble shows. Mutable so a streamed reply can grow token by
    /// token in place.
    var content: String
    /// What is actually sent to the model, when it must differ from what is
    /// shown — e.g. an "Explain" carries a compact label in `content` but the
    /// full command, exit code and output in `sent`. Nil means send `content`.
    var sent: String? = nil

    /// The text the provider should receive for this turn.
    var payload: String { sent ?? content }
}

enum KeychainStore {
    private static let service = "dev.swiftty.terminal"

    static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var selectedSettingsTab: SettingsTab = .general
    @Published var appearance: AppAppearance {
        didSet { persist("appearance", appearance.rawValue) }
    }
    @Published var showHiddenFiles: Bool {
        didSet { persist("showHiddenFiles", showHiddenFiles) }
    }
    @Published var terminalFontSize: Double {
        didSet { persist("terminalFontSize", terminalFontSize) }
    }

    /// Bounds the font can be nudged between with ⌘+/⌘-.
    static let fontSizeRange: ClosedRange<Double> = 9...28
    private static let defaultFontSize: Double = 13

    func adjustFontSize(by delta: Double) {
        terminalFontSize = min(max(terminalFontSize + delta, Self.fontSizeRange.lowerBound),
                               Self.fontSizeRange.upperBound)
    }

    func resetFontSize() {
        terminalFontSize = Self.defaultFontSize
    }
    @Published var terminalCursorBlink: Bool {
        didSet { persist("terminalCursorBlink", terminalCursorBlink) }
    }
    /// How much of the desktop shows through the window, 0.5–1.0.
    @Published var windowOpacity: Double {
        didSet { persist("windowOpacity", windowOpacity) }
    }
    /// Frosts whatever is behind the window instead of showing it sharply.
    @Published var windowBlur: Bool {
        didSet { persist("windowBlur", windowBlur) }
    }
    /// Width of the file explorer, in points.
    @Published var sidebarWidth: Double {
        didSet { persist("sidebarWidth", sidebarWidth) }
    }
    /// Tightens the spacing between blocks to fit more on screen.
    @Published var compactBlocks: Bool {
        didSet { persist("compactBlocks", compactBlocks) }
    }
    /// Routes plainly-worded input in the composer to the AI agent instead of the
    /// shell — Warp-style natural-language detection. Conservative by design: a
    /// real command, or anything prefixed with `!`, still runs as a command.
    @Published var naturalLanguageDetection: Bool {
        didSet { persist("naturalLanguageDetection", naturalLanguageDetection) }
    }

    /// True when the window should let the desktop through at all.
    var isTranslucent: Bool { windowOpacity < 0.99 }
    @Published var shellPath: String {
        didSet { persist("shellPath", shellPath) }
    }

    @Published var selectedProvider: AIProvider {
        didSet { persist("aiProvider", selectedProvider.rawValue) }
    }
    @Published var selectedModelID: String {
        didSet {
            persist("aiModel", selectedModelID)
            persist("aiModel.\(selectedProvider.rawValue)", selectedModelID)
        }
    }
    @Published var baseURL: String {
        didSet { persist("aiBaseURL", baseURL) }
    }
    @Published private(set) var apiKey: String
    @Published var customInstructions: String {
        didSet { persist("customInstructions", customInstructions) }
    }
    @Published var selectedAgent: String {
        didSet { persist("selectedAgent", selectedAgent) }
    }
    @Published private(set) var discoveredModels: [AIModel] = []
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelError: String?

    private var modelDiscoveryGeneration = UUID()
    private static let legacyModelIDs: Set<String> = [
        "gpt-5.6-luna",
        "gpt-5.6-terra",
        "gpt-5.6",
        "claude-sonnet-4-20250514",
        "claude-3-7-sonnet-latest",
        "openai/gpt-4o-mini",
        "anthropic/claude-3.7-sonnet",
        "google/gemini-2.5-flash",
        "llama3.2",
        "qwen2.5-coder",
        "mistral",
        "local-model",
        "custom-model",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        terminalCursorBlink = defaults.object(forKey: "terminalCursorBlink") as? Bool ?? true
        windowOpacity = defaults.object(forKey: "windowOpacity") as? Double ?? 0.75
        windowBlur = defaults.object(forKey: "windowBlur") as? Bool ?? true
        compactBlocks = defaults.object(forKey: "compactBlocks") as? Bool ?? false
        naturalLanguageDetection = defaults.object(forKey: "naturalLanguageDetection") as? Bool ?? true
        sidebarWidth = defaults.object(forKey: "sidebarWidth") as? Double ?? 260
        shellPath = defaults.string(forKey: "shellPath") ?? ShellInfo.path
        let provider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "OpenAI") ?? .openAI
        selectedProvider = provider
        let storedModel = defaults.string(forKey: "aiModel.\(provider.rawValue)")
            ?? defaults.string(forKey: "aiModel")
            ?? ""
        selectedModelID = Self.sanitizedStoredModel(storedModel)
        baseURL = defaults.string(forKey: "aiBaseURL") ?? provider.defaultBaseURL
        apiKey = KeychainStore.read(account: provider.keychainAccount)
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        selectedAgent = defaults.string(forKey: "selectedAgent") ?? "Coder"
    }

    var modelOptions: [AIModel] {
        var options = discoveredModels
        let manualID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualID.isEmpty && !options.contains(where: { $0.id == manualID }) {
            options.insert(AIModel(manualID, manualID, "Manual"), at: 0)
        }
        return options
    }

    var selectedModel: String {
        selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !selectedModel.isEmpty && (!selectedProvider.requiresAPIKey || hasKey)
    }

    func setProvider(_ provider: AIProvider) {
        selectedProvider = provider
        let storedModel = defaults.string(forKey: "aiModel.\(provider.rawValue)") ?? ""
        selectedModelID = Self.sanitizedStoredModel(storedModel)
        baseURL = provider.defaultBaseURL
        apiKey = KeychainStore.read(account: provider.keychainAccount)
        discoveredModels = []
        modelError = nil
        Task { await refreshModels() }
    }

    func setAPIKey(_ value: String) {
        apiKey = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.delete(account: selectedProvider.keychainAccount)
        } else {
            KeychainStore.write(value, account: selectedProvider.keychainAccount)
        }
    }

    func refreshModels() async {
        let generation = UUID()
        modelDiscoveryGeneration = generation
        modelsLoading = true
        modelError = nil

        do {
            let models = try await AIGateway.listModels(
                provider: selectedProvider,
                apiKey: apiKey,
                baseURL: baseURL
            )
            guard generation == modelDiscoveryGeneration else { return }
            discoveredModels = models
        } catch {
            guard generation == modelDiscoveryGeneration else { return }
            discoveredModels = []
            modelError = error.localizedDescription
        }

        if generation == modelDiscoveryGeneration {
            modelsLoading = false
        }
    }

    private static func sanitizedStoredModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyModelIDs.contains(trimmed) ? "" : trimmed
    }

    func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }
}

enum AIGatewayError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an API key in Settings → Models first."
        case .missingModel: return "Choose or enter a model ID in Settings → Models first."
        case .invalidResponse: return "The provider returned an unreadable response."
        case .server(let message): return message
        }
    }
}

enum AIGateway {
    static func listModels(
        provider: AIProvider,
        apiKey: String,
        baseURL: String
    ) async throws -> [AIModel] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.requiresAPIKey || !trimmedKey.isEmpty else {
            throw AIGatewayError.missingAPIKey
        }

        let endpoint: URL
        if provider == .ollama {
            endpoint = try ollamaModelsURL(baseURL)
        } else {
            endpoint = try endpointURL(baseURL, path: "models")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if !trimmedKey.isEmpty {
            if provider == .anthropic {
                request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let models = try parseModels(data)
        guard !models.isEmpty else {
            throw AIGatewayError.server("The provider returned no models. Enter the exact model ID manually.")
        }
        return models
    }

    /// Streams a completion, delivering the reply one chunk at a time through
    /// `onDelta`, so the panel can grow the answer as it arrives instead of
    /// waiting for the whole thing. `onDelta` may be called from a background
    /// executor; the caller marshals to the main actor.
    static func stream(
        provider: AIProvider,
        model: String,
        apiKey: String,
        baseURL: String,
        agent: String,
        customInstructions: String,
        messages: [AIMessage],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        guard !provider.requiresAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGatewayError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGatewayError.missingModel
        }

        if provider == .anthropic {
            try await streamAnthropic(
                model: model,
                apiKey: apiKey,
                baseURL: baseURL,
                agent: agent,
                customInstructions: customInstructions,
                messages: messages,
                onDelta: onDelta
            )
            return
        }

        let endpoint = try endpointURL(baseURL, path: "chat/completions")
        var requestMessages: [[String: String]] = messages.map {
            ["role": $0.role.rawValue, "content": $0.payload]
        }
        let systemPrompt = systemPrompt(agent: agent, customInstructions: customInstructions)
        if !systemPrompt.isEmpty {
            requestMessages.insert(["role": "system", "content": systemPrompt], at: 0)
        }

        func send(includeTemperature: Bool) async throws {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            var payload: [String: Any] = [
                "model": model,
                "messages": requestMessages,
                "stream": true,
            ]
            // A slightly focused temperature gives steadier answers, but the
            // gpt-5 and o-series models reject any value but the default — the
            // caller retries without this key when that happens.
            if includeTemperature { payload["temperature"] = 0.4 }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            try await validateStream(response: response, bytes: bytes)

            for try await line in bytes.lines {
                guard let json = eventData(line) else { continue }
                if json == "[DONE]" { break }
                guard let data = json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String,
                      !piece.isEmpty else { continue }
                onDelta(piece)
            }
        }

        do {
            try await send(includeTemperature: true)
        } catch let AIGatewayError.server(message)
            where message.localizedCaseInsensitiveContains("temperature") {
            // This model only supports the default temperature; resend without
            // it rather than surface the failure to the user.
            try await send(includeTemperature: false)
        }
    }

    private static func streamAnthropic(
        model: String,
        apiKey: String,
        baseURL: String,
        agent: String,
        customInstructions: String,
        messages: [AIMessage],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let endpoint = try endpointURL(baseURL, path: "messages")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let systemPrompt = systemPrompt(agent: agent, customInstructions: customInstructions)
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.payload] },
        ]
        if !systemPrompt.isEmpty { payload["system"] = systemPrompt }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validateStream(response: response, bytes: bytes)

        for try await line in bytes.lines {
            guard let json = eventData(line),
                  let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["type"] as? String) == "content_block_delta",
                  let delta = root["delta"] as? [String: Any],
                  let text = delta["text"] as? String,
                  !text.isEmpty else { continue }
            onDelta(text)
        }
    }

    /// The JSON payload of a server-sent-event `data:` line, or nil for the
    /// blank lines and `event:` lines that separate events.
    private static func eventData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    /// A streamed request never gets to `validate`, because the body arrives as
    /// a byte stream rather than one `Data`. On an error status the body still
    /// carries the provider's JSON error, so drain it and surface the message.
    private static func validateStream(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw AIGatewayError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (payload?["error"] as? [String: Any])?["message"] as? String
        throw AIGatewayError.server(message ?? "The provider returned an HTTP error.")
    }

    private static func endpointURL(_ baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/\(path)") else { throw AIGatewayError.invalidResponse }
        return url
    }

    private static func ollamaModelsURL(_ baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var url = URL(string: trimmed) else { throw AIGatewayError.invalidResponse }
        if url.path.hasSuffix("/v1") {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("api/tags")
    }

    private static func parseModels(_ data: Data) throws -> [AIModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIGatewayError.invalidResponse
        }

        let rows = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        let IDs = rows.compactMap { row in
            (row["id"] as? String)
                ?? (row["name"] as? String)
                ?? (row["model"] as? String)
        }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return IDs
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { AIModel($0, $0) }
    }

    private static func systemPrompt(agent: String, customInstructions: String) -> String {
        var parts = [personaPrompt(agent)]
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.joined(separator: "\n\n")
    }

    /// Each persona is a genuinely different instruction, not a relabelled
    /// default — the Coder is told to emit runnable fenced commands (which the
    /// panel then turns into Insert/Copy actions), the Reviewer to hunt risk,
    /// the Architect to reason about design.
    static func personaPrompt(_ agent: String) -> String {
        switch agent {
        case "Reviewer":
            return "You are a code reviewer working inside Swiftty, a terminal. Scrutinise "
                + "commands, diffs and command output for bugs, security risks and bad practice. "
                + "Flag anything destructive or irreversible before anything else. Be concise and specific."
        case "Architect":
            return "You are a software architect working inside Swiftty, a terminal. Favour design, "
                + "trade-offs and the overall shape of a solution over line-by-line detail. Weigh "
                + "maintainability and the bigger picture, and say plainly when a simpler approach is better."
        case "Custom":
            return "You are a helpful assistant inside Swiftty, a terminal. Be concise, practical, and honest."
        default: // Coder
            return "You are a coding assistant working inside Swiftty, a terminal. Help write, debug "
                + "and run shell commands and code. Whenever you propose a command to run, put the exact "
                + "command in its own fenced code block so it can be run directly. Be concise, practical, and honest."
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = (payload?["error"] as? [String: Any])?["message"] as? String
            throw AIGatewayError.server(error ?? "The provider returned an HTTP error.")
        }
    }
}

extension Notification.Name {
    static let swifttyOpenSettings = Notification.Name("SwifttyOpenSettings")
}

@MainActor
enum SettingsCoordinator {
    private static var preferences: AppPreferences?
    private static var store: TerminalStore?
    private static var settingsWindow: NSWindow?

    static func configure(preferences: AppPreferences, store: TerminalStore) {
        self.preferences = preferences
        self.store = store
    }

    static func open(tab: SettingsTab) {
        guard let preferences, let store else { return }
        preferences.selectedSettingsTab = tab
        NotificationCenter.default.post(name: .swifttyOpenSettings, object: tab)

        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(preferences)
                .environmentObject(store)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 590))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SwifttyCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Settings…") {
                SettingsCoordinator.open(tab: .general)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// Terminals now outlive their SwiftUI views (see `TerminalRegistry`), so on
/// quit nothing else would reap them — this kills every remaining shell so none
/// are orphaned.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { TerminalRegistry.shared.terminateAll() }
    }
}

@main
struct SwifttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: AppPreferences
    @StateObject private var store: TerminalStore

    init() {
        let preferences = AppPreferences()
        let store = TerminalStore(preferences: preferences)
        _preferences = StateObject(wrappedValue: preferences)
        _store = StateObject(wrappedValue: store)
        SettingsCoordinator.configure(preferences: preferences, store: store)
    }

    var body: some Scene {
        WindowGroup {
            TerminalWorkspace()
                .environmentObject(store)
                .environmentObject(preferences)
                .frame(minWidth: 860, minHeight: 540)
                .ignoresSafeArea(.container, edges: .top)
        }
        // Drops the title bar so the tab strip becomes the top of the window.
        // The traffic lights stay, floating over the chrome row, which is why
        // that row carries a leading inset wide enough to clear them.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                // "+" is Shift-"=", so binding "+" alone would demand Shift.
                // Binding the bare "=" as well means ⌘= works without it — the
                // way every browser and editor lets you zoom.
                Button("Increase Text Size") {
                    preferences.adjustFontSize(by: 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Increase Text Size") {
                    preferences.adjustFontSize(by: 1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Text Size") {
                    preferences.adjustFontSize(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Text Size") {
                    preferences.resetFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    store.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Split Right") {
                    store.splitActivePane(.row)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Split Down") {
                    store.splitActivePane(.column)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Focus Next Pane") {
                    store.selectRelativePane(by: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled((store.activeTab?.panes.count ?? 0) < 2)

                Button("Focus Previous Pane") {
                    store.selectRelativePane(by: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled((store.activeTab?.panes.count ?? 0) < 2)

                Button("Focus Pane Left") { store.focusPane(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled((store.activeTab?.panes.count ?? 0) < 2)
                Button("Focus Pane Right") { store.focusPane(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled((store.activeTab?.panes.count ?? 0) < 2)
                Button("Focus Pane Up") { store.focusPane(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled((store.activeTab?.panes.count ?? 0) < 2)
                Button("Focus Pane Down") { store.focusPane(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled((store.activeTab?.panes.count ?? 0) < 2)

                Button("Move Pane to New Tab") {
                    if let paneID = store.activePaneID { store.popPaneToTab(paneID) }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled((store.activeTab?.panes.count ?? 0) < 2)

                Button("Balance Panes") { store.balanceActivePaneSplits() }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                    .disabled((store.activeTab?.panes.count ?? 0) < 2)

                Button("Select Tab 1") { store.select(index: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(store.tabs.count < 1)
                Button("Select Tab 2") { store.select(index: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(store.tabs.count < 2)
                Button("Select Tab 3") { store.select(index: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(store.tabs.count < 3)
                Button("Select Tab 4") { store.select(index: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(store.tabs.count < 4)
                Button("Select Tab 5") { store.select(index: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                    .disabled(store.tabs.count < 5)
                Button("Select Tab 6") { store.select(index: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                    .disabled(store.tabs.count < 6)
                Button("Select Tab 7") { store.select(index: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                    .disabled(store.tabs.count < 7)
                Button("Select Tab 8") { store.select(index: 7) }
                    .keyboardShortcut("8", modifiers: .command)
                    .disabled(store.tabs.count < 8)
                Button("Select Tab 9") { store.select(index: 8) }
                    .keyboardShortcut("9", modifiers: .command)
                    .disabled(store.tabs.count < 9)

                Button("Next Tab") {
                    store.selectRelativeTab(by: 1)
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("Previous Tab") {
                    store.selectRelativeTab(by: -1)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

                Button("Close Pane") {
                    store.closeActivePane()
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close Tab") {
                    store.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button("New Group") { store.newGroup() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Next Group") { store.selectRelativeGroup(by: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(store.groups.count < 2)
                Button("Previous Group") { store.selectRelativeGroup(by: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(store.groups.count < 2)

                Button("Toggle AI Agent") {
                    store.toggleAIPanel()
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Command Palette") {
                    store.toggleCommandPalette()
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Toggle File Explorer") {
                    store.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Enable Blocks in This Session") {
                    store.activeBlockTracker?.warpifySession()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Find in Blocks") {
                    store.beginSearch()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Clear Blocks") {
                    store.clearBlocks()
                }
                // Not plain Cmd-Delete: that is the standard "delete to start of
                // line" every text field uses, and a menu key-equivalent would
                // swallow it before the composer or the AI field ever saw it.
                .keyboardShortcut(.delete, modifiers: [.command, .shift])

                Button("Reset Terminal") {
                    store.resetActiveTerminal()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Previous Block") {
                    store.stepBlockSelection(by: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Next Block") {
                    store.stepBlockSelection(by: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Copy Block Output") {
                    store.copySelectedBlockOutput()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            SwifttyCommands()
        }
        .windowToolbarStyle(.unifiedCompact)

    }
}

@MainActor
final class TerminalStore: ObservableObject {
    /// Tabs are organised into named groups. Every group keeps its own tabs and
    /// its own active tab, and switching groups only changes which is on screen
    /// — every tab across every group stays mounted so no shell is ever killed
    /// by a group switch.
    @Published private(set) var groups: [TabGroup]
    @Published private(set) var activeGroupID: TabGroup.ID
    @Published var sidebarVisible = true
    @Published var aiPanelVisible = false
    /// Filters the block history. Empty shows everything.
    @Published var searchQuery = ""
    /// The find bar is only on screen while searching.
    @Published var searchVisible = false
    /// Bumped by ⌘F to pull focus into the search field.
    @Published var searchFocusRequests = 0
    /// Which match Return has stepped to. Wrapped against the match count.
    @Published var searchMatchIndex = 0
    /// The ⌘K command palette overlay is only on screen while true.
    @Published var commandPaletteVisible = false
    /// Bumped each time the palette opens, to pull focus into its search field.
    @Published var paletteFocusRequests = 0
    @Published private(set) var aiMessages: [AIMessage] = []
    @Published private(set) var aiSending = false
    /// The in-flight streaming reply, if any — cancelled by Stop.
    private var aiStreamTask: Task<Void, Never>?
    /// A command the AI panel wants dropped into the composer for review. The
    /// active tab's `BlockStack` picks it up, fills its input, and clears it.
    @Published var composerInjection: String?

    /// Notifications raised when a command finishes in a tab the user was not
    /// watching, newest first.
    @Published private(set) var notifications: [SwifttyNotification] = []

    /// Commands shorter than this don't notify — you were probably watching.
    private static let notifyThreshold: TimeInterval = 6
    private static let maxNotifications = 100

    var unreadNotificationCount: Int {
        notifications.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }

    /// One block tracker per tab, kept here so the panel and the terminal view
    /// share the same one and it outlives SwiftUI view updates.
    ///
    /// Deliberately not `@Published`: views observe individual trackers, and
    /// publishing the dictionary would fire while a view body is reading it.
    private var blockTrackers: [TerminalTab.ID: BlockTracker] = [:]

    /// Saves the tab layout a beat after it changes. Debounced so a burst of
    /// mutations (opening several tabs, a directory walk) writes once.
    private var sessionCancellable: AnyCancellable?
    private static let sessionKey = "session.v2"

    /// Persists the AI conversation a beat after it changes, so it survives a
    /// relaunch. Debounced for the same reason the layout is.
    private var aiChatCancellable: AnyCancellable?
    private static let aiChatKey = "ai.chat.v1"
    private static let maxStoredAIMessages = 200

    let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences

        if let session = Self.loadSession() {
            let restored = session.groups.map { group -> TabGroup in
                let tabs = group.tabs.map { pt -> TerminalTab in
                    let panes = pt.panes.map {
                        Pane(id: $0.id, title: $0.title, directory: $0.directory)
                    }
                    return TerminalTab(
                        id: pt.id,
                        panes: panes,
                        layout: pt.layout,
                        activePaneID: pt.activePaneID
                    )
                }
                // A saved active tab that somehow no longer exists falls back to
                // the group's first, so no group is left pointing at nothing.
                let active = tabs.contains { $0.id == group.activeTabID }
                    ? group.activeTabID
                    : tabs[0].id
                return TabGroup(id: group.id, name: group.name, tabs: tabs, activeTabID: active)
            }
            groups = restored
            activeGroupID = restored.contains { $0.id == session.activeGroupID }
                ? session.activeGroupID
                : restored[0].id
            for pane in restored.flatMap(\.tabs).flatMap(\.panes) { makeTracker(for: pane.id) }
        } else {
            let initialTab = TerminalTab()
            let group = TabGroup(name: "Default", tabs: [initialTab], activeTabID: initialTab.id)
            groups = [group]
            activeGroupID = group.id
            for pane in initialTab.panes { makeTracker(for: pane.id) }
        }

        aiMessages = Self.loadAIChat()
        startPersistingSession()
    }

    /// Creates a pane's tracker and wires it to raise notifications when a
    /// command finishes there. Every tracker is born through here so the
    /// notification hook is never forgotten at a call site.
    @discardableResult
    private func makeTracker(for paneID: Pane.ID) -> BlockTracker {
        let tracker = BlockTracker()
        tracker.onCommandFinished = { [weak self] block in
            self?.handleFinishedCommand(block, paneID: paneID)
        }
        blockTrackers[paneID] = tracker
        return tracker
    }

    // MARK: - Session persistence

    private func startPersistingSession() {
        sessionCancellable = Publishers.CombineLatest($groups, $activeGroupID)
            // Persists the current layout a beat after any change — and once
            // shortly after launch, so even an untouched single-tab window is on
            // disk to be restored. Re-writing the just-restored state is
            // idempotent, so there is no need to skip the initial value.
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistSession() }

        aiChatCancellable = $aiMessages
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistAIChat() }
    }

    private func persistAIChat() {
        // Drop an empty assistant bubble left behind if the app quit before the
        // first token streamed in — restoring it would show a reply that never
        // finishes. Then keep only the tail so a long conversation cannot grow
        // the stored blob without bound.
        let cleaned = aiMessages.filter { !($0.role == .assistant && $0.content.isEmpty) }
        let recent = Array(cleaned.suffix(Self.maxStoredAIMessages))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        UserDefaults.standard.set(data, forKey: Self.aiChatKey)
    }

    private static func loadAIChat() -> [AIMessage] {
        guard let data = UserDefaults.standard.data(forKey: aiChatKey),
              let messages = try? JSONDecoder().decode([AIMessage].self, from: data)
        else { return [] }
        return messages
    }

    private func persistSession() {
        let session = PersistedSession(
            activeGroupID: activeGroupID,
            groups: groups.map { group in
                PersistedGroup(
                    id: group.id,
                    name: group.name,
                    activeTabID: group.activeTabID,
                    tabs: group.tabs.map { tab in
                        PersistedTab(
                            id: tab.id,
                            activePaneID: tab.activePaneID,
                            panes: tab.panes.map {
                                PersistedPane(id: $0.id, title: $0.title, directory: $0.directory)
                            },
                            layout: tab.layout
                        )
                    }
                )
            }
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionKey)
    }

    private static func loadSession() -> PersistedSession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              var session = try? JSONDecoder().decode(PersistedSession.self, from: data)
        else { return nil }
        // Drop any tab that saved without panes, then any group left without
        // tabs — restoring either would leave something that can never be shown
        // and would crash the `[0]` fallbacks.
        for index in session.groups.indices {
            session.groups[index].tabs.removeAll { $0.panes.isEmpty }
        }
        session.groups.removeAll { $0.tabs.isEmpty }
        return session.groups.isEmpty ? nil : session
    }

    // MARK: - Tabs (scoped to the active group)

    /// Tabs of the group currently on screen. The tab strip shows these.
    var tabs: [TerminalTab] { activeGroup?.tabs ?? [] }

    /// The tab currently on screen — the active group's active tab.
    var activeTabID: TerminalTab.ID { activeGroup?.activeTabID ?? UUID() }

    /// Every tab across every group. The workspace mounts all of these so a
    /// group switch never tears a terminal (and its shell) down.
    var allTabs: [TerminalTab] { groups.flatMap(\.tabs) }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    private var activeGroup: TabGroup? {
        groups.first { $0.id == activeGroupID }
    }

    private func mutateActiveGroup(_ body: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        body(&groups[index])
    }

    /// Mutates the tab with `id`, wherever it lives.
    private func withTab(_ id: TerminalTab.ID, _ body: (inout TerminalTab) -> Void) {
        for groupIndex in groups.indices {
            if let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == id }) {
                body(&groups[groupIndex].tabs[tabIndex])
                return
            }
        }
    }

    /// Mutates the pane with `id`, wherever it lives.
    private func withPane(_ id: Pane.ID, _ body: (inout Pane) -> Void) {
        for groupIndex in groups.indices {
            for tabIndex in groups[groupIndex].tabs.indices {
                if let paneIndex = groups[groupIndex].tabs[tabIndex].panes.firstIndex(where: { $0.id == id }) {
                    body(&groups[groupIndex].tabs[tabIndex].panes[paneIndex])
                    return
                }
            }
        }
    }

    /// Where a pane lives, as indices into `groups` and its tab's `tabs`.
    private func paneLocation(_ id: Pane.ID) -> (group: Int, tab: Int)? {
        for groupIndex in groups.indices {
            for tabIndex in groups[groupIndex].tabs.indices
            where groups[groupIndex].tabs[tabIndex].panes.contains(where: { $0.id == id }) {
                return (groupIndex, tabIndex)
            }
        }
        return nil
    }

    func newTab() {
        // Open where the current tab is, the way a new tab in any terminal does.
        // A remote or deleted directory is caught at spawn and falls back home.
        let pane = Pane(directory: activeTab?.directory ?? ShellInfo.homePath)
        let tab = TerminalTab(pane: pane)
        makeTracker(for: pane.id)
        mutateActiveGroup {
            $0.tabs.append(tab)
            $0.activeTabID = tab.id
        }
    }

    func select(_ tabID: TerminalTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        mutateActiveGroup { $0.activeTabID = tabID }
    }

    /// Cycles tabs within the active group, wrapping at either end.
    func selectRelativeTab(by offset: Int) {
        let tabs = self.tabs
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = (current + offset + tabs.count) % tabs.count
        mutateActiveGroup { $0.activeTabID = tabs[next].id }
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        let id = tabs[index].id
        mutateActiveGroup { $0.activeTabID = id }
    }

    // MARK: - Groups

    var activeGroupName: String { activeGroup?.name ?? "Default" }

    func newGroup() {
        let tab = TerminalTab()
        for pane in tab.panes { makeTracker(for: pane.id) }
        let group = TabGroup(
            name: "Group \(groups.count + 1)",
            tabs: [tab],
            activeTabID: tab.id
        )
        groups.append(group)
        activeGroupID = group.id
    }

    // MARK: - Panes (splits)

    /// The pane taking input in the active tab.
    var activePaneID: Pane.ID? { activeTab?.activePaneID }

    /// The tracker for a specific pane.
    func paneTracker(_ paneID: Pane.ID) -> BlockTracker { blockTracker(for: paneID) }

    /// Makes a pane the one that takes input within its tab.
    func focusPane(_ paneID: Pane.ID) {
        guard let loc = paneLocation(paneID),
              groups[loc.group].tabs[loc.tab].activePaneID != paneID else { return }
        groups[loc.group].tabs[loc.tab].activePaneID = paneID
    }

    /// Splits the active tab's focused pane, opening a new shell beside it in the
    /// same directory and moving focus to it.
    func splitActivePane(_ axis: SplitAxis) {
        guard let tab = activeTab, let loc = paneLocation(tab.activePaneID) else { return }
        let inheritDir = tab.activePane?.directory ?? ShellInfo.homePath
        let pane = Pane(directory: inheritDir)
        makeTracker(for: pane.id)
        groups[loc.group].tabs[loc.tab].panes.append(pane)
        groups[loc.group].tabs[loc.tab].layout =
            groups[loc.group].tabs[loc.tab].layout.splitting(tab.activePaneID, with: pane.id, axis: axis)
        groups[loc.group].tabs[loc.tab].activePaneID = pane.id
    }

    /// Closes the focused pane; if it was the tab's only pane, closes the tab.
    func closeActivePane() {
        guard let paneID = activePaneID else { return }
        closePane(paneID)
    }

    func closePane(_ paneID: Pane.ID) {
        guard let loc = paneLocation(paneID) else { return }
        // The tab's last pane: fall back to closing the whole tab (which handles
        // the last-tab-closes-the-window case too).
        guard groups[loc.group].tabs[loc.tab].panes.count > 1 else {
            close(groups[loc.group].tabs[loc.tab].id)
            return
        }
        TerminalRegistry.shared.terminate(paneID)
        blockTrackers.removeValue(forKey: paneID)
        ShellIntegration.cleanUp(tabID: paneID)
        var tab = groups[loc.group].tabs[loc.tab]
        let collapsed = tab.layout.removing(paneID) ?? tab.layout
        tab.panes.removeAll { $0.id == paneID }
        tab.layout = collapsed
        if tab.activePaneID == paneID {
            tab.activePaneID = collapsed.paneIDs.first ?? tab.panes[0].id
        }
        groups[loc.group].tabs[loc.tab] = tab
    }

    /// Moves focus to the next/previous pane within the active tab, wrapping.
    func selectRelativePane(by offset: Int) {
        guard let tab = activeTab else { return }
        let order = tab.layout.paneIDs
        guard order.count > 1, let current = order.firstIndex(of: tab.activePaneID) else { return }
        focusPane(order[(current + offset + order.count) % order.count])
    }

    /// Explodes a split tab into one tab per pane, in reading order, keeping every
    /// shell alive — the panes keep their ids (and trackers), so the flat pane
    /// mount just re-homes their terminals rather than rebuilding them.
    func breakUpTab(_ tabID: TerminalTab.ID) {
        guard let groupIndex = groups.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = groups[groupIndex].tabs[tabIndex]
        guard tab.panes.count > 1 else { return }

        let ordered = tab.layout.paneIDs.compactMap { id in tab.panes.first { $0.id == id } }
        guard !ordered.isEmpty else { return }
        // The first pane keeps this tab's id so the tab you right-clicked stays
        // put; the rest each become a fresh single-pane tab after it.
        let newTabs = ordered.enumerated().map { index, pane in
            TerminalTab(id: index == 0 ? tab.id : UUID(), pane: pane)
        }
        groups[groupIndex].tabs.replaceSubrange(tabIndex...tabIndex, with: newTabs)
        // Keep focus on the pane that was active before the break-up.
        groups[groupIndex].activeTabID =
            newTabs.first { $0.activePaneID == tab.activePaneID }?.id ?? newTabs[0].id
    }

    /// Detaches one pane into its own new tab, right after the tab it came from,
    /// keeping its shell alive — the pane keeps its id (and tracker), so the flat
    /// pane mount just re-homes its terminal rather than rebuilding it.
    func popPaneToTab(_ paneID: Pane.ID) {
        guard let loc = paneLocation(paneID) else { return }
        // A pane that is already alone is already its own tab.
        guard groups[loc.group].tabs[loc.tab].panes.count > 1,
              let pane = groups[loc.group].tabs[loc.tab].panes.first(where: { $0.id == paneID })
        else { return }

        var source = groups[loc.group].tabs[loc.tab]
        let collapsed = source.layout.removing(paneID) ?? source.layout
        source.panes.removeAll { $0.id == paneID }
        source.layout = collapsed
        if source.activePaneID == paneID {
            source.activePaneID = collapsed.paneIDs.first ?? source.panes[0].id
        }
        groups[loc.group].tabs[loc.tab] = source

        let newTab = TerminalTab(pane: pane)
        groups[loc.group].tabs.insert(newTab, at: loc.tab + 1)
        groups[loc.group].activeTabID = newTab.id
    }

    /// Resets every split in the active tab to an even 50/50.
    func balanceActivePaneSplits() {
        guard let tab = activeTab, tab.isSplit, let loc = paneLocation(tab.activePaneID) else { return }
        groups[loc.group].tabs[loc.tab].layout = groups[loc.group].tabs[loc.tab].layout.balanced()
    }

    enum FocusDirection { case left, right, up, down }

    /// Moves focus to the nearest pane in a direction, by geometry rather than
    /// tree order, so Cmd-Opt-arrows feel like moving around the visible grid.
    func focusPane(_ direction: FocusDirection) {
        guard let tab = activeTab, tab.isSplit else { return }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let leaves = PaneLayout.compute(tab.layout, in: unit).leaves
        guard let from = leaves[tab.activePaneID] else { return }

        var best: (id: UUID, score: CGFloat)?
        for (id, rect) in leaves where id != tab.activePaneID {
            // Must lie in the requested direction.
            let ahead: Bool
            switch direction {
            case .left:  ahead = rect.midX < from.midX
            case .right: ahead = rect.midX > from.midX
            case .up:    ahead = rect.midY < from.midY
            case .down:  ahead = rect.midY > from.midY
            }
            guard ahead else { continue }
            // Prefer panes that overlap on the perpendicular axis (directly
            // beside/above), then the nearest by centre distance.
            let overlaps: Bool
            switch direction {
            case .left, .right: overlaps = rect.minY < from.maxY && rect.maxY > from.minY
            case .up, .down:    overlaps = rect.minX < from.maxX && rect.maxX > from.minX
            }
            let dx = rect.midX - from.midX, dy = rect.midY - from.midY
            let distance = (dx * dx + dy * dy).squareRoot()
            let score = distance + (overlaps ? 0 : 10)
            if best == nil || score < best!.score { best = (id, score) }
        }
        if let best { focusPane(best.id) }
    }

    /// Nudges a split divider (identified by its path in the tab's layout tree) by
    /// `delta` points along `total`, the dimension it slides within.
    func adjustSplit(in tabID: TerminalTab.ID, path: [Int], delta: CGFloat, total: CGFloat) {
        guard total > 0, let groupIndex = groups.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }),
              let current = groups[groupIndex].tabs[tabIndex].layout.fraction(at: path) else { return }
        let next = current + Double(delta / total)
        groups[groupIndex].tabs[tabIndex].layout =
            groups[groupIndex].tabs[tabIndex].layout.settingFraction(next, at: path)
    }

    func selectGroup(_ id: TabGroup.ID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        activeGroupID = id
    }

    /// Cycles groups, wrapping at either end.
    func selectRelativeGroup(by offset: Int) {
        guard groups.count > 1,
              let current = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        activeGroupID = groups[(current + offset + groups.count) % groups.count].id
    }

    func renameGroup(_ id: TabGroup.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
    }

    /// Closes a whole group and every shell in it. The last group is kept.
    func closeGroup(_ id: TabGroup.ID) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        for pane in groups[index].tabs.flatMap(\.panes) {
            TerminalRegistry.shared.terminate(pane.id)
            blockTrackers.removeValue(forKey: pane.id)
            ShellIntegration.cleanUp(tabID: pane.id)
        }
        groups.remove(at: index)
        if activeGroupID == id {
            activeGroupID = groups[min(index, groups.count - 1)].id
        }
    }

    func beginSearch() {
        searchVisible = true
        searchFocusRequests += 1
    }

    func endSearch() {
        searchVisible = false
        searchQuery = ""
        searchMatchIndex = 0
    }

    /// Return in the search field steps to the next match.
    func advanceSearchMatch(by offset: Int = 1) {
        searchMatchIndex += offset
    }

    /// ⌘K. Toggles the command palette, always opening onto an empty query.
    func toggleCommandPalette() {
        if commandPaletteVisible {
            commandPaletteVisible = false
        } else {
            commandPaletteVisible = true
            paletteFocusRequests += 1
        }
    }

    func closeCommandPalette() {
        commandPaletteVisible = false
    }

    /// Runs a command chosen from the palette in the active pane, exactly as if
    /// it had been typed and submitted there.
    func runFromPalette(_ command: String) {
        commandPaletteVisible = false
        activeBlockTracker?.submit(command)
    }

    /// The active pane's past commands, most recent first — the palette's history
    /// section. Empty when no pane is focused yet.
    var paletteHistory: [HistoryEntry] {
        activeBlockTracker?.commandHistory ?? []
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func toggleAIPanel() {
        aiPanelVisible.toggle()
    }

    /// The tracker for a pane. Trackers are created alongside their pane, so the
    /// fallback here only ever fires for a pane that has already been closed.
    func blockTracker(for paneID: Pane.ID) -> BlockTracker {
        blockTrackers[paneID] ?? BlockTracker()
    }

    var activeBlockTracker: BlockTracker? {
        activePaneID.flatMap { blockTrackers[$0] }
    }

    /// Wipes the active tab's block history.
    func clearBlocks() {
        activeBlockTracker?.clearHistory()
    }

    /// Repairs the active terminal's emulator state (⇧⌘K) without touching a
    /// running program.
    func resetActiveTerminal() {
        activeBlockTracker?.resetTerminal()
    }

    /// Runs `cd` into a directory in the active pane — the file explorer's
    /// double-click. Single-quoted (with any inner quote escaped) so paths with
    /// spaces or other metacharacters are one argument. Works over SSH too, since
    /// the path is the remote path the explorer is showing.
    func changeActiveDirectory(to path: String) {
        guard let tracker = activeBlockTracker else { return }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        tracker.submit("cd " + quoted)
    }

    /// Moves the block selection in the active tab. `offset` is -1 for the
    /// previous block, +1 for the next.
    func stepBlockSelection(by offset: Int) {
        activeBlockTracker?.moveSelection(by: offset)
    }

    /// Copies the selected block's output, falling back to the most recent
    /// finished block when nothing is selected.
    func copySelectedBlockOutput() {
        guard let tracker = activeBlockTracker else { return }
        let block = tracker.selectedBlock
            ?? tracker.blocks.last { !$0.command.isEmpty }
        guard let block else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tracker.plainOutput(for: block), forType: .string)
    }

    func clearAIChat() {
        aiMessages.removeAll()
    }

    func sendAI(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A free-text question gets a snapshot of the terminal stapled to it so
        // the model answers for *this* machine and directory. The bubble still
        // shows only what the user typed; the context rides along in `sent`.
        let context = terminalContextBlock()
        let sent = context.isEmpty ? nil : context + "\n\nUser:\n" + trimmed
        await sendAIMessage(AIMessage(role: .user, content: trimmed, sent: sent))
    }

    /// The composer detected a natural-language request: open the agent panel
    /// and send it there instead of the shell.
    func sendAIFromComposer(_ prompt: String) {
        aiPanelVisible = true
        Task { await sendAI(prompt) }
    }

    /// Stops an in-flight reply, keeping whatever streamed in so far.
    func stopAI() {
        aiStreamTask?.cancel()
        aiStreamTask = nil
        aiSending = false
    }

    /// A compact snapshot of the active session — where it is, whether it is
    /// remote, and what was run lately — so the agent's answers are grounded in
    /// the real terminal rather than generic. Empty when there is no session.
    private func terminalContextBlock() -> String {
        guard let tracker = activeBlockTracker else { return "" }
        var lines = ["[Terminal context — background for you; the user did not type this.]"]
        if let host = tracker.subshell {
            lines.append("Session: connected to a remote/subshell session named \"\(host)\".")
        } else {
            lines.append("Session: local shell on macOS (\(Self.osVersionString)).")
        }
        lines.append("Working directory: \(tracker.currentDirectory)")
        if let branch = tracker.gitBranch, !branch.isEmpty {
            lines.append("Git branch: \(branch)")
        }
        let recent = tracker.commandHistory.prefix(6).map { "- \($0.command)" }
        if !recent.isEmpty {
            lines.append("Recent commands (most recent first):")
            lines.append(contentsOf: recent)
        }
        return lines.joined(separator: "\n")
    }

    private static let osVersionString: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }()

    /// Sends one already-built user message and streams the reply in place.
    /// Shared by the free-text composer and the block actions, which carry a
    /// compact label to show but a fuller context to send.
    private func sendAIMessage(_ message: AIMessage) async {
        guard !aiSending else { return }
        aiMessages.append(message)
        let conversation = aiMessages
        // The empty assistant bubble we grow as chunks arrive.
        let replyID = UUID()
        aiMessages.append(AIMessage(id: replyID, role: .assistant, content: ""))
        aiSending = true

        let provider = preferences.selectedProvider
        let model = preferences.selectedModel
        let apiKey = preferences.apiKey
        let baseURL = preferences.baseURL
        let agent = preferences.selectedAgent
        let custom = preferences.customInstructions

        aiStreamTask = Task { [weak self] in
            var accumulated = ""
            let channel = AsyncThrowingStream<String, Error> { continuation in
                let producer = Task.detached {
                    do {
                        try await AIGateway.stream(
                            provider: provider, model: model, apiKey: apiKey,
                            baseURL: baseURL, agent: agent, customInstructions: custom,
                            messages: conversation
                        ) { piece in continuation.yield(piece) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in producer.cancel() }
            }

            do {
                for try await piece in channel {
                    accumulated += piece
                    self?.updateAIReply(id: replyID, content: accumulated)
                }
                if !Task.isCancelled, accumulated.isEmpty {
                    self?.updateAIReply(id: replyID, content: "_(no response)_")
                }
            } catch {
                if accumulated.isEmpty {
                    self?.updateAIReply(id: replyID, content: "Request failed: \(error.localizedDescription)")
                }
            }
            // A deliberate Stop already reset these (and may have started a new
            // reply); only the natural end of a stream cleans up after itself.
            if !Task.isCancelled {
                self?.aiSending = false
                self?.aiStreamTask = nil
            }
        }
    }

    private func updateAIReply(id: AIMessage.ID, content: String) {
        guard let index = aiMessages.firstIndex(where: { $0.id == id }) else { return }
        aiMessages[index].content = content
    }

    // MARK: - AI on blocks

    enum BlockAIMode { case explain, fix }

    /// Opens the AI panel and asks about a specific block, feeding the model the
    /// command, its exit code and (clipped) output while showing only a compact
    /// label in the transcript.
    func askAI(about block: CommandBlock, tracker: BlockTracker, mode: BlockAIMode) {
        guard !block.command.isEmpty, !aiSending else { return }
        aiPanelVisible = true
        let message = Self.blockPrompt(
            block: block,
            output: tracker.plainOutput(for: block),
            mode: mode
        )
        Task { await sendAIMessage(message) }
    }

    /// Fills the active tab's composer with a command for the user to review and
    /// run — the AI never runs anything itself.
    func insertIntoComposer(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerInjection = trimmed
    }

    private static func blockPrompt(block: CommandBlock, output: String, mode: BlockAIMode) -> AIMessage {
        let exit = block.state.exitCode
        let clipped = clip(output, maxLines: 120, maxChars: 6000)
        let label: String
        let instruction: String
        switch mode {
        case .explain:
            label = "Explain `\(block.command)`"
            instruction = "Explain what this command does and interpret its output. Be concise."
        case .fix:
            label = "Fix `\(block.command)`"
            instruction = "This command did not do what was intended. Diagnose the problem "
                + "from its output, then give the corrected command inside a single fenced "
                + "code block, followed by a one-line explanation."
        }
        var sent = instruction + "\n\nCommand:\n```\n" + block.command + "\n```\n"
        sent += "\nWorking directory: \(block.directory)\n"
        if let exit { sent += "Exit code: \(exit)\n" }
        sent += "\nOutput:\n```\n" + (clipped.isEmpty ? "(no output)" : clipped) + "\n```"
        return AIMessage(role: .user, content: label, sent: sent)
    }

    /// Keeps a block's output within a sane size for a prompt: the tail is what
    /// matters for an error, so earlier lines are dropped first.
    private static func clip(_ text: String, maxLines: Int, maxChars: Int) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var note = ""
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
            note = "… (earlier output trimmed)\n"
        }
        var result = note + lines.joined(separator: "\n")
        if result.count > maxChars {
            result = "…\n" + String(result.suffix(maxChars))
        }
        return result
    }

    func closeActiveTab() {
        close(activeTabID)
    }

    /// Closes one tab, wherever it lives. Empties its group when it was the
    /// last tab there; closes the window when it was the last tab anywhere.
    func close(_ tabID: TerminalTab.ID) {
        let total = groups.reduce(0) { $0 + $1.tabs.count }
        guard total > 1 else {
            // The last tab across every group: close the window, which quits.
            NSApp.keyWindow?.close()
            return
        }
        guard let groupIndex = groups.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let removed = groups[groupIndex].tabs.remove(at: tabIndex)
        for pane in removed.panes {
            TerminalRegistry.shared.terminate(pane.id)
            blockTrackers.removeValue(forKey: pane.id)
            ShellIntegration.cleanUp(tabID: pane.id)
        }

        if groups[groupIndex].tabs.isEmpty {
            let closingGroupID = groups[groupIndex].id
            groups.remove(at: groupIndex)
            if activeGroupID == closingGroupID {
                activeGroupID = groups[min(groupIndex, groups.count - 1)].id
            }
        } else if groups[groupIndex].activeTabID == tabID {
            let fallback = groups[groupIndex].tabs[min(tabIndex, groups[groupIndex].tabs.count - 1)]
            groups[groupIndex].activeTabID = fallback.id
        }
    }

    func updateTitle(_ title: String, for paneID: Pane.ID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withPane(paneID) { $0.title = trimmed }
    }

    func updateDirectory(_ directory: String?, for paneID: Pane.ID) {
        withPane(paneID) { $0.directory = directory }
    }

    func markExited(for paneID: Pane.ID, code: Int32?) {
        withPane(paneID) { $0.exitCode = code }
        // A shell that exited is a dead pane — `exit` closes it the way it would
        // in any terminal, collapsing the split; the tab's last pane closes the
        // tab, and the last tab anywhere closes the window. Only a *local* shell
        // process ending reaches here; leaving an SSH session returns to the
        // local shell rather than terminating it.
        closePane(paneID)
    }

    // MARK: - Notifications

    /// Decides whether a just-finished command is worth notifying about.
    ///
    /// The point is to tell you about work you *weren't* watching: a long build
    /// or a failure in a background tab, or anything that finished while the app
    /// was in the background. A quick command in the tab you are staring at is
    /// never a notification.
    private func handleFinishedCommand(_ block: CommandBlock, paneID: Pane.ID) {
        guard !block.command.isEmpty else { return }

        let failed = (block.state.exitCode ?? 0) != 0
        let ranLong = (block.duration ?? 0) >= Self.notifyThreshold
        guard failed || ranLong else { return }

        guard let loc = paneLocation(paneID) else { return }
        let tab = groups[loc.group].tabs[loc.tab]

        // Watching means: app frontmost, this is the visible tab, and this is the
        // pane in focus. A command in a background pane of the front tab still
        // notifies — you were not looking at it.
        let watching = NSApplication.shared.isActive
            && tab.id == activeTabID
            && paneID == tab.activePaneID
        guard !watching else { return }

        let note = SwifttyNotification(
            command: block.command,
            detail: failed
                ? "failed" + (block.state.exitCode.map { " (exit \($0))" } ?? "")
                : "finished" + (block.durationLabel.map { " in \($0)" } ?? ""),
            date: block.finishedAt ?? Date(),
            tabID: tab.id,
            paneID: paneID,
            groupName: groups[loc.group].name,
            isError: failed
        )
        notifications.insert(note, at: 0)
        if notifications.count > Self.maxNotifications {
            notifications.removeLast(notifications.count - Self.maxNotifications)
        }

        // A native banner only when the app is in the background — in the
        // foreground the bell's badge is enough, and a banner would be noise.
        if !NSApplication.shared.isActive {
            SystemNotifier.post(note)
        }
    }

    /// Brings a notification's tab to the front — switching group and window if
    /// need be, and focusing the pane the command finished in — and marks it read.
    func revealTab(_ tabID: TerminalTab.ID, pane paneID: Pane.ID? = nil) {
        guard let group = groups.first(where: { $0.tabs.contains { $0.id == tabID } }) else { return }
        activeGroupID = group.id
        withGroup(group.id) {
            $0.activeTabID = tabID
            if let paneID,
               let tabIndex = $0.tabs.firstIndex(where: { $0.id == tabID }),
               $0.tabs[tabIndex].panes.contains(where: { $0.id == paneID }) {
                $0.tabs[tabIndex].activePaneID = paneID
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        markNotificationRead(for: tabID)
    }

    private func withGroup(_ id: TabGroup.ID, _ body: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        body(&groups[index])
    }

    func markAllNotificationsRead() {
        for index in notifications.indices { notifications[index].isRead = true }
    }

    private func markNotificationRead(for tabID: TerminalTab.ID) {
        for index in notifications.indices where notifications[index].tabID == tabID {
            notifications[index].isRead = true
        }
    }

    func clearNotifications() {
        notifications.removeAll()
    }
}

/// One entry in the notification bell: a command that finished somewhere the
/// user was not looking.
struct SwifttyNotification: Identifiable {
    let id = UUID()
    let command: String
    let detail: String
    let date: Date
    let tabID: TerminalTab.ID
    let paneID: Pane.ID
    let groupName: String
    let isError: Bool
    var isRead = false

    var relativeLabel: String {
        if Date().timeIntervalSince(date) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A named set of tabs. Groups let one window hold several independent sets of
/// terminals — a project's tabs kept apart from a server's, say.
struct TabGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabs: [TerminalTab]
    var activeTabID: TerminalTab.ID

    init(id: UUID = UUID(), name: String, tabs: [TerminalTab], activeTabID: TerminalTab.ID) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

/// One terminal within a tab. A tab with no splits has exactly one pane; each
/// split adds another. Panes are the unit that owns a shell, a tracker and the
/// title/directory the shell reports — everything a tab used to own directly.
struct Pane: Identifiable, Equatable {
    let id: UUID
    var title: String
    var directory: String?
    var exitCode: Int32?

    init(
        id: UUID = UUID(),
        title: String = ShellInfo.displayName,
        directory: String? = ShellInfo.homePath,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.exitCode = exitCode
    }
}

/// Which way a split lays its two children out.
enum SplitAxis: String, Codable, Equatable {
    case row      // side by side  (a vertical divider)
    case column   // stacked       (a horizontal divider)
}

/// A tab's pane layout: a binary tree whose leaves are panes. Each split stores
/// the fraction of space its first child takes, so dividers are draggable and the
/// ratio survives a relaunch.
indirect enum PaneNode: Equatable, Codable {
    case leaf(UUID)
    case split(axis: SplitAxis, first: PaneNode, second: PaneNode, fraction: Double)

    /// Every pane id under this node, left-to-right / top-to-bottom.
    var paneIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let a, let b, _): return a.paneIDs + b.paneIDs
        }
    }

    /// Splits the given leaf in place, adding `newPane` beside it 50/50.
    func splitting(_ paneID: UUID, with newPane: UUID, axis: SplitAxis) -> PaneNode {
        switch self {
        case .leaf(let id):
            return id == paneID
                ? .split(axis: axis, first: .leaf(id), second: .leaf(newPane), fraction: 0.5)
                : self
        case .split(let ax, let a, let b, let f):
            return .split(axis: ax,
                          first: a.splitting(paneID, with: newPane, axis: axis),
                          second: b.splitting(paneID, with: newPane, axis: axis),
                          fraction: f)
        }
    }

    /// Removes a leaf, collapsing the split it lived in to its sibling. Returns
    /// nil if this whole node was that single leaf.
    func removing(_ paneID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == paneID ? nil : self
        case .split(let ax, let a, let b, let f):
            let na = a.removing(paneID)
            let nb = b.removing(paneID)
            if na == nil { return nb }
            if nb == nil { return na }
            return .split(axis: ax, first: na!, second: nb!, fraction: f)
        }
    }

    /// The fraction stored at the split reached by `path` (0 = first child, 1 =
    /// second), or nil if the path does not land on a split.
    func fraction(at path: [Int]) -> Double? {
        guard case .split(_, let a, let b, let f) = self else { return nil }
        if path.isEmpty { return f }
        let tail = Array(path.dropFirst())
        return path[0] == 0 ? a.fraction(at: tail) : b.fraction(at: tail)
    }

    /// Returns a copy with the split at `path` set to `value`, clamped so a pane
    /// can never be dragged to nothing.
    func settingFraction(_ value: Double, at path: [Int]) -> PaneNode {
        guard case .split(let ax, let a, let b, let f) = self else { return self }
        if path.isEmpty {
            return .split(axis: ax, first: a, second: b, fraction: min(0.85, max(0.15, value)))
        }
        let tail = Array(path.dropFirst())
        return .split(axis: ax,
                      first: path[0] == 0 ? a.settingFraction(value, at: tail) : a,
                      second: path[0] == 1 ? b.settingFraction(value, at: tail) : b,
                      fraction: f)
    }

    /// A copy with every split reset to an even 50/50.
    func balanced() -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let ax, let a, let b, _):
            return .split(axis: ax, first: a.balanced(), second: b.balanced(), fraction: 0.5)
        }
    }
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var panes: [Pane]
    var layout: PaneNode
    var activePaneID: UUID

    /// A fresh single-pane tab.
    init(id: UUID = UUID(), pane: Pane = Pane()) {
        self.id = id
        self.panes = [pane]
        self.layout = .leaf(pane.id)
        self.activePaneID = pane.id
    }

    /// A multi-pane tab, e.g. one being restored.
    init(id: UUID, panes: [Pane], layout: PaneNode, activePaneID: UUID) {
        self.id = id
        self.panes = panes
        self.layout = layout
        self.activePaneID = panes.contains { $0.id == activePaneID } ? activePaneID : panes[0].id
    }

    var activePane: Pane? { panes.first { $0.id == activePaneID } }
    /// The tab's label follows whichever pane is focused.
    var title: String { activePane?.title ?? ShellInfo.displayName }
    var directory: String? { activePane?.directory }
    var isSplit: Bool { panes.count > 1 }
}

// MARK: - Session persistence

/// The window's tab layout, saved to `UserDefaults` so a relaunch reopens the
/// same tabs in the same working directories rather than a single fresh shell.
///
/// Only what is cheap and safe to restore is stored: a live shell cannot be
/// resurrected, so each tab reopens a new shell pointed at its last directory.
/// Block history and running processes are deliberately not persisted.
struct PersistedSession: Codable {
    var activeGroupID: UUID
    var groups: [PersistedGroup]
}

struct PersistedGroup: Codable {
    var id: UUID
    var name: String
    var activeTabID: UUID
    var tabs: [PersistedTab]
}

struct PersistedTab: Codable {
    var id: UUID
    var activePaneID: UUID
    var panes: [PersistedPane]
    var layout: PaneNode
}

struct PersistedPane: Codable {
    var id: UUID
    var title: String
    var directory: String?
}

struct TerminalWorkspace: View {
    @EnvironmentObject private var store: TerminalStore
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        ZStack {
            WindowBackdrop(
                opacity: preferences.windowOpacity,
                blurred: preferences.windowBlur
            )

            VStack(spacing: 0) {
                WorkspaceChrome()

                HStack(spacing: 0) {
                    if store.sidebarVisible {
                        WorkspaceSidebar(tracker: store.blockTracker(for: store.activePaneID ?? store.activeTabID))
                            .frame(width: preferences.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        SidebarResizer()
                    }

                    WorkspaceMain()
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.24), value: store.sidebarVisible)
            }

            if store.commandPaletteVisible {
                CommandPaletteOverlay()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.commandPaletteVisible)
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct WorkspaceChrome: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        Group {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ChromeButton(systemName: "sidebar.left", help: "Toggle sidebar") {
                        store.toggleSidebar()
                    }

                    ChromeButton(systemName: "command", help: "Command palette (⌘K)") {
                        store.toggleCommandPalette()
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                TabGroupMenu()

                TerminalTabStrip()

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    ChromeButton(
                        systemName: "sparkles",
                        help: store.aiPanelVisible ? "Close AI agent (⌘I)" : "Open AI agent (⌘I)"
                    ) {
                        store.toggleAIPanel()
                    }
                    NotificationBell()
                    ChromeButton(systemName: "gearshape", help: "Settings") {
                        SettingsCoordinator.open(tab: .general)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
        }
        // Leaves room for the traffic lights, which now float over this row
        // rather than sitting in a title bar of their own.
        .padding(.leading, 82)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background {
            // Without this the row would swallow drags and the window could
            // only be moved by its edges.
            Surface.chrome
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
    }
}

/// The drag handle between the explorer and the terminal.
struct SidebarResizer: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(isHovering ? 0.14 : 0.07))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            // The hit area is wider than the hairline, or the handle would be
            // almost impossible to grab.
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        preferences.sidebarWidth = min(max(
                            preferences.sidebarWidth + value.translation.width, 200
                        ), 520)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A plain button that dips and dims slightly while pressed, so every control
/// gives a bit of tactile feedback instead of firing dead.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ChromeButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.secondary)
        .help(help)
    }
}


/// The group selector that replaced the old static "Default" label: it names
/// the current group and drops a menu to switch, add, rename, or close groups.
struct TabGroupMenu: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        Menu {
            ForEach(store.groups) { group in
                Button {
                    store.selectGroup(group.id)
                } label: {
                    // A leading checkmark marks the active group. It reads as a
                    // radio list rather than plain items.
                    Label(
                        "\(group.name)  ·  \(group.tabs.count) tab\(group.tabs.count == 1 ? "" : "s")",
                        systemImage: group.id == store.activeGroupID ? "checkmark" : "square.stack"
                    )
                }
            }

            Divider()

            Button("New Group") { store.newGroup() }
            Button("Rename Group…") { presentRename(for: store.activeGroupID) }
            if store.groups.count > 1 {
                Button("Close Group", role: .destructive) {
                    store.closeGroup(store.activeGroupID)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.activeGroupName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func presentRename(for id: TabGroup.ID) {
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.informativeText = "Give this tab group a name."
        let field = NSTextField(string: store.activeGroupName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameGroup(id, to: field.stringValue)
        }
    }
}

struct TerminalTabStrip: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                TerminalTabButton(
                    // The active pane's tracker drives the icon, rename and menu;
                    // the pane trackers (in layout order) drive the label so a
                    // split shows every pane's name.
                    tracker: store.blockTracker(for: tab.activePaneID),
                    paneTrackers: tab.layout.paneIDs.map { store.blockTracker(for: $0) },
                    isActive: tab.id == store.activeTabID,
                    paneCount: tab.panes.count,
                    onSelect: { store.select(tab.id) },
                    onClose: { store.close(tab.id) },
                    onBreakUp: { store.breakUpTab(tab.id) }
                )
                // A new tab grows in from the trailing edge; a closed one
                // collapses away, so the strip reshuffles smoothly instead of
                // snapping.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .leading)
                        .combined(with: .opacity)
                        .combined(with: .move(edge: .leading)),
                    removal: .scale(scale: 0.8, anchor: .center)
                        .combined(with: .opacity)
                ))
            }

            ChromeButton(systemName: "plus", help: "New tab") {
                store.newTab()
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: store.tabs.count)
        .animation(.easeOut(duration: 0.1), value: store.activeTabID)
    }
}

/// One pane's name inside a tab button, observing that pane's tracker so it
/// updates as the pane runs a command or changes directory.
private struct TabPaneLabel: View {
    @ObservedObject var tracker: BlockTracker
    let emphasized: Bool

    var body: some View {
        Text(tracker.tabLabel)
            .font(.system(size: 12, weight: emphasized ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct TerminalTabButton: View {
    // Observed, not read through the store: the label changes when a command
    // starts or the directory moves, and the store publishes neither.
    @ObservedObject var tracker: BlockTracker
    /// The panes' trackers in layout order, so a split tab shows every name.
    var paneTrackers: [BlockTracker] = []
    let isActive: Bool
    var paneCount: Int = 1
    let onSelect: () -> Void
    let onClose: () -> Void
    var onBreakUp: () -> Void = {}

    private var labelTrackers: [BlockTracker] {
        paneTrackers.isEmpty ? [tracker] : paneTrackers
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Image(systemName: tracker.runningBlock == nil ? "terminal" : "circle.dotted")
                    .font(.system(size: 12, weight: .medium))
                    .symbolEffect(.pulse, isActive: tracker.runningBlock != nil)

                // One name per pane, the focused one emphasised. `enumerated` id
                // is fine — the order is stable for a given render.
                HStack(spacing: 5) {
                    ForEach(Array(labelTrackers.enumerated()), id: \.offset) { index, paneTracker in
                        if index > 0 {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        TabPaneLabel(
                            tracker: paneTracker,
                            emphasized: isActive && paneTracker === tracker
                        )
                    }
                }

                // A split tab carries more than one shell; show how many so the
                // strip does not misleadingly read as a single terminal.
                if paneCount > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(paneCount)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(isActive ? .primary : .secondary)
        .background(
            Capsule().fill(Color.white.opacity(isActive ? 0.08 : 0))
        )
        .clipShape(Capsule())
        // Double-click to rename, the way Terminal and iTerm do it. A
        // simultaneous gesture rather than onTapGesture(count:2), so the
        // button's single-tap select still fires instantly instead of waiting
        // to see whether a second click is coming.
        .simultaneousGesture(TapGesture(count: 2).onEnded { rename() })
        .contextMenu {
            Button("Rename…") { rename() }
            if tracker.hasCustomName {
                Button("Use Automatic Name") { tracker.customName = nil }
            }
            if paneCount > 1 {
                Divider()
                Button("Split into Separate Tabs") { onBreakUp() }
            }
            Divider()
            Button("Close Tab") { onClose() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal tab " + tracker.tabLabel)
        .animation(.easeOut(duration: 0.15), value: tracker.tabLabel)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave blank to use the automatic name."
        let field = NSTextField(string: tracker.customName ?? "")
        field.placeholderString = tracker.tabLabel
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tracker.customName = name.isEmpty ? nil : name
    }
}

extension TerminalTab {
    var displayLabel: String {
        guard let directory, !directory.isEmpty else { return ShellInfo.userName }
        return (directory as NSString).lastPathComponent.isEmpty
            ? ShellInfo.userName
            : (directory as NSString).lastPathComponent
    }
}

struct WorkspaceMain: View {
    @EnvironmentObject private var store: TerminalStore
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                PaneMountLayer(store: store, full: CGRect(origin: .zero, size: proxy.size))
            }
            .padding(.top, 6)
            // Breathing room between the terminal and the agent panel, only when
            // the panel is up — full width otherwise.
            .padding(.trailing, store.aiPanelVisible ? 14 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.aiPanelVisible {
                Divider()
                AIAgentPanel()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.24), value: store.aiPanelVisible)
    }
}

/// One pane's placement: which tab it belongs to, its frame, and whether that
/// tab is currently the visible one.
struct PaneMount: Identifiable {
    let pane: Pane
    let tab: TerminalTab
    let rect: CGRect
    let visible: Bool
    var id: UUID { pane.id }
}

/// A divider's placement, carrying the tab and tree-path it adjusts.
struct DividerMount: Identifiable {
    let id: String
    let tabID: UUID
    let rect: CGRect
    let axis: SplitAxis
    let path: [Int]
}

/// Mounts every pane of every tab in one flat `ForEach` keyed by pane id, and
/// positions each by the frame its tab's layout gives it. This is what keeps a
/// shell alive across changes that a per-tab hierarchy could not: splitting a
/// pane, resizing a divider — and moving a pane to another tab (breaking a split
/// apart) — only change a pane's computed frame or its `tab`, never its identity
/// or its place in the view tree, so its terminal is updated, never rebuilt.
struct PaneMountLayer: View {
    @ObservedObject var store: TerminalStore
    let full: CGRect

    var body: some View {
        let mounts = computeMounts()
        ZStack(alignment: .topLeading) {
            ForEach(mounts.panes) { mount in
                PaneHost(
                    store: store,
                    tab: mount.tab,
                    pane: mount.pane,
                    isTabVisible: mount.visible,
                    tracker: store.blockTracker(for: mount.pane.id)
                )
                .frame(width: mount.rect.width, height: mount.rect.height)
                .position(x: mount.rect.midX, y: mount.rect.midY)
                // The active tab's panes fade to the front; the rest fade back.
                // Opacity alone — no scale, which would keep AppKit re-running
                // autolayout on the terminal every frame.
                .opacity(mount.visible ? 1 : 0)
                .allowsHitTesting(mount.visible)
                .accessibilityHidden(!mount.visible)
            }
            ForEach(mounts.dividers) { divider in
                PaneDivider(axis: divider.axis) { delta in
                    store.adjustSplit(
                        in: divider.tabID,
                        path: divider.path,
                        delta: delta,
                        total: divider.axis == .row ? full.width : full.height
                    )
                }
                .frame(width: divider.rect.width, height: divider.rect.height)
                .position(x: divider.rect.midX, y: divider.rect.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A quick crossfade, not a slow dissolve — switching tabs with ⌘1-9 or
        // Ctrl-Tab should feel instant. easeOut starts at full speed so the new
        // tab is legible almost immediately.
        .animation(.easeOut(duration: 0.1), value: store.activeTabID)
    }

    private func computeMounts() -> (panes: [PaneMount], dividers: [DividerMount]) {
        var panes: [PaneMount] = []
        var dividers: [DividerMount] = []
        for tab in store.allTabs {
            let visible = tab.id == store.activeTabID
            let layout = PaneLayout.compute(tab.layout, in: full)
            for pane in tab.panes {
                panes.append(PaneMount(
                    pane: pane,
                    tab: tab,
                    rect: layout.leaves[pane.id] ?? full,
                    visible: visible
                ))
            }
            // Only the visible tab's dividers need laying out — the rest are
            // hidden and non-interactive anyway.
            if visible {
                for d in layout.dividers {
                    dividers.append(DividerMount(
                        id: "\(tab.id.uuidString)-\(d.id)",
                        tabID: tab.id,
                        rect: d.rect,
                        axis: d.axis,
                        path: d.path
                    ))
                }
            }
        }
        return (panes, dividers)
    }
}

/// One divider between two panes, with the path that locates the split it moves.
struct PaneDividerFrame: Identifiable {
    let id: String
    let rect: CGRect
    let axis: SplitAxis
    let path: [Int]
}

/// Turns a pane tree plus a bounding rect into absolute frames for each leaf and
/// each divider. Kept separate from the view so it stays a pure, testable step.
enum PaneLayout {
    static let dividerThickness: CGFloat = 8

    static func compute(_ node: PaneNode, in rect: CGRect)
        -> (leaves: [UUID: CGRect], dividers: [PaneDividerFrame]) {
        var leaves: [UUID: CGRect] = [:]
        var dividers: [PaneDividerFrame] = []
        walk(node, in: rect, path: [], leaves: &leaves, dividers: &dividers)
        return (leaves, dividers)
    }

    private static func walk(
        _ node: PaneNode,
        in rect: CGRect,
        path: [Int],
        leaves: inout [UUID: CGRect],
        dividers: inout [PaneDividerFrame]
    ) {
        switch node {
        case .leaf(let id):
            leaves[id] = rect
        case .split(let axis, let first, let second, let fraction):
            let t = dividerThickness
            let key = path.map(String.init).joined(separator: "-")
            if axis == .row {
                let firstW = max(0, (rect.width - t) * fraction)
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstW, height: rect.height)
                let secondRect = CGRect(x: rect.minX + firstW + t, y: rect.minY,
                                        width: max(0, rect.width - firstW - t), height: rect.height)
                dividers.append(PaneDividerFrame(
                    id: "r-\(key)",
                    rect: CGRect(x: rect.minX + firstW, y: rect.minY, width: t, height: rect.height),
                    axis: .row, path: path))
                walk(first, in: firstRect, path: path + [0], leaves: &leaves, dividers: &dividers)
                walk(second, in: secondRect, path: path + [1], leaves: &leaves, dividers: &dividers)
            } else {
                let firstH = max(0, (rect.height - t) * fraction)
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstH)
                let secondRect = CGRect(x: rect.minX, y: rect.minY + firstH + t,
                                        width: rect.width, height: max(0, rect.height - firstH - t))
                dividers.append(PaneDividerFrame(
                    id: "c-\(key)",
                    rect: CGRect(x: rect.minX, y: rect.minY + firstH, width: rect.width, height: t),
                    axis: .column, path: path))
                walk(first, in: firstRect, path: path + [0], leaves: &leaves, dividers: &dividers)
                walk(second, in: secondRect, path: path + [1], leaves: &leaves, dividers: &dividers)
            }
        }
    }
}

/// The draggable strip between two panes. Reports incremental drag deltas along
/// its axis; the store turns those into a new split fraction.
struct PaneDivider: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay {
                Rectangle().fill(Color.white.opacity(0.06))
                    .frame(
                        width: axis == .row ? 1 : nil,
                        height: axis == .column ? 1 : nil
                    )
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .row ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let current = axis == .row ? value.translation.width : value.translation.height
                        onDrag(current - last)
                        last = current
                    }
                    .onEnded { _ in last = 0 }
            )
    }
}

/// One pane: its block stack over its live terminal, plus the focus ring that
/// marks the active pane in a split.
///
/// It observes its tracker, which is the point — `wantsFocus` is derived from
/// tracker state, so when a command starts (or a full-screen program takes over)
/// this re-renders and the terminal grabs the keyboard.
struct PaneHost: View {
    let store: TerminalStore
    let tab: TerminalTab
    let pane: Pane
    let isTabVisible: Bool
    @ObservedObject var tracker: BlockTracker

    @State private var hovered = false
    @State private var dragging = false
    @State private var dragDistance: CGFloat = 0

    private var isActivePane: Bool { tab.activePaneID == pane.id }
    /// The terminal is "active" (and may take the keyboard) only when its tab is
    /// on screen and it is the focused pane.
    private var isLive: Bool { isTabVisible && isActivePane }
    private let detachThreshold: CGFloat = 44
    private var readyToDetach: Bool { dragging && dragDistance > detachThreshold }

    var body: some View {
        BlockStack(
            tracker: tracker,
            terminal: TerminalSessionView(
                paneID: pane.id,
                isActive: isLive,
                // The terminal takes the keyboard while any command is running
                // that has not been confirmed a batch job — that covers a TUI
                // (which may still be entering raw mode) and the ambiguous window
                // before classification — as well as the alternate screen or a
                // shell we could not instrument. Once a batch command is
                // confirmed the keyboard returns to the composer, so you can
                // queue the next command while it runs. Gated by `isLive` so only
                // the focused pane of the visible tab ever pulls focus.
                wantsFocus: isLive && ((tracker.runningVisible && !tracker.batchConfirmed)
                    || tracker.isAlternateScreen
                    || !tracker.isIntegrationActive),
                initialDirectory: pane.directory ?? ShellInfo.homePath,
                tracker: tracker,
                onTitle: { store.updateTitle($0, for: pane.id) },
                onDirectory: { store.updateDirectory($0, for: pane.id) },
                onExit: { store.markExited(for: pane.id, code: $0) }
            )
        )
        // A click on an inactive pane focuses it. The catcher sits only over
        // inactive panes, so the active pane's terminal keeps every click — you
        // click once to focus a pane, then interact with it normally.
        .overlay {
            if isTabVisible && tab.isSplit && !isActivePane {
                Color.white.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture { store.focusPane(pane.id) }
            }
        }
        // The grabber: drag it out to pop this pane into its own tab.
        .overlay(alignment: .top) {
            if isTabVisible && tab.isSplit {
                paneGrip
            }
        }
        // Feedback once the drag has passed the threshold to detach.
        .overlay {
            if readyToDetach {
                detachHint
            }
        }
        // Only splits get a focus ring — a lone pane needs no "which one" cue.
        .overlay {
            if isTabVisible && tab.isSplit {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isActivePane ? Color.accentColor.opacity(0.55) : Color.clear,
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.15), value: isActivePane)
            }
        }
        .onHover { hovered = $0 }
    }

    /// A small grabber at the top of the pane. Dragging it far enough tears the
    /// pane off into its own tab, keeping the shell alive.
    ///
    /// The drag is handled by an AppKit view rather than a SwiftUI `DragGesture`:
    /// a plain SwiftUI view reports `mouseDownCanMoveWindow = true`, so AppKit
    /// would start moving the whole window on the first drag before the gesture
    /// ever recognised — which is exactly the "the window moves instead" bug.
    private var paneGrip: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 28, height: 4)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            .overlay {
                PaneDetachHandle(
                    onBegin: { store.focusPane(pane.id); dragging = true; dragDistance = 0 },
                    onChange: { dragDistance = $0 },
                    onEnd: { distance in
                        dragging = false
                        dragDistance = 0
                        if distance > detachThreshold { store.popPaneToTab(pane.id) }
                    }
                )
            }
            .padding(.top, 4)
            .opacity(hovered || dragging ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            // Only grabbable while visible, so an invisible strip never steals
            // clicks or a drag-select from the top of the terminal.
            .allowsHitTesting(hovered || dragging)
            .help("Drag out to move this pane into its own tab")
    }

    private var detachHint: some View {
        Label("Release to move into a new tab", systemImage: "rectangle.badge.plus")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// The mouse handling behind the pane grabber. An AppKit view because it must
/// report `mouseDownCanMoveWindow = false` — otherwise dragging it moves the
/// whole window (plain SwiftUI views default that to true) instead of tearing
/// the pane off. Reports the drag distance so the pane can show the "release to
/// detach" hint and act on release.
struct PaneDetachHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView(onBegin: onBegin, onChange: onChange, onEnd: onEnd)
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: () -> Void
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat) -> Void
        private var start: NSPoint = .zero

        init(onBegin: @escaping () -> Void, onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat) -> Void) {
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        // The whole point: keep AppKit from starting a window move here.
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) {
            let p = event.locationInWindow
            onChange(hypot(p.x - start.x, p.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            let p = event.locationInWindow
            onEnd(hypot(p.x - start.x, p.y - start.y))
        }
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject var tracker: BlockTracker

    @State private var searchPresented = false
    @StateObject private var explorerModel = FileExplorerModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let host = explorerModel.remoteHost {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .help("Showing files on \(host)")
                }

                Text(explorerModel.rootLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(explorerModel.rootURL.path)

                Spacer(minLength: 0)

                ChromeButton(systemName: "magnifyingglass", help: "Search files") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        searchPresented.toggle()
                        if !searchPresented {
                            explorerModel.searchQuery = ""
                        }
                    }
                }
                ChromeButton(systemName: "arrow.up.doc", help: "New file") {
                    explorerModel.createFile()
                }
                ChromeButton(systemName: "folder.badge.plus", help: "New folder") {
                    explorerModel.createFolder()
                }
                ChromeButton(systemName: "arrow.clockwise", help: "Refresh explorer") {
                    explorerModel.refresh()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
            }

            if searchPresented {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Search files", text: $explorerModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))

                    if !explorerModel.searchQuery.isEmpty {
                        Button {
                            explorerModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.white.opacity(0.045))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                }
            }

            FileExplorerPreview(model: explorerModel)
        }
        .background(Surface.chrome)
        .onChange(of: tracker.currentDirectory, initial: true) { _, directory in
            syncExplorer(directory: directory)
        }
        .onChange(of: tracker.subshell, initial: true) { _, _ in
            syncExplorer(directory: tracker.currentDirectory)
        }
        .onChange(of: tracker.remoteListings) { _, _ in
            syncExplorer(directory: tracker.currentDirectory)
        }
    }
}

extension WorkspaceSidebar {
    /// Points the explorer at whichever machine the shell is actually on.
    fileprivate func syncExplorer(directory: String) {
        guard let host = tracker.subshell else {
            explorerModel.showLocal()
            explorerModel.setRoot(URL(fileURLWithPath: directory))
            return
        }

        // Go remote *first* — before the listing has even arrived — so the local
        // watch is stopped and no local rows linger. Otherwise the listing-not-
        // cached branch below would leave the local directory being watched and
        // its rows on screen, which is what popped a permission prompt for a
        // local folder during an SSH session.
        explorerModel.prepareRemote(host: host)
        if let entries = tracker.remoteEntries(for: directory) {
            explorerModel.showRemote(host: host, path: directory, entries: entries)
        } else {
            tracker.requestRemoteListing(directory)
        }
    }
}

struct FileExplorerPreview: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var model: FileExplorerModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.filteredRootEntries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: model.searchQuery.isEmpty ? "folder" : "magnifyingglass")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text(model.searchQuery.isEmpty ? "No files" : "No matches")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    FileExplorerRows(
                        entries: model.filteredRootEntries,
                        depth: 0,
                        model: model
                    )
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.rootURL)
        .animation(.easeOut(duration: 0.15), value: model.expandedPaths)
        .onAppear {
            model.refresh(showHidden: preferences.showHiddenFiles)
        }
        .onChange(of: preferences.showHiddenFiles) { _, showHidden in
            model.refresh(showHidden: showHidden)
        }
    }
}

struct SidebarFileRow: View {
    @EnvironmentObject private var store: TerminalStore
    let entry: FileExplorerEntry
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory
                    ? (isExpanded ? "chevron.down" : "chevron.right")
                    : "circle")
                    .font(.system(size: entry.isDirectory ? 8 : 4, weight: .semibold))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)

                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(entry.isDirectory ? Color.blue.opacity(0.82) : .secondary)
                    .frame(width: 16)

                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(depth * 14))
            .padding(.trailing, 10)
            .frame(height: 25)
            .foregroundStyle(.primary)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        // Double-click a folder to cd the terminal into it. A simultaneous
        // gesture so the single-click expand/select still fires immediately.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if entry.isDirectory { store.changeActiveDirectory(to: entry.url.path) }
        })
        .help(entry.isDirectory
            ? (isExpanded ? "Collapse \(entry.name) · double-click to cd here" : "Expand \(entry.name) · double-click to cd here")
            : entry.name)
        .accessibilityLabel((entry.isDirectory ? "Folder " : "File ") + entry.name)
        .accessibilityValue(entry.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "")
    }
}

struct FileExplorerRows: View {
    let entries: [FileExplorerEntry]
    let depth: Int
    @ObservedObject var model: FileExplorerModel

    var body: some View {
        ForEach(entries) { entry in
            SidebarFileRow(
                entry: entry,
                depth: depth,
                isExpanded: model.expandedPaths.contains(entry.id),
                isSelected: model.selectedPath == entry.id,
                onActivate: { model.activate(entry) }
            )

            if entry.isDirectory && model.expandedPaths.contains(entry.id) {
                AnyView(
                    FileExplorerRows(
                        entries: model.filtered(model.children(for: entry)),
                        depth: depth + 1,
                        model: model
                    )
                )
            }
        }
    }
}

struct FileExplorerEntry: Identifiable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
}

@MainActor
final class FileExplorerModel: ObservableObject {
    @Published private(set) var rootEntries: [FileExplorerEntry] = []
    @Published private(set) var childrenByPath: [String: [FileExplorerEntry]] = [:]
    @Published var expandedPaths: Set<String> = []
    @Published var selectedPath: String?
    @Published var searchQuery = ""

    private(set) var showHidden = false
    @Published private(set) var rootURL = FileManager.default.homeDirectoryForCurrentUser
    /// Set while the explorer is showing a remote host's files, which arrive
    /// from the shell on the far end rather than from local disk.
    @Published private(set) var remoteHost: String?
    private var remoteEntries: [String] = []

    /// A kernel file-system watch on the current local directory, so the
    /// explorer reflects files a command (or anything else) creates, renames or
    /// deletes — without polling. It fires only when the directory actually
    /// changes, and bursts are coalesced into one refresh, so it costs nothing at
    /// idle. Remote sessions do not use it; their listings arrive with each
    /// prompt from the far end instead.
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    init() {
        refresh()
        startWatching(rootURL)
    }

    deinit {
        // Closes the watched fd. The pending refresh captures `self` weakly, so
        // it no-ops once we are gone — no need to reach for it here (and it is
        // not Sendable across the nonisolated deinit anyway).
        directoryWatch?.cancel()
    }

    private func startWatching(_ url: URL) {
        stopWatching()
        // Never open a local directory while a remote session is showing — that
        // is the whole point of remote mode, and opening a protected local
        // folder (Documents, Desktop…) would pop a macOS permission prompt for a
        // folder we are not even looking at.
        guard remoteHost == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        directoryWatch = source
        source.resume()
    }

    private func stopWatching() {
        directoryWatch?.cancel()
        directoryWatch = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// Coalesces a burst of changes (unpacking an archive, `git clone`) into a
    /// single refresh a beat later, so the directory is re-read once rather than
    /// on every syscall.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Home shows as `~`, everything else by its own folder name.
    var rootLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if rootURL.path == home { return "~" }
        return rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
    }

    /// Shows a listing that came back from a remote shell.
    ///
    /// Local disk is the wrong machine once a session is remote — the paths
    /// happen to resolve, which makes the wrong answer look like a right one.
    /// Switches to remote mode the moment the session is known to be remote —
    /// before any listing has arrived. Stops the local watch and drops the local
    /// rows so nothing local is read or shown while we wait for the far end.
    func prepareRemote(host: String) {
        stopWatching()
        guard remoteHost != host else { return }
        remoteHost = host
        remoteEntries = []
        rootEntries = []
        childrenByPath.removeAll()
        expandedPaths.removeAll()
        selectedPath = nil
    }

    func showRemote(host: String, path: String, entries: [String]) {
        // Nothing local to watch once a session is remote.
        stopWatching()
        remoteHost = host
        remoteEntries = entries
        rootURL = URL(fileURLWithPath: path)
        expandedPaths.removeAll()
        childrenByPath.removeAll()
        selectedPath = nil
        rebuildRemoteRows()
    }

    /// Returns to the local filesystem when a remote session ends.
    func showLocal() {
        guard remoteHost != nil else { return }
        remoteHost = nil
        remoteEntries = []
        refresh()
        startWatching(rootURL)
    }

    private func rebuildRemoteRows() {
        let base = rootURL.path
        rootEntries = remoteEntries
            .filter { showHidden || !$0.hasPrefix(".") }
            .map { entry in
                let isDirectory = entry.hasSuffix("/")
                let name = isDirectory ? String(entry.dropLast()) : entry
                return FileExplorerEntry(
                    id: (base as NSString).appendingPathComponent(name),
                    url: URL(fileURLWithPath: (base as NSString).appendingPathComponent(name)),
                    name: name,
                    isDirectory: isDirectory
                )
            }
            .sorted { lhs, rhs in
                lhs.isDirectory == rhs.isDirectory
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.isDirectory
            }
    }

    /// Points the explorer at a new directory, following the shell.
    ///
    /// Expansion and selection are dropped rather than carried over: they are
    /// keyed by absolute path, and holding on to paths from the old tree would
    /// leave rows expanded that are no longer part of it.
    func setRoot(_ url: URL) {
        let resolved = url.standardizedFileURL
        guard resolved != rootURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        rootURL = resolved
        expandedPaths.removeAll()
        childrenByPath.removeAll()
        selectedPath = nil
        refresh()
        startWatching(resolved)
    }

    var filteredRootEntries: [FileExplorerEntry] {
        filtered(rootEntries)
    }

    func refresh(showHidden: Bool? = nil) {
        if let showHidden {
            self.showHidden = showHidden
        }
        if remoteHost != nil {
            rebuildRemoteRows()
            return
        }

        rootEntries = loadDirectory(rootURL)
        let loadedPaths = Array(childrenByPath.keys)
        for path in loadedPaths {
            let directoryURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                childrenByPath[path] = loadDirectory(directoryURL)
            } else {
                childrenByPath.removeValue(forKey: path)
                expandedPaths.remove(path)
            }
        }
    }

    func activate(_ entry: FileExplorerEntry) {
        selectedPath = entry.id
        // Expanding a remote folder would need another round trip; the shell's
        // own `cd` is the way to move around a remote tree for now.
        guard entry.isDirectory, remoteHost == nil else { return }

        if expandedPaths.contains(entry.id) {
            expandedPaths.remove(entry.id)
        } else {
            childrenByPath[entry.id] = loadDirectory(entry.url)
            expandedPaths.insert(entry.id)
        }
    }

    func children(for entry: FileExplorerEntry) -> [FileExplorerEntry] {
        childrenByPath[entry.id] ?? []
    }

    func filtered(_ entries: [FileExplorerEntry]) -> [FileExplorerEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func createFile() {
        let directory = targetDirectory()
        guard let name = requestName(
            title: "New File",
            message: "Create a file in \(directory.lastPathComponent).",
            defaultName: "untitled.txt"
        ) else { return }

        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showError("A file or folder named “\(name)” already exists.")
            return
        }

        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
            showError("Swiftty could not create “\(name)”.")
            return
        }
        refresh()
        selectedPath = url.path
    }

    func createFolder() {
        let directory = targetDirectory()
        guard let name = requestName(
            title: "New Folder",
            message: "Create a folder in \(directory.lastPathComponent).",
            defaultName: "New Folder"
        ) else { return }

        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showError("A file or folder named “\(name)” already exists.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
            selectedPath = url.path
        } catch {
            showError("Swiftty could not create “\(name)”.")
        }
    }

    private func targetDirectory() -> URL {
        guard let selectedPath else { return rootURL }
        let selectedURL = URL(fileURLWithPath: selectedPath)
        let isDirectory = (try? selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? selectedURL : selectedURL.deletingLastPathComponent()
    }

    private func loadDirectory(_ directory: URL) -> [FileExplorerEntry] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        )) ?? []

        return urls
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileExplorerEntry(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(200)
            .map { $0 }
    }

    private func requestName(title: String, message: String, defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            showError("Choose a valid name without “/”.")
            return nil
        }
        return name
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not update the explorer"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}


/// One selectable line in the command palette — either an app action or a past
/// command to re-run. `matchIndices` records which characters the current query
/// hit, so the row can highlight them.
struct PaletteItem: Identifiable {
    enum Kind {
        case action(icon: String, shortcut: String?, run: () -> Void)
        case history(command: String)
    }
    let id: String
    let title: String
    let subtitle: String?
    let kind: Kind
    var matchIndices: [Int] = []
}

/// A subsequence fuzzy matcher. Returns a score (higher is better) and the
/// matched character positions, or nil when `query` is not a subsequence of
/// `text`. Contiguous runs and word-boundary hits score higher, so "gc" ranks
/// "git commit" above "graphics-cache".
enum PaletteMatch {
    static func score(_ query: String, _ text: String) -> (score: Int, indices: [Int])? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return (0, []) }
        let t = Array(text.lowercased())

        var qi = 0
        var indices: [Int] = []
        var score = 0
        var lastHit = -2
        var previous: Character?

        for (ti, ch) in t.enumerated() where qi < q.count {
            guard ch == q[qi] else { previous = ch; continue }
            if ti == lastHit + 1 { score += 6 }           // contiguous
            if ti == 0 { score += 10 }                     // start of string
            else if let p = previous, !p.isLetter, !p.isNumber { score += 7 }  // word boundary
            score += 1
            indices.append(ti)
            lastHit = ti
            qi += 1
            previous = ch
        }
        guard qi == q.count else { return nil }
        score -= t.count / 24                               // gently prefer shorter targets
        return (score, indices)
    }
}

/// The ⌘K command palette: a centred overlay that fuzzy-searches every command
/// this pane has run (session blocks + shell history) plus the app's own
/// actions. Return runs the highlighted item; a query that matches nothing is
/// still runnable as a raw command, so the palette doubles as a launcher.
struct CommandPaletteOverlay: View {
    @EnvironmentObject private var store: TerminalStore
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.closeCommandPalette() }

            panel
                .frame(width: 560)
                .padding(.top, 82)
        }
    }

    private var panel: some View {
        let items = results
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("Run a command or search history…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit { runSelection(in: items) }
                    .onExitCommand { store.closeCommandPalette() }
                    .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Divider().opacity(0.5)

            if items.isEmpty {
                Text(query.isEmpty ? "No history yet" : "Press ⏎ to run “\(query)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteResultRow(item: item, selected: index == selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { invoke(item) }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 372)
                    .onChange(of: selection) { _, new in
                        if items.indices.contains(new) {
                            proxy.scrollTo(items[new].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 0.985)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .onAppear { fieldFocused = true; selection = 0 }
        .onChange(of: store.paletteFocusRequests) { _, _ in fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    // MARK: - Result assembly

    private var results: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let acts = actions()
        let hist = historyItems()
        guard !q.isEmpty else { return acts + Array(hist.prefix(8)) }

        func ranked(_ source: [PaletteItem]) -> [PaletteItem] {
            source.compactMap { item -> (PaletteItem, Int)? in
                guard let m = PaletteMatch.score(q, item.title) else { return nil }
                var copy = item
                copy.matchIndices = m.indices
                return (copy, m.score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }
        return ranked(acts) + Array(ranked(hist).prefix(40))
    }

    private func actions() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ title: String, _ icon: String, _ shortcut: String?, _ run: @escaping () -> Void) {
            items.append(PaletteItem(
                id: "action:" + title,
                title: title,
                subtitle: nil,
                kind: .action(icon: icon, shortcut: shortcut, run: run)
            ))
        }
        add("New Tab", "plus", "⌘T") { store.newTab() }
        add("Split Right", "rectangle.split.2x1", "⌘D") { store.splitActivePane(.row) }
        add("Split Down", "rectangle.split.1x2", "⇧⌘D") { store.splitActivePane(.column) }
        add("Toggle File Explorer", "sidebar.left", "⌘S") { store.toggleSidebar() }
        add(store.aiPanelVisible ? "Close AI Agent" : "Open AI Agent", "sparkles", "⌘I") { store.toggleAIPanel() }
        add("Find in Blocks", "text.magnifyingglass", "⌘F") { store.beginSearch() }
        add("Clear Blocks", "square.stack.3d.up.slash", "⌘⌫") { store.clearBlocks() }
        add("Reset Terminal", "arrow.counterclockwise", "⇧⌘K") { store.resetActiveTerminal() }
        add("Enable Blocks in This Session", "link", "⇧⌘E") { store.activeBlockTracker?.warpifySession() }
        add("Settings", "gearshape", "⌘,") { SettingsCoordinator.open(tab: .general) }
        add("Configure Models", "cpu", nil) { SettingsCoordinator.open(tab: .models) }
        return items
    }

    private func historyItems() -> [PaletteItem] {
        store.paletteHistory.map { entry in
            PaletteItem(
                id: "hist:" + entry.command,
                title: entry.command,
                subtitle: entry.relativeLabel,
                kind: .history(command: entry.command)
            )
        }
    }

    // MARK: - Navigation

    private func move(_ delta: Int, in items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    private func runSelection(in items: [PaletteItem]) {
        if items.indices.contains(selection) {
            invoke(items[selection])
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            store.runFromPalette(query)
        }
    }

    private func invoke(_ item: PaletteItem) {
        switch item.kind {
        case .action(_, _, let run):
            store.closeCommandPalette()
            run()
        case .history(let command):
            store.runFromPalette(command)
        }
    }
}

struct PaletteResultRow: View {
    let item: PaletteItem
    let selected: Bool

    private var icon: String {
        if case .action(let icon, _, _) = item.kind { return icon }
        return "clock.arrow.circlepath"
    }
    private var shortcut: String? {
        if case .action(_, let shortcut, _) = item.kind { return shortcut }
        return nil
    }
    /// History rows render in monospace (they are shell commands); action titles
    /// stay in the UI font.
    private var isCommand: Bool {
        if case .history = item.kind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(selected ? .primary : .secondary)
            Text(highlightedTitle)
                .font(.system(size: 13, design: isCommand ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.24) : Color.clear)
        )
    }

    private var highlightedTitle: AttributedString {
        let hits = Set(item.matchIndices)
        guard !hits.isEmpty else { return AttributedString(item.title) }
        var result = AttributedString()
        for (index, character) in item.title.enumerated() {
            var piece = AttributedString(String(character))
            if hits.contains(index) {
                piece.foregroundColor = Color.accentColor
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(piece)
        }
        return result
    }
}

struct AIAgentPanel: View {
    @EnvironmentObject private var store: TerminalStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var draft = ""
    private static let bottomAnchor = "ai.transcript.bottom"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI agent")
                        .font(.system(size: 13, weight: .semibold))
                    Text(preferences.selectedProvider.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button { store.clearAIChat() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear conversation")
                Button {
                    SettingsCoordinator.open(tab: .models)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Configure models")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
            }

            if preferences.modelOptions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("No model selected")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Configure") {
                        SettingsCoordinator.open(tab: .models)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                Picker("Model", selection: Binding(
                    get: { preferences.selectedModel },
                    set: { preferences.selectedModelID = $0 }
                )) {
                    ForEach(preferences.modelOptions) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider()

            if store.aiMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text("Ask your agent")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Use the selected model to explain code, plan a change, or troubleshoot the terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(store.aiMessages) { message in
                                AIMessageBubble(message: message)
                            }
                            // Anchor to keep the newest text in view as it streams.
                            Color.clear.frame(height: 1).id(Self.bottomAnchor)
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: store.aiMessages.last?.content) { _, _ in
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                    .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }

            VStack(spacing: 7) {
                TextField("Ask the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(9)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        sendDraft()
                    }

                HStack {
                    Circle()
                        .fill(store.aiSending ? Color.purple : (preferences.isConfigured ? Color.green : Color.orange))
                        .frame(width: 7, height: 7)
                    Text(store.aiSending ? "Thinking…" : (preferences.isConfigured ? "Ready" : "Configure a model in Settings"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.aiSending {
                        Button { store.stopAI() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Stop generating")
                    } else {
                        Button { sendDraft() } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(10)
        }
        .background(Surface.chrome)
    }

    private func sendDraft() {
        let prompt = draft
        draft = ""
        Task { await store.sendAI(prompt) }
    }
}

struct AIMessageBubble: View {
    let message: AIMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "Agent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(message.role == .user ? .blue : .purple)

            if message.role == .assistant && message.content.isEmpty {
                // The reply's placeholder bubble, before the first token lands.
                TypingIndicator()
            } else {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .prose(let text):
                        Text(text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .code(let code):
                        AICodeBlock(code: code)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.blue.opacity(0.10) : Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// User bubbles are our own compact labels, never worth parsing for code;
    /// assistant replies are split so commands become runnable code blocks.
    private var segments: [AIMessageSegment] {
        message.role == .user
            ? [.prose(message.content)]
            : AIMessageSegment.parse(message.content)
    }
}

/// Three dots that breathe while the first token of a reply is still on its way.
struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + 0.45 * pulse(i))
            }
        }
        .frame(height: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func pulse(_ index: Int) -> Double {
        // A small phase offset per dot makes the three ripple rather than blink.
        abs(sin((phase + Double(index) * 0.25) * .pi))
    }
}

/// A fenced code block from an assistant reply, with actions to copy it or drop
/// it into the composer for review. The AI never runs anything itself.
struct AICodeBlock: View {
    let code: String
    @EnvironmentObject private var store: TerminalStore
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button {
                    store.insertIntoComposer(code)
                } label: {
                    Label("Insert", systemImage: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Put this command in the composer to review and run")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
        }
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A piece of an assistant reply: plain prose, or a fenced code block.
enum AIMessageSegment {
    case prose(String)
    case code(String)

    /// Splits Markdown-ish text on ``` fences. An unterminated fence treats the
    /// remainder as code, which is the safer guess for a cut-off command.
    static func parse(_ content: String) -> [AIMessageSegment] {
        var segments: [AIMessageSegment] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.prose(text)) }
            prose.removeAll()
        }
        func flushCode() {
            let text = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { segments.append(.code(text)) }
            code.removeAll()
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flushCode() } else { flushProse() }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { flushCode() } else { flushProse() }
        return segments.isEmpty ? [.prose(content)] : segments
    }
}

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)
            TerminalSettingsView()
                .tabItem { Label(SettingsTab.terminal.title, systemImage: SettingsTab.terminal.systemImage) }
                .tag(SettingsTab.terminal)
            ModelsSettingsView()
                .tabItem { Label(SettingsTab.models.title, systemImage: SettingsTab.models.systemImage) }
                .tag(SettingsTab.models)
            AgentsSettingsView()
                .tabItem { Label(SettingsTab.agents.title, systemImage: SettingsTab.agents.systemImage) }
                .tag(SettingsTab.agents)
            AboutSettingsView()
                .tabItem { Label(SettingsTab.about.title, systemImage: SettingsTab.about.systemImage) }
                .tag(SettingsTab.about)
        }
        .padding(22)
        .onAppear { selection = preferences.selectedSettingsTab }
        .onChange(of: selection) { _, newValue in
            preferences.selectedSettingsTab = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .swifttyOpenSettings)) { notification in
            if let tab = notification.object as? SettingsTab {
                selection = tab
            }
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.rawValue.capitalized).tag(appearance)
                    }
                }
                Toggle("Show hidden files", isOn: $preferences.showHiddenFiles)
            } header: {
                SettingsSectionHeader(title: "General", subtitle: "Workspace appearance and explorer behavior.")
            }

            Section {
                HStack {
                    Text("Window opacity")
                    Slider(value: $preferences.windowOpacity, in: 0.5...1.0)
                    Text("\(Int(preferences.windowOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }

                Toggle("Blur what's behind the window", isOn: $preferences.windowBlur)
                    .disabled(!preferences.isTranslucent)
                Text(preferences.isTranslucent
                    ? "Frosts the desktop behind Swiftty instead of showing it sharply."
                    : "Lower the opacity below 100% to let the desktop show through.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Window")
            }

            Section {
                Text("Blocks work over SSH and inside containers once the remote shell announces itself. Add one line to the shell config **on the remote host** — nothing is installed there, and Swiftty sends the hooks over the connection you already have.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SnippetRow(
                    label: "zsh — add to ~/.zshrc",
                    snippet: ShellIntegration.handshakeSnippet(for: .zsh)
                )
                SnippetRow(
                    label: "bash — add to ~/.bashrc",
                    snippet: ShellIntegration.handshakeSnippet(for: .bash)
                )
            } header: {
                Text("Remote sessions")
            }

            Section {
                Toggle("Compact blocks", isOn: $preferences.compactBlocks)
                Text("Tightens the spacing between blocks so more fits on screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Blocks")
            }

            Section {
                Toggle("Detect natural language in the command bar", isOn: $preferences.naturalLanguageDetection)
                Text("Plainly-worded input (\u{201C}how do I…\u{201D}) is sent to the AI agent on Return instead of the shell. A real command still runs; prefix with \u{201C}!\u{201D} to force the shell.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("AI command bar")
            }

            Section {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("Home directory")
                    Spacer()
                    Text(ShellInfo.homePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } header: {
                Text("Workspace")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}

struct TerminalSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Font size")
                    Slider(value: $preferences.terminalFontSize, in: AppPreferences.fontSizeRange, step: 1)
                    Text("\(Int(preferences.terminalFontSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }
                Toggle("Blinking cursor", isOn: $preferences.terminalCursorBlink)
            } header: {
                SettingsSectionHeader(title: "Terminal", subtitle: "Tune the terminal without touching the shell configuration.")
            }

            Section {
                TextField("Shell path", text: $preferences.shellPath)
                    .font(.system(size: 12, design: .monospaced))
                Text("New tabs use this executable with a login shell. Changes apply to new tabs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shell")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}

struct ModelsSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var apiKeyDraft = ""
    @State private var savedMessage = ""

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(
                    get: { preferences.selectedProvider },
                    set: { preferences.setProvider($0) }
                )) {
                    ForEach(AIProvider.allCases) { provider in
                        HStack {
                            Image(systemName: provider.isLocal ? "desktopcomputer" : "cloud")
                            Text(provider.rawValue)
                        }
                        .tag(provider)
                    }
                }
                Text(providerDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader(title: "Models", subtitle: "Choose which provider powers the AI agent.")
            }

            Section("Model") {
                HStack(spacing: 10) {
                    if preferences.modelsLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(preferences.discoveredModels.isEmpty
                        ? "No models discovered"
                        : "\(preferences.discoveredModels.count) models discovered")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Discover") {
                        Task { await preferences.refreshModels() }
                    }
                    .disabled(preferences.modelsLoading)
                }

                if !preferences.modelOptions.isEmpty {
                    Picker("Chat model", selection: Binding(
                        get: { preferences.selectedModel },
                        set: { preferences.selectedModelID = $0 }
                    )) {
                        ForEach(preferences.modelOptions) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                }

                TextField("Model ID (exact)", text: $preferences.selectedModelID)
                    .font(.system(size: 12, design: .monospaced))
                Text(preferences.selectedProvider == .ollama
                    ? "Enter the exact identifier shown by “ollama ls”, including any tag."
                    : "Enter the exact model identifier accepted by the selected endpoint.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let modelError = preferences.modelError {
                    Text(modelError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section("Connection") {
                TextField("Base URL", text: $preferences.baseURL)
                    .font(.system(size: 12, design: .monospaced))

                if preferences.selectedProvider.requiresAPIKey || preferences.selectedProvider == .compatible {
                    SecureField(
                        preferences.selectedProvider == .compatible ? "API key (optional)" : "API key",
                        text: $apiKeyDraft
                    )
                    HStack {
                        Button("Save key") {
                            preferences.setAPIKey(apiKeyDraft)
                            savedMessage = apiKeyDraft.isEmpty ? "Key cleared" : "Key saved to Keychain"
                            Task { await preferences.refreshModels() }
                        }
                        Button("Clear") {
                            apiKeyDraft = ""
                            preferences.setAPIKey("")
                            savedMessage = "Key cleared"
                            Task { await preferences.refreshModels() }
                        }
                        if !savedMessage.isEmpty {
                            Text(savedMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Local providers do not require an API key. Make sure the local server is running before opening the agent.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(preferences.isConfigured ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(preferences.isConfigured ? "Ready to send requests" : "Configuration incomplete")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(preferences.selectedProvider.rawValue)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .onAppear { apiKeyDraft = preferences.apiKey }
        .onChange(of: preferences.selectedProvider) { _, _ in
            apiKeyDraft = preferences.apiKey
        }
        .task { await preferences.refreshModels() }
    }

    private var providerDescription: String {
        switch preferences.selectedProvider {
        case .openAI: return "Discover models from OpenAI’s model catalog, then use the selected ID with Chat Completions."
        case .anthropic: return "Anthropic models through the Messages API."
        case .openRouter: return "Route multiple hosted model families through one OpenRouter key."
        case .ollama: return "Use models served locally by Ollama."
        case .lmStudio: return "Use a model served by LM Studio’s local OpenAI-compatible server."
        case .compatible: return "Connect any OpenAI-compatible endpoint by URL and model ID."
        }
    }
}

struct AgentsSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker("Active agent", selection: $preferences.selectedAgent) {
                    Text("Coder").tag("Coder")
                    Text("Reviewer").tag("Reviewer")
                    Text("Architect").tag("Architect")
                    Text("Custom").tag("Custom")
                }
                Text(AIGateway.personaPrompt(preferences.selectedAgent))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(title: "Agents", subtitle: "Choose the persona and instructions used by the AI pane.")
            }

            Section("Custom instructions") {
                TextEditor(text: $preferences.customInstructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 150)
                Text("These instructions are kept locally and sent with future agent requests.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Swiftty")
                .font(.system(size: 22, weight: .semibold))
            Text("A native Swift terminal workspace with an integrated AI agent.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Version 0.1.0")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A copyable one-liner for the user to paste into a remote shell config.
struct SnippetRow: View {
    let label: String
    let snippet: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button(copied ? "Copied" : "Copy") {
                    Pasteboard.copy(snippet)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 3)
    }
}

/// Owns the live terminal views, keyed by pane id, so a terminal outlives the
/// SwiftUI representable that hosts it.
///
/// This is what makes a pane's shell survive being torn off into another window:
/// SwiftUI rebuilds an `NSViewRepresentable` when it moves between windows, which
/// would normally respawn the shell. Instead the terminal is cached here, reused
/// on the far side of a move, and only actually terminated when the pane is
/// really closed (by the store) or the app quits — never when SwiftUI merely
/// dismantles the view.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [Pane.ID: SwifttyTerminalView] = [:]

    func view(for id: Pane.ID) -> SwifttyTerminalView? { views[id] }

    func register(_ view: SwifttyTerminalView, for id: Pane.ID) {
        views[id] = view
    }

    /// Kills the pane's shell and forgets its view. Called by the store when a
    /// pane is genuinely closed.
    func terminate(_ id: Pane.ID) {
        views.removeValue(forKey: id)?.terminate()
    }

    /// Kills every shell — the app is quitting.
    func terminateAll() {
        for view in views.values { view.terminate() }
        views.removeAll()
    }
}

struct TerminalSessionView: NSViewRepresentable {
    @EnvironmentObject private var preferences: AppPreferences
    let paneID: Pane.ID
    let isActive: Bool
    let wantsFocus: Bool
    /// Where the shell should start — a restored pane's last directory, or the
    /// directory inherited from the pane a split was opened from. Falls back to
    /// home if it is not a directory that exists on this machine.
    let initialDirectory: String
    let tracker: BlockTracker
    let onTitle: (String) -> Void
    let onDirectory: (String?) -> Void
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTitle: onTitle, onDirectory: onDirectory, onExit: onExit)
    }

    /// The directory a shell can actually be started in: the requested one when
    /// it exists locally, home otherwise. A restored or inherited path may be
    /// gone, or belong to a remote host, in which case chdir would fail.
    private static func startDirectory(_ requested: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: requested, isDirectory: &isDir), isDir.boolValue {
            return requested
        }
        return ShellInfo.homePath
    }

    func makeNSView(context: Context) -> SwifttyTerminalView {
        // A terminal already exists for this pane — it is being re-hosted (a move
        // into another window). Reuse it so its shell, scrollback and running
        // process carry over untouched; only re-point the delegate at this
        // representable's coordinator. The tracker is the same instance (one
        // store), and its OSC handler and view reference are still live, so it is
        // deliberately *not* re-attached (that would double-register the handler).
        if let existing = TerminalRegistry.shared.view(for: paneID) {
            existing.removeFromSuperview()
            existing.processDelegate = context.coordinator
            context.coordinator.terminal = existing
            existing.applyBackground(opacity: preferences.windowOpacity)
            return existing
        }

        let terminal = SwifttyTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: preferences.terminalFontSize, weight: .regular)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        terminal.caretColor = .systemGreen
        terminal.caretViewTracksFocus = true
        // Rebuild only the rows that changed, rather than the whole screen every
        // frame. This is the cheaper mode for interactive use — typing, scrolling
        // output — which is nearly all of ours; only a handful of rows are dirty
        // per frame. `.perFrameAggregated` suits a TUI that repaints everything,
        // but even then this only rebuilds what actually changed.
        terminal.metalBufferingMode = .perRowPersistent
        try? terminal.setUseMetal(true)
        // After setUseMetal, so there is an MTKView to make non-opaque.
        terminal.applyBackground(opacity: preferences.windowOpacity)
        terminal.processDelegate = context.coordinator
        context.coordinator.terminal = terminal

        let shell = preferences.shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ShellInfo.path
            : preferences.shellPath
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Swiftty"
        environment["TERM_PROGRAM_VERSION"] = "0.1"

        // Load the OSC 133 hooks that command blocks are built on. Shells we
        // cannot instrument just start normally and produce no blocks.
        var arguments = ["-l"]
        var execName = "-" + (shell as NSString).lastPathComponent
        // Each pane's shell integration lives in its own namespace, keyed by the
        // pane id, so split panes never trample one another's marker files.
        if let injection = ShellIntegration.prepare(shellPath: shell, tabID: paneID) {
            environment.merge(injection.environment) { _, new in new }
            if !injection.arguments.isEmpty { arguments = injection.arguments }
            if let name = injection.execName { execName = name }
        }

        // The tracker has to be listening before the shell's first prompt, so
        // register the OSC handler ahead of startProcess.
        tracker.attach(to: terminal)

        terminal.startProcess(
            executable: shell,
            args: arguments,
            environment: environment.map { $0.key + "=" + $0.value },
            execName: execName,
            currentDirectory: Self.startDirectory(initialDirectory)
        )

        terminal.setCursorBlink(preferences.terminalCursorBlink)
        TerminalRegistry.shared.register(terminal, for: paneID)

        DispatchQueue.main.async {
            guard isActive, wantsFocus else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: SwifttyTerminalView, context: Context) {
        context.coordinator.onTitle = onTitle
        context.coordinator.onDirectory = onDirectory
        context.coordinator.onExit = onExit
        terminal.setCursorBlink(preferences.terminalCursorBlink)
        terminal.font = NSFont.monospacedSystemFont(ofSize: preferences.terminalFontSize, weight: .regular)
        terminal.applyBackground(opacity: preferences.windowOpacity)

        guard isActive, wantsFocus else { return }
        DispatchQueue.main.async {
            // Only claim focus if something else has not already taken it, or
            // this would fight the editor for the keyboard every redraw.
            guard terminal.window?.firstResponder !== terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    static func dismantleNSView(_ terminal: SwifttyTerminalView, coordinator: Coordinator) {
        // Deliberately does NOT terminate the shell. The terminal outlives this
        // representable so it can be re-hosted in another window; the registry
        // owns its lifetime, and the store terminates it on a real close (or the
        // app terminates them all on quit). Terminating here would kill a shell
        // every time a pane was merely moved.
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminal: SwifttyTerminalView?
        var onTitle: (String) -> Void
        var onDirectory: (String?) -> Void
        var onExit: (Int32?) -> Void

        init(
            onTitle: @escaping (String) -> Void,
            onDirectory: @escaping (String?) -> Void,
            onExit: @escaping (Int32?) -> Void
        ) {
            self.onTitle = onTitle
            self.onDirectory = onDirectory
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            onTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            onDirectory(Self.path(from: directory))
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit(exitCode)
        }

        private static func path(from directory: String?) -> String? {
            guard let directory, !directory.isEmpty else { return nil }
            if let url = URL(string: directory), url.isFileURL {
                return url.path
            }
            return directory
        }
    }
}

enum ShellInfo {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    static let userName = NSUserName()
    static let path = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    static let displayName = (path as NSString).lastPathComponent
}
