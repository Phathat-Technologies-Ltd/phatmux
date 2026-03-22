import Foundation
import SQLite3

struct HistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let command: String
    let timestamp: Date
    let exitCode: Int32
    let cwd: String
    let duration: TimeInterval
}

final class AtuinHistoryReader {
    private var db: OpaquePointer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent(".local/share/atuin/history.db").path
        
        // Atuin might use XDG_DATA_HOME, but standard is ~/.local/share/atuin/history.db
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            // Check if it's a file at all
            if !FileManager.default.fileExists(atPath: dbPath) {
                 // Try to check if we can find atuin config to get the path
                 // For now, we follow the default path as per the plan
            }
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func isAvailable() -> Bool {
        return db != nil
    }

    func search(query: String, limit: Int = 50) -> [HistoryEntry] {
        guard let db else { return [] }

        var results: [HistoryEntry] = []
        let sql: String
        let hasFilter = !query.isEmpty

        if hasFilter {
            sql = """
                SELECT id, command, MAX(timestamp), exit, cwd, duration 
                FROM history 
                WHERE command LIKE ? AND deleted_at IS NULL
                GROUP BY command 
                ORDER BY MAX(timestamp) DESC 
                LIMIT ?;
            """
        } else {
            sql = """
                SELECT id, command, MAX(timestamp), exit, cwd, duration 
                FROM history 
                WHERE deleted_at IS NULL
                GROUP BY command 
                ORDER BY MAX(timestamp) DESC 
                LIMIT ?;
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return results
        }
        defer { sqlite3_finalize(statement) }

        if hasFilter {
            let likeQuery = "%\(query)%"
            sqlite3_bind_text(statement, 1, strdup(likeQuery), -1, { free($0) })
            sqlite3_bind_int(statement, 2, Int32(limit))
        } else {
            sqlite3_bind_int(statement, 1, Int32(limit))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0),
                  let cmdPtr = sqlite3_column_text(statement, 1),
                  let cwdPtr = sqlite3_column_text(statement, 4) else {
                continue
            }

            let id = String(cString: idPtr)
            let command = String(cString: cmdPtr)
            let timestampNanos = sqlite3_column_int64(statement, 2)
            let exitCode = sqlite3_column_int(statement, 3)
            let cwdValue = String(cString: cwdPtr)
            let durationNanos = sqlite3_column_int64(statement, 5)

            let date = Date(timeIntervalSince1970: TimeInterval(timestampNanos) / 1_000_000_000.0)
            let duration = TimeInterval(durationNanos) / 1_000_000_000.0

            results.append(HistoryEntry(
                id: id,
                command: command,
                timestamp: date,
                exitCode: exitCode,
                cwd: cwdValue,
                duration: duration
            ))
        }
        return results
    }

    func suggestPrefix(_ prefix: String) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let db, !trimmed.isEmpty else { return nil }

        let sql = """
            SELECT command FROM history
            WHERE command LIKE ? AND command != ? AND deleted_at IS NULL
            ORDER BY timestamp DESC
            LIMIT 1
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let likePrefix = "\(trimmed)%"
        sqlite3_bind_text(statement, 1, strdup(likePrefix), -1, { free($0) })
        sqlite3_bind_text(statement, 2, strdup(trimmed), -1, { free($0) })

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cmdPtr = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: cmdPtr)
    }
}
