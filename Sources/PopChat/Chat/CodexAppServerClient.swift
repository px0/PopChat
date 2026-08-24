import Foundation

/// Readiness of the user's own Codex installation. PopChat deliberately does not
/// install, update, or authenticate Codex; it only starts `codex app-server`.
enum CodexAppServerStatus: Equatable {
    case unknown
    case checking
    case ready(email: String?, plan: String?)
    case missing
    case notSignedIn
    case failed(String)
}

/// Local adapter for Codex's experimental JSONL app-server protocol.
///
/// Each PopChat request gets an ephemeral Codex thread with the resolved PopChat
/// history injected into it. The thread is read-only, its sandbox has no network
/// access, and it never asks for an approval: this provider is a chat transport,
/// not an authorization for Codex to operate on the user's machine. Codex's own
/// `web_search` is the one exception, since it acts on the backend rather than
/// the machine — it follows PopChat's globe toggle (see `Session.init`).
enum CodexAppServerClient {
    static let executablePathKey = "codexExecutablePath"

    struct Inspection: Sendable {
        var email: String?
        var plan: String?
        var models: [String]
        var defaultModel: String?
        var supportedEfforts: [String: [String]]
        var defaultEfforts: [String: String]
    }

    struct ClientError: LocalizedError, Sendable {
        /// Why this failed, as DATA. `ProviderStore` maps failures onto
        /// `CodexAppServerStatus` from this — never by substring-matching
        /// `message`, which is user-facing prose that is free to be reworded
        /// (and lives in a different file from the code doing the matching).
        enum Reason: Sendable {
            case missing
            case notSignedIn
            case protocolFailure
        }

        let message: String
        var reason: Reason = .protocolFailure
        var errorDescription: String? { message }
    }

    /// Finder-launched apps have a small PATH, so also check the common Codex
    /// install locations. An explicit path wins when the user supplies one.
    ///
    /// May block for seconds (the login-shell probe below), so it must only run
    /// on the dedicated check/turn queues — never the main thread or a Swift
    /// concurrency cooperative task.
    static func executableURL() -> URL? {
        let defaultsPath = UserDefaults.standard.string(forKey: executablePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentPath = ProcessInfo.processInfo.environment["POPCHAT_CODEX_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            defaultsPath,
            environmentPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        // Also honor PATH for terminal-launched builds.
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: "codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        return loginShellCodexURL()
    }

    /// Last resort: ask the user's own login shell for its PATH and search that
    /// ourselves. Version managers (nvm, asdf, fnm, custom prefixes) install
    /// codex wherever their init scripts decide, and the fixed candidates above
    /// can't chase every layout — but `$SHELL` sources those same scripts, so
    /// its PATH finds codex exactly where the user's terminal does. Details that
    /// are all load-bearing (each one is a review counterexample):
    /// - PATH + marker, not `command -v codex`: in an interactive shell an
    ///   alias shadows the lookup (`command -v` prints the alias DEFINITION
    ///   with exit 0, so a fallback after `||` never runs), and rc greetings
    ///   drown plain output — the marker line is unambiguous whatever the rc
    ///   files print.
    /// - Interactive (-i) as well as login (-l): nvm and friends initialize in
    ///   rc files a plain login shell never reads; stdin is /dev/null so
    ///   nothing can prompt. csh/tcsh REJECT -l combined with any other flag
    ///   ("Unknown option"), so they get plain -i -c — csh-family PATH setup
    ///   lives in .cshrc/.tcshrc anyway. fish needs its own script because its
    ///   $PATH is a LIST that echoes space-separated (and paths contain
    ///   spaces), so it colon-joins explicitly.
    /// - The pipe is read INCREMENTALLY and parsed even on timeout: an rc file
    ///   that spawns a background process (ssh agent, tmux hook) leaves the
    ///   write end open and holds off EOF forever, and waiting for EOF would
    ///   throw away a marker line that arrived within milliseconds.
    /// Cached on success only — and re-validated on read — so "Check Again"
    /// after installing codex (or nvm-switching it away) actually re-probes.
    private static func loginShellCodexURL() -> URL? {
        if let cached = shellProbeCache.get() { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let marker = "POPCHAT-CODEX-PATH:"
        let flags: [String]
        let script: String
        switch shellName {
        case "csh", "tcsh":
            flags = ["-i", "-c"]
            script = "echo \(marker)$PATH"
        case "fish":
            flags = ["-l", "-i", "-c"]
            script = "echo \(marker)(string join : $PATH)"
        default: // zsh, bash, dash, ksh, …
            flags = ["-l", "-i", "-c"]
            script = "echo \(marker)$PATH"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = flags + [script]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        do { try process.run() } catch { return nil }

        let buffer = ProbeBuffer(marker: marker)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        buffer.waitForMarkerLine(timeout: 10)
        stdout.fileHandleForReading.readabilityHandler = nil
        // Done either way — a shell still alive here is stuck in an rc file.
        // (No waitUntilExit: Process reaps the child on its own, and the whole
        // point of the incremental read is not to wait on stragglers.)
        if process.isRunning { process.terminate() }

        guard let path = buffer.markerPayload()?
            .split(separator: ":")
            .map({ $0.trimmingCharacters(in: .whitespaces) + "/codex" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let url = URL(fileURLWithPath: path)
        shellProbeCache.set(url)
        return url
    }

    private static let shellProbeCache = ShellProbeCache()

    private final class ShellProbeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var found: URL?
        /// Re-validated on every read: an nvm/npm version switch deletes the
        /// old bin directory, and "Check Again" must re-probe rather than
        /// resurrect a dead path until relaunch.
        func get() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = found, !FileManager.default.isExecutableFile(atPath: cached.path) {
                found = nil
            }
            return found
        }
        func set(_ url: URL) { lock.lock(); defer { lock.unlock() }; found = url }
    }

    /// Thread-safe accumulator for the shell probe's stdout: the readability
    /// handler appends from FileHandle's own queue, the probing queue blocks
    /// until a COMPLETE marker line is present (PATH can span chunks), the pipe
    /// closes, or the deadline passes — whichever comes first.
    private final class ProbeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private let marker: String
        private var data = Data()
        private var closed = false

        init(marker: String) { self.marker = marker }

        func append(_ chunk: Data) {
            lock.lock()
            if chunk.isEmpty { closed = true } else { data.append(chunk) }
            let done = closed || completedMarkerLine() != nil
            lock.unlock()
            if done { ready.signal() }
        }

        func waitForMarkerLine(timeout: TimeInterval) {
            _ = ready.wait(timeout: .now() + timeout)
        }

        /// The text after the marker, once its line is complete — or whatever
        /// of it arrived, when the pipe closed or the deadline hit.
        func markerPayload() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let line = completedMarkerLine() { return line }
            // Deadline/EOF fallback: take the partial tail. A truncated PATH
            // still yields its complete leading entries after the colon split.
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: marker, options: .backwards) else { return nil }
            return String(text[range.upperBound...])
        }

        /// Caller must hold `lock`.
        private func completedMarkerLine() -> String? {
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: marker, options: .backwards) else { return nil }
            let tail = text[range.upperBound...]
            guard let newline = tail.firstIndex(of: "\n") else { return nil }
            return String(tail[..<newline])
        }
    }

