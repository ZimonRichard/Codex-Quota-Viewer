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
        let standardizedCodexHomeURL = codexHomeURL.standardizedFileURL
        let sqliteDirectoryURL = standardizedCodexHomeURL.appendingPathComponent("sqlite", isDirectory: true)
        let sqliteStateDBURL = sqliteDirectoryURL.appendingPathComponent("state.db", isDirectory: false)
        let databaseURL =
            newestExistingStateDatabase(in: sqliteDirectoryURL, fileManager: fileManager)
            ?? (fileManager.fileExists(atPath: sqliteStateDBURL.path) ? sqliteStateDBURL : nil)
            ?? newestExistingStateDatabase(in: standardizedCodexHomeURL, fileManager: fileManager)
            ?? sqliteDirectoryURL.appendingPathComponent("state_5.sqlite", isDirectory: false)

        return CodexStateDatabaseLocation(
            databaseURL: databaseURL,
            walURL: URL(fileURLWithPath: databaseURL.path + "-wal", isDirectory: false),
            shmURL: URL(fileURLWithPath: databaseURL.path + "-shm", isDirectory: false)
        )
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
