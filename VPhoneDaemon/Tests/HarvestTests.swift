import Foundation

// Checks the harvest recorder on the Mac: the timer's cadence, the gesture
// debounce, the skip while a capture is in flight, both caps, notes, retention,
// startup recovery and the built-in archive. GuestHarvest.swift and
// GuestHarvestArchive.swift are compiled with this file by
// run-harvest-tests.sh; the capture, the clock and the root are substitutes, so
// no guest is involved.

@main
enum HarvestTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    static func refuses(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return true
        }
    }

    /// Compares a value from a JSON line with the value that produced it. A
    /// JSON round trip turns Swift numbers and flags into NSNumber, so a plain
    /// `==` on `Any` would miss otherwise identical params.
    static func sameJSON(_ expected: Any, _ actual: Any?) -> Bool {
        guard let expected = expected as? NSObject, let actual = actual as? NSObject else {
            return false
        }
        return expected.isEqual(actual)
    }

    static func main() {
        do {
            try clamping()
            try emptyStatus()
            try timerCadence()
            try startFrame()
            try selfDescribing()
            try startIsIdempotent()
            try interactionDebounce()
            try interactionLog()
            try interactionCaptureLink()
            try inputWithoutCapture()
            try inputSilence()
            try oneCapturePerBurst()
            try captureProfiles()
            try timerCoalescesInteraction()
            try interactionAccounting()
            try skipWhileCapturing()
            try sizeCap()
            try timeCap()
            try captureFailure()
            try notes()
            retentionPlan()
            try retentionOnStart()
            try interruptedRecovery()
            try archives()
        } catch {
            failures += 1
            print("FAIL: \(error)")
        }
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Fixtures

    final class Clock: GuestHarvestRecorder.Clock, @unchecked Sendable {
        struct Wait {
            let due: Date
            let body: @Sendable () -> Void
        }

        var current = Date(timeIntervalSince1970: 1_796_000_000)
        var waits: [Wait] = []

        var now: Date { current }

        func after(_ delay: TimeInterval, _ body: @escaping @Sendable () -> Void) {
            waits.append(Wait(due: current.addingTimeInterval(delay), body: body))
        }

        /// Fires everything due within `seconds`, earliest first.
        func advance(by seconds: TimeInterval) {
            let target = current.addingTimeInterval(seconds)
            while true {
                waits.sort { $0.due < $1.due }
                guard let next = waits.first, next.due <= target else { break }
                waits.removeFirst()
                current = max(current, next.due)
                next.body()
            }
            current = target
        }
    }

    struct CaptureFailure: Error, CustomStringConvertible {
        let description: String
    }

    final class Source: @unchecked Sendable {
        var jpegSize = 1_000
        var treeSize = 1_000
        var failure: String?
        var calls = 0
        var profiles: [GuestHarvestRecorder.CaptureProfile] = []

        func capture(_ profile: GuestHarvestRecorder.CaptureProfile) throws -> GuestHarvestRecorder.Capture {
            calls += 1
            profiles.append(profile)
            if let failure { throw CaptureFailure(description: failure) }
            // The numbers a real guest reports: native is 3x the point grid.
            return GuestHarvestRecorder.Capture(
                jpeg: Data(repeating: 0x41, count: jpegSize),
                tree: Data(repeating: 0x7B, count: treeSize),
                error: nil,
                width: profile.nativeResolution ? 1290 : 430,
                height: profile.nativeResolution ? 2796 : 932,
                coordinateScale: profile.nativeResolution ? 3 : 1,
            )
        }
    }

    /// Stands in for the guest's capture queue: a capture waits here until the
    /// test runs it, which is what makes "still in flight" observable.
    final class Runner: @unchecked Sendable {
        var pending: [@Sendable () -> Void] = []

        func take(_ body: @escaping @Sendable () -> Void) {
            pending.append(body)
        }

        @discardableResult
        func runNext() -> Bool {
            guard !pending.isEmpty else { return false }
            pending.removeFirst()()
            return true
        }
    }

    final class Harness {
        let root: URL
        let clock: Clock
        let source: Source
        let runner: Runner
        let recorder: GuestHarvestRecorder

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("vphoned-harvest-tests-\(UUID().uuidString)")
            let clock = Clock()
            let source = Source()
            let runner = Runner()
            self.root = root
            self.clock = clock
            self.source = source
            self.runner = runner
            recorder = GuestHarvestRecorder(
                root: root,
                capture: { profile in try source.capture(profile) },
                clock: clock,
                runCapture: { body in runner.take(body) },
            )
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func start(
            interval: Double = 3, maxBytes: Int = 2 << 30, maxSeconds: Double = 1800,
            environment: GuestHarvestRecorder.Environment = .unknown,
            captureAtStart: Bool = false,
        ) throws -> [String: Any] {
            try recorder.start(
                GuestHarvestRecorder.Config(
                    intervalSeconds: interval, maxBytes: maxBytes, maxSeconds: maxSeconds,
                ),
                environment: environment,
                captureAtStart: captureAtStart,
            )
        }

        /// Lets the loop run everything the clock and the gestures queued.
        func settle() {
            _ = recorder.payload()
        }

        /// Moves the clock, then lets the loop run what that fired.
        func advance(_ seconds: TimeInterval) {
            clock.advance(by: seconds)
            settle()
        }

        /// One timer interval, with the capture it asked for run to the end.
        func tick(by interval: TimeInterval) {
            advance(interval)
            runner.runNext()
            settle()
        }

        /// One input the way the guest's RPC handlers report it, then the loop
        /// run so the line and the schedule are in place.
        func input(_ method: String, _ params: [String: Any] = [:]) {
            recorder.noteInput(method, params)
            settle()
        }

        var status: [String: Any] {
            recorder.payload()["status"] as? [String: Any] ?? [:]
        }

        var sessions: [[String: Any]] {
            recorder.payload()["sessions"] as? [[String: Any]] ?? []
        }

        var session: String {
            status["session"] as? String ?? ""
        }

        func captures() -> Int {
            status["captures"] as? Int ?? -1
        }

        func directory(_ name: String) -> URL {
            root.appendingPathComponent(name, isDirectory: true)
        }

        func files(_ name: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory(name).path)) ?? []).sorted()
        }

        func logBytes(_ name: String) -> Int {
            let path = directory(name).appendingPathComponent("interactions.jsonl").path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber
            else { return 0 }
            return size.intValue
        }

        func manifest(_ name: String) -> [String: Any] {
            let path = directory(name).appendingPathComponent("harvest.json")
            guard let data = FileManager.default.contents(atPath: path.path),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return body
        }

        func index(_ name: String) -> [[String: Any]] {
            let path = directory(name).appendingPathComponent("index.jsonl")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
        }

        func interactions(_ name: String) -> [[String: Any]] {
            let path = directory(name).appendingPathComponent("interactions.jsonl")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
        }

        /// A session a previous daemon left: `stopped` or, when nil, still open.
        func writeSession(name: String, bytes: Int, stopped: String?) throws {
            let directory = directory(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "session": name,
                "directory": directory.path,
                "intervalSeconds": 3,
                "maxBytes": 2 << 30,
                "maxSeconds": 1800,
                "startedAt": "2026-01-01T00:00:00Z",
                "stoppedAt": stopped ?? NSNull(),
                "captures": 1,
                "interactionCaptures": 0,
                "interactions": 0,
                "recordedBytes": bytes,
                "stopReason": stopped == nil ? NSNull() : "stopped",
                "lastError": NSNull(),
                "notes": [],
                "running": stopped == nil,
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: directory.appendingPathComponent("harvest.json"))
            guard bytes > 0 else { return }
            let capture = directory.appendingPathComponent("capture.bin")
            FileManager.default.createFile(atPath: capture.path, contents: nil)
            let handle = try FileHandle(forWritingTo: capture)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
    }

    // MARK: - Configuration

    static func clamping() throws {
        let defaults = GuestHarvestRecorder.Config.clamped(intervalSeconds: nil, maxBytes: nil, maxSeconds: nil)
        check(defaults == GuestHarvestRecorder.Config.defaults, "no arguments are the defaults")

        let low = GuestHarvestRecorder.Config.clamped(intervalSeconds: 0.1, maxBytes: 1, maxSeconds: 1)
        check(low.intervalSeconds == 1, "a short interval is raised to one second")
        check(low.maxBytes == 1 << 20, "a small cap is raised to one MiB")
        check(low.maxSeconds == 60, "a short session is raised to a minute")

        let high = GuestHarvestRecorder.Config.clamped(
            intervalSeconds: 600, maxBytes: 64 << 30, maxSeconds: 86_400,
        )
        check(high.intervalSeconds == 60, "a long interval is lowered to a minute")
        check(high.maxBytes == 8 << 30, "a large cap is lowered to 8 GiB")
        check(high.maxSeconds == 7200, "a long session is lowered to two hours")
    }

    static func emptyStatus() throws {
        let harness = Harness()
        let status = harness.status
        check(status["running"] as? Bool == false, "nothing runs before the first start")
        check(status["session"] is NSNull, "no session is named")
        check(status["recordedBytes"] as? Int == 0, "no bytes are recorded")
        check(status["interactions"] as? Int == 0, "no interactions are logged")
        check(status["stopReason"] is NSNull, "no stop reason")
        check(harness.sessions.isEmpty, "no sessions are listed")
        harness.recorder.noteInput("input.type", ["text": "ignored"])
        harness.settle()
        check(harness.sessions.isEmpty, "an input before a session writes nothing")
    }

    // MARK: - Loop

    static func timerCadence() throws {
        let harness = Harness()
        try harness.start(interval: 3)

        harness.advance(2.9)
        check(harness.captures() == 0, "nothing is captured before the interval")
        check(harness.runner.pending.isEmpty, "no capture is asked for early")

        harness.advance(0.1)
        check(harness.runner.pending.count == 1, "the interval asks for exactly one capture")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "the capture is counted")

        harness.tick(by: 3)
        harness.tick(by: 3)
        check(harness.captures() == 3, "one capture per interval")

        let name = harness.session
        let files = harness.files(name)
        check(files.contains("harvest.json"), "the manifest is written")
        check(files.contains("index.jsonl"), "the index is written")
        check(files.contains("interactions.jsonl"), "the interaction log exists from the start")
        check(files.filter { $0.hasSuffix(".jpg") }.count == 3, "one JPEG per capture")
        check(files.filter { $0.hasSuffix(".tree.json") }.count == 3, "one tree per capture")
        check(files.contains { $0.hasPrefix("000001-") && $0.hasSuffix(".jpg") }, "the sequence pads to six digits")

        let index = harness.index(name)
        check(index.count == 3, "one index line per capture")
        check(index.first?["seq"] as? Int == 1, "the sequence starts at one")
        check(index.first?["trigger"] as? String == "timer", "the trigger is the timer")
        check(index.first?["gesture"] is NSNull, "a timer capture has no gesture")
        check(index.first?["bytes"] as? Int == 2_000, "the line counts both halves")
        check((index.first?["error"] as? String) == nil, "a good capture records no error")
        check((index.first?["at"] as? String)?.hasSuffix("Z") == true, "the index time is UTC")

        let manifest = harness.manifest(name)
        check(manifest["running"] as? Bool == true, "the manifest follows the running session")
        check(manifest["captures"] as? Int == 3, "the manifest counts the captures")
        check(manifest["recordedBytes"] as? Int == 6_000, "the manifest counts the bytes")
        check(manifest["stopReason"] is NSNull, "the session is still open")
        check(harness.status["stopReason"] is NSNull, "status agrees")
    }

    static func startFrame() throws {
        let harness = Harness()
        try harness.start(captureAtStart: true)
        check(harness.runner.pending.count == 1, "the session asks for its opening frame at once")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "the opening frame is capture one")

        let name = harness.session
        let index = harness.index(name)
        check(index.first?["trigger"] as? String == "start", "named start")
        check(index.first?["gesture"] is NSNull, "the opening frame has no gesture")
        check(index.first?["interaction"] is NSNull, "and no interaction")
        check(
            harness.files(name).contains { $0.hasPrefix("000001-") && $0.hasSuffix("-start.jpg") },
            "the file name says start too",
        )

        // The interval runs from the start, not from the opening frame.
        harness.tick(by: 3)
        check(harness.captures() == 2, "the first tick still follows one interval later")
        check(harness.index(name).last?["trigger"] as? String == "timer", "as a timer capture")
    }

    static func selfDescribing() throws {
        let harness = Harness()
        try harness.start(
            interval: 3,
            environment: GuestHarvestRecorder.Environment(
                vm: "vm1",
                model: "iPhone99,11",
                iosVersion: "26.6.0",
                kernel: "25.4.0",
                vphonedHash: "abc123",
                screenWidth: 430,
                screenHeight: 932,
                screenScale: 3,
                timeZone: "Asia/Shanghai",
                label: "open Settings, General, About",
            ),
            captureAtStart: false,
        )

        let name = harness.session
        let manifest = harness.manifest(name)
        check(manifest["formatVersion"] as? Int == 1, "the manifest is versioned")
        check(manifest["vm"] as? String == "vm1", "the guest names the VM")
        check(manifest["iosVersion"] as? String == "26.6.0", "and its iOS")
        check(manifest["vphonedHash"] as? String == "abc123", "and the daemon build")
        check(manifest["timeZone"] as? String == "Asia/Shanghai", "and the guest clock")
        check(
            manifest["label"] as? String == "open Settings, General, About",
            "the caller's label is kept verbatim",
        )
        let screen = manifest["screen"] as? [String: Any] ?? [:]
        check(screen["width"] as? Int == 430, "the screen width is copied")
        check(screen["height"] as? Int == 932, "with its height")
        check((screen["scale"] as? NSNumber)?.doubleValue == 3, "and its scale")
        check(screen["space"] as? String == "points", "marked as points")
        check(
            (manifest["captureProfile"] as? [String: Any])?["interaction"] != nil,
            "the capture profile is recorded",
        )

        let readme = (try? String(
            contentsOf: harness.directory(name).appendingPathComponent("README.md"),
            encoding: .utf8,
        )) ?? ""
        check(readme.contains("vphone-harvest/1"), "the README states the format version")
        check(readme.contains("vm1"), "and the guest")
        check(readme.contains("open Settings, General, About"), "and the label")
        check(readme.contains("interactions.jsonl"), "and how to replay")

        harness.input("input.touch", ["phase": "up", "x": 0.5, "y": 0.5, "normalized": true])
        harness.advance(0.7)
        harness.runner.runNext()
        harness.settle()

        let index = harness.index(name)
        check(index.count == 1, "one frame")
        let frame = index.first ?? [:]
        check(frame["t"] as? Int == 700, "the frame is stamped in ms from the start")
        check((frame["at"] as? String)?.contains(".") == true, "and its time carries milliseconds")
        check(frame["jpeg"] as? String == "000001-\(Self.clockText(harness.clock.current))-interaction.jpg",
              "the index names the JPEG")
        check(frame["tree"] as? String != nil, "and the tree")
        check(frame["jpeg_bytes"] as? Int == 1_000, "the halves are sized apart")
        check(frame["tree_bytes"] as? Int == 1_000, "both of them")
        check(frame["bytes"] as? Int == 2_000, "and together")
        check(frame["foreground"] is NSNull, "a capture without a foreground says null")

        let log = harness.interactions(name)
        check(log.first?["t"] as? Int == 0, "the input is stamped from the start")
        check((log.first?["at"] as? String)?.contains(".") == true, "with milliseconds")
    }

    /// The same `HHMMSS` the recorder puts in a capture's file name.
    static func clockText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func startIsIdempotent() throws {
        let harness = Harness()
        _ = try harness.start(interval: 3)
        let first = harness.session
        let second = try harness.start(interval: 60, maxSeconds: 60)
        check(second["status"] is [String: Any], "a second start still answers with a status")
        check(harness.session == first, "a second start keeps the running session")
        check(harness.status["intervalSeconds"] as? Double == 3, "a second start keeps its configuration")
        check(try FileManager.default.contentsOfDirectory(atPath: harness.root.path).count == 1, "only one session exists")
    }

    static func interactionDebounce() throws {
        let harness = Harness()
        try harness.start(interval: 60)

        harness.input("input.drag", ["points": [[10, 10], [20, 20]]])
        harness.advance(0.1)
        harness.input("input.drag", ["points": [[10, 10], [20, 20]]])
        harness.advance(0.5)
        check(harness.runner.pending.isEmpty, "the capture waits out the 600 ms of silence")

        harness.advance(0.15)
        check(harness.runner.pending.count == 1, "one drag is one capture")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "the interaction is captured once")
        check(harness.status["interactionCaptures"] as? Int == 1, "and counted as an interaction")

        let index = harness.index(harness.session)
        check(index.first?["trigger"] as? String == "interaction", "an interaction capture")
        check(index.first?["gesture"] as? String == "drag", "the gesture is named")
        check(index.first?["interaction"] as? Int == 2, "the last input of the burst is linked")

        harness.input("input.tap", ["x": 10, "y": 20])
        harness.advance(0.5)
        check(harness.runner.pending.isEmpty, "a second capture keeps 800 ms away")
        harness.advance(0.3)
        check(harness.runner.pending.count == 1, "and lands after the gap")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 2, "the tap is captured")
    }

    static func interactionLog() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        let inputs: [(String, [String: Any])] = [
            ("input.tap", ["x": 12.5, "y": 34.5]),
            ("input.double_tap", ["x": 1, "y": 2]),
            ("input.long_press", ["x": 3, "y": 4, "seconds": 1.2]),
            ("input.swipe", ["x1": 1, "y1": 2, "x2": 3, "y2": 4]),
            ("input.drag", ["points": [[1, 2], [3, 4]], "seconds": 0.5]),
            ("input.touch_sequence", ["events": [["phase": "down", "x": 0.5, "y": 0.5]]]),
            ("input.touch", ["phase": "down", "x": 0.5, "y": 0.5, "normalized": true]),
            ("input.touch", ["phase": "move", "x": 0.6, "y": 0.6, "normalized": true]),
            ("input.touch", ["phase": "up", "x": 0.6, "y": 0.6, "normalized": true]),
            ("input.touch2", ["phase": "up", "x1": 0.4, "y1": 0.4, "x2": 0.6, "y2": 0.6]),
            ("input.type", ["text": "hello", "delay_ms": 10]),
            ("input.paste", ["text": "pasted"]),
            ("input.key", ["name": "return"]),
            ("input.hid", ["page": 7, "usage": 4]),
            ("input.scroll", ["phase": "ended", "dy": 3]),
            ("input.button", ["name": "home"]),
            ("input.pointer", ["x": 5, "y": 6, "buttons": 0]),
        ]
        for (method, params) in inputs {
            harness.input(method, params)
        }

        let log = harness.interactions(harness.session)
        check(log.count == inputs.count, "every input is one line")
        check(log.map { $0["seq"] as? Int ?? 0 } == Array(1 ... inputs.count), "the log keeps the order")
        check(
            zip(log, inputs).allSatisfy { $0["method"] as? String == $1.0 },
            "the method names are verbatim",
        )
        check(
            zip(log, inputs).allSatisfy { sameJSON($1.1, $0["params"]) },
            "the params are verbatim",
        )
        // The first gesture reserves a capture; the rest of the burst names it.
        check(log.contains { $0["capture"] as? Int == 1 }, "a gesture names the capture it caused")
        check(harness.status["interactions"] as? Int == inputs.count, "the status counts every input")
    }

    static func interactionCaptureLink() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        harness.input("input.touch", ["phase": "down", "x": 0.5, "y": 0.5, "normalized": true])
        harness.input("input.touch", ["phase": "up", "x": 0.5, "y": 0.5, "normalized": true])
        harness.advance(0.6)
        check(harness.runner.pending.count == 1, "the touch up asks for a capture")
        harness.runner.runNext()
        harness.settle()

        let log = harness.interactions(harness.session)
        let index = harness.index(harness.session)
        check(log.count == 2, "both touch phases are logged")
        check(index.first?["seq"] as? Int == 1, "the capture is the first")
        check(index.first?["interaction"] as? Int == 2, "the index names the up")
        check(index.first?["gesture"] as? String == "touch", "the gesture is the touch")
        if log.count == 2 {
            check(log[0]["capture"] is NSNull, "the down caused no capture")
            check(log[1]["capture"] as? Int == 1, "the up names capture 1")
        }
    }

    static func inputWithoutCapture() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        harness.input("input.type", ["text": "hello"])
        harness.input("input.key", ["name": "return"])
        check(harness.runner.pending.isEmpty, "typing and keys trigger no capture")
        check(harness.captures() == 0, "nothing is captured")

        let log = harness.interactions(harness.session)
        check(log.count == 2, "both are still logged")
        check(log.allSatisfy { $0["capture"] is NSNull }, "neither names a capture")
        check(harness.status["interactions"] as? Int == 2, "the status counts them")
    }

    static func inputSilence() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        harness.input("input.tap", ["x": 1, "y": 2])
        harness.advance(0.59)
        check(harness.runner.pending.isEmpty, "599 ms of silence is not enough")
        harness.advance(0.01)
        check(harness.runner.pending.count == 1, "600 ms is enough")
        harness.runner.runNext()
        harness.settle()

        // Typing restarts the silence window. The deadline still forces one
        // capture two seconds after the gesture, so a continuous typist is
        // not left without one.
        harness.input("input.tap", ["x": 1, "y": 2])
        for _ in 0 ..< 5 {
            harness.advance(0.3)
            harness.input("input.type", ["text": "x"])
        }
        harness.advance(0.3)
        check(harness.runner.pending.isEmpty, "typing keeps the capture back")
        harness.advance(0.3)
        check(harness.runner.pending.count == 1, "two seconds after the gesture forces it")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 2, "the forced capture lands")
    }

    static func oneCapturePerBurst() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        harness.input("input.tap", ["x": 1, "y": 2])
        harness.advance(0.1)
        harness.input("input.type", ["text": "h"])
        harness.advance(0.1)
        harness.input("input.type", ["text": "i"])
        harness.advance(0.6)
        check(harness.runner.pending.count == 1, "the whole burst is one capture")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "one capture")
        harness.advance(5)
        check(harness.runner.pending.isEmpty, "no second capture follows")

        let log = harness.interactions(harness.session)
        check(log.count == 3, "all three inputs are logged")
        check(harness.index(harness.session).first?["interaction"] as? Int == 1, "the index links the tap")
        if log.count == 3 {
            check(log[0]["capture"] as? Int == 1, "the tap names the capture")
            check(log[1]["capture"] is NSNull, "the text does not")
        }
    }

    static func captureProfiles() throws {
        let harness = Harness()
        // A four-second interval keeps the next timer far from the interaction
        // capture this test wants, so the two profiles are observed separately.
        try harness.start(interval: 4, maxSeconds: 600)
        harness.tick(by: 4)
        check(
            harness.source.profiles.last == GuestHarvestRecorder.CaptureProfile.timer,
            "a timer capture uses the full profile",
        )

        harness.input("input.tap", ["x": 1, "y": 2])
        harness.advance(0.8)
        check(harness.runner.pending.count == 1, "the interaction capture is due")
        harness.runner.runNext()
        harness.settle()
        let profile = harness.source.profiles.last
        check(profile == GuestHarvestRecorder.CaptureProfile.interaction, "an interaction uses its own profile")
        check(profile?.nativeResolution == true, "native pixels: downscaling costs more, and looks worse")
        check(profile?.maxElements == 250, "with a smaller element cap")
        check(profile?.maxDepth == 16, "a shallower tree")
        check(profile?.timeoutMS == 1200, "and a shorter walk")

        let index = harness.index(harness.session)
        check(index.count == 2, "two captures are indexed")
        if index.count == 2 {
            check(index[0]["width"] as? Int == 1290, "the timer capture is native width")
            check(index[0]["height"] as? Int == 2796, "and native height")
            check(index[0]["coordinate_scale"] as? Double == 3, "with a 3x scale")
            check(index[1]["width"] as? Int == 1290, "the interaction capture is native width")
            check(index[1]["height"] as? Int == 2796, "and native height")
            check(index[1]["coordinate_scale"] as? Double == 3, "with the same 3x scale")
        }
    }

    static func timerCoalescesInteraction() throws {
        let harness = Harness()
        try harness.start(interval: 1, maxSeconds: 600)
        harness.advance(0.6)
        harness.input("input.tap", ["x": 1, "y": 2])
        harness.advance(0.4)
        check(harness.runner.pending.count == 1, "the timer and the burst make one capture")

        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "only one capture is taken")
        check(
            harness.source.profiles.last == GuestHarvestRecorder.CaptureProfile.timer,
            "the coalesced capture is the timer's full one",
        )
        let index = harness.index(harness.session)
        check(index.first?["trigger"] as? String == "timer", "the timer took it")
        check(index.first?["interaction"] as? Int == 1, "and names the interaction")
        check(index.first?["gesture"] as? String == "tap", "with the gesture the burst ended on")
        check(
            harness.interactions(harness.session).first?["capture"] as? Int == 1,
            "the interaction names the timer capture",
        )
        harness.advance(0.6)
        check(harness.runner.pending.isEmpty, "the burst left no second capture behind")

        // The other order: the interaction is due 150 ms before the timer, so
        // it waits for the timer instead of taking a capture of its own.
        let early = Harness()
        try early.start(interval: 1, maxSeconds: 600)
        early.advance(0.25)
        early.input("input.tap", ["x": 1, "y": 2])
        early.advance(0.6)
        check(early.runner.pending.isEmpty, "a burst due just before the timer waits for it")
        early.advance(0.15)
        check(early.runner.pending.count == 1, "the timer takes that one too")
        early.runner.runNext()
        early.settle()
        check(early.captures() == 1, "one capture, not two")
        check(
            early.index(early.session).first?["interaction"] as? Int == 1,
            "and it names the interaction",
        )
    }

    static func interactionAccounting() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        harness.input("input.type", ["text": "hello"])
        let logOnly = harness.logBytes(harness.session)
        check(logOnly > 0, "the log has bytes")
        check(harness.status["interactions"] as? Int == 1, "the status counts the input")
        check(harness.status["recordedBytes"] as? Int == logOnly, "recordedBytes includes the log")
        check(harness.sessions.first?["interactions"] as? Int == 1, "the session summary counts it")

        harness.input("input.tap", ["x": 1, "y": 2])
        harness.advance(0.6)
        harness.runner.runNext()
        harness.settle()
        let logAndCapture = harness.logBytes(harness.session)
        check(harness.status["interactions"] as? Int == 2, "the tap is counted too")
        check(
            harness.status["recordedBytes"] as? Int == logAndCapture + 2_000,
            "the log and the capture are both counted",
        )
        check(harness.manifest(harness.session)["interactions"] as? Int == 2, "the manifest carries the count")
    }

    static func skipWhileCapturing() throws {
        let harness = Harness()
        try harness.start(interval: 1, maxSeconds: 600)

        harness.advance(1)
        check(harness.runner.pending.count == 1, "the first interval asks for a capture")
        harness.advance(1)
        harness.advance(1)
        check(harness.runner.pending.count == 1, "a tick while one is in flight is skipped")
        check(harness.source.calls == 0, "the capture has not even started")

        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "the skipped ticks made no second capture")
        check(harness.source.calls == 1, "the capture ran once")

        harness.tick(by: 1)
        check(harness.captures() == 2, "the loop resumes once the capture finished")
    }

    static func sizeCap() throws {
        let harness = Harness()
        harness.source.jpegSize = 200_000
        harness.source.treeSize = 200_000
        try harness.start(interval: 1, maxBytes: 1 << 20, maxSeconds: 600)

        harness.tick(by: 1)
        harness.tick(by: 1)
        check(harness.captures() == 2, "two captures fit")
        check(harness.status["recordedBytes"] as? Int == 800_000, "their bytes are counted")

        harness.advance(1)
        check(harness.runner.pending.count == 1, "the third capture is asked for")
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 2, "the capture over the cap is not counted")
        check(harness.status["recordedBytes"] as? Int == 800_000, "and not written")
        check(harness.status["running"] as? Bool == false, "the session stops")
        check(harness.status["stopReason"] as? String == "size", "because of its size")
        check(harness.index(harness.session).count == 2, "the index has no line for it")
        check(harness.files(harness.session).filter { $0.hasSuffix(".jpg") }.count == 2, "no JPEG either")
        check(harness.manifest(harness.session)["stopReason"] as? String == "size", "the manifest says why")

        harness.advance(10)
        check(harness.runner.pending.isEmpty, "a stopped session asks for nothing")
        check(harness.captures() == 2, "and captures nothing")
    }

    static func timeCap() throws {
        let harness = Harness()
        try harness.start(interval: 10, maxSeconds: 60)

        for _ in 0 ..< 5 {
            harness.tick(by: 10)
        }
        check(harness.captures() == 5, "five captures in the first fifty seconds")

        harness.advance(10)
        check(harness.runner.pending.isEmpty, "the tick at the cap asks for nothing")
        check(harness.captures() == 5, "and writes nothing")
        check(harness.status["running"] as? Bool == false, "the session stops")
        check(harness.status["stopReason"] as? String == "time", "because of the hour")
        check(harness.status["elapsedSeconds"] as? Int == 60, "the elapsed time is the cap")
        check((harness.status["stoppedAt"] as? String)?.hasSuffix("Z") == true, "a stop time is recorded")
        check(harness.manifest(harness.session)["stopReason"] as? String == "time", "the manifest says why")
    }

    static func captureFailure() throws {
        let harness = Harness()
        harness.source.failure = "ui.tree: the foreground app is not verified"
        try harness.start(interval: 1)

        harness.advance(1)
        harness.runner.runNext()
        harness.settle()
        check(harness.captures() == 1, "a failed capture is still a capture")
        check(harness.status["running"] as? Bool == true, "a failed capture keeps the session running")
        check((harness.status["lastError"] as? String)?.contains("not verified") == true, "the error is reported")

        let index = harness.index(harness.session)
        check((index.first?["error"] as? String)?.contains("not verified") == true, "the index names the error")
        check(index.first?["bytes"] as? Int == 0, "a failed capture writes no bytes")
        check(harness.files(harness.session).filter { $0.hasSuffix(".jpg") }.isEmpty, "and no files")

        harness.source.failure = nil
        harness.tick(by: 1)
        check(harness.captures() == 2, "the next capture is taken")
        check(harness.status["lastError"] is NSNull, "a good capture clears the error")
    }

    // MARK: - Notes

    static func notes() throws {
        let harness = Harness()
        try harness.start(interval: 60)
        let name = harness.session

        harness.advance(60)
        check(harness.runner.pending.count == 1, "a capture is in flight")
        let payload = try harness.recorder.note(session: name, text: "the screen hung")
        let listed = (payload["sessions"] as? [[String: Any]])?.first
        check((listed?["notes"] as? [[String: Any]])?.first?["text"] as? String == "the screen hung", "the reply carries the note")

        harness.runner.runNext()
        harness.settle()
        let manifest = harness.manifest(name)
        check(manifest["captures"] as? Int == 1, "the capture still lands")
        let notes = manifest["notes"] as? [[String: Any]] ?? []
        check(notes.count == 1, "the capture's manifest write keeps the note")
        check(notes.first?["text"] as? String == "the screen hung", "the note text is the one sent")
        check((notes.first?["at"] as? String)?.hasSuffix("Z") == true, "the note has a UTC time")

        _ = harness.recorder.stop()
        check(FileManager.default.fileExists(atPath: harness.directory(name).path), "stopping keeps the directory")
        _ = try harness.recorder.note(session: name, text: "after the stop")
        check((harness.manifest(name)["notes"] as? [[String: Any]])?.count == 2, "an old session takes notes")

        check(refuses { _ = try harness.recorder.note(session: "20260101-000000", text: "x") }, "an unknown session is refused")
        check(refuses { _ = try harness.recorder.note(session: "../outside", text: "x") }, "a path is not a session")
        check(refuses { _ = try harness.recorder.note(session: "20260101-00000", text: "x") }, "a short name is refused")
    }

    // MARK: - Retention

    static func retentionPlan() {
        let six = (1 ... 6).map { (name: String(format: "20260101-00000%d", 7 - $0), bytes: 100) }
        let plan = GuestHarvestRetention.plan(sessions: six, running: nil)
        check(plan == ["20260101-000001", "20260101-000002"], "six sessions leave room for the new one")

        let heavy = [
            (name: "20260103-000000", bytes: 900 << 20),
            (name: "20260102-000000", bytes: 900 << 20),
            (name: "20260101-000000", bytes: 900 << 20),
        ]
        check(
            GuestHarvestRetention.plan(sessions: heavy, running: nil) == ["20260101-000000"],
            "one old session goes and the other two fit in two gigabytes",
        )
        let overfull = [
            (name: "20260102-000000", bytes: 100),
            (name: "20260101-000000", bytes: 3 << 30),
        ]
        check(
            GuestHarvestRetention.plan(sessions: overfull, running: "20260101-000000") == ["20260102-000000"],
            "the running session is never deleted, even when it is over the cap itself",
        )
        let five = Array(six.prefix(5))
        check(
            GuestHarvestRetention.plan(sessions: five, running: nil) == ["20260101-000002"],
            "five sessions leave room for the new one",
        )
    }

    static func retentionOnStart() throws {
        let harness = Harness()
        for index in 1 ... 6 {
            try harness.writeSession(name: String(format: "2026010%d-000000", index), bytes: 10, stopped: "2026-01-01T00:10:00Z")
        }
        _ = try harness.start(interval: 60)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: harness.root.path)
        check(remaining.count == 5, "four old sessions and the new one")
        check(!remaining.contains("20260101-000000"), "the oldest goes first")
        check(!remaining.contains("20260102-000000"), "and then the next oldest")
        check(remaining.contains("20260106-000000"), "the newest old session stays")
        check(remaining.contains(harness.session), "the new session is there")

        let bytes = Harness()
        for index in 1 ... 3 {
            try bytes.writeSession(name: String(format: "2026010%d-000000", index), bytes: 900 << 20, stopped: "2026-01-01T00:10:00Z")
        }
        _ = try bytes.start(interval: 60)
        let kept = try FileManager.default.contentsOfDirectory(atPath: bytes.root.path)
        check(kept.count == 3, "two old sessions and the new one")
        check(!kept.contains("20260101-000000"), "the oldest 900 MiB session goes")
        check(kept.contains("20260103-000000"), "the newest one stays")
    }

    static func interruptedRecovery() throws {
        let harness = Harness()
        try harness.writeSession(name: "20260101-000001", bytes: 4, stopped: "2026-01-01T00:10:00Z")
        try harness.writeSession(name: "20260102-000002", bytes: 4, stopped: nil)

        harness.recorder.recoverOnStartup()
        harness.settle()

        let recovered = harness.manifest("20260102-000002")
        check(recovered["stopReason"] as? String == "interrupted", "a session without a stop is interrupted")
        check((recovered["stoppedAt"] as? String)?.hasSuffix("Z") == true, "it gets a stop time")
        check(recovered["running"] as? Bool == false, "and is not running")
        check(recovered["captures"] as? Int == 1, "its counts stay")
        check(harness.files("20260102-000002").contains("capture.bin"), "its files stay")

        let stopped = harness.manifest("20260101-000001")
        check(stopped["stopReason"] as? String == "stopped", "a closed session is left alone")
        check(stopped["stoppedAt"] as? String == "2026-01-01T00:10:00Z", "with its own stop time")
        check(harness.sessions.count == 2, "both sessions are listed")
        check(harness.sessions.first?["session"] as? String == "20260102-000002", "newest first")
        check(harness.sessions.first?["stopReason"] as? String == "interrupted", "the interrupted one leads")
    }

    // MARK: - Archive

    static func archives() throws {
        let harness = Harness()
        // A JPEG well past one tar block and one read chunk.
        harness.source.jpegSize = 300_000
        try harness.start(interval: 1)
        harness.input("input.type", ["text": "archive me"])
        harness.tick(by: 1)
        _ = harness.recorder.stop()
        let name = harness.session
        let archivePath = harness.root.appendingPathComponent(name + ".tar.gz")
        check(!FileManager.default.fileExists(atPath: archivePath.path), "no archive is written unless asked")

        let stale = harness.root.appendingPathComponent(name + ".tar.gz.part")
        try Data("stale".utf8).write(to: stale)
        let result = try harness.recorder.archive(session: name)
        check(result["archive"] as? String == archivePath.path, "the archive is beside the sessions")
        check(!FileManager.default.fileExists(atPath: stale.path), "a part from an earlier attempt is gone")
        let bytes = result["bytes"] as? Int ?? 0
        check(bytes > 0, "the archive has bytes")
        let digest = result["sha256"] as? String ?? ""
        check(digest.count == 64, "a SHA-256 is reported")
        check(digest == (try HarvestArchive.sha256(of: archivePath)), "the SHA-256 is of the file")

        let extraction = harness.root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archivePath.path, "-C", extraction.path]
        try tar.run()
        tar.waitUntilExit()
        check(tar.terminationStatus == 0, "the system tar reads the archive")

        let unpacked = extraction.appendingPathComponent(name)
        let unpackedFiles = ((try? FileManager.default.contentsOfDirectory(atPath: unpacked.path)) ?? []).sorted()
        check(unpackedFiles.contains("harvest.json"), "the archive holds the manifest")
        check(unpackedFiles.contains("index.jsonl"), "the archive holds the index")
        check(unpackedFiles.contains("interactions.jsonl"), "the archive holds the interaction log")
        let unpackedLog = try String(
            contentsOf: unpacked.appendingPathComponent("interactions.jsonl"), encoding: .utf8,
        )
        check(unpackedLog.contains(#""method":"input.type""#), "with the input in it")
        let jpegs = unpackedFiles.filter { $0.hasSuffix(".jpg") }
        check(jpegs.count == 1, "the archive holds the capture")
        check(unpackedFiles.contains(jpegs[0].replacingOccurrences(of: ".jpg", with: ".tree.json")), "with its tree")
        let guestJPEG = try Data(contentsOf: harness.directory(name).appendingPathComponent(jpegs[0]))
        let unpackedJPEG = try Data(contentsOf: unpacked.appendingPathComponent(jpegs[0]))
        check(guestJPEG == unpackedJPEG, "the unpacked JPEG is the guest's")

        check((try harness.recorder.deleteArchive(session: name))["deleted"] as? Bool == true, "the archive is removed")
        check(!FileManager.default.fileExists(atPath: archivePath.path), "and gone")
        check((try harness.recorder.deleteArchive(session: name))["deleted"] as? Bool == false, "a missing archive is an answer")

        let again = try harness.recorder.archive(session: name)
        check(again["bytes"] as? Int == bytes, "the same session archives to the same size")
        _ = try harness.recorder.archive(session: name)
        check(!FileManager.default.fileExists(atPath: archivePath.path + ".part"), "archiving twice leaves no part")

        let removed = try harness.recorder.delete(session: name)
        check((removed["status"] as? [String: Any])?["session"] is NSNull, "deleting the last session clears status")
        check((removed["sessions"] as? [[String: Any]])?.isEmpty == true, "and lists nothing")
        check(!FileManager.default.fileExists(atPath: harness.directory(name).path), "the directory is gone")
        check(refuses { _ = try harness.recorder.archive(session: name) }, "a deleted session cannot be archived")
    }
}