    static func inspect(includeModels: Bool = true) async throws -> Inspection {
        let holder = SessionHolder()
        return try await withThrowingTaskGroup(of: Inspection.self) { group in
            group.addTask(priority: .userInitiated) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Inspection, Error>) in
                        // FileHandle.availableData is deliberately blocking. Keep it
                        // off Swift's cooperative executor so a slow Codex process
                        // cannot starve unrelated async work.
                        let queue = DispatchQueue(
                            label: "com.chenle.PopChat.codex-app-server.inspect.\(UUID().uuidString)",
                            qos: .userInitiated
                        )
                        queue.async {
                            continuation.resume(with: Result {
                                try inspectBlocking(
                                    includeModels: includeModels,
                                    holder: holder
                                )
                            })
                        }
                    }
                } onCancel: {
                    holder.stop()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                holder.stop()
                throw ClientError(message: "Codex app-server did not answer within 30 seconds. Update Codex and check its login, then try again.")
            }
            defer {
                group.cancelAll()
                holder.stop()
            }
            guard let first = try await group.next() else {
                throw ClientError(message: "Codex app-server check ended unexpectedly.")
            }
            return first
        }
    }

    private static func inspectBlocking(
        includeModels: Bool,
        holder: SessionHolder
    ) throws -> Inspection {
        // Resolved HERE, on the dedicated queue, not in async `inspect` — the
        // login-shell probe inside executableURL() can block for seconds and
        // must stay off the cooperative pool. The 30s race in `inspect` covers
        // the probe as well.
        guard let executable = executableURL() else {
            throw ClientError(message: missingMessage, reason: .missing)
        }
        let session = try Session(executable: executable)
        holder.set(session)
        defer { session.stop() }
        try holder.checkCancellation()
        try session.initialize()
        let account = try readChatGPTAccount(session)

        guard includeModels else {
            return Inspection(
                email: account.email, plan: account.plan,
                models: [], defaultModel: nil,
                supportedEfforts: [:], defaultEfforts: [:]
            )
        }
        let response = try session.request(method: "model/list", params: [
            "includeHidden": .bool(false),
            "limit": .integer(200),
        ])
        let result = try responseResult(response, method: "model/list")
        let entries = result["data"]?.arrayValue ?? []
        let models = entries.compactMap { $0.objectValue?["id"]?.stringValue }
        let defaultModel = entries.first {
            $0.objectValue?["isDefault"]?.boolValue == true
        }?.objectValue?["id"]?.stringValue
        var supportedEfforts: [String: [String]] = [:]
        var defaultEfforts: [String: String] = [:]
        for entry in entries {
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue else { continue }
            let efforts = (object["supportedReasoningEfforts"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["reasoningEffort"]?.stringValue }
            if !efforts.isEmpty { supportedEfforts[id] = efforts }
            if let defaultEffort = object["defaultReasoningEffort"]?.stringValue {
                defaultEfforts[id] = defaultEffort
            }
        }
        guard !models.isEmpty else {
            throw ClientError(message: "Codex app-server returned no available models. Update Codex and try again.")
        }
        return Inspection(
            email: account.email,
            plan: account.plan,
            models: models,
            defaultModel: defaultModel,
            supportedEfforts: supportedEfforts,
            defaultEfforts: defaultEfforts
        )
    }

    /// Replaces Codex's own base instructions — the coding-agent harness prompt
    /// it prepends to every thread — with one that describes what PopChat
    /// actually is.
    ///
    /// Measured on codex-cli 0.149.0 with PopChat's real developer
    /// instructions: 9,176 → 5,640 input tokens with search off, 15,613 →
    /// 12,081 with search on. That preamble is paid on EVERY turn, including a
    /// two-line question, and it describes tools PopChat has already disabled at
    /// launch (`--disable shell_tool` and siblings in Session.init).
    ///
    /// This is not a security control and must never be treated as one. The
    /// containment is the disabled tools, `sandbox: read-only`,
    /// `networkAccess: false` and `approvalPolicy: never`; removing Codex's
    /// preamble removes a DESCRIPTION of capabilities that are already gone.
    /// PopChat's own system prompt and sandbox boundary stay in
    /// `developerInstructions`, so the split remains honest: this is the
    /// harness, that is what the user asked for.
    ///
    /// Verified that Codex's native `web_search` still fires under it — the
    /// tool is registered at launch, not described into existence here.
    static let chatBaseInstructions = """
    You are a helpful assistant answering in a small desktop chat panel. \
    Prefer concise, well-formatted Markdown.
    """

    /// One-shot entry point: runs a single turn and tears the session down.
    ///
    /// Delegates to `CodexAppServerBackend` rather than duplicating the turn
    /// loop, so the deterministic harnesses exercise the SAME code the app runs.
    /// The app itself goes through the backend directly and keeps it alive
    /// across a conversation's turns — which is the entire point, so anything
    /// calling this instead is opting out of prompt caching.
    static func run(
        history: [OpenAIChatClient.WireMessage],
        config: ProviderConfig,
        webSearch: Bool = false,
        executableOverride: URL? = nil,
        inactivityTimeout: TimeInterval = 300
    ) -> AsyncStream<ChatStreamEvent> {
        let backend = CodexAppServerBackend(
            executableOverride: executableOverride,
            inactivityTimeout: inactivityTimeout
        )
        let turn = ChatTurn(
            transcript: history, config: config, webAccess: nil, codexWebSearch: webSearch
        )
        return AsyncStream { continuation in
            let inner = backend.stream(turn)
            let pump = Task {
                for await event in inner { continuation.yield(event) }
                backend.discard()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pump.cancel()
                backend.discard()
            }
        }
    }

    /// The thread-level instructions for a turn: PopChat's own system prompt,
    /// then the boundary this provider is bound by.
    ///
    /// Says nothing about network when web search is on: the old blanket "no
    /// tool network access" line reads as an instruction not to search, and the
    /// model would obey it over the tool being present.
    ///
    /// A `thread/start` parameter, not a per-turn one — which is why a change
    /// here has to invalidate a live thread (see `CodexAppServerBackend`).
    fileprivate static func developerInstructions(
        systemPrompt: String?, webSearch: Bool
    ) -> String {
        let boundary = webSearch
            ? """
            You are serving a normal chat inside PopChat. Do not inspect local files, run shell commands, modify files, call MCP tools, spawn agents, or otherwise act on the user's computer. Answer from the conversation, using web search when the question needs current or external information. PopChat has started this thread with a read-only filesystem and no local tool network access.
            """
            : """
            You are serving a normal chat inside PopChat. Do not inspect local files, run shell commands, modify files, call MCP tools, spawn agents, or otherwise act on the user's computer. Answer directly from the conversation. PopChat has started this thread with read-only filesystem and no tool network access.
            """
        return [systemPrompt, boundary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    fileprivate static func threadStartParams(
        developerInstructions: String,
        model: String,
        sandboxDirectory: URL,
        withBaseInstructions: Bool
    ) -> JSONObject {
        var params: JSONObject = [
            "approvalPolicy": .string("never"),
            "cwd": .string(sandboxDirectory.path),
            "developerInstructions": .string(developerInstructions),
            "ephemeral": .bool(true),
            "model": .string(model),
            "sandbox": .string("read-only"),
            "serviceName": .string("popchat"),
        ]
        if withBaseInstructions {
            params["baseInstructions"] = .string(chatBaseInstructions)
        }
        return params
    }

    /// Assembly key for a reasoning delta: the item id plus the part index the
    /// protocol requires on that notification, so separate thoughts under one
    /// item stay separate entries.
    fileprivate static func reasoningKey(_ params: JSONObject, index: String) -> String {
        let itemID = params["itemId"]?.stringValue ?? ""
        let part = params[index]?.intValue ?? 0
        return "\(itemID)#\(part)"
    }

    /// Ordered assembly of one turn's agentMessage items.
    ///
    /// The app-server protocol requires `itemId` on every agentMessage delta and
    /// `item.id` on every completion (schema: `AgentMessageDeltaNotification` /
    /// `AgentMessageThreadItem`), so assembly must honor that keying rather than
    /// folding deltas into one running string:
    /// - a delta appends to ITS item, never to whichever item streamed last;
    /// - `item/completed` text is authoritative for its id, and a REPLAYED
    ///   completion settles the same entry again instead of appending a
    ///   duplicate item;
    /// - a retryable turn error (`willRetry: true`) drops in-flight items only:
    ///   the retry re-delivers the aborted item's content, and appending that
    ///   re-stream onto the aborted half is exactly the prefix-duplication bug.
    ///   Completed items are not re-sent, so they stay.
    struct ItemAssembly {
        private struct Entry {
            var id: String
            var text: String
            var completed: Bool
        }

        private var entries: [Entry] = []

        mutating func delta(id: String, text: String) {
            if let index = entries.lastIndex(where: { $0.id == id }) {
                // A delta for an id that already settled is a replay; the
                // completed text is authoritative, so late deltas are noise.
                guard !entries[index].completed else { return }
                entries[index].text += text
            } else {
                entries.append(Entry(id: id, text: text, completed: false))
            }
        }

        mutating func completed(id: String, text: String) {
            if let index = entries.lastIndex(where: { $0.id == id }) {
                // The item's own text wins over the deltas reassembled for it;
                // fall back to those when it carries none.
                if !text.isEmpty { entries[index].text = text }
                entries[index].completed = true
            } else if !text.isEmpty {
                entries.append(Entry(id: id, text: text, completed: true))
            }
        }

        /// Reports whether anything was dropped, so the caller knows the
        /// visible snapshot shrank and must be re-yielded.
        mutating func dropInFlight() -> Bool {
            let count = entries.count
            entries.removeAll { !$0.completed }
            return entries.count != count
        }

        var snapshot: String {
            entries.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    fileprivate static func timeoutMessage(_ seconds: TimeInterval) -> String {
        let duration: String
        if seconds >= 60 {
            duration = "\(Int((seconds / 60).rounded())) minutes"
        } else if seconds >= 1 {
            duration = "\(Int(seconds.rounded())) seconds"
        } else {
            duration = "\(Int((seconds * 1_000).rounded())) milliseconds"
        }
        return "Codex app-server stopped responding: no protocol event arrived for \(duration). Stop the turn or update Codex, then try again."
    }

    fileprivate static let missingMessage = "Codex is not installed or PopChat cannot find it. Install Codex yourself and run `codex login`. If it is already installed, run `which codex` in Terminal and paste the result into the Codex path field in Settings → Providers."

    fileprivate struct Account: Sendable {
        var email: String?
        var plan: String?
    }

    fileprivate static func readChatGPTAccount(_ session: Session) throws -> Account {
        let response = try session.request(method: "account/read", params: ["refreshToken": .bool(false)])
        let result = try responseResult(response, method: "account/read")
        guard let account = result["account"]?.objectValue else {
            throw ClientError(
                message: "Codex is installed but not signed in. Run `codex login` in Terminal, then check again.",
                reason: .notSignedIn
            )
        }
        guard account["type"]?.stringValue == "chatgpt" else {
            throw ClientError(
                message: "Codex is not using a ChatGPT subscription. Run `codex login` and choose ChatGPT sign-in, then check again.",
                reason: .notSignedIn
            )
        }
        return Account(email: account["email"]?.stringValue, plan: account["planType"]?.stringValue)
    }

    fileprivate static func responseResult(_ response: JSONObject, method: String) throws -> JSONObject {
        if let error = response["error"]?.objectValue {
            let detail = error["message"]?.stringValue ?? "unknown protocol error"
            throw ClientError(message: "Codex app-server rejected \(method): \(detail). Try updating Codex.")
        }
        guard let result = response["result"]?.objectValue else {
            throw ClientError(message: "Codex app-server returned an invalid \(method) response. Try updating Codex.")
        }
        return result
    }

    fileprivate struct HistorySplit {
        var systemPrompt: String?
        /// Every user/assistant message up to and INCLUDING the user message
        /// this turn is about — the exact sequence a thread must hold to answer
        /// it. The last element is always the user message; anything the store
        /// appended after it (the empty streaming row) is dropped.
        ///
        /// Returned whole rather than pre-split into prior/current because a
        /// backend holding a live thread needs to know which of these it has
        /// already delivered, and that is a comparison over the whole sequence.
        var conversational: [OpenAIChatClient.WireMessage]

        var priorMessages: ArraySlice<OpenAIChatClient.WireMessage> { conversational.dropLast() }
        var currentMessage: OpenAIChatClient.WireMessage { conversational[conversational.count - 1] }
    }

    fileprivate static func splitHistory(_ history: [OpenAIChatClient.WireMessage]) throws -> HistorySplit {
        let system = history.first { $0.role == "system" }.flatMap(textContent)
        let conversational = history.filter { $0.role == "user" || $0.role == "assistant" }
        guard let lastUser = conversational.lastIndex(where: { $0.role == "user" }) else {
            throw ClientError(message: "The Codex app-server request has no user message.")
        }
        return HistorySplit(
            systemPrompt: system,
            conversational: Array(conversational[...lastUser])
        )
    }

    private static func textContent(_ message: OpenAIChatClient.WireMessage) -> String? {
        switch message.content {
        case .text(let text): return text
        case .parts(let parts): return parts.compactMap(\.text).joined(separator: "\n")
        case nil: return nil
        }
    }

    /// Raw Responses API item accepted by `thread/inject_items`.
    fileprivate static func responseItem(_ message: OpenAIChatClient.WireMessage) -> JSONValue {
        let assistant = message.role == "assistant"
        let textType = assistant ? "output_text" : "input_text"
        var content: [JSONValue] = []
        switch message.content {
        case .text(let text):
            content.append(.object(["type": .string(textType), "text": .string(text)]))
        case .parts(let parts):
            for part in parts {
                if let text = part.text {
                    content.append(.object(["type": .string(textType), "text": .string(text)]))
                } else if let image = part.imageURL {
                    content.append(.object(["type": .string("input_image"), "image_url": .string(image.url)]))
                }
            }
        case nil:
            break
        }
        return .object([
            "type": .string("message"),
            "role": .string(message.role),
            "content": .array(content),
        ])
    }

    fileprivate static func turnInput(_ message: OpenAIChatClient.WireMessage) -> [JSONValue] {
        var input: [JSONValue] = []
        switch message.content {
        case .text(let text):
            input.append(.object(["type": .string("text"), "text": .string(text)]))
        case .parts(let parts):
            for part in parts {
                if let text = part.text {
                    input.append(.object(["type": .string("text"), "text": .string(text)]))
                } else if let image = part.imageURL {
                    input.append(.object(["type": .string("image"), "url": .string(image.url)]))
                }
            }
        case nil:
            break
        }
        return input
    }

    /// The transcript row for a web search, labeled from `item/completed` ONLY:
    /// the protocol's begin event carries just a call id — the query arrives
    /// with the end event — so labeling at `item/started` printed a bare
    /// "searched the web:" with nothing after the colon.
    fileprivate static func webSearchLabel(_ item: JSONObject) -> String {
        let query = (item["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? "Codex app-server searched the web."
            : "Codex app-server searched the web: \(query)"
    }

    fileprivate static func activityLabel(item: JSONObject?) -> String? {
        guard let item, let type = item["type"]?.stringValue else { return nil }
        switch type {
        case "commandExecution":
            return "⚠︎ Codex app-server attempted a local command; PopChat's read-only, no-approval policy applies."
        case "fileChange":
            return "⚠︎ Codex app-server attempted a file change; PopChat's read-only policy applies."
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return "⚠︎ Codex app-server attempted a tool call; PopChat did not grant additional permissions."
        default:
            return nil
        }
    }

    fileprivate static func friendlyError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") {
            return "Your ChatGPT plan's Codex usage limit was reached. \(message)"
        }
        return "Codex app-server: \(message)"
    }

    fileprivate static func appServerWorkingDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "PopChat/codex-app-server-sandbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Backend

/// The Codex app-server as a `ChatBackend`.
///
/// Lives in this file rather than beside the protocol because the JSONL
/// transport below it (`Session`, `JSONValue`) is deliberately file-private:
/// nothing outside this adapter should be able to speak the protocol directly.
/// Holds ONE `codex` child process and ONE ephemeral thread across the turns of
/// a conversation, so a follow-up question reuses the backend's prompt cache
/// instead of replaying the transcript into a brand-new thread.
///
/// Measured on codex-cli 0.149.0: a second turn in a live thread reported 11,008
/// of 11,635 input tokens cached, while two fresh threads seconds apart with the
/// same prefix cached nothing at all. The cache keys off the SESSION, not off
/// prefix content, so the only way to have it is to keep the thread.
///
/// The safety argument this rests on, in one sentence: the store's transcript is
/// authoritative and the live thread is a pure cache, reused only when the
/// backend can prove — by fingerprint, message by message — that the thread was
/// told exactly the prefix the store now believes. Anything else rebuilds.
///
/// Ephemeral threads are deliberate. Nothing here is persisted or resumable:
/// `thread/resume` reads rollout state from disk that an ephemeral thread never
/// writes, and it would not restore the backend-side cache anyway.
final class CodexAppServerBackend: ChatBackend {
    private let executableOverride: URL?
    private let inactivityTimeout: TimeInterval

    /// Serial, and the reason "at most one turn in flight" holds by
    /// construction. It matters because `ChatStore` releases the composer
    /// before a turn's tail finishes (see its streamTask), so Stop followed
    /// immediately by a new send is a real interleaving: the second turn's block
    /// simply runs after the first one's teardown, and if that teardown dirtied
    /// the session, the second turn rebuilds.
    private let queue = DispatchQueue(
        label: "com.chenle.PopChat.codex-app-server.turn", qos: .userInitiated
    )
    /// Cancellation must never queue behind the turn it is cancelling.
    private let cancelQueue = DispatchQueue(
        label: "com.chenle.PopChat.codex-app-server.cancel", qos: .userInitiated
    )
    /// The interrupt's fallback timer lives on its OWN queue: if the interrupt
    /// write blocks, `cancelQueue` is stuck, and a fallback scheduled there
    /// could never fire — which is the one thing the fallback exists for.
    private let fallbackQueue = DispatchQueue(
        label: "com.chenle.PopChat.codex-app-server.cancel-fallback", qos: .userInitiated
    )

    /// How long after an interrupt to give up and kill the child.
    private static let interruptGrace: TimeInterval = 1

    /// Idle lifetime of the child process.
    ///
    /// Defaults to `ChatStore.staleAfter` deliberately: past that window a
    /// non-pinned conversation has been replaced by a fresh chat anyway, so the
    /// session would be dropped regardless — and a PINNED conversation is
    /// exactly the case where a resident `codex` would otherwise sit for hours
    /// holding memory for a chat nobody is having. One knob, not two that drift.
    ///
    /// Note the store's own staleness reset only runs when the panel is
    /// SUMMONED (`startFreshIfStale`). Dismiss the panel and never come back and
    /// this timer is the only thing that retires the child, which is why it is a
    /// real mechanism rather than a backstop.
    private let idleTimeout: TimeInterval

    private let lock = NSLock()
    private var session: Session?
    private var threadID: String?
    /// What the live child was LAUNCHED with. `web_search` is a process
    /// argument, so flipping the globe needs a new process — unlike model and
    /// effort, which ride on `turn/start` and were verified to override the
    /// values `thread/start` pinned.
    private var launchedWebSearch: Bool?
    /// What the live thread was STARTED with. A `thread/start` parameter, so a
    /// change needs a new thread but not a new process.
    private var threadInstructions: String?
    /// Fingerprints of the wire messages this thread has already been given,
    /// in order.
    private var delivered: [Int] = []
    private var dirty = false
    private var turnEpoch = 0
    private var turnInFlight = false
    /// Nil until `turn/started` names the turn — which is why cancelling during
    /// setup has to fall back to killing the child.
    private var activeTurnID: String?
    private var lastTurnID: String?
    private var currentWatchdog: InactivityWatchdog?
    private var idleTimer: DispatchSourceTimer?

    struct TokenUsage: Equatable {
        var input: Int
        var cached: Int
    }
    private var lastTokenUsage: TokenUsage?

    /// What the most recent turn reported. Diagnostic only — nothing in the app
    /// reads it; the live cache harness does.
    var tokenUsage: TokenUsage? {
        lock.lock()
        defer { lock.unlock() }
        return lastTokenUsage
    }

    /// The overrides exist for the deterministic smoke harnesses, which drive a
    /// fake app-server executable and a short timeout.
    init(
        executableOverride: URL? = nil,
        inactivityTimeout: TimeInterval = 300,
        idleTimeout: TimeInterval = ChatStore.staleAfter
    ) {
        self.executableOverride = executableOverride
        self.inactivityTimeout = inactivityTimeout
        self.idleTimeout = idleTimeout
    }

    deinit {
        session?.stop()
        idleTimer?.cancel()
    }

    // MARK: - ChatBackend

    func stream(_ turn: ChatTurn) -> AsyncStream<ChatStreamEvent> {
        AsyncStream { continuation in
            let watchdog = InactivityWatchdog(timeout: max(inactivityTimeout, 0.05)) {
                [weak self] in
                // A child that has stopped speaking the protocol is unusable, so
                // this kills it outright; the blocked read then returns and the
                // turn reports the timeout.
                self?.discard()
            }
            queue.async { [self] in
                runTurn(turn, watchdog: watchdog, continuation: continuation)
                watchdog.cancel()
                continuation.finish()
            }
            continuation.onTermination = { [weak self] reason in
                watchdog.cancel()
                // `.finished` is the NORMAL end of every turn. Cancelling there
                // would interrupt and then kill the very session this class
                // exists to keep, respawn on every turn, and present as
                // "caching is still broken" — this feature's own bug, delivered
                // by its safety wiring.
                if case .cancelled = reason { self?.cancelTurn() }
            }
        }
    }

    func cancelTurn() {
        cancelQueue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            // No-op when nothing is running: ChatStore.stop() can race a turn
            // that just ended, and the stream's termination handler asks for the
            // same thing this call already did.
            guard turnInFlight, let session else { lock.unlock(); return }
            let epoch = turnEpoch
            let thread = threadID
            let turnID = activeTurnID
            lock.unlock()

            // Armed BEFORE the write, not after. A cancel that blocks on the
            // write lock behind a wedged 1 MB inject_items would never reach a
            // later arming step, leaving nothing but the inactivity watchdog to
            // bound the hang.
            armInterruptFallback(epoch: epoch)

            guard let thread, let turnID else {
                // Stopped during setup — spawn, initialize, inject — where no
                // turn exists to interrupt. Killing the child is what PopChat
                // did for every cancellation before `turn/interrupt`, and it is
                // still the right answer here.
                discard()
                return
            }
            _ = try? session.beginRequest(method: "turn/interrupt", params: [
                "threadId": .string(thread),
                "turnId": .string(turnID),
            ])
        }
    }

    func discard() {
        lock.lock()
        let dying = session
        session = nil
        threadID = nil
        launchedWebSearch = nil
        threadInstructions = nil
        delivered = []
        dirty = false
        activeTurnID = nil
        idleTimer?.cancel()
        idleTimer = nil
        lock.unlock()
        dying?.stop()
    }

    // MARK: - Cancellation fallback

    private func armInterruptFallback(epoch: Int) {
        fallbackQueue.asyncAfter(deadline: .now() + Self.interruptGrace) { [weak self] in
            guard let self else { return }
            lock.lock()
            // The epoch guard is not belt-and-braces. Without it: stop at t=0
            // arms this, the interrupt lands at t=0.2 and dirties the thread,
            // the user sends again immediately, the new turn starts a fresh
            // thread on the SAME live process at t=0.3 — and this timer kills
            // that process mid-turn at t=1.0.
            let stale = turnEpoch != epoch || !turnInFlight
            lock.unlock()
            guard !stale else { return }
            discard()
        }
    }

    // MARK: - Turn

    private enum TurnOutcome {
        /// The thread now holds this answer and may be reused.
        case clean(answer: String, fingerprints: [Int])
        /// Anything else. `killProcess` distinguishes a thread that merely
        /// disagrees with the store from a child that is no longer usable.
        case spoiled(killProcess: Bool)
    }

    private func runTurn(
        _ turn: ChatTurn,
        watchdog: InactivityWatchdog,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) {
        let epoch = beginTurn(watchdog: watchdog)
        var outcome = TurnOutcome.spoiled(killProcess: false)
        defer { endTurn(epoch: epoch, outcome: outcome) }

        do {
            let split = try CodexAppServerClient.splitHistory(turn.transcript)
            let instructions = CodexAppServerClient.developerInstructions(
                systemPrompt: split.systemPrompt, webSearch: turn.codexWebSearch
            )
            let fingerprints = split.conversational.map(Self.fingerprint)

            let prepared = try prepare(
                turn: turn, split: split, instructions: instructions,
                fingerprints: fingerprints, watchdog: watchdog, continuation: continuation
            )

            var turnParams: JSONObject = [
                "approvalPolicy": .string("never"),
                "input": .array(CodexAppServerClient.turnInput(split.currentMessage)),
                "model": .string(turn.config.model),
                "sandboxPolicy": .object([
                    "type": .string("readOnly"),
                    "networkAccess": .bool(false),
                ]),
                "threadId": .string(prepared.threadID),
            ]
            if let effort = turn.config.reasoningEffort {
                turnParams["effort"] = .string(effort)
            }
            // A turn can start emitting notifications before app-server writes the
            // matching JSON-RPC response. Waiting through `request` would buffer
            // those deltas and make the whole answer appear at once.
            continuation.yield(.status("Waiting for \(turn.config.model)…"))
            let turnRequestID = try prepared.session.beginRequest(
                method: "turn/start", params: turnParams
            )
            outcome = try readTurn(
                session: prepared.session,
                turnRequestID: turnRequestID,
                fingerprints: fingerprints,
                watchdog: watchdog,
                continuation: continuation
            )
        } catch is CancellationError {
            if watchdog.didTimeOut {
                continuation.yield(.error(CodexAppServerClient.timeoutMessage(inactivityTimeout)))
            }
            outcome = .spoiled(killProcess: true)
        } catch let error as CodexAppServerClient.ClientError {
            if watchdog.didTimeOut {
                continuation.yield(.error(CodexAppServerClient.timeoutMessage(inactivityTimeout)))
            } else if !isDiscarded {
                continuation.yield(.error(error.message))
            }
            outcome = .spoiled(killProcess: true)
        } catch {
            if watchdog.didTimeOut {
                continuation.yield(.error(CodexAppServerClient.timeoutMessage(inactivityTimeout)))
            } else if !isDiscarded {
                continuation.yield(.error("Codex app-server failed: \(error.localizedDescription)"))
            }
            outcome = .spoiled(killProcess: true)
        }
    }

    private struct Prepared {
        var session: Session
        var threadID: String
    }

    /// Resolves this turn to a live session and thread, reusing as much as can
    /// be PROVEN reusable and rebuilding the rest.
    private func prepare(
        turn: ChatTurn,
        split: CodexAppServerClient.HistorySplit,
        instructions: String,
        fingerprints: [Int],
        watchdog: InactivityWatchdog,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) throws -> Prepared {
        lock.lock()
        let live = session
        let liveThread = threadID
        let liveWebSearch = launchedWebSearch
        let liveInstructions = threadInstructions
        let liveDelivered = delivered
        let spoiled = dirty
        lock.unlock()

        // Every condition is a thing that would make the thread's history
        // disagree with the transcript, or a `thread/start`/launch parameter
        // that the thread was fixed with.
        let reusableThread = !spoiled
            && live != nil
            && live?.isRunning == true
            && liveThread != nil
            && liveWebSearch == turn.codexWebSearch
            && liveInstructions == instructions
            && liveDelivered.count < fingerprints.count
            && Array(fingerprints.prefix(liveDelivered.count)) == liveDelivered

        if reusableThread, let live, let liveThread {
            // The thread already holds everything up to `liveDelivered.count`;
            // hand it only what it has not seen.
            try inject(
                Array(split.conversational.dropFirst(liveDelivered.count).dropLast()),
                session: live, threadID: liveThread
            )
            return Prepared(session: live, threadID: liveThread)
        }

        // A live child can still host a NEW thread — which is why an interrupt
        // or a dirty turn costs a thread/start, not a respawn. Only a web-search
        // change (a launch argument) forces a new process.
        var active: Session
        if let live, live.isRunning, liveWebSearch == turn.codexWebSearch {
            active = live
        } else {
            discard()
            // Spawning means seconds of silence before the first token — say
            // what is happening or the app reads as frozen. `.status` is
            // transient (the waiting row), not a permanent transcript row.
            continuation.yield(.status("Starting Codex…"))
            guard let executable = executableOverride ?? CodexAppServerClient.executableURL() else {
                throw CodexAppServerClient.ClientError(
                    message: CodexAppServerClient.missingMessage, reason: .missing
                )
            }
            let fresh = try Session(
                executable: executable,
                webSearch: turn.codexWebSearch,
                // Forwards to whichever turn is running, NOT to the watchdog
                // that happened to be current when the child was spawned —
                // a session outlives its first turn now, and a stale watchdog
                // would never be kicked again.
                onMessage: { [weak self] in self?.kickWatchdog() }
            )
            lock.lock()
            session = fresh
            launchedWebSearch = turn.codexWebSearch
            threadID = nil
            threadInstructions = nil
            delivered = []
            lock.unlock()
            // The watchdog's clock starts when it is CONSTRUCTED, which is before
            // this queue was even scheduled and before the child was spawned.
            // Resolving the executable and launching Codex (cold start, Gatekeeper
            // scan on first run) is not the process being unresponsive — start
            // measuring silence only now that it is actually up.
            watchdog.kick()
            try fresh.initialize()
            _ = try CodexAppServerClient.readChatGPTAccount(fresh)
            active = fresh
        }

        let thread = try startThread(
            session: active, instructions: instructions, model: turn.config.model
        )
        lock.lock()
        threadID = thread
        threadInstructions = instructions
        delivered = []
        dirty = false
        lock.unlock()

        try inject(Array(split.priorMessages), session: active, threadID: thread)
        return Prepared(session: active, threadID: thread)
    }

    private func startThread(session: Session, instructions: String, model: String) throws -> String {
        let sandboxDirectory = try CodexAppServerClient.appServerWorkingDirectory()
        func params(_ withBaseInstructions: Bool) -> JSONObject {
            CodexAppServerClient.threadStartParams(
                developerInstructions: instructions,
                model: model,
                sandboxDirectory: sandboxDirectory,
                withBaseInstructions: withBaseInstructions
            )
        }
        // Retried ONCE without `baseInstructions` on any thread/start failure.
        // PopChat runs whatever `codex` the user has installed (see
        // executableURL), and a build predating the parameter would otherwise
        // turn a token optimization into a provider that cannot start a thread
        // at all. Deliberately not conditioned on the error text: that prose is
        // the server's to reword, and this file already treats
        // substring-matching it as a bug (see ClientError.Reason).
        let result: JSONObject
        do {
            result = try CodexAppServerClient.responseResult(
                try session.request(method: "thread/start", params: params(true)),
                method: "thread/start"
            )
        } catch {
            result = try CodexAppServerClient.responseResult(
                try session.request(method: "thread/start", params: params(false)),
                method: "thread/start"
            )
        }
        guard let id = result["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerClient.ClientError(
                message: "Codex app-server returned an invalid thread/start response."
            )
        }
        return id
    }

    private func inject(
        _ messages: [OpenAIChatClient.WireMessage], session: Session, threadID: String
    ) throws {
        guard !messages.isEmpty else { return }
        let response = try session.request(method: "thread/inject_items", params: [
            "threadId": .string(threadID),
            "items": .array(messages.map(CodexAppServerClient.responseItem)),
        ])
        _ = try CodexAppServerClient.responseResult(response, method: "thread/inject_items")
    }

    /// The turn's event loop. Returns what the session may be used for next.
    private func readTurn(
        session: Session,
        turnRequestID: Int64,
        fingerprints: [Int],
        watchdog: InactivityWatchdog,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) throws -> TurnOutcome {
        // A turn can produce SEVERAL agentMessage items (a preamble, then the
        // answer), and the protocol keys every delta and completion by item
        // id. `ItemAssembly` holds that shape; its doc comment carries the
        // laws (authoritative idempotent completions, willRetry semantics).
        var items = CodexAppServerClient.ItemAssembly()
        // Thinking, assembled the same way and shown in the collapsed
        // reasoning disclosure. Two streams, never interleaved: the backend
        // emits `summaryTextDelta` for summarized reasoning and
        // `textDelta` for raw reasoning, so summaries win and raw text is
        // the fallback for models that summarize nothing.
        //
        // Local to the turn, not the session: reasoning belongs to the answer
        // being written, so a reused thread must not carry the previous turn's
        // thinking into this one.
        var reasoningSummary = CodexAppServerClient.ItemAssembly()
        var reasoningRaw = CodexAppServerClient.ItemAssembly()
        func reasoningSnapshot() -> String {
            let summary = reasoningSummary.snapshot
            return summary.isEmpty ? reasoningRaw.snapshot : summary
        }
        var outcome: TurnOutcome?

        while outcome == nil, let message = try session.nextMessage() {
            if message["id"]?.intValue == turnRequestID {
                _ = try CodexAppServerClient.responseResult(message, method: "turn/start")
                continue
            }
            guard let method = message["method"]?.stringValue,
                  let params = message["params"]?.objectValue else { continue }

            if method == "turn/started" {
                if let id = params["turn"]?.objectValue?["id"]?.stringValue {
                    setActiveTurnID(id)
                }
                continue
            }
            guard accepts(params: params) else { continue }

            switch method {
            case "item/agentMessage/delta":
                if let delta = params["delta"]?.stringValue {
                    // `itemId` is required by the protocol; "" is a last-resort
                    // key so a nonconforming server still streams.
                    items.delta(id: params["itemId"]?.stringValue ?? "", text: delta)
                    continuation.yield(.partial(items.snapshot))
                }
            // Thinking. Keyed like agentMessage deltas, but by item AND
            // part index (`summaryIndex`/`contentIndex` are required by the
            // schema): a model interleaves several summary parts under one
            // item id, and folding them into one entry would concatenate
            // separate thoughts into a run-on paragraph. Consecutive
            // entries join with a blank line, which is exactly the part
            // break `item/reasoning/summaryPartAdded` announces — so that
            // notification needs no handler of its own.
            case "item/reasoning/summaryTextDelta":
                if let delta = params["delta"]?.stringValue {
                    reasoningSummary.delta(
                        id: CodexAppServerClient.reasoningKey(params, index: "summaryIndex"),
                        text: delta
                    )
                    continuation.yield(.reasoning(reasoningSnapshot()))
                }
            case "item/reasoning/textDelta":
                if let delta = params["delta"]?.stringValue {
                    reasoningRaw.delta(
                        id: CodexAppServerClient.reasoningKey(params, index: "contentIndex"),
                        text: delta
                    )
                    continuation.yield(.reasoning(reasoningSnapshot()))
                }
            case "item/started":
                if let activity = CodexAppServerClient.activityLabel(item: params["item"]?.objectValue) {
                    continuation.yield(.activity(activity))
                } else {
                    switch params["item"]?.objectValue?["type"]?.stringValue {
                    case "reasoning":
                        // Reasoning items stream no visible text but can run
                        // for a long time — the one signal that the model is
                        // alive.
                        continuation.yield(.status("Reasoning…"))
                    case "webSearch":
                        continuation.yield(.status("Searching the web…"))
                    default:
                        break
                    }
                }
            case "item/completed":
                guard let item = params["item"]?.objectValue else { continue }
                switch item["type"]?.stringValue {
                case "agentMessage":
                    items.completed(
                        id: item["id"]?.stringValue ?? "",
                        text: item["text"]?.stringValue ?? ""
                    )
                    continuation.yield(.partial(items.snapshot))
                case "webSearch":
                    continuation.yield(.activity(CodexAppServerClient.webSearchLabel(item)))
                default:
                    break
                }
            case "error":
                if params["willRetry"]?.boolValue == true {
                    // Codex is about to re-deliver the aborted attempt, so an
                    // in-flight partial would double up with the re-stream —
                    // drop it, and say what the pause is instead of stalling
                    // silently. NOT a reason to spoil the session: the turn can
                    // still complete cleanly, and giving up the cache here would
                    // punish the transport exactly when it recovered.
                    if items.dropInFlight() {
                        continuation.yield(.partial(items.snapshot))
                    }
                    // Thinking is re-delivered by the retry too, and no
                    // reasoning entry is ever marked completed (the
                    // protocol's authoritative text arrives only for
                    // agentMessage items), so this drops the aborted
                    // attempt's reasoning wholesale — the same
                    // never-glue-a-retry-onto-its-own-prefix rule.
                    // Both assemblies always, so the array rather than `||`,
                    // which would short-circuit past the second drop.
                    let dropped = [
                        reasoningSummary.dropInFlight(), reasoningRaw.dropInFlight(),
                    ]
                    if dropped.contains(true) {
                        continuation.yield(.reasoning(reasoningSnapshot()))
                    }
                    continuation.yield(.status("Temporary error — Codex is retrying…"))
                } else if let message = params["error"]?.objectValue?["message"]?.stringValue {
                    continuation.yield(.error(CodexAppServerClient.friendlyError(message)))
                }
            case "thread/tokenUsage/updated":
                // Not shown anywhere in the UI. Recorded because the entire
                // point of holding a thread open is the cached fraction of the
                // input, and a claim about it should be checkable against the
                // real Codex rather than argued — see
                // `--smoke-codex-app-server-cache`.
                if let last = params["tokenUsage"]?.objectValue?["last"]?.objectValue {
                    lock.lock()
                    lastTokenUsage = TokenUsage(
                        input: Int(last["inputTokens"]?.intValue ?? 0),
                        cached: Int(last["cachedInputTokens"]?.intValue ?? 0)
                    )
                    lock.unlock()
                }
            case "turn/completed":
                let turn = params["turn"]?.objectValue
                let status = turn?["status"]?.stringValue ?? "failed"
                let answer = items.snapshot
                if status == "completed" || status == "interrupted" {
                    continuation.yield(.done(answer))
                } else {
                    let message = turn?["error"]?.objectValue?["message"]?.stringValue
                        ?? "Codex app-server turn failed (status: \(status))."
                    continuation.yield(.error(CodexAppServerClient.friendlyError(message)))
                }
                // Only a clean completion leaves the thread agreeing with the
                // store. An interrupted thread holds a partial answer the panel
                // may have trimmed, and a failed one may hold nothing at all —
                // both rebuild next time, which now costs a thread/start rather
                // than a respawn. An empty answer counts as spoiled too: the
                // store drops an empty assistant row, so the thread would hold
                // an item the transcript does not.
                outcome = (status == "completed" && !answer.isEmpty)
                    ? .clean(answer: answer, fingerprints: fingerprints)
                    : .spoiled(killProcess: false)
            default:
                continue
            }
        }

        if let outcome { return outcome }
        if watchdog.didTimeOut {
            continuation.yield(.error(CodexAppServerClient.timeoutMessage(inactivityTimeout)))
        } else if !isDiscarded {
            continuation.yield(.error("Codex app-server exited before the response completed. Update Codex and try again."))
        }
        return .spoiled(killProcess: true)
    }

    // MARK: - State

    private func beginTurn(watchdog: InactivityWatchdog) -> Int {
        lock.lock()
        turnEpoch += 1
        turnInFlight = true
        activeTurnID = nil
        currentWatchdog = watchdog
        idleTimer?.cancel()
        idleTimer = nil
        let epoch = turnEpoch
        lock.unlock()
        return epoch
    }

    private func endTurn(epoch: Int, outcome: TurnOutcome) {
        lock.lock()
        turnInFlight = false
        lastTurnID = activeTurnID
        activeTurnID = nil
        currentWatchdog = nil
        var kill = false
        switch outcome {
        case .clean(let answer, let fingerprints):
            // The thread now also holds its own reply, so record it: the next
            // turn's transcript will carry that assistant message, and the
            // prefix has to match through it.
            delivered = fingerprints + [Self.fingerprint(
                OpenAIChatClient.WireMessage(role: "assistant", content: .text(answer))
            )]
            dirty = false
        case .spoiled(let killProcess):
            dirty = true
            kill = killProcess
        }
        lock.unlock()
        if kill {
            discard()
        } else {
            armIdleTimer()
        }
    }

    private func armIdleTimer() {
        lock.lock()
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: fallbackQueue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.discard() }
        idleTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func setActiveTurnID(_ id: String) {
        lock.lock()
        activeTurnID = id
        lock.unlock()
    }

    private func kickWatchdog() {
        lock.lock()
        let watchdog = currentWatchdog
        lock.unlock()
        watchdog?.kick()
    }

    private var isDiscarded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session == nil || session?.isRunning == false
    }

    /// Whether a notification belongs to the turn being read.
    ///
    /// Presence-gated on purpose. `turnId` is required by the 0.149.0 schema and
    /// present on every notification observed, but PopChat runs whatever `codex`
    /// the user installed, and filtering strictly against a build that omits it
    /// would drop every delta and render empty replies. When the ids are there,
    /// they are honored: a session outlives its turns now, so a straggler from
    /// the previous turn would otherwise append to the wrong message.
    private func accepts(params: JSONObject) -> Bool {
        let incoming = params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
        guard let incoming else { return true }
        lock.lock()
        let active = activeTurnID
        let previous = lastTurnID
        lock.unlock()
        if let active { return incoming == active }
        // Before `turn/started`, the only id we can rule out is the last turn's.
        return incoming != previous
    }

    /// Identity of a wire message, for deciding whether the live thread has
    /// already been told it.
    ///
    /// Hashed rather than stored: a conversation can carry megabytes of image
    /// data URLs, and this list is consulted on every send. `Hasher` is seeded
    /// per PROCESS, which is exactly this list's lifetime — nothing is
    /// persisted, and a fingerprint from a previous launch would describe a
    /// thread that no longer exists.
    ///
    /// Taken over the RESOLVED wire message, which is what makes it catch more
    /// than edits: `ChatStore.wireContent` re-renders historical attachments
    /// against today's capabilities on every send, so a capability change
    /// alters an already-delivered message's fingerprint and correctly forces a
    /// rebuild.
    private static func fingerprint(_ message: OpenAIChatClient.WireMessage) -> Int {
        var hasher = Hasher()
        hasher.combine(message.role)
        switch message.content {
        case .text(let text):
            hasher.combine(0)
            hasher.combine(text)
        case .parts(let parts):
            hasher.combine(1)
            for part in parts {
                hasher.combine(part.type)
                hasher.combine(part.text)
                hasher.combine(part.imageURL?.url)
                hasher.combine(part.file?.filename)
                hasher.combine(part.file?.fileData)
            }
        case nil:
            hasher.combine(2)
        }
        return hasher.finalize()
    }
}

// MARK: - JSONL process transport

private typealias JSONObject = [String: JSONValue]

/// Small Sendable JSON representation, avoiding `[String: Any]` across the
/// detached process task while keeping the protocol's schemaless extension room.
private enum JSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(JSONObject.self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var objectValue: JSONObject? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var intValue: Int64? {
        switch self {
        case .integer(let value): value
        // Never `Int64(value)`: NaN, ±Infinity or an out-of-range magnitude TRAPS,
        // and this is evaluated on every notification the process sends.
        case .double(let value): Int64(exactly: value)
        default: nil
        }
    }
}

/// Cancellation handle for `inspect`, whose session is genuinely one-shot: it
/// asks the child a few questions and is done.
///
/// Turns do NOT use this. `CodexAppServerBackend` owns its session across turns
/// and cancels with `turn/interrupt` rather than by killing the child, so it
/// keeps that state itself.
private final class SessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?
    private var stopped = false

    func set(_ session: Session) {
        lock.lock()
        if stopped {
            lock.unlock()
            session.stop()
        } else {
            self.session = session
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let active = session
        session = nil
        stopped = true
        lock.unlock()
        active?.stop()
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func checkCancellation() throws {
        if isStopped { throw CancellationError() }
    }
}

/// A turn may legitimately run for a long time, but it must not remain wedged
/// forever after app-server stops producing protocol traffic. This watchdog is
/// reset by every decoded JSONL message and terminates only after an inactivity
/// interval (not a total turn-duration limit).
private final class InactivityWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let onTimeout: @Sendable () -> Void
    private let timer: DispatchSourceTimer
    private var lastActivity = DispatchTime.now().uptimeNanoseconds
    private var stopped = false
    private var timedOut = false

    init(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        self.timeout = max(timeout, 0.05)
        self.onTimeout = onTimeout
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.chenle.PopChat.codex-app-server.watchdog")
        )
        self.timer = timer
        let interval = max(0.05, min(self.timeout / 4, 5))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func kick() {
        lock.lock()
        if !stopped { lastActivity = DispatchTime.now().uptimeNanoseconds }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        timer.cancel()
    }

    private func check() {
        let now = DispatchTime.now().uptimeNanoseconds
        var shouldStop = false
        lock.lock()
        if !stopped {
            let elapsed = Double(now - lastActivity) / 1_000_000_000
            if elapsed >= timeout {
                stopped = true
                timedOut = true
                shouldStop = true
            }
        }
        lock.unlock()
        if shouldStop {
            timer.cancel()
            onTimeout()
        }
    }
}

private final class Session: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let onMessage: @Sendable () -> Void
    private let stateLock = NSLock()
    private var stopped = false
    private var stderrData = Data()
    /// Touched ONLY by the turn queue, which owns the read side end to end. Not
    /// under any lock, and must stay that way: `readMessage` blocks inside
    /// `availableData` for as long as the model is thinking.
    private var readBuffer = Data()
    private var bufferedMessages: [JSONObject] = []

    /// Serializes WRITERS against each other, and nothing else.
    ///
    /// It exists because a session now outlives one turn, so a second writer is
    /// possible: `cancelTurn` writes `turn/interrupt` from a utility queue while
    /// the turn queue is blocked reading. Two concurrent `write(contentsOf:)`
    /// calls could otherwise interleave bytes and corrupt the JSONL framing.
    ///
    /// What it must NEVER become is a lock that teardown waits on. `stop()` and
    /// `appendStderr` take `stateLock` only; no `stateLock` holder ever takes
    /// this. So a writer blocked on a full stdin buffer can stall another
    /// writer — never the Stop button, never the watchdog, never the MainActor.
    /// See `send` for why that distinction is load-bearing.
    private let writeLock = NSLock()

    /// Its own lock rather than `stateLock`: the id is allocated by both the
    /// turn queue and the cancelling utility queue, and holding `stateLock`
    /// across the write that follows is exactly what `send` documents as fatal.
    private let requestIDLock = NSLock()
    private var nextRequestID: Int64 = 1

    /// `stop()` terminates the child precisely when a write may be blocked on its
    /// stdin, so EPIPE is now an EXPECTED outcome rather than a freak one. Its
    /// default disposition (SIGPIPE) kills the whole app; ignoring it makes
    /// `write(contentsOf:)` throw instead, which `send`'s callers already handle.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    init(executable: URL, webSearch: Bool = false, onMessage: @escaping @Sendable () -> Void = {}) throws {
        _ = Session.ignoreSIGPIPE
        self.onMessage = onMessage
        process.executableURL = executable
        // The app-server is used only as a model transport. Disable Codex's
        // machine/connector tool surfaces at process startup as well as using a
        // read-only thread: developer instructions alone are not a security
        // boundary, and read-only would still permit shell-based file reads.
        //
        // `web_search` is deliberately NOT in that set. It grants no access to
        // the user's machine — it runs on the model backend, the sandbox stays
        // read-only and `networkAccess: false` — and Codex owns its own tool
        // loop, so this switch is the only web access this provider can have.
        // It therefore follows PopChat's globe toggle instead of being pinned
        // off; a fresh process per turn is what makes that a launch argument.
        // The key is an ENUM (`disabled`/`cached`/`indexed`/`live`) and Codex
        // refuses to start on an unknown variant, so this is not a Bool spelled
        // as a string: `live` is what `codex --search` sets, the native
        // Responses `web_search` tool. `--smoke-codex-app-server-search` is
        // what catches the variant list changing under us.
        process.arguments = [
            "--disable", "shell_tool",
            "--disable", "unified_exec",
            "--disable", "multi_agent",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "remote_plugin",
            "--disable", "browser_use",
            "--disable", "computer_use",
            "--disable", "image_generation",
            "-c", "web_search=\"\(webSearch ? "live" : "disabled")\"",
            "-c", "mcp_servers={}",
            "-c", "tools_view_image=false",
            "app-server", "--listen", "stdio://",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [executableDirectory, "/opt/homebrew/bin", "/usr/local/bin", existingPath]
            .joined(separator: ":")
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CodexAppServerClient.ClientError(
                message: "Couldn't start Codex at \(executable.path): \(error.localizedDescription)"
            )
        }
        // Drain stderr so a verbose app-server cannot fill its pipe and deadlock,
        // while retaining a short tail for launch/protocol failure messages.
        let stderr = errorOutput.fileHandleForReading
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }
    }

    func initialize() throws {
        let response = try request(method: "initialize", params: [
            "clientInfo": .object([
                "name": .string("popchat"),
                "title": .string("PopChat"),
                "version": .string("1.0.0"),
            ]),
        ])
        _ = try CodexAppServerClient.responseResult(response, method: "initialize")
        try notify(method: "initialized", params: [:])
    }

    func request(method: String, params: JSONObject) throws -> JSONObject {
        let id = try beginRequest(method: method, params: params)
        while let message = try readMessage() {
            if message["id"]?.intValue == id { return message }
            bufferedMessages.append(message)
        }
        throw CodexAppServerClient.ClientError(
            message: "Codex app-server exited while waiting for \(method). Make sure your Codex installation is current.\(stderrSuffix())"
        )
    }

    /// Starts a JSON-RPC request without consuming stdout. Long-running methods
    /// such as `turn/start` use this so their notifications can be handled while
    /// the matching response is still pending.
    func beginRequest(method: String, params: JSONObject) throws -> Int64 {
        requestIDLock.lock()
        let id = nextRequestID
        nextRequestID += 1
        requestIDLock.unlock()
        try send(["id": .integer(id), "method": .string(method), "params": .object(params)])
        return id
    }

    func notify(method: String, params: JSONObject) throws {
        try send(["method": .string(method), "params": .object(params)])
    }

    func nextMessage() throws -> JSONObject? {
        if !bufferedMessages.isEmpty { return bufferedMessages.removeFirst() }
        return try readMessage()
    }

    /// Whether the child is still alive — the cheapest of the reuse conditions,
    /// and the one that catches a codex that died between turns.
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped && process.isRunning
    }

    func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        // Do not close stdin from this thread while the worker may be inside a
        // FileHandle write. Terminating the child closes its pipe endpoints and
        // wakes the blocking stdout read without risking fd-close/reuse races.
        if process.isRunning { process.terminate() }
        errorOutput.fileHandleForReading.readabilityHandler = nil
        stateLock.unlock()
    }

    private func send(_ object: JSONObject) throws {
        var data = try JSONEncoder().encode(object)
        data.append(0x0A)
        // The `stopped` READ is locked; the write is NEVER under stateLock.
        // `write(contentsOf:)` blocks as soon as the child's ~64 KB stdin buffer
        // fills — a `thread/inject_items` carrying one image attachment is ~1 MB
        // — and it can only unblock if the child drains. Holding stateLock across
        // it wedges the process permanently: stop() (the watchdog's AND the Stop
        // button's only exit) blocks on the lock, and so does appendStderr, so the
        // child's stderr fills and it stops reading stdin at all. onTermination
        // runs on the consuming task's actor, so that hang reaches the MainActor.
        // stop() deliberately does not close stdin, so this fd cannot be closed
        // and reused underneath an in-flight write.
        //
        // `writeLock` is a DIFFERENT lock and preserves all of the above: it is
        // held across the blocking write, but only writers ever take it, so the
        // worst case is one writer waiting on another. Teardown still cannot be
        // blocked by a write, which is the invariant that comment protects. If a
        // writer is stuck here, stop()'s terminate() closes the child's pipe
        // ends and this write fails with EPIPE (SIGPIPE ignored above) rather
        // than hanging — which is what releases the lock for anyone behind it.
        stateLock.lock()
        let alreadyStopped = stopped
        stateLock.unlock()
        guard !alreadyStopped else { throw CancellationError() }
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() throws -> JSONObject? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                do {
                    let message = try JSONDecoder().decode(JSONObject.self, from: Data(line))
                    onMessage()
                    return message
                } catch {
                    throw CodexAppServerClient.ClientError(
                        message: "Codex app-server sent invalid JSON. Try updating Codex."
                    )
                }
            }
            // `read(upToCount:)` may wait for the FULL requested length on a pipe;
            // initialize responses are much smaller and would deadlock forever.
            // availableData blocks only until some bytes arrive, then returns the
            // currently available JSONL chunk.
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    private func appendStderr(_ data: Data) {
        stateLock.lock(); defer { stateLock.unlock() }
        stderrData.append(data)
        if stderrData.count > 8_192 {
            stderrData.removeFirst(stderrData.count - 8_192)
        }
    }

    private func stderrSuffix() -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        let text = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : " Codex said: \(text)"
    }
}
