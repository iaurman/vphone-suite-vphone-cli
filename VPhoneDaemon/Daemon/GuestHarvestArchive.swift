import CryptoKit
import Foundation
import zlib

/// The tar.gz `harvest.archive` writes on a guest with no `/usr/bin/tar`.
///
/// The archive holds `<session>/` exactly as it sits in the guest, so an
/// extraction recreates the session directory. zlib's `gz*` writer produces
/// the gzip wrapper, and the tar stream is plain ustar: the session's paths are
/// far shorter than a name field, which is the only part of ustar this writer
/// leaves out.
enum HarvestArchive {
    private static let blockSize = 512
    private static let chunkSize = 256 << 10

    /// Writes every regular file under `session`, as `session/<path>`, into a
    /// gzip stream at `destination`.
    static func write(session: URL, to destination: URL) throws {
        let files = try entries(in: session, prefix: session.lastPathComponent)
        guard let gzip = gzopen(destination.path, "wb") else {
            throw HarvestArchiveError.cannotWrite(destination.path)
        }
        var failure: Error?
        do {
            for file in files {
                try emit(try header(file), to: gzip)
                try emit(file: file.url, size: file.size, to: gzip)
                try emit([UInt8](repeating: 0, count: (blockSize - file.size % blockSize) % blockSize), to: gzip)
            }
            try emit([UInt8](repeating: 0, count: blockSize * 2), to: gzip)
        } catch {
            failure = error
        }
        let closed = gzclose(gzip)
        if let failure { throw failure }
        guard closed == Z_OK else {
            throw HarvestArchiveError.cannotWrite(destination.path)
        }
    }

    /// The hex SHA-256 of a file, read in chunks so an archive of gigabytes
    /// never sits in memory.
    static func sha256(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw HarvestArchiveError.cannotRead(url.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Entries

    struct Entry {
        let name: String
        let url: URL
        let size: Int
        let modified: Date
    }

    /// Every regular file under `directory`, sorted so two archives of the
    /// same session are byte-identical.
    static func entries(in directory: URL, prefix: String) throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        // Relative subpaths, because a root under /var enumerates as /private/var.
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        var entries: [Entry] = []
        for relative in subpaths.sorted() {
            let file = directory.appendingPathComponent(relative)
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }
            entries.append(Entry(
                name: prefix + "/" + relative,
                url: file,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            ))
        }
        return entries
    }

    // MARK: - Tar

    private static func header(_ entry: Entry) throws -> [UInt8] {
        let name = Array(entry.name.utf8)
        guard name.count <= 100 else { throw HarvestArchiveError.nameTooLong(entry.name) }
        var block = [UInt8](repeating: 0, count: blockSize)
        block.replaceSubrange(0 ..< name.count, with: name)
        place(number(0o644, width: 8), at: 100, in: &block)
        place(number(0, width: 8), at: 108, in: &block)
        place(number(0, width: 8), at: 116, in: &block)
        place(number(entry.size, width: 12), at: 124, in: &block)
        place(number(Int(entry.modified.timeIntervalSince1970), width: 12), at: 136, in: &block)
        place(Array("ustar".utf8) + [0], at: 257, in: &block)
        place(Array("00".utf8), at: 263, in: &block)
        place(Array("root".utf8), at: 265, in: &block)
        place(Array("root".utf8), at: 297, in: &block)
        place(number(0, width: 8), at: 329, in: &block)
        place(number(0, width: 8), at: 337, in: &block)
        block[156] = UInt8(ascii: "0")
        // The checksum sums the header with its own field read as spaces.
        for index in 148 ..< 156 {
            block[index] = 0x20
        }
        let checksum = block.reduce(0) { $0 + Int($1) }
        place(Array(String(format: "%06o", checksum).utf8) + [0, 0x20], at: 148, in: &block)
        return block
    }

    /// A numeric field of `width` bytes: octal digits then a NUL, or, when the
    /// value does not fit — a session may be capped at 8 GiB — tar's binary
    /// form, a set high bit and a big-endian value.
    private static func number(_ value: Int, width: Int) -> [UInt8] {
        let digits = Array(String(max(0, value), radix: 8).utf8)
        if digits.count <= width - 1 {
            return [UInt8](repeating: UInt8(ascii: "0"), count: width - 1 - digits.count) + digits + [0]
        }
        var bytes = [UInt8](repeating: 0, count: width)
        var remaining = value
        for index in stride(from: width - 1, through: 1, by: -1) {
            bytes[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        bytes[0] = 0x80
        return bytes
    }

    private static func place(_ bytes: [UInt8], at offset: Int, in block: inout [UInt8]) {
        block.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }

    // MARK: - Streams

    private static func emit(_ bytes: [UInt8], to gzip: gzFile) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBufferPointer { buffer in
            var written = 0
            while written < buffer.count {
                let count = gzwrite(gzip, buffer.baseAddress! + written, UInt32(buffer.count - written))
                guard count > 0 else { throw HarvestArchiveError.cannotWrite("the gzip stream stopped") }
                written += Int(count)
            }
        }
    }

    /// Writes exactly the `size` the header declares, so an `index.jsonl` that
    /// grows while it is archived cannot shift the stream behind it.
    private static func emit(file: URL, size: Int, to gzip: gzFile) throws {
        guard size > 0 else { return }
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            throw HarvestArchiveError.cannotRead(file.path)
        }
        defer { try? handle.close() }
        var remaining = size
        while remaining > 0 {
            if let chunk = try handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty {
                remaining -= chunk.count
                try emit([UInt8](chunk), to: gzip)
            } else {
                try emit([UInt8](repeating: 0, count: min(chunkSize, remaining)), to: gzip)
                remaining -= min(chunkSize, remaining)
            }
        }
    }
}

enum HarvestArchiveError: Error, CustomStringConvertible {
    case cannotWrite(String)
    case cannotRead(String)
    case nameTooLong(String)

    var description: String {
        switch self {
        case let .cannotWrite(message): "could not write the archive: \(message)"
        case let .cannotRead(path): "could not read \(path)"
        case let .nameTooLong(name): "\(name) is longer than a tar name field"
        }
    }
}
