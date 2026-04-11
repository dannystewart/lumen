import Foundation
import Vapor

// MARK: - FileController

/// Handles file download and upload between Prism and Lumen nodes.
///
/// These endpoints allow Prism to act as a relay when transferring files between nodes that cannot
/// communicate directly. Prism downloads from the source node and uploads to the destination node
/// in a two-phase transfer coordinated entirely by the app.
///
/// - `GET /files?path=<absolute-path>` — stream a file's bytes to the caller
/// - `PUT /files?path=<absolute-path>` — receive file bytes and write them to disk
struct FileController: RouteCollection {
    /// Hard cap on file size for both download and upload. 50 MB covers most practical use cases
    /// (source files, configs, archives, build artifacts) without risking memory exhaustion.
    static let maxFileSize = 50 * 1024 * 1024 // 50 MB

    func boot(routes: RoutesBuilder) throws {
        routes.get("files", use: self.download)
        // Cap the body collection at maxFileSize to reject oversized uploads before they land.
        routes.on(.PUT, "files", body: .collect(maxSize: ByteCount(value: Self.maxFileSize)), use: self.upload)
    }

    // MARK: - GET /files

    /// Stream a file from this node back to the Prism app.
    ///
    /// Query parameters:
    /// - `path` (required): Absolute path of the file to download.
    @Sendable
    func download(req: Request) async throws -> Response {
        guard let path = req.query[String.self, at: "path"], !path.isEmpty else {
            throw Abort(.badRequest, reason: "Missing required query parameter: path")
        }

        // Confirm the path exists and is not a directory.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists else {
            throw Abort(.notFound, reason: "File not found: \(path)")
        }
        guard !isDirectory.boolValue else {
            throw Abort(.badRequest, reason: "Path is a directory, not a file: \(path)")
        }

        // Enforce the size cap before streaming to avoid buffering an oversized file.
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes[.size] as? Int) ?? 0
        guard fileSize <= Self.maxFileSize else {
            let mb = fileSize / (1024 * 1024)
            throw Abort(.payloadTooLarge, reason: "File is \(mb) MB, which exceeds the 50 MB transfer limit.")
        }

        req.logger.info("file download: path=\(path) size=\(fileSize)")

        // Vapor streams the file in chunks — no need to load it all into memory at once.
        return try await req.fileio.asyncStreamFile(at: path)
    }

    // MARK: - PUT /files

    /// Receive file bytes from Prism and write them atomically to a path on this node.
    ///
    /// Query parameters:
    /// - `path` (required): Absolute path where the file will be written. Parent directories
    ///   are created automatically if they do not exist.
    @Sendable
    func upload(req: Request) async throws -> FileUploadResponse {
        guard let path = req.query[String.self, at: "path"], !path.isEmpty else {
            throw Abort(.badRequest, reason: "Missing required query parameter: path")
        }

        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Request body is empty.")
        }

        let data = Data(buffer.readableBytesView)

        req.logger.info("file upload: path=\(path) size=\(data.count)")

        // Create parent directories if they do not yet exist.
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Atomic write: Foundation writes to a temp file and renames it into place, so a crash
        // mid-write never leaves a partial file at the destination path.
        let destination = URL(fileURLWithPath: path)
        try data.write(to: destination, options: .atomic)

        return FileUploadResponse(written: data.count, path: path)
    }
}

// MARK: - FileUploadResponse

struct FileUploadResponse: Content {
    /// Number of bytes written to disk.
    let written: Int
    /// The absolute path where the file was written.
    let path: String
}
