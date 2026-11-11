import Darwin
import Foundation

/// The only AMFI operation exposed by the root helper. The client supplies a
/// version, never a path or command line. Both executables come from the
/// root-owned, receipt-verified bundle store.
enum VPhoneLaunchpadHelperAMFI {
    private static let lock = NSLock()

    /// Whether amfid currently holds the requirement the preference asks for,
    /// for the bundle's `vphone-vm`. No authorization: it reads a status and
    /// changes nothing, so the app can ask before deciding whether an
    /// administrator is needed at all.
    ///
    /// `vphone-escalator status` prints
    /// `requirement in force       the preference's Entitlements` exactly when
    /// amfid has adopted the preference, which is the condition
    /// `allow` fixes. Anything else means `allow` is still needed.
    static func isAllowed(bundleVersion: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(bundleVersion),
              let receipt = VPhoneLaunchpadBundleReceipt.load(version: bundleVersion),
              let vmHash = receipt.cdhashes["vphone-vm"]
        else { return false }
        let escalator = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-escalator")
        guard FileManager.default.isExecutableFile(atPath: escalator.path) else { return false }
        guard let output = run(escalator, ["status"]) else { return false }
        guard output.contains("the preference's Entitlements") else { return false }
        // The preference is global, so the status alone does not prove *this*
        // bundle is named in it. Ask the file, which is root-readable and the
        // same one amfid reads.
        return preferenceNames(vmHash)
    }

    /// Whether the coderequirements preference names `cdhash`. Read, not
    /// written: `allow` remains the only writer.
    private static func preferenceNames(_ cdhash: String) -> Bool {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.security.coderequirements.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? String
        else { return false }
        return entitlements.range(of: "cdhash H\"\(cdhash)\"", options: .caseInsensitive) != nil
    }

    static func allow(bundleVersion: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try VPhoneLaunchpadHostPolicy.requireReady()

        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(bundleVersion),
              let receipt = VPhoneLaunchpadBundleReceipt.load(version: bundleVersion)
        else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle \(bundleVersion) is not installed. Reinstall it, then try again.")
        }

        let bundle = VPhoneLaunchpadBundleStore.bundle(version: bundleVersion)
        let vm = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-vm")
        let escalator = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-escalator")
        try VPhoneLaunchpadHelperCodeCheck.requireValidBundle(bundle)
        try VPhoneLaunchpadHelperCodeCheck.requireCDHash(vm, receipt.cdhashes["vphone-vm"])

        var info = stat()
        guard lstat(escalator.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              info.st_mode & 0o022 == 0
        else {
            throw VPhoneLaunchpadHelperError("A required tool in VPhone.bundle is missing or was changed. Reinstall VPhone.bundle.")
        }

        let process = Process()
        process.executableURL = escalator
        process.arguments = ["allow", vm.path]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw VPhoneLaunchpadHelperError("Unable to allow the bundle to run. Try again.")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw VPhoneLaunchpadHelperError(text.isEmpty ? "Unable to allow the bundle to run. Check the System Integrity Protection settings on this Mac." : text)
        }
        // The preference is now in place, so the boot script can re-adopt it
        // without an administrator next time; installing it here means a
        // prompt that had to happen anyway also removes the next one.
        try? VPhoneLaunchpadHelperBootScript.install()
    }

    /// Runs the escalator as root and returns its combined output, or nil when
    /// it could not be started.
    private static func run(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }
}
