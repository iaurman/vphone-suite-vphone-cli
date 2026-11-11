import Darwin
import Foundation

/// Removing a machine folder, whatever its contents happen to be.
///
/// `FileManager.removeItem` is one pass over the tree, and it gives up on the
/// first entry the filesystem refuses: an immutable file (`chflags uchg`, which
/// some installers and backup tools set), a read-only directory, a Unix
/// socket, or an ACL that denies deletion. A machine folder that cannot be
/// deleted is worse than one deleted eagerly, so this walks the tree itself:
///
/// 1. Clear the barriers: `UF_IMMUTABLE`, `SF_IMMUTABLE`, the append and
///    "cannot unlink" flags, then add the owner's write bit to a file and the
///    owner's write and search bits to a directory.
/// 2. Remove each entry with `unlinkat`, children before their directory, and
///    the machine folder itself last.
/// 3. On a refusal, repair the entry and try again; if that is not enough,
///    drop the ACL of the directory holding it (one of ours, never the
///    library root) and try once more.
///
/// The walk is descriptor relative (`openat`/`fstatat`/`unlinkat` with
/// `O_NOFOLLOW`), the discipline `VPhoneHostFilePermissions` already uses:
/// a symlink inside the folder is removed as a link and never followed, and a
/// directory swapped for a symlink between the check and the open is refused
/// rather than descended into. Only the named entry and its contents are
/// touched.
public enum VPhoneDirectoryRemoval {
    /// Removes `url` and everything under it. A path that does not exist is
    /// already removed and returns normally. Throws only when an entry truly
    /// remains, naming the path that survived.
    public static func remove(_ url: URL) throws {
        var root = stat()
        guard lstat(url.path, &root) == 0 else {
            if errno == ENOENT {
                return
            }
            throw failure(at: url.path, "inspect")
        }
        // A file where a folder was expected is still removed: it is the entry
        // the caller named, and leaving it would be the bug this exists for.
        guard root.st_mode & S_IFMT == S_IFDIR else {
            try removeFile(at: url)
            return
        }

        let parentURL = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", parentURL.path != url.path else {
            throw VPhoneDirectoryRemovalError(path: url.path, detail: "Not a name inside a directory.")
        }
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            throw failure(at: parentURL.path, "open")
        }
        defer { close(parent) }

        try removeDirectory(named: cString(name), in: parent, expected: root, path: url.path, mayDropParentACL: false)

        var check = stat()
        if lstat(url.path, &check) == 0 {
            throw VPhoneDirectoryRemovalError(path: url.path, detail: "The folder is still there after it was removed.")
        }
    }

    // MARK: - Entries

    private static func removeFile(at url: URL) throws {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            throw failure(at: url.deletingLastPathComponent().path, "open")
        }
        defer { close(parent) }
        try unlink(
            named: cString(url.lastPathComponent),
            in: parent,
            directory: false,
            path: url.path,
            mayDropParentACL: false,
        )
    }

    /// Removes one name inside `parent`, whatever kind of entry it is.
    private static func removeEntry(named name: [CChar], in parent: Int32, path: String, mayDropParentACL: Bool) throws {
        var expected = stat()
        guard fstatat(parent, name, &expected, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw failure(at: path, "inspect")
        }
        if expected.st_mode & S_IFMT == S_IFDIR {
            try removeDirectory(named: name, in: parent, expected: expected, path: path, mayDropParentACL: mayDropParentACL)
        } else {
            // A file, a socket, a fifo or a symlink: one unlinkat, and a
            // symlink is removed itself, never what it points at.
            try unlink(named: name, in: parent, directory: false, path: path, mayDropParentACL: mayDropParentACL)
        }
    }

    private static func removeDirectory(
        named name: [CChar],
        in parent: Int32,
        expected: stat,
        path: String,
        mayDropParentACL: Bool,
    ) throws {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if errno == ENOENT {
                return
            }
            throw failure(at: path, "open")
        }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0 else {
            throw failure(at: path, "inspect")
        }
        // The name may have been retyped between `fstatat` and `openat`: a
        // symlink to a directory outside the machine would open that instead.
        guard opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              opened.st_mode & S_IFMT == S_IFDIR
        else {
            throw VPhoneDirectoryRemovalError(path: path, detail: "The entry changed while it was being removed.")
        }

        // An immutable or unwritable directory refuses the removal of what is
        // inside it, so the repair comes first.
        repair(directory)
        // The folder can gain an entry between the listing and the `rmdir`: vpd
        // rewrites a machine's port reservation, a backup tool writes a file,
        // another instance of the app allocates one. That entry is what made a
        // delete fail with "Directory not empty" and leave the folder behind,
        // so the listing is taken again while `rmdir` keeps answering
        // `ENOTEMPTY`, up to `removalPasses` times. A folder that keeps growing
        // is given up on instead of looped over forever; the refusal then names
        // the folder that survived.
        for _ in 0..<Self.removalPasses {
            let children = try list(directory, path: path)
            for child in children {
                let childPath = path.hasSuffix("/") ? path + describe(child) : path + "/" + describe(child)
                try removeEntry(named: child, in: directory, path: childPath, mayDropParentACL: true)
            }
            if unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                return
            }
            guard errno == ENOTEMPTY else { break }
        }
        try unlink(named: name, in: parent, directory: true, path: path, mayDropParentACL: mayDropParentACL)
    }

    /// How many times a directory is listed again when `rmdir` reports that it
    /// is not empty. Three is the walk, one retry for an entry that appeared,
    /// and one more so a short burst of writes still ends removed.
    private static let removalPasses = 3

    /// Every name in `directory` except `.` and `..`, as null-terminated C
    /// strings, read into a snapshot so entries can be removed while the walk
    /// goes on. Names are kept as bytes: a name need not be valid UTF-8, and
    /// rebuilding one from a mangled `String` would address a file that does
    /// not exist.
    private static func list(_ directory: Int32, path: String) throws -> [[CChar]] {
        let listing = dup(directory)
        guard listing >= 0 else {
            throw failure(at: path, "list")
        }
        guard let stream = fdopendir(listing) else {
            let error = failure(at: path, "list")
            close(listing)
            throw error
        }
        defer { closedir(stream) }
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw failure(at: path, "list")
                }
                return names
            }
            let length = Int(entry.pointee.d_namlen)
            // Copied out here: a slice into the buffer `withUnsafeBytes` lends
            // would dangle once it returns, and the names would be garbage.
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                Array(raw.bindMemory(to: UInt8.self).prefix(length))
            }
            if bytes == [0x2E] || bytes == [0x2E, 0x2E] {
                continue
            }
            names.append(bytes.map { CChar(bitPattern: $0) } + [0])
        }
    }

    /// Removes one entry, repairing it first when the filesystem refuses.
    ///
    /// Three attempts, each only after fixing what made the previous one fail:
    /// the entry's own flags and mode, then (for a directory) the ACL of the
    /// directory that holds it, which is one of the machine's own.
    private static func unlink(
        named name: [CChar],
        in parent: Int32,
        directory: Bool,
        path: String,
        mayDropParentACL: Bool,
    ) throws {
        let mode = directory ? AT_REMOVEDIR : 0
        if unlinkat(parent, name, mode) == 0 {
            return
        }
        guard let refused = POSIXErrorCode(rawValue: errno), refused == .EACCES || refused == .EPERM else {
            throw failure(at: path, "remove")
        }
        // The flags and mode on the entry itself.
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        let child = openat(parent, name, flags)
        if child >= 0 {
            repair(child)
            close(child)
        }
        if unlinkat(parent, name, mode) == 0 {
            return
        }
        // An ACL that denies deletion is carried by the entry, or by the
        // directory holding it: the parent when this is a directory, the entry
        // itself (a file with a deny ACE) otherwise.
        if directory, mayDropParentACL {
            dropACL(of: parent)
        } else {
            let entry = openat(parent, name, flags)
            if entry >= 0 {
                dropACL(of: entry)
                close(entry)
            }
        }
        if unlinkat(parent, name, mode) == 0 {
            return
        }
        throw failure(at: path, "remove")
    }

    // MARK: - Repair

    /// Clears the flags that hold an entry in place and adds the owner's write
    /// and search bits. Works on the descriptor, so a path swapped underneath
    /// cannot redirect it.
    private static func repair(_ descriptor: Int32) {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return }
        let held = metadata.st_flags & UInt32(
            UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK,
        )
        if held != 0 {
            _ = fchflags(descriptor, metadata.st_flags & ~held)
        }
        let wanted: UInt16 = metadata.st_mode & S_IFMT == S_IFDIR ? 0o700 : 0o200
        if metadata.st_mode & wanted != wanted {
            _ = fchmod(descriptor, (metadata.st_mode & 0o7777) | wanted)
        }
    }

    private static func dropACL(of descriptor: Int32) {
        guard let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        _ = acl_set_fd(descriptor, empty)
    }

    // MARK: - Names and errors

    /// A path component as a C string. `Array(...)` rather than the raw
    /// `ContiguousArray` keeps the pointer stable for the call.
    private static func cString(_ name: String) -> [CChar] {
        Array(name.utf8CString)
    }

    /// A name read from `readdir`, for a message. Names that are not valid
    /// UTF-8 are shown with the replacement character; only the message is
    /// affected, never what is removed.
    private static func describe(_ name: [CChar]) -> String {
        String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func failure(at path: String, _ operation: String) -> VPhoneDirectoryRemovalError {
        VPhoneDirectoryRemovalError(
            path: path,
            detail: "\(operation): \(String(cString: strerror(errno)))",
        )
    }
}

/// A machine folder that survived the removal, with the entry that refused and
/// the reason the filesystem gave.
public struct VPhoneDirectoryRemovalError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The entry that is still there: the folder itself, or what is left in it.
    public let path: String
    public let detail: String

    public init(path: String, detail: String) {
        self.path = path
        self.detail = detail
    }

    public var description: String {
        "Could not delete \(path): \(detail)."
    }

    public var errorDescription: String? {
        description
    }
}
