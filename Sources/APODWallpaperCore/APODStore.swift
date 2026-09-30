import Foundation
import ImageIO
import SQLite3

public struct APODRecord: Equatable, Sendable {
    public let apod: APOD
    public let isFavorite: Bool
    public let firstShownAt: Date?
    public let lastShownAt: Date?
    public let showCount: Int
    public let cachedImagePath: URL?
    public let cachedImageSourceURL: URL?

    public init(
        apod: APOD,
        isFavorite: Bool = false,
        firstShownAt: Date? = nil,
        lastShownAt: Date? = nil,
        showCount: Int = 0,
        cachedImagePath: URL? = nil,
        cachedImageSourceURL: URL? = nil
    ) {
        self.apod = apod
        self.isFavorite = isFavorite
        self.firstShownAt = firstShownAt
        self.lastShownAt = lastShownAt
        self.showCount = showCount
        self.cachedImagePath = cachedImagePath
        self.cachedImageSourceURL = cachedImageSourceURL
    }
}

public struct NavigationEntry: Equatable, Sendable {
    public let id: Int64
    public let date: String
    public let shownAt: Date
}

public final class APODStore: @unchecked Sendable {
    public let directoryURL: URL
    public let imageDirectoryURL: URL
    public let databaseURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var database: OpaquePointer?

    public init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let root = directoryURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APOD Wallpaper", isDirectory: true)
        self.directoryURL = root
        self.imageDirectoryURL = root.appendingPathComponent("Images", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("database.sqlite")
        self.database = nil

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: imageDirectoryURL,
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            let message = connection.map(Self.errorMessage) ?? "Could not open database."
            if let connection {
                sqlite3_close(connection)
            }
            throw APODStoreError.database(message)
        }

