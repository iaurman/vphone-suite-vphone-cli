import Foundation
import IcliKit
import VphonedNative

/// `harvest.*`: a recording of screenshots and UI trees that lives only in the
/// guest.
extension GuestAPI {
    static func executeHarvest(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        do {
            switch method {
            case "harvest.start":
                let config = GuestHarvestRecorder.Config.clamped(
                    intervalSeconds: (params["interval_seconds"] as? NSNumber)?.doubleValue,
                    maxBytes: (params["max_bytes"] as? NSNumber)?.intValue,
                    maxSeconds: (params["max_seconds"] as? NSNumber)?.doubleValue,
                )
                return try GuestHarvestRecorder.guest.start(
                    config,
                    environment: harvestEnvironment(label: label(params)),
                )
            case "harvest.stop":
                return GuestHarvestRecorder.guest.stop()
            case "harvest.status", "harvest.sessions":
                return GuestHarvestRecorder.guest.payload()
            case "harvest.note":
                return try GuestHarvestRecorder.guest.note(
                    session: string(params, "session"),
                    text: string(params, "note"),
                )
            case "harvest.delete":
                return try GuestHarvestRecorder.guest.delete(session: string(params, "session"))
            case "harvest.archive":
                return try GuestHarvestRecorder.guest.archive(
                    session: string(params, "session"),
                    using: systemTar,
                )
            case "harvest.archive.delete":
                return try GuestHarvestRecorder.guest.deleteArchive(session: string(params, "session"))
            default:
                return nil
            }
        } catch let error as GuestHarvestError {
            throw GuestAPIError.invalidRequest(error.description)
        }
    }

    /// The facts `harvest.start` copies into the manifest. `collectDeviceSnapshot`
    /// is the same read `device.info` does, taken once per session; a failure
    /// leaves fields unknown instead of failing the start. The device name and
    /// the screen are separate reads on purpose: `device.info` adds them after
    /// the snapshot, which does not carry either.
    private static func harvestEnvironment(label: String?) -> GuestHarvestRecorder.Environment {
        let snapshot = (try? collectDeviceSnapshot()) ?? [:]
        let screen = screenInfo()
        let device = deviceNameInfo()
        return GuestHarvestRecorder.Environment(
            vm: device["name"] as? String ?? device["own_name"] as? String,
            model: snapshot["model"] as? String,
            iosVersion: snapshot["ios_version"] as? String,
            kernel: snapshot["kernel"] as? String,
            vphonedHash: binaryHash,
            screenWidth: (screen["width"] as? NSNumber)?.intValue,
            screenHeight: (screen["height"] as? NSNumber)?.intValue,
            screenScale: (screen["scale"] as? NSNumber)?.doubleValue,
            timeZone: TimeZone.current.identifier,
            label: label,
        )
    }

    /// The caller's own description of the session, stored verbatim. Long text
    /// is cut rather than rejected: a label is a note, not a contract.
    private static func label(_ params: [String: Any]) -> String? {
        guard let text = params["label"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }

    /// The guest's tar, when it has one. `false` means neither binary exists,
    /// and the recorder writes the archive itself.
    private static func systemTar(session: URL, part: URL) throws -> Bool {
        guard let tool = ["/usr/bin/tar", "/bin/tar"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return false }
        let words = [
            tool, "-czf", part.path,
            "-C", session.deletingLastPathComponent().path, session.lastPathComponent,
        ]
        var argv: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) } + [nil]
        defer { argv.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var status: Int32 = 0
        var output: UnsafeMutablePointer<CChar>?
        var errors: UnsafeMutablePointer<CChar>?
        defer {
            free(output)
            free(errors)
        }
        let failure = vp_spawn_collect(tool, &argv, nil, &status, &output, &errors)
        guard failure == 0 else {
            throw GuestAPIError.operationFailed("\(tool): \(String(cString: strerror(failure)))")
        }
        let signal = status & 0x7F
        let code = (status >> 8) & 0xFF
        guard signal == 0, code == 0 else {
            let message = errors.map { String(cString: $0) } ?? ""
            throw GuestAPIError.operationFailed(
                "tar failed: \(message.isEmpty ? "status \(code)" : message)",
            )
        }
        return true
    }
}

