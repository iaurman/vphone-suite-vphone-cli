import Darwin
import Foundation

/// The boot-time AMFI allow, installed by the root helper so a normal launch
/// never asks for an administrator.
///
/// Why it exists: AMFI admits an ad-hoc signed `vphone-vm` only while amfid
/// holds a requirement naming its cdhash, and amfid reads that requirement
/// from `com.apple.security.coderequirements.plist` **once**, at start. The
/// file itself therefore survives a reboot, but the requirement in force
/// starts out as the stock one, so preflight fails after every reboot and the
/// app had to run `vphone-escalator allow` through the helper, which needs an
/// administrator's approval on every call.
///
/// A LaunchDaemon runs the same allow as root at boot with nobody watching, so
/// amfid adopts the preference before any guest starts and preflight passes on
/// its own.
///
/// Two files, deliberately separated:
///
/// * `/Library/LaunchDaemons/com.vphone.launchpad.amfi.plist` is static: no
///   version in it, so it is written once and never again.
/// * `/Library/Application Support/vphone-launchpad/amfi-allow.sh` carries a
///   `# vphone-launchpad-version:` line. The helper rewrites it only when it
///   is missing or the line differs from what this build wants, so a local
///   edit survives and a launch that changes nothing writes nothing.
///
/// The script loops the installed bundles itself instead of naming versions,
/// so installing or removing a bundle needs no rewrite at all.
nonisolated enum VPhoneLaunchpadHelperBootScript {
    static let label = "com.vphone.launchpad.amfi"
    static let scriptName = "amfi-allow.sh"

    /// Where the two files live. A test points this at a temporary directory;
    /// the product always uses ``standard``.
    struct Layout: Sendable, Equatable {
        var daemonPlist: URL
        var script: URL

        static let standard = Layout(
            daemonPlist: URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist", isDirectory: false),
            script: URL(
                fileURLWithPath: "/Library/Application Support/vphone-launchpad/\(scriptName)",
                isDirectory: false,
            ),
        )
    }

    nonisolated(unsafe) static var layout = Layout.standard

    /// Whether launchd already knows the job, and how to reload it. Both are
    /// settable so a test can exercise the write-if-changed logic without
    /// touching the running system's launchd; the product keeps the defaults.
    /// Guarded the same way the rest of this file is, with an explicit
    /// nonisolated(unsafe) since only the helper process and one test write them.
    nonisolated(unsafe) static var isLoaded: () -> Bool = { systemIsLoaded() }
    nonisolated(unsafe) static var reload: () -> Void = { systemReload() }

    /// The real launchd probes, for a test to put back after injecting.
    static func defaultIsLoaded() -> Bool { systemIsLoaded() }
    static func defaultReload() { systemReload() }

    static var daemonPlist: URL {
        layout.daemonPlist
    }

    static var script: URL {
        layout.script
    }

    /// Bumped when `body` changes. Nothing else reads it, so a helper version
    /// bump for an unrelated fix does not rewrite the script.
    static let scriptRevision = 1

    /// The line the script must carry. A file whose line differs is replaced.
    static var versionLine: String {
        "# vphone-launchpad-version: \(scriptRevision)"
    }

    /// The script. Every bundle is allowed by its own `vphone-escalator`, which
    /// pairs the binary's cdhash with the receipt-pinned `vphone-vm`; nothing
    /// here decides what may run. `allow` is idempotent (it leaves the
    /// preference alone when the cdhash is already there and only re-adopts),
    /// so running it on every boot is its intended use.
    static let body = """
    #!/bin/sh
    # Applied at boot by com.vphone.launchpad.amfi. Do not edit by hand: the app
    # replaces this file when its version line no longer matches and leaves it
    # alone otherwise.

    set -u

    store="/Library/Application Support/vphone-launchpad/Bundles"

    for bundle in "$store"/*/VPhone.bundle; do
        [ -d "$bundle" ] || continue
        macos="$bundle/Contents/MacOS"
        vm="$macos/vphone-vm"
        escalator="$macos/vphone-escalator"
        # A bundle the helper is still writing, or one without the tools, is
        # skipped rather than half applied.
        [ -x "$vm" ] || continue
        [ -x "$escalator" ] || continue
        "$escalator" allow "$vm" >/dev/null 2>&1 || true
    done

    exit 0
    """

    /// The whole file: the version line, then the body. The shebang comes
    /// first and the version line second, so the file is still a runnable
    /// script if someone makes it the daemon's program by hand.
    static var contents: String {
        let body = body
        guard let newline = body.firstIndex(of: "\n") else {
            return "\(versionLine)\n\(body)\n"
        }
        let shebang = body[..<newline]
        let rest = body[body.index(after: newline)...]
        return "\(shebang)\n\(versionLine)\n\(rest)\n"
    }

    // MARK: - Install

    /// Writes the script and the daemon when either is missing or out of date,
    /// and leaves both alone when they are current. Runs as root, so the helper
    /// calls it at start and after each `allow`.
    ///
    /// Returns true when something was written, so the caller can log it.
    @discardableResult
    static func install() throws -> Bool {
        var changed = false
        if (try? Data(contentsOf: daemonPlist)) != daemon {
            try write(daemon, to: daemonPlist, mode: 0o644)
            changed = true
        }
        let current = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
        if !current.contains(versionLine) {
            try write(Data(contents.utf8), to: script, mode: 0o755)
            changed = true
        }
        // A changed file, or a job launchd does not have, needs a reload; a
        // launch that changed nothing must not wake amfid again.
        if changed || !isLoaded() {
            reload()
        }
        return changed
    }

    /// Whether launchd already knows the job. `launchctl print` exits non-zero
    /// when it does not.
    private static func systemIsLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Boots the job out and back in, then runs it now, so the current
    /// preference is adopted without waiting for the next boot.
    private static func systemReload() {
        runLaunchctl(["bootout", "system/\(label)"])
        runLaunchctl(["bootstrap", "system", daemonPlist.path])
        runLaunchctl(["enable", "system/\(label)"])
        runLaunchctl(["kickstart", "-k", "system/\(label)"])
    }

    /// The LaunchDaemon, serialised the same way every time so the comparison
    /// above is meaningful. `RunAtLoad` covers the boot; there is deliberately
    /// no `KeepAlive`, since the script exits at once and a failing run must
    /// not loop.
    static var daemon: Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [script.path],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "ThrottleInterval": 0,
            "StandardOutPath": "/var/log/vphone-launchpad-amfi.log",
            "StandardErrorPath": "/var/log/vphone-launchpad-amfi.log",
        ]
        return (try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0,
        )) ?? Data()
    }

    // MARK: - Files

    /// Replaces `url` in one step: a temp file in the same directory, then a
    /// rename, so a launchd run never reads half a script.
    private static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
        )
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temp.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: mode), .ownerAccountID: 0, .groupOwnerAccountID: 0],
        ) else {
            throw VPhoneLaunchpadHelperError("Unable to install the AMFI boot script. Try again.")
        }
        _ = chmod(temp.path, mode)
        _ = chown(temp.path, 0, 0)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            // A missing destination makes `replaceItemAt` fail on some
            // volumes; a plain move covers it.
            do {
                try FileManager.default.moveItem(at: temp, to: url)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw VPhoneLaunchpadHelperError("Unable to install the AMFI boot script. Try again.")
            }
        }
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
