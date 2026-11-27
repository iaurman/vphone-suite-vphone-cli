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
                return try GuestHarvestRecorder.guest.start(config)
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
        root: URL(fileURLWithPath: "/var/root/vphoned-harvest", isDirectory: true),
        capture: harvestCapture,
    )

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
            tree = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        } catch {
            problems.append("ui.tree: \(Self.message(error))")
        }
        return Capture(
            jpeg: jpeg,
            tree: tree,
            error: problems.isEmpty ? nil : problems.joined(separator: "; "),
            width: width,
            height: height,
            coordinateScale: scale,
        )
    }

    /// IcliKit's errors carry a message that its own description hides.
    private static func message(_ error: any Error) -> String {
        (error as? IcliError)?.message ?? String(describing: error)
    }
}