extension GuestHarvestRecorder {
    /// The recorder `harvest.*` drives. Its capture is vphoned's own
    /// screenshot and UI tree, so the guest instance sits beside the RPC
    /// surface; the engine file stays free of IcliKit for the Mac tests.
    static let guest = GuestHarvestRecorder(
        root: harvestRoot(),
        capture: harvestCapture,
    )

    /// Where sessions live: the jailbreak's fake root when the guest has one
    /// (roothide), so the data sits with the jailbreak instead of in the real
    /// `/var/root`. The path is resolved at runtime because the fake root
    /// carries a per-install identifier (`.jbroot-<uuid>`).
    private static func harvestRoot() -> URL {
        let jbroot = GuestAPI.jailbreakInfo()["jbroot"] as? String
        let base = jbroot.flatMap { $0.hasPrefix("/") && $0 != "/" ? $0 : nil } ?? ""
        return URL(fileURLWithPath: base + "/var/root/vphoned-harvest", isDirectory: true)
    }

    /// One screenshot and one UI tree at the profile's cost. A failure in either
    /// half is recorded in the index and the other half is still written: a
    /// guest whose foreground app cannot be verified should not cost the host
    /// its screenshots.
    private static func harvestCapture(_ profile: CaptureProfile) throws -> Capture {
        var jpeg: Data?
        var width: Int?
        var height: Int?
        var scale: Double?
        var problems: [String] = []
        do {
            let shot = try takeScreenshot(base64: true, nativeResolution: profile.nativeResolution)
            // The image's own size and its ratio to the point grid are what
            // tell a consumer which space the interaction log's coordinates
            // are in; native captures are three times the points on this guest.
            width = (shot["width"] as? NSNumber)?.intValue
            height = (shot["height"] as? NSNumber)?.intValue
            scale = (shot["coordinate_scale"] as? NSNumber)?.doubleValue
            guard let encoded = shot["data"] as? String else {
                throw GuestAPIError.operationFailed("the screenshot carried no image")
            }
            guard let data = Data(base64Encoded: encoded) else {
                throw GuestAPIError.operationFailed("the screenshot was not base64")
            }
            jpeg = data
        } catch {
            problems.append("screenshot: \(Self.message(error))")
        }
        var tree: Data?
        var foreground: Foreground?
        do {
            // The AX snapshot enables and restores switches process-wide; the
            // interface operations hold this lock for the same reason.
            GuestAPI.interfaceLock.lock()
            defer { GuestAPI.interfaceLock.unlock() }
            let snapshot = try GuestAPI.nestedHierarchy([
                "max_elements": profile.maxElements,
                "max_depth": profile.maxDepth,
                "timeout_ms": profile.timeoutMS,
            ])
            foreground = foregroundInfo(snapshot["foreground_after"] as? [String: Any])
            tree = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        } catch {
            problems.append("ui.tree: \(Self.message(error))")
            // The guest still names the app it has in front; record that,
            // unverified, instead of leaving the frame without any app at all.
            foreground = foregroundInfo(frontmostApp())
        }
        return Capture(
            jpeg: jpeg,
            tree: tree,
            error: problems.isEmpty ? nil : problems.joined(separator: "; "),
            width: width,
            height: height,
            coordinateScale: scale,
            foreground: foreground,
        )
    }

    /// The part of a foreground answer worth keeping. `verified` is what the
    /// tree's own check decided; a failed walk leaves it false.
    private static func foregroundInfo(_ body: [String: Any]?) -> Foreground? {
        guard let body,
              let bundle = body["bundle_id"] as? String, !bundle.isEmpty
        else { return nil }
        return Foreground(
            bundleID: bundle,
            pid: (body["pid"] as? NSNumber)?.intValue,
            verified: body["verified"] as? Bool,
        )
    }

    /// IcliKit's errors carry a message that its own description hides.
    private static func message(_ error: any Error) -> String {
        (error as? IcliError)?.message ?? String(describing: error)
    }
}