        self.database = connection
        do {
            try Self.execute(connection, sql: Self.schema)
        } catch {
            sqlite3_close(connection)
            self.database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func save(_ apod: APOD, imageSourceURL: URL? = nil) throws {
        try withDatabase { database in
            let statement = try Self.prepare(database, sql: """
                INSERT INTO apods (
                    date, title, explanation, media_type, url, hdurl,
                    thumbnail_url, copyright, service_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET
                    title = excluded.title,
                    explanation = excluded.explanation,
                    media_type = excluded.media_type,
                    url = excluded.url,
                    hdurl = excluded.hdurl,
                    thumbnail_url = excluded.thumbnail_url,
                    copyright = excluded.copyright,
                    service_version = excluded.service_version
                """)
            defer { sqlite3_finalize(statement) }

            try Self.bind(apod.date, at: 1, in: statement)
            try Self.bind(apod.title, at: 2, in: statement)
            try Self.bind(apod.explanation, at: 3, in: statement)
            try Self.bind(apod.mediaType.rawValue, at: 4, in: statement)
            try Self.bind(apod.url.absoluteString, at: 5, in: statement)
            try Self.bind(apod.hdURL?.absoluteString, at: 6, in: statement)
            try Self.bind(apod.thumbnailURL?.absoluteString, at: 7, in: statement)
            try Self.bind(apod.copyright, at: 8, in: statement)
            try Self.bind(apod.serviceVersion, at: 9, in: statement)
            try Self.step(statement, in: database)
        }

        if let imageSourceURL {
            try withDatabase { database in
                let statement = try Self.prepare(
                    database,
                    sql: "UPDATE apods SET cached_source_url = ? WHERE date = ?"
                )
                defer { sqlite3_finalize(statement) }
                try Self.bind(imageSourceURL.absoluteString, at: 1, in: statement)
                try Self.bind(apod.date, at: 2, in: statement)
                try Self.step(statement, in: database)
            }
        }
    }

    public func record(for date: String) -> APODRecord? {
        try? withDatabase { database in
            let statement = try Self.prepare(database, sql: Self.selectSQL + " WHERE date = ?")
            defer { sqlite3_finalize(statement) }
            try Self.bind(date, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Self.readRecord(statement)
        }
    }

    public func allRecords() -> [APODRecord] {
        (try? records(sql: Self.selectSQL + " ORDER BY date ASC")) ?? []
    }

    public func recentRecords(limit: Int? = nil) -> [APODRecord] {
        let suffix = " WHERE last_shown_at IS NOT NULL ORDER BY last_shown_at DESC"
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        return (try? records(sql: Self.selectSQL + suffix + limitClause)) ?? []
    }

    public func favoriteRecords() -> [APODRecord] {
        (try? records(
            sql: Self.selectSQL
                + " WHERE is_favorite = 1 ORDER BY COALESCE(last_shown_at, 0) DESC, date DESC"
        )) ?? []
    }

    public func seenDates() -> Set<String> {
        let dates = (try? withDatabase { database -> [String] in
            let statement = try Self.prepare(
                database,
                sql: "SELECT date FROM apods WHERE first_shown_at IS NOT NULL"
            )
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let date = Self.columnString(statement, at: 0) {
                    result.append(date)
                }
            }
            return result
        }) ?? []
        return Set(dates)
    }

    public func markFavorite(date: String, isFavorite: Bool) throws {
        try withDatabase { database in
            let statement = try Self.prepare(
                database,
                sql: "UPDATE apods SET is_favorite = ? WHERE date = ?"
            )
            defer { sqlite3_finalize(statement) }
            try Self.bind(isFavorite ? 1 : 0, at: 1, in: statement)
            try Self.bind(date, at: 2, in: statement)
            try Self.step(statement, in: database)
        }
    }

    @discardableResult
    public func recordShown(_ apod: APOD, at date: Date = Date()) throws -> NavigationEntry {
        try save(apod)
        return try withDatabase { database in
            let timestamp = date.timeIntervalSince1970
            let update = try Self.prepare(
                database,
                sql: """
                UPDATE apods
                SET first_shown_at = COALESCE(first_shown_at, ?),
                    last_shown_at = ?,
                    show_count = show_count + 1
                WHERE date = ?
                """
            )
            defer { sqlite3_finalize(update) }
            try Self.bind(timestamp, at: 1, in: update)
            try Self.bind(timestamp, at: 2, in: update)
            try Self.bind(apod.date, at: 3, in: update)
            try Self.step(update, in: database)

            let insert = try Self.prepare(
                database,
                sql: "INSERT INTO display_events (date, shown_at) VALUES (?, ?)"
            )
            defer { sqlite3_finalize(insert) }
            try Self.bind(apod.date, at: 1, in: insert)
            try Self.bind(timestamp, at: 2, in: insert)
            try Self.step(insert, in: database)

            return NavigationEntry(
                id: sqlite3_last_insert_rowid(database),
                date: apod.date,
                shownAt: date
            )
        }
    }

    public func latestNavigationEntry() -> NavigationEntry? {
        navigationEntry(sql: """
            SELECT id, date, shown_at FROM display_events ORDER BY id DESC LIMIT 1
            """)
    }

    public func navigationEntry(before id: Int64) -> NavigationEntry? {
        navigationEntry(sql: """
            SELECT id, date, shown_at FROM display_events
            WHERE id < \(id) ORDER BY id DESC LIMIT 1
            """)
    }

    public func navigationEntry(after id: Int64) -> NavigationEntry? {
        navigationEntry(sql: """
            SELECT id, date, shown_at FROM display_events
            WHERE id > \(id) ORDER BY id ASC LIMIT 1
            """)
    }

    public func cachedImageURL(for date: String) -> URL? {
        let url = record(for: date)?.cachedImagePath ?? imageURL(for: date)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return nil
        }
        return url
    }

    public func imageURL(for date: String) -> URL {
        imageDirectoryURL.appendingPathComponent(Self.fileName(for: date))
    }

    @discardableResult
    public func saveImageData(_ data: Data, for date: String) throws -> URL {
        try saveImageData(data, for: date, staging: false)
    }

    func stageImageData(_ data: Data, for date: String) throws -> URL {
        try saveImageData(data, for: date, staging: true)
    }

