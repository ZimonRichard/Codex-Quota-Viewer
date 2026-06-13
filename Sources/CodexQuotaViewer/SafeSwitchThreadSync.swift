import Foundation

enum LocalSQLiteQueryError: LocalizedError {
    case sqliteUnavailable
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .sqliteUnavailable:
            return AppLocalization.localized(
                en: "sqlite3 is required to inspect local thread metadata.",
                zh: "检查本地线程元数据需要 sqlite3。"
            )
        case .queryFailed(let message):
            return message
        }
    }
}

struct RolloutProviderSyncResult: Equatable {
    let updatedFiles: [URL]
}

struct LocalThreadTitleCandidate: Equatable {
    let id: String
    let title: String
    let updatedAt: Date?
}

final class LocalThreadTitlePreserver {
    private let fileManager = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()

    func captureCandidates(sessionIndexURL: URL) throws -> [LocalThreadTitleCandidate] {
        guard fileManager.fileExists(atPath: sessionIndexURL.path) else {
            return []
        }

        let content = try String(contentsOf: sessionIndexURL, encoding: .utf8)
        var candidatesByID: [String: LocalThreadTitleCandidate] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let id = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (
                object["thread_name"] as? String
                    ?? object["threadName"] as? String
                    ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let updatedAtText = object["updated_at"] as? String ?? object["updatedAt"] as? String

            guard !id.isEmpty, !title.isEmpty else {
                continue
            }

            let candidate = LocalThreadTitleCandidate(
                id: id,
                title: title,
                updatedAt: updatedAtText.flatMap(parseDate)
            )

            if let existing = candidatesByID[id],
               compare(candidate, existing) <= 0 {
                continue
            }

            candidatesByID[id] = candidate
        }

        return candidatesByID.values.sorted {
            if $0.id == $1.id {
                return compare($0, $1) > 0
            }
            return $0.id < $1.id
        }
    }

    func preserveUserVisibleTitles(
        stateDatabaseURL: URL,
        sessionIndexURL: URL
    ) throws -> Int {
        try preserveUserVisibleTitles(
            stateDatabaseURL: stateDatabaseURL,
            candidates: captureCandidates(sessionIndexURL: sessionIndexURL)
        )
    }

    func preserveUserVisibleTitles(
        stateDatabaseURL: URL,
        candidates: [LocalThreadTitleCandidate]
    ) throws -> Int {
        guard !candidates.isEmpty,
              fileManager.fileExists(atPath: stateDatabaseURL.path) else {
            return 0
        }

        let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard fileManager.isExecutableFile(atPath: sqliteURL.path) else {
            throw LocalSQLiteQueryError.sqliteUnavailable
        }

        let sql = buildPreserveSQL(for: candidates)
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }

        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = [stateDatabaseURL.path]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(sql.utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw LocalSQLiteQueryError.queryFailed(errorOutput.isEmpty ? output : errorOutput)
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .reduce(0, +)
    }

    private func buildPreserveSQL(for candidates: [LocalThreadTitleCandidate]) -> String {
        var statements = [
            ".timeout 3000",
            "BEGIN IMMEDIATE;",
        ]

        for candidate in candidates {
            let id = sqlLiteral(candidate.id)
            let title = sqlLiteral(candidate.title)

            statements.append(
                """
                UPDATE threads
                SET title = \(title)
                WHERE id = \(id)
                  AND \(title) <> ''
                  AND COALESCE(first_user_message, '') <> ''
                  AND \(title) <> COALESCE(first_user_message, '')
                  AND COALESCE(title, '') = COALESCE(first_user_message, '');
                SELECT changes();
                """
            )
        }

        statements.append("COMMIT;")
        return statements.joined(separator: "\n")
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func parseDate(_ value: String) -> Date? {
        isoFormatter.date(from: value)
    }

    private func compare(
        _ lhs: LocalThreadTitleCandidate,
        _ rhs: LocalThreadTitleCandidate
    ) -> Int {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case (.some(let lhsDate), .some(let rhsDate)):
            return lhsDate.compare(rhsDate).rawValue
        case (.some, .none):
            return 1
        case (.none, .some):
            return -1
        case (.none, .none):
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title).rawValue
        }
    }
}

final class RolloutProviderSynchronizer {
    private let fileManager = FileManager.default
    private let copyChunkSize = 1024 * 1024

