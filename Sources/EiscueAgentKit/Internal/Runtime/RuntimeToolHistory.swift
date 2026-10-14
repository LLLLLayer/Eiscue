import Foundation
import PiDurableKit
import SQLite3

/// The pinned Pi schema stays inside the runtime adapter. A read-only SQLite snapshot avoids
/// opening a second scheduler or writable harness while the app runs or switches model engines.
enum RuntimeToolHistory {
    private enum ReadError: Error { case unavailable, unsupportedSchema }
    private enum Binding { case text(String), integer(Int64) }

    static func result(at url: URL, requestID: UUID, toolCallID: String) throws -> AgentToolCompletion? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try Task.checkCancellation()
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close_v2(connection) }
        guard status == SQLITE_OK, let connection else { throw ReadError.unavailable }
        sqlite3_busy_timeout(connection, 200)
        try execute("BEGIN DEFERRED TRANSACTION", in: connection)
        defer { _ = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
        let versions = try rows("SELECT version FROM durable_schema WHERE singleton = 1", in: connection)
        guard versions == [Data("1".utf8)] else { throw ReadError.unsupportedSchema }

        // Pi indexes request IDs as JSON strings. Use the actual durable submission rather
        // than timestamps or display metadata: providers can reuse call IDs across requests.
        let encodedID = String(decoding: try JSONEncoder().encode(requestID.uuidString), as: UTF8.self)
        let submissions = try rows("SELECT record FROM submissions WHERE request_id = ? LIMIT 2",
                                   bindings: [.text(encodedID)], in: connection)
        guard submissions.count == 1 else { return nil }
        let submission = try JSONDecoder().decode(SubmissionRecord.self, from: submissions[0])
        guard submission.requestId == requestID.uuidString, submission.type == .input else { return nil }
        let input: EntryID?
        switch submission.status {
        case .placed(let entry), .done(let entry, _): input = entry
        case .unanswered(let entry, _, _): input = entry
        case .queued: input = nil
        }
        guard let input else { return nil }
        let records = try rows("""
            SELECT e.record FROM entries e
            WHERE e.conversation_id = ? AND e.id > ? AND e.id < COALESCE((
                SELECT MIN(id) FROM entries WHERE conversation_id = ? AND id > ?
                AND json_extract(record, '$.kind') = 'pi.user'
            ), 9223372036854775807)
            AND EXISTS (
                SELECT 1 FROM json_each(e.record, '$.model') message
                WHERE (json_extract(message.value, '$.role') = 'toolResult'
                    AND json_extract(message.value, '$.toolCallId') = ?)
                OR (json_extract(message.value, '$.role') = 'assistant' AND EXISTS (
                    SELECT 1 FROM json_each(message.value, '$.content') content
                    WHERE json_extract(content.value, '$.type') = 'toolCall'
                    AND json_extract(content.value, '$.id') = ?
                ))
            ) ORDER BY e.id LIMIT 3
            """, bindings: [.integer(Int64(submission.conversationId.rawValue)), .integer(Int64(input.rawValue)),
                             .integer(Int64(submission.conversationId.rawValue)), .integer(Int64(input.rawValue)),
                             .text(toolCallID), .text(toolCallID)], in: connection)
        guard records.count == 2 else { return nil }
        let entries = try records.map { try JSONDecoder().decode(Entry.self, from: $0) }
        let calls = entries.flatMap { $0.assistantMessage?.toolCalls ?? [] }.filter { $0.id == toolCallID }
        let results = entries.compactMap(\.toolResult).filter { $0.toolCallId == toolCallID }
        guard calls.count == 1, results.count == 1, let call = calls.first, let result = results.first,
              call.name == result.toolName, entries[0].assistantMessage != nil, entries[1].toolResult != nil else { return nil }
        return AgentToolCompletion(call: AgentToolCall(id: call.id, name: call.name,
            arguments: (try? AgentJSONValue.from(call.arguments)) ?? .object([:])), result: RuntimeMapping.result(result))
    }

    private static func execute(_ sql: String, in connection: OpaquePointer) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil))
    }

    private static func rows(_ sql: String, bindings: [Binding] = [], in connection: OpaquePointer) throws -> [Data] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))
        guard let statement else { throw ReadError.unavailable }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            let status: Int32
            switch binding {
            case .text(let value): status = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            case .integer(let value): status = sqlite3_bind_int64(statement, Int32(index + 1), value)
            }
            try check(status)
        }
        var result: [Data] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { try check(status); throw ReadError.unavailable }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count <= 96 * 1_024 * 1_024, let bytes = sqlite3_column_blob(statement, 0) else { throw ReadError.unavailable }
            result.append(Data(bytes: bytes, count: count))
        }
    }

    private static func check(_ status: Int32) throws {
        if status == SQLITE_BUSY || status == SQLITE_LOCKED { throw AgentError.busy }
        guard status == SQLITE_OK else { throw ReadError.unavailable }
    }
}
