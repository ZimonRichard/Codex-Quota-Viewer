import Foundation

struct CodexStateDatabaseLocation: Equatable {
    let databaseURL: URL
    let walURL: URL
    let shmURL: URL
}

enum CodexStateDatabaseLocator {
    static func locate(
        codexHomeURL: URL,
        fileManager: FileManager = .default
    ) -> CodexStateDatabaseLocation {
        locateAll(codexHomeURL: codexHomeURL, fileManager: fileManager)[0]
    }

    static func locateAll(
        codexHomeURL: URL,
        fileManager: FileManager = .default
    ) -> [CodexStateDatabaseLocation] {
        let standardizedCodexHomeURL = codexHomeURL.standardizedFileURL
        let sqliteDirectoryURL = standardizedCodexHomeURL.appendingPathComponent("sqlite", isDirectory: true)
        let sqliteStateDBURL = sqliteDirectoryURL.appendingPathComponent("state.db", isDirectory: false)
        var databaseURLs: [URL] = []

        if let newestSQLiteDatabaseURL = newestExistingStateDatabase(in: sqliteDirectoryURL, fileManager: fileManager) {
            databaseURLs.append(newestSQLiteDatabaseURL)
        } else if fileManager.fileExists(atPath: sqliteStateDBURL.path) {
            databaseURLs.append(sqliteStateDBURL.standardizedFileURL)
        }

        if let legacyDatabaseURL = newestExistingStateDatabase(in: standardizedCodexHomeURL, fileManager: fileManager) {
            databaseURLs.append(legacyDatabaseURL)
        }

        if databaseURLs.isEmpty {
            databaseURLs.append(
                sqliteDirectoryURL.appendingPathComponent("state_5.sqlite", isDirectory: false)
                    .standardizedFileURL
            )
        }

        return deduplicated(databaseURLs).map(location(for:))
    }

    private static func location(for databaseURL: URL) -> CodexStateDatabaseLocation {
        let standardizedDatabaseURL = databaseURL.standardizedFileURL
        return CodexStateDatabaseLocation(
            databaseURL: standardizedDatabaseURL,
            walURL: URL(fileURLWithPath: standardizedDatabaseURL.path + "-wal", isDirectory: false),
            shmURL: URL(fileURLWithPath: standardizedDatabaseURL.path + "-shm", isDirectory: false)
        )
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else {
                continue
            }
            result.append(url.standardizedFileURL)
        }

        return result
    }

    private static func newestExistingStateDatabase(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return nil
        }

        return names
            .compactMap { name -> (version: Int, url: URL)? in
                guard let version = stateDatabaseVersion(from: name) else {
                    return nil
                }

                let url = directoryURL.appendingPathComponent(name, isDirectory: false)
                guard fileManager.fileExists(atPath: url.path) else {
                    return nil
                }

                return (version, url.standardizedFileURL)
            }
            .sorted {
                if $0.version != $1.version {
                    return $0.version > $1.version
                }
                return $0.url.path < $1.url.path
            }
            .first?
            .url
    }

    private static func stateDatabaseVersion(from fileName: String) -> Int? {
        guard fileName.hasPrefix("state_"),
              fileName.hasSuffix(".sqlite") else {
            return nil
        }

        let start = fileName.index(fileName.startIndex, offsetBy: "state_".count)
        let end = fileName.index(fileName.endIndex, offsetBy: -".sqlite".count)
        return Int(fileName[start..<end])
    }
}