    func plannedUpdates(in roots: [URL], targetProvider: String) throws -> [URL] {
        var updates: [URL] = []

        for fileURL in try rolloutFiles(in: roots) {
            if try updatedFirstLineIfNeeded(for: fileURL, targetProvider: targetProvider) != nil {
                updates.append(fileURL)
            }
        }

        return updates.sorted { $0.path < $1.path }
    }

    func syncProviders(
        in roots: [URL],
        targetProvider: String
    ) throws -> RolloutProviderSyncResult {
        var updatedFiles: [URL] = []

        for fileURL in try rolloutFiles(in: roots) {
            guard let updatedFirstLine = try updatedFirstLineIfNeeded(for: fileURL, targetProvider: targetProvider) else {
                continue
            }

            try replaceFirstLine(in: fileURL, with: updatedFirstLine)
            updatedFiles.append(fileURL)
        }

        return RolloutProviderSyncResult(updatedFiles: updatedFiles.sorted { $0.path < $1.path })
    }

    func providerCounts(in roots: [URL]) throws -> [ProviderCount] {
        var counts: [String: Int] = [:]

        for fileURL in try rolloutFiles(in: roots) {
            guard let provider = try sessionMetaProvider(in: fileURL) else {
                continue
            }
            counts[provider, default: 0] += 1
        }

        return counts
            .map { ProviderCount(providerID: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.providerID < $1.providerID
                }
                return $0.count > $1.count
            }
    }

    func sessionMetaProvider(in fileURL: URL) throws -> String? {
        guard let firstLine = try readFirstLine(in: fileURL),
              !firstLine.isEmpty else {
            return nil
        }

        guard let object = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        return payload["model_provider"] as? String
    }

    private func rolloutFiles(in roots: [URL]) throws -> [URL] {
        var files: [URL] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else {
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                files.append(fileURL)
            }
        }

        return files
    }

    private func updatedFirstLineIfNeeded(
        for fileURL: URL,
        targetProvider: String
    ) throws -> Data? {
        guard let firstLine = try readFirstLine(in: fileURL),
              !firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard var object = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              let type = object["type"] as? String,
              type == "session_meta",
              var payload = object["payload"] as? [String: Any] else {
            return nil
        }

        let existingProvider = (payload["model_provider"] as? String) ?? ""
        guard existingProvider != targetProvider else {
            return nil
        }

        payload["model_provider"] = targetProvider
        object["payload"] = payload

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func replaceFirstLine(in fileURL: URL, with firstLineData: Data) throws {
        let folderURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let originalAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path)

        let tempURL = folderURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        let input = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? input.close()
        }

        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: tempURL)
        defer {
            try? output.close()
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        try output.write(contentsOf: firstLineData)
        try output.write(contentsOf: Data([0x0A]))

        var skippedOriginalFirstLine = false
        while let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty {
            if skippedOriginalFirstLine {
                try output.write(contentsOf: chunk)
                continue
            }

            guard let newlineIndex = chunk.firstIndex(of: 0x0A) else {
                continue
            }

            skippedOriginalFirstLine = true
            let suffixStart = chunk.index(after: newlineIndex)
            if suffixStart < chunk.endIndex {
                try output.write(contentsOf: chunk[suffixStart...])
            }
        }

        if let permissions = originalAttributes?[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        }

        _ = try fileManager.replaceItemAt(
            fileURL,
            withItemAt: tempURL,
            backupItemName: nil,
            options: []
        )

        var preservedAttributes: [FileAttributeKey: Any] = [:]
        if let permissions = originalAttributes?[.posixPermissions] {
            preservedAttributes[.posixPermissions] = permissions
        }
        if let creationDate = originalAttributes?[.creationDate] {
            preservedAttributes[.creationDate] = creationDate
        }
        if !preservedAttributes.isEmpty {
            try fileManager.setAttributes(preservedAttributes, ofItemAtPath: fileURL.path)
        }
    }

    private func readFirstLine(in fileURL: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var buffer = Data()

        while true {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty {
                break
            }

            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk.prefix(upTo: newlineIndex))
                break
            }

            buffer.append(chunk)
        }

        if buffer.last == 0x0D {
            buffer.removeLast()
        }

        guard !buffer.isEmpty else {
            return nil
        }

        return String(data: buffer, encoding: .utf8)
    }
}

struct LocalThreadProviderRelabeler {
    func relabel(databaseURL: URL, targetProvider: String) throws -> Int {
        let trimmedProvider = targetProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            return 0
        }

