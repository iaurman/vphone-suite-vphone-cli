import Foundation

/// The boot-time AMFI allow: the files it writes, and when it leaves them
/// alone. Run by `BootScriptTests.sh` with the helper sources compiled in.
@main
struct BootScriptTests {
    static func main() throws {
        try writesTheScriptAndTheDaemon()
        try leavesCurrentFilesAlone()
        try replacesAStaleScript()
        try preservesALocalEdit()
        try theScriptLoopsEveryInstalledBundle()
        print("BootScriptTests: ok")
    }

    // MARK: - Helpers

    private static func makeTemporaryLayout() throws -> (VPhoneLaunchpadHelperBootScript.Layout, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layout = VPhoneLaunchpadHelperBootScript.Layout(
            daemonPlist: root.appendingPathComponent("com.vphone.launchpad.amfi.plist"),
            script: root.appendingPathComponent("amfi-allow.sh"),
        )
        return (layout, { try? FileManager.default.removeItem(at: root) })
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A launchd double: records the reloads it was asked for.
    private final class Recorder: @unchecked Sendable {
        var reloads = 0
        var loaded = false
    }

    private static func install(
        _ layout: VPhoneLaunchpadHelperBootScript.Layout,
        recorder: Recorder,
    ) throws -> Bool {
        VPhoneLaunchpadHelperBootScript.layout = layout
        VPhoneLaunchpadHelperBootScript.isLoaded = { recorder.loaded }
        VPhoneLaunchpadHelperBootScript.reload = {
            recorder.reloads += 1
            recorder.loaded = true
        }
        defer {
            VPhoneLaunchpadHelperBootScript.layout = .standard
            VPhoneLaunchpadHelperBootScript.isLoaded = { VPhoneLaunchpadHelperBootScript.defaultIsLoaded() }
            VPhoneLaunchpadHelperBootScript.reload = { VPhoneLaunchpadHelperBootScript.defaultReload() }
        }
        return try VPhoneLaunchpadHelperBootScript.install()
    }

    // MARK: - Tests

    /// A first run writes both files: the script with its version line and the
    /// executable bit, and the plist naming it.
    private static func writesTheScriptAndTheDaemon() throws {
        let (layout, clean) = try makeTemporaryLayout()
        defer { clean() }
        let recorder = Recorder()
        let changed = try install(layout, recorder: recorder)
        try expect(changed, "a first install must report a change")

        let script = try String(contentsOf: layout.script, encoding: .utf8)
        try expect(script.contains(VPhoneLaunchpadHelperBootScript.versionLine), "the version line is missing")
        try expect(script.hasPrefix("#!/bin/sh"), "the script needs a shebang launchd can run")
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.script.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try expect(mode & 0o111 == 0o111, "the script must be executable, mode is \(String(mode, radix: 8))")

        let plist = try Data(contentsOf: layout.daemonPlist)
        let parsed = try PropertyListSerialization.propertyList(from: plist, format: nil)
        let dictionary = try expectType([String: Any].self, parsed, "the daemon plist is not a dictionary")
        try expect(dictionary["Label"] as? String == VPhoneLaunchpadHelperBootScript.label, "wrong label")
        try expect(dictionary["RunAtLoad"] as? Bool == true, "RunAtLoad is what makes it run at boot")
        try expect(dictionary["KeepAlive"] == nil, "KeepAlive would loop a script that exits at once")
        let program = try expectType([String].self, dictionary["ProgramArguments"], "ProgramArguments")
        try expect(program == [layout.script.path], "the daemon must run the script it was installed with")
    }

    /// The whole point of the version line: a second run with current files
    /// writes nothing and wakes nothing.
    private static func leavesCurrentFilesAlone() throws {
        let (layout, clean) = try makeTemporaryLayout()
        defer { clean() }
        let recorder = Recorder()
        _ = try install(layout, recorder: recorder)
        let scriptBefore = try Data(contentsOf: layout.script)
        let plistBefore = try Data(contentsOf: layout.daemonPlist)
        let reloadsBefore = recorder.reloads

        let changed = try install(layout, recorder: recorder)
        try expect(!changed, "a current install must not report a change")
        try expect(try Data(contentsOf: layout.script) == scriptBefore, "the script was rewritten")
        try expect(try Data(contentsOf: layout.daemonPlist) == plistBefore, "the plist was rewritten")
        try expect(recorder.reloads == reloadsBefore, "a current install must not reload the job")
    }

    /// A script whose version line is from another revision is replaced.
    private static func replacesAStaleScript() throws {
        let (layout, clean) = try makeTemporaryLayout()
        defer { clean() }
        let recorder = Recorder()
        _ = try install(layout, recorder: recorder)
        try "#!/bin/sh\n# vphone-launchpad-version: 0\nexit 0\n"
            .write(to: layout.script, atomically: true, encoding: .utf8)

        let changed = try install(layout, recorder: recorder)
        try expect(changed, "a stale script must report a change")
        let script = try String(contentsOf: layout.script, encoding: .utf8)
        try expect(script.contains(VPhoneLaunchpadHelperBootScript.versionLine), "the stale script survived")
    }

    /// A script that still carries the right version line is left exactly as
    /// it is, so a hand edit survives an app update.
    private static func preservesALocalEdit() throws {
        let (layout, clean) = try makeTemporaryLayout()
        defer { clean() }
        let recorder = Recorder()
        _ = try install(layout, recorder: recorder)
        let edited = "#!/bin/sh\n\(VPhoneLaunchpadHelperBootScript.versionLine)\n# local note\nexit 0\n"
        try edited.write(to: layout.script, atomically: true, encoding: .utf8)

        _ = try install(layout, recorder: recorder)
        try expect(try String(contentsOf: layout.script, encoding: .utf8) == edited, "a local edit was overwritten")
    }

    /// The daemon plist is versionless and never names a bundle, so installing
    /// or removing a bundle needs no rewrite. The script finds them itself.
    private static func theScriptLoopsEveryInstalledBundle() throws {
        let body = VPhoneLaunchpadHelperBootScript.body
        try expect(body.contains("/Library/Application Support/vphone-launchpad/Bundles"), "the store is not the one the helper writes")
        try expect(body.contains("\"$store\"/*/VPhone.bundle"), "the script must loop the installed bundles")
        try expect(body.contains("vphone-escalator"), "the script must use the bundle's escalator")
        try expect(body.contains("allow \"$vm\""), "the script must allow the bundle's vphone-vm")
        try expect(!body.contains("2.15"), "the script must not name a bundle version")
        // Anything else would make a failure abort the loop and leave later
        // bundles unallowed.
        try expect(body.contains("|| true"), "a failing bundle must not stop the loop")
    }

    private static func expectType<T>(_ type: T.Type, _ value: Any?, _ name: String) throws -> T {
        guard let typed = value as? T else {
            throw Failure("\(name) has the wrong type: \(String(describing: value))")
        }
        return typed
    }
}
