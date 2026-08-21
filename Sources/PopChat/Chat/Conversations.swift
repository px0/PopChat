import Foundation

struct Conversation: Codable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
    /// For a fork: only the messages AFTER the fork point — the shared prefix
    /// lives in the parent chain and is resolved on load.
    var messages: [ChatMessage]
    /// Conversation this one was forked from; nil for a root conversation.
    var parentID: UUID? = nil
    /// Last shared message (inclusive) in the parent's resolved transcript.
    var forkMessageID: UUID? = nil
    /// Filled in by the store on load. Nil on a value the caller just built,
    /// which the store reads as "keep whatever is already stored, or stamp now
    /// if this is the first insert" — so callers never have to carry it.
    var createdAt: Date? = nil
}

struct ConversationMeta: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    /// One-line preview for the history popover (last real message).
    let snippet: String
    let messageCount: Int
    let attachmentCount: Int
    let isFork: Bool

    /// Takes roles and text rather than `[ChatMessage]` because the store
    /// computes this while walking a fork chain it has only decoded far enough
    /// to read text — pulling attachment payloads in just to build a preview is
    /// the exact cost this storage layout exists to avoid.
    static func snippet(roleTexts: [(role: ChatRole, text: String)]) -> String {
        let last = roleTexts.last { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
        let flattened = (last?.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(120))
    }
}

/// Conversations live in a SQLite database in Application Support.
///
/// The shape is deliberate. Listing history is on the launch path, and it must
/// not read message bodies or attachment bytes to do its job — so every value
/// the history popover shows (title, timestamps, snippet, counts) is a column
/// on `conversations`, computed once at save time. Message bodies sit in a
/// `messages_json` column that listing never selects, and attachment payloads
/// live in their own table as raw BLOBs, never base64. Before this, listing
/// decoded every attachment in every conversation to produce a 120-character
/// preview: a store with a few screenshots per conversation cost ~1 ms per
/// megabyte on disk, all of it on the launch path. See `--smoke-history-bench`.
///
/// Forked conversations form a tree: a fork's row stores a parent pointer plus
/// only the messages added after the fork, so shared history is never
/// duplicated. The full transcript is resolved by walking the parent chain.
/// Deleting a parent first materializes its direct children (their rows absorb
/// the shared prefix and become standalone) — one transaction, so a crash
/// cannot leave a fork orphaned halfway through.
///
/// Nothing is ever deleted to make room. The history popover asks for the rows
/// it wants with a LIMIT; the store does not prune itself behind the user's
/// back. Because the store therefore grows without bound, finding an old
/// conversation cannot mean scanning the page currently on screen — a third
/// table, `conversations_fts`, indexes transcript text so the popover's filter
/// searches everything held rather than everything loaded.
enum ConversationStore {
    /// How many conversations the history popover asks for by default. A read
    /// limit, not a storage cap — raising it costs one query, not a migration.
    static let defaultRecentLimit = 50

    /// Test hook: smoke harnesses point this at a scratch directory so synthetic
    /// conversations never touch the user's real history.
    nonisolated(unsafe) static var overrideDirectory: URL? {
        didSet { withLock { connection = nil; connectedDirectory = nil } }
    }

    // MARK: - Connection

    private nonisolated(unsafe) static var connection: SQLiteDatabase?
    private nonisolated(unsafe) static var connectedDirectory: URL?
    /// Recursive because transaction bodies call back into store helpers that
    /// take the lock themselves (materialize → loadResolved → save).
    private static let lock = NSRecursiveLock()

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static var directory: URL {
        overrideDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PopChat/conversations", isDirectory: true)
    }

    /// Runs `body` against the open database, reporting rather than swallowing
    /// failures. The public API stays non-throwing because every call site is a
    /// UI action with nothing useful to do about a disk error, but a silent
    /// persistence failure is undiagnosable — so it goes to stderr.
    @discardableResult
    private static func perform<T>(_ label: String, _ body: (SQLiteDatabase) throws -> T) -> T? {
        withLock {
            do {
                return try body(try database())
            } catch {
                FileHandle.standardError.write(Data("PopChat: conversation store \(label) failed: \(error)\n".utf8))
                return nil
            }
        }
    }