        let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqliteURL.path) else {
            throw LocalSQLiteQueryError.sqliteUnavailable
        }

        let escapedProvider = trimmedProvider.replacingOccurrences(of: "'", with: "''")
        let sql = """
        BEGIN IMMEDIATE;
        UPDATE threads
        SET model_provider = '\(escapedProvider)'
        WHERE COALESCE(model_provider, '') <> '\(escapedProvider)';
        SELECT changes();
        COMMIT;
        """

        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = [
            "-batch",
            "-noheader",
            databaseURL.path,
            sql,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalSQLiteQueryError.queryFailed(
                errorText
                    ?? AppLocalization.localized(
                        en: "Unknown sqlite error",
                        zh: "未知 sqlite 错误"
                    )
            )
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output ?? "") ?? 0
    }
}

final class LocalThreadSyncInspector {
    typealias QueryRunner = (URL, String) throws -> String

    private let rolloutSynchronizer: RolloutProviderSynchronizer
    private let queryRunner: QueryRunner

    init(
        rolloutSynchronizer: RolloutProviderSynchronizer = RolloutProviderSynchronizer(),
        queryRunner: QueryRunner? = nil
    ) {
        self.rolloutSynchronizer = rolloutSynchronizer
        self.queryRunner = queryRunner ?? Self.defaultQueryRunner
    }

    func inspect(
        store: ProfileStore,
        expectedProviderID: String?
    ) -> LocalThreadSyncStatus {
        let rolloutProviders = (try? rolloutSynchronizer.providerCounts(
            in: [store.sessionsRootURL, store.archivedSessionsRootURL]
        )) ?? []

        let threadProviders: [ProviderCount]
        if FileManager.default.fileExists(atPath: store.stateDatabaseURL.path) {
            do {
                threadProviders = try stateThreadProviderCounts(databaseURL: store.stateDatabaseURL)
            } catch {
                return .unavailable(
                    AppLocalization.localized(
                        en: "State DB could not be read.",
                        zh: "无法读取状态数据库。"
                    )
                )
            }
        } else {
            threadProviders = []
        }

        if rolloutProviders.isEmpty, threadProviders.isEmpty {
            return .unavailable(
                AppLocalization.localized(
                    en: "No local threads found.",
                    zh: "未发现本地线程。"
                )
            )
        }

        let normalizedExpected = expectedProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateExpected = (normalizedExpected?.isEmpty == false)
            ? normalizedExpected
            : ([rolloutProviders, threadProviders]
                .flatMap { $0 }
                .first?.providerID)

        guard let expected = candidateExpected else {
            return .unavailable(
                AppLocalization.localized(
                    en: "Provider metadata is unavailable.",
                    zh: "无法获取 Provider 元数据。"
                )
            )
        }

        let rolloutMismatch = rolloutProviders.contains { $0.providerID != expected }
        let threadMismatch = threadProviders.contains { $0.providerID != expected }

        if rolloutMismatch || threadMismatch {
            return .repairNeeded(
                expectedProvider: expected,
                rolloutProviders: rolloutProviders,
                threadProviders: threadProviders
            )
        }

        return .healthy(expectedProvider: expected)
    }

    private func stateThreadProviderCounts(databaseURL: URL) throws -> [ProviderCount] {
        let sql = """
        SELECT COALESCE(TRIM(model_provider), ''), COUNT(*)
        FROM threads
        GROUP BY COALESCE(TRIM(model_provider), '')
        ORDER BY COUNT(*) DESC, COALESCE(TRIM(model_provider), '') ASC;
        """

        let output = try queryRunner(databaseURL, sql)
        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> ProviderCount? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return nil
                }

                let columns = trimmed.components(separatedBy: "\t")
                guard columns.count == 2,
                      let count = Int(columns[1]) else {
                    return nil
                }

                return ProviderCount(providerID: columns[0], count: count)
            }
    }

    private static func defaultQueryRunner(dbURL: URL, sql: String) throws -> String {
        let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqliteURL.path) else {
            throw LocalSQLiteQueryError.sqliteUnavailable
        }

        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = [
            "-readonly",
            "-separator",
            "\t",
            dbURL.path,
            sql,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalSQLiteQueryError.queryFailed(
                errorText
                    ?? AppLocalization.localized(
                        en: "Unknown sqlite error",
                        zh: "未知 sqlite 错误"
                    )
            )
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
