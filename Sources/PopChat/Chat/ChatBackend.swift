import Foundation

/// One turn's request, as the store sees it.
///
/// `transcript` is ALWAYS the complete resolved conversation, system prompt
/// first, ending with the user message this turn is about — even for a backend
/// holding a live session that only needs the tail. A backend may serve a turn
/// from state it already has, but only when it can prove that state matches this
/// transcript; the store never tells it how much is new, because a count is a
/// second source of truth that can drift from the transcript it describes.
struct ChatTurn {
    var transcript: [OpenAIChatClient.WireMessage]
    var config: ProviderConfig
    /// How PopChat's own tool loop may reach the web. Nil for backends that own
    /// their tool loop (Codex) or when search is off.
    var webAccess: OpenAIChatClient.WebAccess?
    /// Codex's NATIVE web_search. Not a per-turn parameter — it is a launch
    /// argument of the `codex` process (see CodexAppServerClient.Session.init),
    /// which is why a backend holding a live process must rebuild when it flips.
    var codexWebSearch: Bool
}

/// A conversation's transport.
///
/// Created per CONVERSATION, not per turn — that is the whole point of the
/// protocol. The three static `run(history:)` functions this replaced were each
/// shaped as "stateless function of the whole transcript", which is right for
/// HTTP chat completions and wrong for a local Codex thread that could have
/// stayed alive and kept its prompt cache.
///
/// The division of responsibility, which every conformance depends on:
/// - the STORE owns conversation identity. A new chat, a fork, loading a stored
///   conversation, deleting the current one, or switching provider kind all
///   `discard()` and build a new backend.
/// - the BACKEND owns transport reusability. Whether a model change, an effort
///   change, or a web-search toggle invalidates its state is a fact about the
///   protocol it speaks, and nothing the store should have to know.
protocol ChatBackend: AnyObject {
    func stream(_ turn: ChatTurn) -> AsyncStream<ChatStreamEvent>

    /// Cancel the turn in flight, keeping reusable state if the transport can.
    /// MUST be a no-op when no turn is running: `ChatStore.stop()` can race a
    /// turn that has just ended, and the stream's own termination handler calls
    /// this as well.
    func cancelTurn()

    /// Drop everything, including any live child process. Called whenever
    /// conversation identity changes, and at teardown.
    func discard()
}

/// Backends whose every turn is a fresh request carrying the whole transcript:
/// OpenAI-compatible chat completions, and the ChatGPT Codex Responses endpoint.
///
/// `cancelTurn()` and `discard()` are deliberately near-empty. The store cancels
/// its own iterating task, which terminates the `AsyncStream`, which cancels the
/// client's task through the `onTermination` handler each client already
/// installs — there is no process or server-side session to tear down beyond it.
final class StatelessChatBackend: ChatBackend {
    enum Transport {
        case openAICompatible
        /// The Responses backend keys routing and prompt caching off a stable
        /// per-conversation id, so it is fixed at construction rather than
        /// re-derived per turn.
        case chatGPT(sessionID: String)
    }

    private let transport: Transport

    init(transport: Transport) {
        self.transport = transport
    }

    func stream(_ turn: ChatTurn) -> AsyncStream<ChatStreamEvent> {
        switch transport {
        case .openAICompatible:
            return OpenAIChatClient.run(
                history: turn.transcript, config: turn.config, webAccess: turn.webAccess
            )
        case .chatGPT(let sessionID):
            return CodexResponsesClient.run(
                history: turn.transcript, config: turn.config,
                webAccess: turn.webAccess, sessionID: sessionID
            )
        }
    }

    func cancelTurn() {}
    func discard() {}
}

enum ChatBackendFactory {
    static func make(kind: ProviderKind, conversationID: UUID) -> ChatBackend {
        switch kind {
        case .openAICompatible:
            return StatelessChatBackend(transport: .openAICompatible)
        case .chatGPT:
            return StatelessChatBackend(
                transport: .chatGPT(sessionID: conversationID.uuidString.lowercased())
            )
        case .codexAppServer:
            return CodexAppServerBackend()
        }
    }
}