    private func saveImageData(_ data: Data, for date: String, staging: Bool) throws -> URL {
        guard !data.isEmpty else {
            throw APODStoreError.emptyImageData
        }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
            throw APODStoreError.invalidImageData
        }

        let url = staging
            ? imageDirectoryURL.appendingPathComponent("\(date)-\(UUID().uuidString).image")
            : imageURL(for: date)
        try data.write(to: url, options: .atomic)
        if staging { return url }
        try withDatabase { database in
            let statement = try Self.prepare(
                database,
                sql: """
                UPDATE apods SET cached_image_path = ? WHERE date = ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try Self.bind(url.path, at: 1, in: statement)
            try Self.bind(date, at: 2, in: statement)
            try Self.step(statement, in: database)
        }
        return url
    }

    func commitImage(at url: URL, for apod: APOD, sourceURL: URL) throws {
        let previousURL = cachedImageURL(for: apod.date)
        try save(apod, imageSourceURL: sourceURL)
        try withDatabase { database in
            let statement = try Self.prepare(
                database,
                sql: "UPDATE apods SET cached_image_path = ? WHERE date = ?"
            )
            defer { sqlite3_finalize(statement) }
            try Self.bind(url.path, at: 1, in: statement)
            try Self.bind(apod.date, at: 2, in: statement)
            try Self.step(statement, in: database)
        }
        if let previousURL, previousURL != url {
            try? fileManager.removeItem(at: previousURL)
        }
    }

    func discardStagedImage(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func recordReapplied(_ apod: APOD, at date: Date = Date()) throws {
        try withDatabase { database in
            let statement = try Self.prepare(database, sql: """
                UPDATE apods SET last_shown_at = ?, show_count = show_count + 1
                WHERE date = ?
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(date.timeIntervalSince1970, at: 1, in: statement)
            try Self.bind(apod.date, at: 2, in: statement)
            try Self.step(statement, in: database)
        }
    }

    public func clearImageCache() throws {
        for url in try fileManager.contentsOfDirectory(
            at: imageDirectoryURL,
            includingPropertiesForKeys: nil
        ) {
            try fileManager.removeItem(at: url)
        }
        try withDatabase { database in
            try Self.execute(
                database,
                sql: "UPDATE apods SET cached_image_path = NULL"
            )
        }
    }