    private static func database() throws -> SQLiteDatabase {
        let directory = directory
        if let connection, connectedDirectory == directory { return connection }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("conversations.sqlite").path)
        // WAL so a write never blocks the read that the launch path is doing;
        // NORMAL because losing the last few milliseconds of a chat to a power
        // cut is not worth an fsync on every keystroke-driven save.
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try migrate(database)
        connection = database
        connectedDirectory = directory
        return database
    }

    // MARK: - Schema

    private static let schemaVersion: Int32 = 2

    private static func migrate(_ database: SQLiteDatabase) throws {
        if database.userVersion < 1 { try createBaseSchema(database) }
        if database.userVersion < 2 { try addSearchIndex(database) }
    }

    private static func createBaseSchema(_ database: SQLiteDatabase) throws {
        try database.transaction {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS conversations (
                    id               TEXT PRIMARY KEY NOT NULL,
                    title            TEXT NOT NULL,
                    created_at       REAL NOT NULL,
                    updated_at       REAL NOT NULL,
                    snippet          TEXT NOT NULL,
                    message_count    INTEGER NOT NULL,
                    attachment_count INTEGER NOT NULL,
                    -- Intentionally NOT a foreign key: a dangling parent is a
                    -- broken fork chain, which callers must be told about
                    -- (`missingParent`). A cascade or SET NULL would silently
                    -- turn a truncated transcript into a plausible-looking one.
                    parent_id        TEXT,
                    fork_message_id  TEXT,
                    messages_json    TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS conversations_updated_at
                    ON conversations(updated_at DESC);
                CREATE INDEX IF NOT EXISTS conversations_parent
                    ON conversations(parent_id);

                CREATE TABLE IF NOT EXISTS attachments (
                    conversation_id TEXT NOT NULL
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    attachment_id   TEXT NOT NULL,
                    message_id      TEXT NOT NULL,
                    filename        TEXT NOT NULL,
                    kind            TEXT NOT NULL,
                    -- NULL means `data` holds the literal data-URL text rather
                    -- than decoded bytes: the lossless fallback for a payload
                    -- this store could not parse.
                    mime            TEXT,
                    note            TEXT,
                    note_kind       TEXT NOT NULL,
                    data            BLOB NOT NULL,
                    extracted_text  TEXT,
                    PRIMARY KEY (conversation_id, attachment_id)
                );
                """
            )
            try database.setUserVersion(1)
        }
    }

    /// Full-text index over conversation text.
    ///
    /// The history filter used to match against the newest 50 rows' title and
    /// 120-character snippet. That was complete only while the store was capped
    /// at 50 — once nothing is pruned, filtering the visible slice searches a
    /// shrinking fraction of a history that keeps growing, and never looks
    /// inside a message at all.
    ///
    /// What gets indexed is the RESOLVED transcript, so a fork is findable by
    /// the text it inherits and displays. Only user and assistant text goes in:
    /// error and activity rows are UI furniture ("Forked here — this branch
    /// diverges…"), and indexing them would make every fork a hit for "forked".
    private static func addSearchIndex(_ database: SQLiteDatabase) throws {
        try database.transaction {
            try database.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(
                    title,
                    body,
                    -- Matches what in-conversation ⌘F already does
                    -- (`.diacriticInsensitive`), so the two searches agree on
                    -- what counts as the same word.
                    tokenize = "unicode61 remove_diacritics 2"
                );

                -- Retracting the index entry belongs in a trigger, not at the
                -- call sites: deletes arrive from an explicit delete AND from
                -- the fork-materialization path, and an index that silently
                -- keeps returning deleted conversations fails in the direction
                -- nobody checks.
                CREATE TRIGGER IF NOT EXISTS conversations_fts_delete
                AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END;
                """
            )

            // Backfill whatever the store already holds.
            let ids = try database.prepare("SELECT id FROM conversations")
            var existing: [UUID] = []
            try ids.forEachRow { row in
                if let id = row.uuid(0) { existing.append(id) }
            }
            for id in existing {
                guard let row = try storedRow(id: id, database: database) else { continue }
                let (resolved, _) = try resolve(row, database: database, visited: [id])
                try indexForSearch(id: id, title: row.title, resolved: resolved, database: database)
            }
            try database.setUserVersion(2)
        }
    }

    private static func rowID(of id: UUID, database: SQLiteDatabase) throws -> Int? {
        let statement = try database.prepare("SELECT rowid FROM conversations WHERE id = ?")
        statement.bind(1, id)
        guard try statement.step() else { return nil }
        return statement.int(0)
    }

    private static func indexForSearch(
        id: UUID,
        title: String,
        resolved: [(owner: UUID, message: StoredMessage)],
        database: SQLiteDatabase
    ) throws {
        guard let rowID = try rowID(of: id, database: database) else { return }
        let delete = try database.prepare("DELETE FROM conversations_fts WHERE rowid = ?")
        delete.bind(1, rowID)
        try delete.run()

        let body = resolved
            .filter { $0.message.role == .user || $0.message.role == .assistant }
            .map { $0.message.text }
            .joined(separator: "\n")
        let insert = try database.prepare(
            "INSERT INTO conversations_fts(rowid, title, body) VALUES (?, ?, ?)"
        )
        insert.bind(1, rowID).bind(2, title).bind(3, body)
        try insert.run()
    }

    // MARK: - Stored representation

    /// What `messages_json` holds: a message WITHOUT its attachment payloads,
    /// which live in the `attachments` table. Keeping the bytes out of this
    /// column is the whole point — it is what makes a conversation body cheap
    /// to read and lets listing skip bodies entirely.
    private struct StoredAttachment: Codable {
        var id: UUID
        var filename: String
        var note: String?
        var noteKind: Attachment.NoteKind
    }

    private struct StoredMessage: Codable {
        var id: UUID
        var role: ChatRole
        var text: String
        var wireText: String?
        var attachments: [StoredAttachment]

        init(_ message: ChatMessage) {
            id = message.id
            role = message.role
            text = message.text
            wireText = message.wireText
            attachments = message.attachments.map {
                StoredAttachment(id: $0.id, filename: $0.filename, note: $0.note, noteKind: $0.noteKind)
            }
        }
    }

    private struct StoredRow {
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var parentID: UUID?
        var forkMessageID: UUID?
        var messages: [StoredMessage]
    }

    // MARK: - Attachment payload encoding

    /// Splits `data:image/jpeg;base64,…` into its media type and decoded bytes.
    /// Storing the bytes rather than the base64 text is a quarter less on disk
    /// and skips a decode on every read of the conversation.
    private static func splitDataURL(_ dataURL: String) -> (mime: String, bytes: Data)? {
        guard dataURL.hasPrefix("data:"), let marker = dataURL.range(of: ";base64,") else { return nil }
        let mime = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<marker.lowerBound])
        guard let bytes = Data(base64Encoded: String(dataURL[marker.upperBound...])) else { return nil }
        return (mime, bytes)
    }

    private static func makeDataURL(mime: String?, bytes: Data) -> String {
        guard let mime else { return String(decoding: bytes, as: UTF8.self) }
        return "data:\(mime);base64," + bytes.base64EncodedString()
    }

    private static func columns(
        for content: Attachment.Content
    ) -> (kind: String, mime: String?, bytes: Data, extracted: String?) {
        switch content {
        case .text(let text):
            return ("text", nil, Data(text.utf8), nil)
        case .image(let dataURL):
            guard let split = splitDataURL(dataURL) else { return ("image", nil, Data(dataURL.utf8), nil) }
            return ("image", split.mime, split.bytes, nil)
        case .pdf(let dataURL, let extractedText):
            guard let split = splitDataURL(dataURL) else {
                return ("pdf", nil, Data(dataURL.utf8), extractedText)
            }
            return ("pdf", split.mime, split.bytes, extractedText)
        }
    }

    private static func content(
        kind: String, mime: String?, bytes: Data, extracted: String?
    ) -> Attachment.Content? {
        switch kind {
        case "text": return .text(String(decoding: bytes, as: UTF8.self))
        case "image": return .image(dataURL: makeDataURL(mime: mime, bytes: bytes))
        case "pdf": return .pdf(dataURL: makeDataURL(mime: mime, bytes: bytes), extractedText: extracted ?? "")
        default: return nil
        }
    }

    private static func noteKindName(_ kind: Attachment.NoteKind) -> String {
        kind == .info ? "info" : "warning"
    }

    private static func noteKind(named name: String?) -> Attachment.NoteKind {
        name == "info" ? .info : .warning
    }

    // MARK: - Reading rows

    private static func storedRow(id: UUID, database: SQLiteDatabase) throws -> StoredRow? {
        let statement = try database.prepare(
            """
            SELECT title, created_at, updated_at, parent_id, fork_message_id, messages_json
            FROM conversations WHERE id = ?
            """
        )
        statement.bind(1, id)
        guard try statement.step() else { return nil }
        let json = statement.string(5) ?? "[]"
        let messages = (try? JSONDecoder().decode([StoredMessage].self, from: Data(json.utf8))) ?? []
        return StoredRow(
            id: id,
            title: statement.string(0) ?? "",
            createdAt: statement.date(1) ?? Date(),
            updatedAt: statement.date(2) ?? Date(),
            parentID: statement.uuid(3),
            forkMessageID: statement.uuid(4),
            messages: messages
        )
    }

    /// Walks the parent chain, tagging each message with the conversation that
    /// owns it so attachment payloads can be fetched from the right row.
    /// `missingParent` is true when the chain is broken (row gone, or the fork
    /// point no longer present) — callers surface that rather than degrading
    /// silently into a truncated transcript.
    private static func resolve(
        _ row: StoredRow, database: SQLiteDatabase, visited: Set<UUID>
    ) throws -> (messages: [(owner: UUID, message: StoredMessage)], missingParent: Bool) {
        let own = row.messages.map { (owner: row.id, message: $0) }
        guard let parentID = row.parentID, let forkMessageID = row.forkMessageID else { return (own, false) }
        guard !visited.contains(parentID),
              let parent = try storedRow(id: parentID, database: database) else { return (own, true) }
        let (parentMessages, parentBroken) = try resolve(
            parent, database: database, visited: visited.union([parentID])
        )
        guard let cut = parentMessages.firstIndex(where: { $0.message.id == forkMessageID }) else {
            return (own, true)
        }
        return (Array(parentMessages.prefix(through: cut)) + own, parentBroken)
    }

    /// Reattaches payloads from the `attachments` table. Batched per owning
    /// conversation so a resolved fork chain costs one query per ancestor, not
    /// one per attachment.
    private static func hydrate(
        _ resolved: [(owner: UUID, message: StoredMessage)], database: SQLiteDatabase
    ) throws -> [ChatMessage] {
        var payloads: [UUID: [UUID: Attachment]] = [:]
        for owner in Set(resolved.map(\.owner)) {
            let statement = try database.prepare(
                """
                SELECT attachment_id, filename, kind, mime, note, note_kind, data, extracted_text
                FROM attachments WHERE conversation_id = ?
                """
            )
            statement.bind(1, owner)
            var byID: [UUID: Attachment] = [:]
            try statement.forEachRow { row in
                guard let attachmentID = row.uuid(0),
                      let content = content(
                          kind: row.string(2) ?? "",
                          mime: row.string(3),
                          bytes: row.data(6) ?? Data(),
                          extracted: row.string(7)
                      ) else { return }
                byID[attachmentID] = Attachment(
                    id: attachmentID,
                    filename: row.string(1) ?? "",
                    content: content,
                    note: row.string(4),
                    noteKind: noteKind(named: row.string(5))
                )
            }
            payloads[owner] = byID
        }

        return resolved.map { owner, stored in
            ChatMessage(
                id: stored.id,
                role: stored.role,
                text: stored.text,
                wireText: stored.wireText,
                attachments: stored.attachments.compactMap { payloads[owner]?[$0.id] }
            )
        }
    }

    // MARK: - Public API

    /// Persists the conversation and returns the metadata the history list
    /// should show. Derived columns (snippet, counts) come from the RESOLVED
    /// chain, so a fork whose own tail is just its divergence marker still gets
    /// a meaningful preview.
    @discardableResult
    static func save(_ conversation: Conversation) -> ConversationMeta? {
        perform("save") { database in
            try database.transaction { try saveInternal(conversation, database: database) }
        }
    }

    @discardableResult
    private static func saveInternal(
        _ conversation: Conversation, database: SQLiteDatabase
    ) throws -> ConversationMeta {
        let stored = conversation.messages.map(StoredMessage.init)
        let row = StoredRow(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt ?? Date(),
            updatedAt: conversation.updatedAt,
            parentID: conversation.parentID,
            forkMessageID: conversation.forkMessageID,
            messages: stored
        )
        let (resolved, _) = try resolve(row, database: database, visited: [conversation.id])
        let snippet = ConversationMeta.snippet(
            roleTexts: resolved.map { (role: $0.message.role, text: $0.message.text) }
        )
        let attachmentCount = resolved.reduce(0) { $0 + $1.message.attachments.count }
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)

        // created_at is absent from the UPDATE clause on purpose: the first
        // insert stamps it and every later save leaves it alone, so callers
        // never have to carry a value they do not have.
        let upsert = try database.prepare(
            """
            INSERT INTO conversations
                (id, title, created_at, updated_at, snippet,
                 message_count, attachment_count, parent_id, fork_message_id, messages_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                updated_at = excluded.updated_at,
                snippet = excluded.snippet,
                message_count = excluded.message_count,
                attachment_count = excluded.attachment_count,
                parent_id = excluded.parent_id,
                fork_message_id = excluded.fork_message_id,
                messages_json = excluded.messages_json
            """
        )
        upsert.bind(1, conversation.id)
            .bind(2, conversation.title)
            .bind(3, row.createdAt)
            .bind(4, conversation.updatedAt)
            .bind(5, snippet)
            .bind(6, resolved.count)
            .bind(7, attachmentCount)
            .bind(8, conversation.parentID)
            .bind(9, conversation.forkMessageID)
            .bind(10, json)
        try upsert.run()

        // Reconcile WHICH attachments belong to this conversation rather than
        // rewriting all of them. An Attachment is immutable once built — its
        // `content` is a `let`, and nothing mutates `note`/`noteKind` after
        // construction — so a row that is still referenced is still correct.
        // Rewriting every blob on each persisted turn cost ~27 ms and re-wrote
        // the conversation's whole image payload every time a message landed.
        var alreadyStored: Set<UUID> = []
        let existing = try database.prepare(
            "SELECT attachment_id FROM attachments WHERE conversation_id = ?"
        )
        existing.bind(1, conversation.id)
        try existing.forEachRow { row in
            if let attachmentID = row.uuid(0) { alreadyStored.insert(attachmentID) }
        }
        let current = Set(conversation.messages.flatMap { $0.attachments.map(\.id) })

        let delete = try database.prepare(
            "DELETE FROM attachments WHERE conversation_id = ? AND attachment_id = ?"
        )
        for removed in alreadyStored.subtracting(current) {
            delete.bind(1, conversation.id).bind(2, removed)
            try delete.run()
            delete.reset()
        }

        let insert = try database.prepare(
            """
            INSERT OR REPLACE INTO attachments
                (conversation_id, attachment_id, message_id, filename,
                 kind, mime, note, note_kind, data, extracted_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        for message in conversation.messages {
            for attachment in message.attachments where !alreadyStored.contains(attachment.id) {
                let payload = columns(for: attachment.content)
                insert.bind(1, conversation.id)
                    .bind(2, attachment.id)
                    .bind(3, message.id)
                    .bind(4, attachment.filename)
                    .bind(5, payload.kind)
                    .bind(6, payload.mime)
                    .bind(7, attachment.note)
                    .bind(8, noteKindName(attachment.noteKind))
                    .bind(9, payload.bytes)
                    .bind(10, payload.extracted)
                try insert.run()
                insert.reset()
            }
        }

        try indexForSearch(
            id: conversation.id, title: conversation.title, resolved: resolved, database: database
        )

        // The created_at that actually landed — an update kept the stored one.
        let createdAt = try storedRow(id: conversation.id, database: database)?.createdAt ?? row.createdAt
        return ConversationMeta(
            id: conversation.id,
            title: conversation.title,
            createdAt: createdAt,
            updatedAt: conversation.updatedAt,
            snippet: snippet,
            messageCount: resolved.count,
            attachmentCount: attachmentCount,
            isFork: conversation.parentID != nil
        )
    }

    static func load(id: UUID) -> Conversation? {
        perform("load") { database in
            try loadInternal(id: id, database: database)
        } ?? nil
    }

    private static func loadInternal(id: UUID, database: SQLiteDatabase) throws -> Conversation? {
        guard let row = try storedRow(id: id, database: database) else { return nil }
        let own = row.messages.map { (owner: row.id, message: $0) }
        return Conversation(
            id: row.id,
            title: row.title,
            updatedAt: row.updatedAt,
            messages: try hydrate(own, database: database),
            parentID: row.parentID,
            forkMessageID: row.forkMessageID,
            createdAt: row.createdAt
        )
    }

    static func delete(id: UUID) {
        perform("delete") { database in
            let statement = try database.prepare("DELETE FROM conversations WHERE id = ?")
            statement.bind(1, id)
            try statement.run()
        }
    }

    // MARK: - Fork resolution

    /// Full transcript: the parent chain's shared prefix plus this
    /// conversation's own tail. `missingParent` is true when the chain is
    /// broken — the caller should surface that instead of degrading silently.
    static func resolveMessages(_ conversation: Conversation) -> (messages: [ChatMessage], missingParent: Bool) {
        perform("resolve") { database -> ([ChatMessage], Bool) in
            let row = StoredRow(
                id: conversation.id,
                title: conversation.title,
                createdAt: conversation.createdAt ?? Date(),
                updatedAt: conversation.updatedAt,
                parentID: conversation.parentID,
                forkMessageID: conversation.forkMessageID,
                messages: conversation.messages.map(StoredMessage.init)
            )
            let (resolved, missingParent) = try resolve(
                row, database: database, visited: [conversation.id]
            )
            // The caller's own messages already carry their payloads; only the
            // inherited prefix has to come back out of the database.
            let prefix = resolved.dropLast(conversation.messages.count)
            let hydratedPrefix = try hydrate(Array(prefix), database: database)
            return (hydratedPrefix + conversation.messages, missingParent)
        } ?? (conversation.messages, conversation.parentID != nil)
    }

    static func loadResolved(id: UUID) -> (conversation: Conversation, messages: [ChatMessage], missingParent: Bool)? {
        perform("loadResolved") { database in
            try loadResolvedInternal(id: id, database: database)
        } ?? nil
    }

    private static func loadResolvedInternal(
        id: UUID, database: SQLiteDatabase
    ) throws -> (conversation: Conversation, messages: [ChatMessage], missingParent: Bool)? {
        guard let row = try storedRow(id: id, database: database),
              let conversation = try loadInternal(id: id, database: database) else { return nil }
        let (resolved, missingParent) = try resolve(row, database: database, visited: [id])
        return (conversation, try hydrate(resolved, database: database), missingParent)
    }

    /// Delete with fork safety: direct children absorb the shared prefix and
    /// become standalone roots before the parent's row is removed. One
    /// transaction — either every child is materialized and the parent is gone,
    /// or nothing changed.
    static func deleteMaterializingChildren(id: UUID) {
        perform("deleteMaterializingChildren") { database in
            try database.transaction {
                for childID in try childIDs(of: id, database: database) {
                    guard let loaded = try loadResolvedInternal(id: childID, database: database) else { continue }
                    var standalone = loaded.conversation
                    standalone.messages = loaded.messages
                    standalone.parentID = nil
                    standalone.forkMessageID = nil
                    try saveInternal(standalone, database: database)
                }
                let statement = try database.prepare("DELETE FROM conversations WHERE id = ?")
                statement.bind(1, id)
                try statement.run()
            }
        }
    }

    private static func childIDs(of id: UUID, database: SQLiteDatabase) throws -> [UUID] {
        let statement = try database.prepare("SELECT id FROM conversations WHERE parent_id = ?")
        statement.bind(1, id)
        var result: [UUID] = []
        try statement.forEachRow { row in
            if let childID = row.uuid(0) { result.append(childID) }
        }
        return result
    }

    // MARK: - Listing

    /// Newest first. Reads metadata columns only — no message bodies, no
    /// attachment bytes — which is what keeps this off the launch path's
    /// critical cost. A pure read: it never deletes or rewrites anything.
    static func listRecent(limit: Int = defaultRecentLimit) -> [ConversationMeta] {
        perform("listRecent") { database in
            let statement = try database.prepare(
                """
                SELECT id, title, created_at, updated_at, snippet,
                       message_count, attachment_count, parent_id
                FROM conversations
                ORDER BY updated_at DESC
                LIMIT ?
                """
            )
            statement.bind(1, limit)
            var result: [ConversationMeta] = []
            try statement.forEachRow { row in
                guard let id = row.uuid(0) else { return }
                result.append(ConversationMeta(
                    id: id,
                    title: row.string(1) ?? "",
                    createdAt: row.date(2) ?? Date(),
                    updatedAt: row.date(3) ?? Date(),
                    snippet: row.string(4) ?? "",
                    messageCount: row.int(5) ?? 0,
                    attachmentCount: row.int(6) ?? 0,
                    isFork: row.uuid(7) != nil
                ))
            }
            return result
        } ?? []
    }

    // MARK: - Search

    /// Turns what the user typed into an FTS5 MATCH expression.
    ///
    /// Splitting on everything that is not a letter or digit is the safety
    /// property, not a nicety: FTS5's own syntax (`"`, `*`, `:`, `^`, `NEAR`,
    /// `AND`) then never reaches the parser, so an apostrophe in "don't" is a
    /// word boundary rather than a syntax error that fails the whole query.
    /// Quoting each term makes the operator words literal too. The last term is
    /// prefix-matched so results narrow while the user is still typing.
    static func matchExpression(for input: String) -> String? {
        let terms = input.split { !$0.isLetter && !$0.isNumber }
        guard !terms.isEmpty else { return nil }
        return terms.enumerated()
            .map { index, term in index == terms.count - 1 ? "\"\(term)\"*" : "\"\(term)\"" }
            .joined(separator: " ")
    }

    /// Full-text search across every stored conversation.
    ///
    /// The result is the best `limit` matches by relevance, handed back newest
    /// first. Both halves of that are deliberate.
    ///
    /// Selecting by bm25 rank and only then sorting by date is what keeps the
    /// cost bounded. Sorting all matches by date instead means the work scales
    /// with how many conversations match, and a broad query matches nearly
    /// everything: on a 10,000-conversation store a term present in every
    /// conversation took 1,060 ms that way versus 13 ms this way. Search runs
    /// on each keystroke, and the FIRST keystroke is always the broadest query
    /// the user will type, so the worst case is the common case.
    ///
    /// Displaying that set newest-first rather than in rank order is for the
    /// popover, which groups rows under day headers — rank order would
    /// interleave dates and repeat the headers.
    static func search(_ query: String, limit: Int = defaultRecentLimit) -> [ConversationMeta] {
        guard let match = matchExpression(for: query) else { return [] }
        return perform("search") { database in
            let statement = try database.prepare(
                """
                SELECT c.id, c.title, c.created_at, c.updated_at, c.snippet,
                       c.message_count, c.attachment_count, c.parent_id, m.excerpt
                FROM (
                    SELECT rowid,
                           snippet(conversations_fts, -1, '', '', '…', 12) AS excerpt
                    FROM conversations_fts
                    WHERE conversations_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                ) m
                JOIN conversations c ON c.rowid = m.rowid
                ORDER BY c.updated_at DESC
                """
            )
            statement.bind(1, match).bind(2, limit)
            var result: [ConversationMeta] = []
            try statement.forEachRow { row in
                guard let id = row.uuid(0) else { return }
                let matched = row.string(8) ?? ""
                result.append(ConversationMeta(
                    id: id,
                    title: row.string(1) ?? "",
                    createdAt: row.date(2) ?? Date(),
                    updatedAt: row.date(3) ?? Date(),
                    // Show text around the hit, so a row never appears with a
                    // preview that does not contain what was searched for.
                    // A title-only match has no body snippet; fall back then.
                    snippet: matched.isEmpty ? (row.string(4) ?? "") : matched,
                    messageCount: row.int(5) ?? 0,
                    attachmentCount: row.int(6) ?? 0,
                    isFork: row.uuid(7) != nil
                ))
            }
            return result
        } ?? []
    }

    /// Attachment rows whose conversation is gone. Always zero in a healthy
    /// store — the foreign key cascades — so this exists for the smoke harness
    /// to assert on, because a leak here is invisible from the UI.
    static func orphanAttachmentCount() -> Int {
        perform("orphanAttachmentCount") { database in
            let statement = try database.prepare(
                """
                SELECT COUNT(*) FROM attachments
                WHERE conversation_id NOT IN (SELECT id FROM conversations)
                """
            )
            guard try statement.step() else { return 0 }
            return statement.int(0) ?? 0
        } ?? 0
    }

    /// Total conversations held, which `listRecent`'s limit deliberately hides.
    static func count() -> Int {
        perform("count") { database in
            let statement = try database.prepare("SELECT COUNT(*) FROM conversations")
            guard try statement.step() else { return 0 }
            return statement.int(0) ?? 0
        } ?? 0
    }
}