    public func cacheSizeBytes() -> Int64 {
        let urls = (try? fileManager.contentsOfDirectory(
            at: imageDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls.reduce(into: Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
    }

    private func records(sql: String) throws -> [APODRecord] {
        try withDatabase { database in
            let statement = try Self.prepare(database, sql: sql)
            defer { sqlite3_finalize(statement) }
            var result: [APODRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = Self.readRecord(statement) {
                    result.append(record)
                }
            }
            return result
        }
    }

    private func navigationEntry(sql: String) -> NavigationEntry? {
        try? withDatabase { database in
            let statement = try Self.prepare(database, sql: sql)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let date = Self.columnString(statement, at: 1) else {
                return nil
            }
            return NavigationEntry(
                id: sqlite3_column_int64(statement, 0),
                date: date,
                shownAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
    }

    private func withDatabase<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let database else {
            throw APODStoreError.database("The APOD database is unavailable.")
        }
        return try body(database)
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS apods (
            date TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            explanation TEXT,
            media_type TEXT NOT NULL,
            url TEXT NOT NULL,
            hdurl TEXT,
            thumbnail_url TEXT,
            copyright TEXT,
            service_version TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            first_shown_at REAL,
            last_shown_at REAL,
            show_count INTEGER NOT NULL DEFAULT 0,
            cached_image_path TEXT,
            cached_source_url TEXT
        );
        CREATE TABLE IF NOT EXISTS display_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            shown_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS display_events_date_idx ON display_events(date);
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """

    private static let selectSQL = """
        SELECT date, title, explanation, media_type, url, hdurl, thumbnail_url,
               copyright, service_version, is_favorite, first_shown_at, last_shown_at,
               show_count, cached_image_path, cached_source_url
        FROM apods
        """

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? Self.errorMessage(database)
            sqlite3_free(errorMessage)
            throw APODStoreError.database(message)
        }
    }

    private static func prepare(
        _ database: OpaquePointer,
        sql: String
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw APODStoreError.database(errorMessage(database))
        }
        return statement
    }

    private static func step(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw APODStoreError.database(errorMessage(database))
        }
    }

    private static func bind(
        _ value: String?,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw APODStoreError.database("Could not bind database value.")
        }
    }

    private static func bind(
        _ value: Int,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw APODStoreError.database("Could not bind database value.")
        }
    }

    private static func bind(
        _ value: Double,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw APODStoreError.database("Could not bind database value.")
        }
    }

    private static func columnString(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private static func readRecord(_ statement: OpaquePointer) -> APODRecord? {
        guard let date = columnString(statement, at: 0),
              let title = columnString(statement, at: 1),
              let mediaTypeValue = columnString(statement, at: 3),
              let urlValue = columnString(statement, at: 4),
              let url = URL(string: urlValue) else {
            return nil
        }

        let apod = APOD(
            date: date,
            title: title,
            explanation: columnString(statement, at: 2),
            mediaType: APODMediaType(rawValue: mediaTypeValue) ?? .unknown,
            url: url,
            hdURL: columnString(statement, at: 5).flatMap(URL.init(string:)),
            thumbnailURL: columnString(statement, at: 6).flatMap(URL.init(string:)),
            copyright: columnString(statement, at: 7),
            serviceVersion: columnString(statement, at: 8)
        )
        let firstShown = sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        let lastShown = sqlite3_column_type(statement, 11) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        let cachedPath = columnString(statement, at: 13).map { URL(fileURLWithPath: $0) }
        let cachedSource = columnString(statement, at: 14).flatMap(URL.init(string:))

        return APODRecord(
            apod: apod,
            isFavorite: sqlite3_column_int(statement, 9) != 0,
            firstShownAt: firstShown,
            lastShownAt: lastShown,
            showCount: Int(sqlite3_column_int(statement, 12)),
            cachedImagePath: cachedPath,
            cachedImageSourceURL: cachedSource
        )
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func fileName(for date: String) -> String {
        let safeDate = date.unicodeScalars.filter {
            CharacterSet.decimalDigits.contains($0) || $0 == "-"
        }
        let value = String(String.UnicodeScalarView(safeDate))
        return value.isEmpty ? "apod.jpg" : "\(value).jpg"
    }
}

public enum APODStoreError: Error, Equatable, LocalizedError, Sendable {
    case database(String)
    case emptyImageData
    case invalidImageData

    public var errorDescription: String? {
        switch self {
        case let .database(message):
            return message
        case .emptyImageData:
            return "NASA returned an empty image."
        case .invalidImageData:
            return "NASA returned data that is not a valid image."
        }
    }
}

public protocol ImageDownloading: Sendable {
    func download(
        from url: URL,
        progress: @escaping @Sendable (_ receivedBytes: Int64, _ expectedBytes: Int64) -> Void
    ) async throws -> Data
}

public struct URLSessionImageDownloader: ImageDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(session: URLSession = .shared) {
        self.configuration = session.configuration
    }

    public func download(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Data {
        let transfer = ImageDownloadTransfer(progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                transfer.start(url: url, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }
}

private final class ImageDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var result: Result<Data, Error>?
    private var lastProgressAt = Date.distantPast

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.progress = progress
    }

    func start(
        url: URL,
        configuration: URLSessionConfiguration,
        continuation: CheckedContinuation<Data, Error>
    ) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        lock.lock()
        self.continuation = continuation
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        task.resume()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressAt) >= 0.1
            || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastProgressAt = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw APODClientError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw APODClientError.httpStatus(response.statusCode)
            }
            // The temporary file disappears after this delegate callback. Mapping avoids
            // accumulating chunks or copying the complete response into another buffer.
            return try Data(contentsOf: location, options: .mappedIfSafe)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: result ?? .failure(APODClientError.invalidResponse))
        }
    }
}
