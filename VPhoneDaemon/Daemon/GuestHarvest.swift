import Foundation

/// The harvest recorder: one session of screenshots, UI trees and the full
/// sequence of inputs that led to them, kept only in the guest.
///
/// Two queues, for one reason. The loop that arms captures, logs inputs and
/// runs the input-silence debounce runs on `queue`; the capture itself — a
/// screenshot and a UI tree, 150–260 ms of the guest's CPU — is offloaded by
/// `runCapture`. The loop therefore keeps ticking while a capture is in flight,
/// sees it, and skips that tick instead of queueing a second capture behind the
/// first. An input only hands its params to `queue`, so the input that caused a
/// capture never waits for it.
///
/// Nothing here touches UIKit or IcliKit: the capture, the clock and the root
/// directory are injected, so `Tests/run-harvest-tests.sh` drives the whole
/// recorder on the Mac.
final class GuestHarvestRecorder: @unchecked Sendable {
    // MARK: - Shapes

    struct Config: Equatable, Sendable {
        var intervalSeconds: Double
        var maxBytes: Int
        var maxSeconds: Double

        static let defaults = Config(intervalSeconds: 3, maxBytes: 2 << 30, maxSeconds: 1800)
        static let intervalRange = 1.0 ... 60.0
        static let byteRange = (1 << 20) ... (8 << 30)
        static let secondsRange = 60.0 ... 7200.0

        /// What `harvest.start` accepts, brought inside the ranges a session
        /// can actually record at.
        static func clamped(intervalSeconds: Double?, maxBytes: Int?, maxSeconds: Double?) -> Config {
            Config(
                intervalSeconds: min(max(intervalSeconds ?? defaults.intervalSeconds, intervalRange.lowerBound), intervalRange.upperBound),
                maxBytes: min(max(maxBytes ?? defaults.maxBytes, byteRange.lowerBound), byteRange.upperBound),
                maxSeconds: min(max(maxSeconds ?? defaults.maxSeconds, secondsRange.lowerBound), secondsRange.upperBound),
            )
        }

        /// The ranges applied to a value a caller passed.
        func clamped() -> Config {
            Self.clamped(intervalSeconds: intervalSeconds, maxBytes: maxBytes, maxSeconds: maxSeconds)
        }
    }

    /// What the recorder knows about the guest at the moment the session
    /// starts: identity, screen and clock only. Every field is a fact the guest
    /// can answer or the host passed in `harvest.start`; an unknown one is left
    /// out rather than guessed. The session's purpose, when the caller gives
    /// one, is ``label``.
    struct Environment: Equatable, Sendable {
        /// The guest's own device name, which the host sets to the VM name.
        var vm: String?
        var model: String?
        var iosVersion: String?
        var kernel: String?
        /// Hash of the serving vphoned, so a session names the daemon build
        /// that recorded it without needing the host's bundle store.
        var vphonedHash: String?
        /// Screen size in points, as `device.info` reports it. Captures are in
        /// pixels: multiply by ``screenScale`` to compare them.
        var screenWidth: Int?
        var screenHeight: Int?
        var screenScale: Double?
        var timeZone: String?
        /// What the caller asked to record, verbatim. vphoned does not derive
        /// one: an unlabelled session says so.
        var label: String?

        static let unknown = Environment()
    }

    /// How one capture is taken. An interaction capture is deliberately cheap:
    /// it lands just after the input, so it must not walk the whole
    /// accessibility tree while the user is still interacting: the tree is on
    /// the foreground app's main thread, which is the half a user feels. A
    /// timer capture is the reference image, so it keeps the full limits.
    ///
    /// Both profiles ask for the native screen on purpose. Capturing at screen
    /// points is not the cheap path it looks like — icli captures first and
    /// then downscales, and measurements on a guest put interaction captures at
    /// 175–260 ms with points against 50–97 ms native. Native is also the better
    /// image, so nothing is traded away here.
    struct CaptureProfile: Equatable, Sendable {
        var nativeResolution: Bool
        var maxElements: Int
        var maxDepth: Int
        var timeoutMS: Int

        static let timer = CaptureProfile(
            nativeResolution: true, maxElements: 800, maxDepth: 32, timeoutMS: 3000,
        )
        static let interaction = CaptureProfile(
            nativeResolution: true, maxElements: 250, maxDepth: 16, timeoutMS: 1200,
        )
    }

    /// What one capture produced. Either half may be missing: a UI tree that
    /// cannot be read must not throw away a good screenshot. The resolution is
    /// what the capture actually had, so the index says which space the logged
    /// input coordinates map to.
    struct Capture: Sendable {
        var jpeg: Data? = nil
        var tree: Data? = nil
        var error: String? = nil
        var width: Int? = nil
        var height: Int? = nil
        var coordinateScale: Double? = nil
        /// The verified foreground app when the tree could resolve one, or the
        /// app the guest named when it could not. Never inferred from pixels.
        var foreground: Foreground? = nil
    }

    /// The foreground app as the guest saw it at capture time.
    struct Foreground: Equatable, Sendable {
        var bundleID: String?
        var pid: Int?
        var verified: Bool?
    }

    /// Where the recorder waits out its interval, its input-silence debounce
    /// and the gap between two interaction captures. Tests keep the pending
    /// delays on a clock of their own and move it by hand.
    protocol Clock: AnyObject {
        var now: Date { get }
        func after(_ delay: TimeInterval, _ body: @escaping @Sendable () -> Void)
    }

    /// The guest's clock: wall time, and delays on the loop's own queue.
    final class QueueClock: Clock, @unchecked Sendable {
        private let queue: DispatchQueue

        init(queue: DispatchQueue) {
            self.queue = queue
        }

        var now: Date { Date() }

        func after(_ delay: TimeInterval, _ body: @escaping @Sendable () -> Void) {
            queue.asyncAfter(deadline: .now() + max(0, delay), execute: body)
        }
    }

    /// One recording, and everything `harvest.status` and `harvest.sessions`
    /// report about it.
    private struct Session {
        let name: String
        let directory: URL
        let config: Config
        let environment: Environment
        let startedAt: Date
        var stoppedAt: Date?
        var captures = 0
        var interactionCaptures = 0
        var interactions = 0
        var recordedBytes = 0
        var stopReason: String?
        var lastError: String?
        var notes: [[String: Any]] = []
        var running = true
        /// The `seq` of the last event written; the next one is this + 1.
        var events = 0
    }

    // MARK: - Tuning

    /// An interaction capture waits for this much silence after the last input.
    /// It is longer than the 150–260 ms a capture costs, so the capture does not
    /// compete with the input that caused it.
    static let inputSilence: TimeInterval = 0.6
    /// A continuous typist restarts the silence window forever; this forces one
    /// capture two seconds after the gesture that started the burst.
    static let interactionDeadline: TimeInterval = 2.0
    /// Interaction captures stay this far apart whatever the guest does.
    static let interactionGap: TimeInterval = 0.8
    /// A timer capture due inside this window is taken first and the interaction
    /// capture coalesces into it, instead of two back-to-back captures.
    static let timerCoalesceWindow: TimeInterval = 0.2
    /// The one data file: one JSON object per event, one event per line.
    static let logName = "session.jsonl"
    /// The session's header, its notes and the format description, in markdown.
    static let readmeName = "README.md"
    static let archiveSuffix = ".tar.gz"

    /// The on-disk format this recorder writes: 2 is the single log, the header
    /// and notes in README.md, and no manifest. A folder with a harvest.json is
    /// version 1.
    static let formatVersion = 2

    /// Session names are the guest's local time, as the session happened.
    private static func sessionName(for date: Date) -> String {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date,
        )
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
        )
    }

    /// The capture's own clock, for a name that sorts with the index.
    private static func captureClock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02d%02d%02d",
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
        )
    }

    /// Every timestamp in a reply is RFC3339 UTC, whole seconds; the session log
    /// carries milliseconds so a burst's rhythm survives the round trip.
    private static func timestamp(_ date: Date) -> String {
        date.formatted(Self.rfc3339)
    }

    private static func preciseTimestamp(_ date: Date) -> String {
        date.formatted(Self.rfc3339Millis)
    }

    /// `TimeZone.gmt` is iOS 16, and this daemon still builds for 15: the UTC
    /// zone by offset keeps both targets working.
    private static let rfc3339 = Date.ISO8601FormatStyle(
        timeZone: TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!,
    )
    /// The same instant with milliseconds, for the two event logs: the order of
    /// inputs inside one second is what a replay needs, and `seq` alone does not
    /// say how long a drag took.
    private static let rfc3339Millis = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!,
    )

    /// Milliseconds from the session's start, monotonic within a session.
    private static func milliseconds(_ date: Date, since start: Date) -> Int {
        max(0, Int((date.timeIntervalSince(start) * 1000).rounded()))
    }

    // MARK: - State

    /// Where sessions live. `harvest.archive` writes beside them.
    let root: URL

    private let capture: @Sendable (CaptureProfile) throws -> Capture
    private let clock: any Clock
    private let runCapture: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// Owns every property below, and every file this type writes.
    private let queue: DispatchQueue
    /// Read by the input path without touching `queue`, so a session that is
    /// not recording costs one lock and one bool per input.
    private let inputGate = NSLock()
    private var acceptingInput = false

    private var session: Session?
    private var capturing = false
    private var tickArmed = false
    /// When the armed timer tick will fire, so a due interaction burst can tell
    /// whether the timer is about to take the capture instead.
    private var tickDue: Date?
    /// The input sequence that started the burst waiting for a capture, the
    /// capture number reserved for it, the gesture it is named after, the
    /// interaction sequence of that gesture, and when its silence window ends.
    /// The capture number is reserved as the input arrives so the input's line
    /// can name the capture it caused before it runs; the recorder is serial, so
    /// no other capture can take that number first.
    private var burstStartedAt: Date?
    private var burstCaptureSeq: Int?
    private var burstInteractionSeq: Int?
    private var burstGesture: String?
    private var burstDue: Date?
    private var burstScheduled = false
    /// The interaction sequence of the capture in flight, when a burst landed
    /// while it ran and coalesced into it.
    private var inFlightInteraction: Int?
    /// When the last accepted capture landed, for the interaction gap.
    private var lastCaptureAt: Date?

    /// Params are JSON values straight off the wire. The wrapper says the
    /// recorder may carry them to its own queue without walking every nested
    /// array; it is the same reason `APIRequest` is unchecked.
    private struct InputRecord: @unchecked Sendable {
        let method: String
        let params: [String: Any]
    }

    init(
        root: URL,
        capture: @escaping @Sendable (CaptureProfile) throws -> Capture,
        clock: (any Clock)? = nil,
        runCapture: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
    ) {
        self.root = root
        self.capture = capture
        let queue = DispatchQueue(label: "vphoned.harvest", qos: .utility)
        let captureQueue = DispatchQueue(label: "vphoned.harvest.capture", qos: .utility)
        self.queue = queue
        self.clock = clock ?? QueueClock(queue: queue)
        self.runCapture = runCapture ?? { body in captureQueue.async(execute: body) }
    }

    // MARK: - RPC surface

    /// Starts a session, or reports the one already running: two harvests at
    /// once would write two indexes into the same file.
    ///
    /// `environment` is copied into the manifest verbatim; `captureAtStart`
    /// takes the reference frame a replay starts from (the tests turn it off to
    /// keep their counts about the timer alone).
    func start(
        _ config: Config,
        environment: Environment = .unknown,
        captureAtStart: Bool = true,
    ) throws -> [String: Any] {
        try queue.sync {
            if session?.running == true { return payloadLocked() }
            prune()
            try begin(config.clamped(), environment: environment, captureAtStart: captureAtStart)
            return payloadLocked()
        }
    }

    func stop() -> [String: Any] {
        queue.sync {
            finish(reason: "stopped")
            return payloadLocked()
        }
    }

    func payload() -> [String: Any] {
        queue.sync { payloadLocked() }
    }

    /// Appends a note to a session's README, this one or an old one. Notes are
    /// session facts, not interaction events, so they stay out of the log: the
    /// host asks for every session's notes on each status poll.
    func note(session name: String, text: String) throws -> [String: Any] {
        try queue.sync {
            try requireSessionName(name)
            let directory = directory(for: name)
            guard var header = readHeader(name: name) else {
                throw GuestHarvestError.missingSession(name)
            }
            var notes = header["notes"] as? [[String: Any]] ?? []
            notes.append(["at": Self.timestamp(clock.now), "text": text])
            header["notes"] = notes
            try writeReadme(header: header, to: directory)
            // The running session's in-memory copy feeds the next write of the
            // README, which happens on stop; without this a note would be lost.
            if var current = session, current.name == name {
                current.notes = notes
                session = current
            }
            return payloadLocked()
        }
    }

    /// Removes one session directory. A running session is stopped first, so
    /// its manifest records why it ended before the directory goes.
    func delete(session name: String) throws -> [String: Any] {
        try queue.sync {
            try requireSessionName(name)
            guard FileManager.default.fileExists(atPath: directory(for: name).path) else {
                throw GuestHarvestError.missingSession(name)
            }
            if session?.name == name {
                finish(reason: "stopped")
            }
            try FileManager.default.removeItem(at: directory(for: name))
            if session?.name == name {
                session = nil
            }
            return payloadLocked()
        }
    }

    /// Writes `<session>.tar.gz` beside the session directories, through the
    /// guest's tar when it has one and the built-in writer otherwise.
    func archive(
        session name: String,
        using external: (@Sendable (URL, URL) throws -> Bool)? = nil,
    ) throws -> [String: Any] {
        try queue.sync {
            try requireSessionName(name)
            let directory = directory(for: name)
            let manager = FileManager.default
            guard manager.fileExists(atPath: directory.path) else {
                throw GuestHarvestError.missingSession(name)
            }
            let part = root.appendingPathComponent(name + Self.archiveSuffix + ".part")
            let archive = root.appendingPathComponent(name + Self.archiveSuffix)
            try? manager.removeItem(at: part)
            do {
                let built = try external?(directory, part) ?? false
                if !built {
                    try HarvestArchive.write(session: directory, to: part)
                }
            } catch {
                try? manager.removeItem(at: part)
                throw GuestHarvestError.archiveFailed(String(describing: error))
            }
            guard let size = fileSize(part), size > 0 else {
                try? manager.removeItem(at: part)
                throw GuestHarvestError.archiveFailed("the archive came out empty")
            }
            try? manager.removeItem(at: archive)
            do {
                try manager.moveItem(at: part, to: archive)
            } catch {
                try? manager.removeItem(at: part)
                throw GuestHarvestError.archiveFailed(String(describing: error))
            }
            do {
                return [
                    "archive": archive.path,
                    "bytes": size,
                    "sha256": try HarvestArchive.sha256(of: archive),
                ]
            } catch {
                throw GuestHarvestError.archiveFailed(String(describing: error))
            }
        }
    }

    /// A missing archive is an answer, not an error: the host can ask twice.
    func deleteArchive(session name: String) throws -> [String: Any] {
        try queue.sync {
            try requireSessionName(name)
            let archive = root.appendingPathComponent(name + Self.archiveSuffix)
            guard FileManager.default.fileExists(atPath: archive.path) else {
                return ["deleted": false]
            }
            do {
                try FileManager.default.removeItem(at: archive)
            } catch {
                throw GuestHarvestError.archiveFailed(String(describing: error))
            }
            return ["deleted": true]
        }
    }

    /// Marks the sessions a dead daemon left behind. It runs off the caller's
    /// thread so the server binds without waiting for the walk.
    func recoverOnStartup() {
        queue.async { self.markInterrupted() }
    }

    // MARK: - Recording loop

    /// Called from the queue that serves input. It only checks the gate and hops
    /// onto the loop; the line and the schedule are written there, so the input
    /// that caused a capture never waits for one. With no session running this
    /// is one lock and one bool, and nothing is queued.
    func noteInput(_ method: String, _ params: [String: Any]) {
        inputGate.lock()
        let recording = acceptingInput
        inputGate.unlock()
        guard recording else { return }
        let record = InputRecord(method: method, params: params)
        queue.async { self.recordInput(record) }
    }

    private func begin(
        _ config: Config,
        environment: Environment,
        captureAtStart: Bool,
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let name = availableSessionName()
        let directory = directory(for: name)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = Session(
            name: name,
            directory: directory,
            config: config,
            environment: environment,
            startedAt: clock.now,
        )
        // The file exists from the first second, so every session archives the
        // same shape even when nothing is typed or tapped during it.
        manager.createFile(
            atPath: directory.appendingPathComponent(Self.logName).path,
            contents: nil,
        )
        self.session = session
        setAcceptingInput(true)
        try writeReadme(header: Self.header(for: session), to: directory)
        armTick()
        // The frame a replay starts from: the screen before any input of this
        // session, taken at the interval the reference captures use.
        if captureAtStart {
            beginCapture(trigger: "start", gesture: nil, interaction: nil)
        }
    }

    private func setAcceptingInput(_ value: Bool) {
        inputGate.lock()
        acceptingInput = value
        inputGate.unlock()
    }

    /// `yyyyMMdd-HHmmss`, with a counter only when a session stopped and
    /// another started inside the same second.
    private func availableSessionName() -> String {
        let base = Self.sessionName(for: clock.now)
        guard FileManager.default.fileExists(atPath: directory(for: base).path) else {
            return base
        }
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory(for: "\(base)-\(suffix)").path) {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private func armTick() {
        guard let session, session.running, !tickArmed else { return }
        tickArmed = true
        let name = session.name
        let interval = session.config.intervalSeconds
        tickDue = clock.now.addingTimeInterval(interval)
        clock.after(interval) { [weak self] in
            // The clock may fire anywhere; the loop runs only on its queue.
            guard let self else { return }
            self.queue.async { self.tick(session: name) }
        }
    }

    private func tick(session name: String) {
        guard let current = session, current.name == name, current.running else { return }
        tickArmed = false
        tickDue = nil
        if clock.now.timeIntervalSince(current.startedAt) >= current.config.maxSeconds {
            finish(reason: "time")
            return
        }
        // A burst already owes one capture. If it is due within the coalesce
        // window, take the timer's full-resolution capture now and let the
        // burst ride on it; if it is further off, skip this tick rather than
        // take two captures the user feels as one extra stutter.
        if let due = burstDue, burstCaptureSeq != nil {
            // Adding the window is steadier than subtracting the two times:
            // a difference of 0.2 can land a hair above the constant in binary
            // and cost the burst a timer it should have shared.
            if due <= clock.now.addingTimeInterval(Self.timerCoalesceWindow) {
                let interaction = burstInteractionSeq
                let gesture = burstGesture
                clearBurst()
                beginCapture(trigger: "timer", gesture: gesture, interaction: interaction)
            }
            armTick()
            return
        }
        beginCapture(trigger: "timer", gesture: nil, interaction: nil)
        armTick()
    }

    /// Logs one served input and starts, extends or joins the capture burst it
    /// belongs to. Every input is logged, gesture or not: the file is the
    /// sequence a replay needs, not only the captures.
    private func recordInput(_ input: InputRecord) {
        guard var current = session, current.running else { return }
        let now = clock.now
        current.interactions += 1
        // The event `seq` this input will get. It is assigned when the line is
        // appended, and the loop is serial, so it is known here: a capture can
        // name the input that produced it before the capture runs.
        let sequence = current.events + 1
        let gesture = Self.gestureName(input.method, input.params)
        var capture: Int?
        if let gesture {
            if let reserved = burstCaptureSeq {
                // A drag's moves and a second tap in the same burst name the
                // capture the burst already owes.
                capture = reserved
                burstInteractionSeq = sequence
                burstGesture = gesture
            } else if !capturing {
                // Reserve `captures + 1` now, not when the capture runs: the
                // line must name the capture it caused, the serial loop makes
                // that number stable, and a capture in flight is skipped below.
                let reserved = current.captures + 1
                burstCaptureSeq = reserved
                burstStartedAt = now
                burstInteractionSeq = sequence
                burstGesture = gesture
                capture = reserved
            }
        }
        let line: [String: Any] = [
            "t": Self.milliseconds(now, since: current.startedAt),
            "at": Self.preciseTimestamp(now),
            "method": input.method,
            "params": input.params,
            // The capture this input's burst produced. Moves and every gesture
            // in one burst name the same one; it is the frame after the burst,
            // not a one-to-one pairing.
            "capture": capture ?? NSNull(),
        ]
        do {
            try appendEvent("input", line, to: &current)
        } catch {
            current.lastError = Self.joined([current.lastError, "appending the input: \(error)"])
        }
        session = current
        // The log counts against the same cap as the images; typing alone must
        // not grow a session past it while captures are far apart.
        if current.recordedBytes > current.config.maxBytes {
            finish(reason: "size")
            return
        }
        guard burstCaptureSeq != nil else { return }
        // Every logged input restarts the silence window, keys and text
        // included: a typist must not be photographed between two keystrokes.
        // The deadline still forces one capture two seconds after the gesture
        // that started the burst, so a continuous typist is not missed.
        let silence = now.addingTimeInterval(Self.inputSilence)
        let deadline = (burstStartedAt ?? now).addingTimeInterval(Self.interactionDeadline)
        var due = min(silence, deadline)
        if let last = lastCaptureAt {
            due = max(due, last.addingTimeInterval(Self.interactionGap))
        }
        burstDue = due
        scheduleBurst()
    }

    /// One wait per burst, not one per input: an input that moves the due time
    /// later only updates `burstDue`, and the wait that wakes early sees that
    /// and schedules the remainder.
    private func scheduleBurst() {
        guard !burstScheduled, let due = burstDue, let name = session?.name else { return }
        burstScheduled = true
        let delay = max(0, due.timeIntervalSince(clock.now))
        clock.after(delay) { [weak self] in
            guard let self else { return }
            self.queue.async { self.fireBurst(session: name) }
        }
    }

    private func fireBurst(session name: String) {
        // A wait from a session that has since stopped keeps its hands off the
        // next session's burst.
        guard let current = session, current.name == name, current.running else { return }
        burstScheduled = false
        guard let due = burstDue, let interaction = burstInteractionSeq,
              let gesture = burstGesture
        else {
            clearBurst()
            return
        }
        guard clock.now >= due else {
            scheduleBurst()
            return
        }
        // A capture in flight is the one this burst would duplicate: link the
        // interaction to it and let the burst go, rather than queue a second
        // capture behind it.
        if capturing {
            if inFlightInteraction == nil {
                inFlightInteraction = interaction
            }
            clearBurst()
            return
        }
        // The mirror of the tick's rule: when the timer is about to fire, keep
        // the burst pending so the tick can take the capture and link this
        // interaction, instead of two captures a few hundred ms apart.
        if let tickDue, tickDue <= clock.now.addingTimeInterval(Self.timerCoalesceWindow) {
            burstDue = tickDue
            return
        }
        if let last = lastCaptureAt {
            let wait = last.addingTimeInterval(Self.interactionGap).timeIntervalSince(clock.now)
            if wait > 0 {
                burstDue = clock.now.addingTimeInterval(wait)
                scheduleBurst()
                return
            }
        }
        clearBurst()
        beginCapture(trigger: "interaction", gesture: gesture, interaction: interaction)
    }

    private func clearBurst() {
        burstStartedAt = nil
        burstCaptureSeq = nil
        burstInteractionSeq = nil
        burstGesture = nil
        burstDue = nil
    }

    /// The gesture an input ends, or nil for one that only moves the screen or
    /// types. This is also what names the index's `gesture` field.
    private static func gestureName(_ method: String, _ params: [String: Any]) -> String? {
        switch method {
        case "input.tap": "tap"
        case "input.double_tap": "double_tap"
        case "input.long_press": "long_press"
        case "input.swipe": "swipe"
        case "input.drag": "drag"
        // The app switcher is two home presses, or the bottom-edge swipe that
        // reaches the guest as a touch.
        case "input.button": params["name"] as? String == "home" ? "home" : nil
        case "input.touch": params["phase"] as? String == "up" ? "touch" : nil
        case "input.touch2": params["phase"] as? String == "up" ? "touch2" : nil
        case "input.touch_sequence": "touch_sequence"
        case "input.scroll": params["phase"] as? String == "ended" ? "scroll" : nil
        default: nil
        }
    }

    /// Skips when a capture is still in flight: `queue` only ever holds one,
    /// and a slow guest must not build a queue of them.
    private func beginCapture(trigger: String, gesture: String?, interaction: Int?) {
        guard let session, session.running, !capturing else { return }
        if clock.now.timeIntervalSince(session.startedAt) >= session.config.maxSeconds {
            finish(reason: "time")
            return
        }
        capturing = true
        inFlightInteraction = interaction
        let name = session.name
        // Interaction captures are the ones a user feels, so they use the cheap
        // profile; a timer capture is the reference image and the full tree.
        let profile: CaptureProfile = trigger == "interaction" ? .interaction : .timer
        let started = DispatchTime.now().uptimeNanoseconds
        runCapture { [weak self] in
            guard let self else { return }
            let capture: Capture
            do {
                capture = try self.capture(profile)
            } catch {
                capture = Capture(error: String(describing: error))
            }
            let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            self.queue.async {
                // A burst that fired during this capture attached itself here;
                // read it on the queue, where only one capture is in flight.
                let linked = self.inFlightInteraction
                self.inFlightInteraction = nil
                self.finishCapture(
                    capture, session: name, trigger: trigger, gesture: gesture,
                    interaction: linked, ms: ms,
                )
            }
        }
    }

    private func finishCapture(
        _ capture: Capture, session name: String, trigger: String,
        gesture: String?, interaction: Int?, ms: Int,
    ) {
        capturing = false
        // The session may have stopped, or another one started, while this
        // capture ran; its files belong to neither.
        guard var current = session, current.name == name, current.running else { return }
        let now = clock.now
        lastCaptureAt = now
        let bytes = (capture.jpeg?.count ?? 0) + (capture.tree?.count ?? 0)
        guard current.recordedBytes + bytes <= current.config.maxBytes else {
            finish(reason: "size")
            return
        }
        let sequence = current.captures + 1
        let base = String(format: "%06d", sequence) + "-"
            + Self.captureClock(now) + "-" + trigger
        var error = capture.error
        var written = 0
        var jpegName: String?
        var treeName: String?
        do {
            // In this order, so a daemon that dies mid-capture leaves at worst
            // a file the index does not name.
            if let jpeg = capture.jpeg {
                let name = base + ".jpg"
                try jpeg.write(to: current.directory.appendingPathComponent(name), options: .atomic)
                jpegName = name
                written += jpeg.count
            }
            if let tree = capture.tree {
                let name = base + ".tree.json"
                try tree.write(to: current.directory.appendingPathComponent(name), options: .atomic)
                treeName = name
                written += tree.count
            }
        } catch let failure {
            error = Self.joined([error, "writing the capture: \(failure)"])
        }
        let line: [String: Any] = [
            "capture": sequence,
            "t": Self.milliseconds(now, since: current.startedAt),
            "at": Self.preciseTimestamp(now),
            "trigger": trigger,
            "gesture": gesture ?? NSNull(),
            // The event seq of the input this frame belongs to, or null.
            "input": interaction ?? NSNull(),
            // Named rather than derived from `capture`: a reader must not have
            // to know the naming rule, and the tree is absent when the walk failed.
            "jpeg": jpegName ?? NSNull(),
            "tree": treeName ?? NSNull(),
            "jpeg_bytes": capture.jpeg?.count ?? 0,
            "tree_bytes": capture.tree?.count ?? 0,
            "bytes": written,
            // Pixels of the JPEG; divide by `coordinate_scale` for points, which
            // is the space a tree's `frame` uses.
            "width": capture.width ?? NSNull(),
            "height": capture.height ?? NSNull(),
            "coordinate_scale": capture.coordinateScale ?? NSNull(),
            "foreground": capture.foreground.map { Self.foregroundBody($0) } ?? NSNull(),
            "ms": ms,
            "error": error ?? NSNull(),
        ]
        do {
            try appendEvent("capture", line, to: &current)
        } catch let failure {
            error = Self.joined([error, "appending the capture: \(failure)"])
        }
        current.captures += 1
        // A coalesced timer capture carries an input too, and is the capture
        // that input got; count it either way.
        if trigger == "interaction" || interaction != nil {
            current.interactionCaptures += 1
        }
        current.recordedBytes += written
        current.lastError = error
        session = current
        if now.timeIntervalSince(current.startedAt) >= current.config.maxSeconds {
            finish(reason: "time")
        }
    }

    private func finish(reason: String) {
        guard var current = session, current.running else { return }
        current.running = false
        let stoppedAt = clock.now
        current.stoppedAt = stoppedAt
        current.stopReason = reason
        setAcceptingInput(false)
        tickArmed = false
        tickDue = nil
        burstScheduled = false
        clearBurst()
        inFlightInteraction = nil
        // The log's last line is the one that says the session ended, so a
        // stopped session's counters are read without walking the file.
        let line: [String: Any] = [
            "t": Self.milliseconds(stoppedAt, since: current.startedAt),
            "at": Self.preciseTimestamp(stoppedAt),
            "reason": reason,
            "captures": current.captures,
            "interactionCaptures": current.interactionCaptures,
            "interactions": current.interactions,
            "bytes": current.recordedBytes,
            "lastError": current.lastError ?? NSNull(),
        ]
        do {
            try appendEvent("stop", line, to: &current)
        } catch {
            NSLog(
                "vphoned: harvest: could not append the stop of %@: %@",
                current.name, String(describing: error),
            )
        }
        session = current
    }

    // MARK: - Retention

    /// At every start, oldest first, so the directory holds at most five
    /// sessions and two gigabytes — counting the one about to be created.
    private func prune() {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var sessions: [(name: String, bytes: Int)] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  manager.fileExists(atPath: entry.appendingPathComponent(Self.logName).path)
            else { continue }
            sessions.append((entry.lastPathComponent, directorySize(entry)))
        }
        sessions.sort { $0.name > $1.name }
        let running = session?.running == true ? session?.name : nil
        for name in GuestHarvestRetention.plan(sessions: sessions, running: running) {
            do {
                try manager.removeItem(at: directory(for: name))
            } catch {
                NSLog("vphoned: harvest: could not prune %@: %@", name, String(describing: error))
            }
        }
    }

    private func directorySize(_ directory: URL) -> Int {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total = 0
        for case let file as URL in walk {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    // MARK: - Startup recovery

    /// Marks the sessions a dead daemon left behind: a log whose last event is
    /// not `stop` gets one appended, so a stopped session answers "when did it
    /// end and how much did it record" from its last line alone. A line the
    /// crash cut short is dropped first.
    private func markInterrupted() {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !(session?.running == true && session?.name == entry.lastPathComponent),
                  readHeader(name: entry.lastPathComponent) != nil
            else { continue }
            let log = entry.appendingPathComponent(Self.logName)
            let last = Self.lastEvent(of: log)
            if last?["kind"] as? String == "stop" { continue }
            guard let counts = Self.scanLog(log) else { continue }
            Self.ensureTrailingNewline(log)
            let line: [String: Any] = [
                "seq": counts.events + 1,
                "kind": "stop",
                "t": (last?["t"] as? Int) ?? 0,
                "at": (last?["at"] as? String) ?? Self.preciseTimestamp(clock.now),
                "reason": "interrupted",
                "captures": counts.captures,
                "interactionCaptures": counts.interactionCaptures,
                "interactions": counts.interactions,
                "bytes": counts.bytes,
                "lastError": NSNull(),
            ]
            do {
                _ = try appendLine(line, to: entry, named: Self.logName)
                NSLog("vphoned: harvest: %@ was interrupted; appended its stop", entry.lastPathComponent)
            } catch {
                NSLog(
                    "vphoned: harvest: could not mark %@ interrupted: %@",
                    entry.lastPathComponent, String(describing: error),
                )
            }
        }
    }

    // MARK: - Reporting

    private func payloadLocked() -> [String: Any] {
        ["status": statusLocked(), "sessions": summariesLocked()]
    }

    private func statusLocked() -> [String: Any] {
        guard let session else {
            let config = Config.defaults
            return [
                "running": false,
                "session": NSNull(),
                "directory": NSNull(),
                "intervalSeconds": config.intervalSeconds,
                "maxBytes": config.maxBytes,
                "maxSeconds": config.maxSeconds,
                "startedAt": NSNull(),
                "stoppedAt": NSNull(),
                "elapsedSeconds": 0,
                "captures": 0,
                "interactionCaptures": 0,
                "interactions": 0,
                "recordedBytes": 0,
                "stopReason": NSNull(),
                "lastError": NSNull(),
            ]
        }
        var body = statusFields(session)
        body["running"] = session.running
        body["elapsedSeconds"] = Int(max(0, (session.stoppedAt ?? clock.now).timeIntervalSince(session.startedAt)))
        return body
    }

    private func summariesLocked() -> [[String: Any]] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var summaries: [String: [String: Any]] = [:]
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let header = readHeader(name: entry.lastPathComponent)
            else { continue }
            var body: [String: Any] = [
                "session": header["session"] ?? entry.lastPathComponent,
                "directory": header["directory"] ?? directory(for: entry.lastPathComponent).path,
                "startedAt": header["startedAt"] ?? NSNull(),
                "stoppedAt": NSNull(),
                "stopReason": NSNull(),
                "captures": 0,
                "interactionCaptures": 0,
                "interactions": 0,
                "bytes": 0,
                "label": header["label"] ?? NSNull(),
                "notes": header["notes"] ?? [],
                "running": false,
            ]
            // A stopped session's counters are its log's last line: listing five
            // sessions reads five small headers and five tails, not five logs.
            if let stop = Self.lastEvent(of: entry.appendingPathComponent(Self.logName)),
               stop["kind"] as? String == "stop"
            {
                body["stoppedAt"] = stop["at"] ?? NSNull()
                body["stopReason"] = stop["reason"] ?? NSNull()
                body["captures"] = stop["captures"] ?? 0
                body["interactionCaptures"] = stop["interactionCaptures"] ?? 0
                body["interactions"] = stop["interactions"] ?? 0
                body["bytes"] = stop["bytes"] ?? 0
            }
            summaries[entry.lastPathComponent] = body
        }
        // The running session is a line or two ahead of its log; read it from
        // memory, where the counters live.
        if let session {
            summaries[session.name] = summary(of: session)
        }
        return summaries.keys.sorted(by: >).compactMap { summaries[$0] }
    }

    private func statusFields(_ session: Session) -> [String: Any] {
        [
            "session": session.name,
            "directory": session.directory.path,
            "intervalSeconds": session.config.intervalSeconds,
            "maxBytes": session.config.maxBytes,
            "maxSeconds": session.config.maxSeconds,
            "startedAt": Self.timestamp(session.startedAt),
            "stoppedAt": session.stoppedAt.map { Self.timestamp($0) } ?? NSNull(),
            "captures": session.captures,
            "interactionCaptures": session.interactionCaptures,
            "interactions": session.interactions,
            "recordedBytes": session.recordedBytes,
            "stopReason": session.stopReason ?? NSNull(),
            "lastError": session.lastError ?? NSNull(),
        ]
    }

    /// The session's own facts, copied at start. They become the README's front
    /// matter, so the folder describes itself without the host's bundle store or
    /// the guest: see `harvest-format.md`.
    private static func header(for session: Session) -> [String: Any] {
        var body = environmentBody(session.environment)
        body["formatVersion"] = formatVersion
        body["session"] = session.name
        body["directory"] = session.directory.path
        body["startedAt"] = preciseTimestamp(session.startedAt)
        body["intervalSeconds"] = session.config.intervalSeconds
        body["maxBytes"] = session.config.maxBytes
        body["maxSeconds"] = session.config.maxSeconds
        body["captureProfile"] = captureProfileBody()
        body["notes"] = session.notes
        return body
    }

    private static func environmentBody(_ environment: Environment) -> [String: Any] {
        [
            "vm": environment.vm ?? NSNull(),
            "model": environment.model ?? NSNull(),
            "iosVersion": environment.iosVersion ?? NSNull(),
            "kernel": environment.kernel ?? NSNull(),
            "vphonedHash": environment.vphonedHash ?? NSNull(),
            // Points, the space a tree's `frame` uses. Index width/height are
            // the JPEG's pixels: multiply points by `scale` for those.
            "screen": [
                "width": environment.screenWidth ?? NSNull(),
                "height": environment.screenHeight ?? NSNull(),
                "scale": environment.screenScale ?? NSNull(),
                "space": "points",
            ] as [String: Any],
            "timeZone": environment.timeZone ?? NSNull(),
            "label": environment.label ?? NSNull(),
        ]
    }

    private static func captureProfileBody() -> [String: Any] {
        func body(_ profile: CaptureProfile) -> [String: Any] {
            [
                "nativeResolution": profile.nativeResolution,
                "maxElements": profile.maxElements,
                "maxDepth": profile.maxDepth,
                "timeoutMS": profile.timeoutMS,
            ]
        }
        return ["timer": body(.timer), "interaction": body(.interaction)]
    }

    private static func foregroundBody(_ foreground: Foreground) -> [String: Any] {
        [
            "bundle_id": foreground.bundleID ?? NSNull(),
            "pid": foreground.pid ?? NSNull(),
            "verified": foreground.verified ?? NSNull(),
        ]
    }

    private func summary(of session: Session) -> [String: Any] {
        [
            "session": session.name,
            "directory": session.directory.path,
            "startedAt": Self.timestamp(session.startedAt),
            "stoppedAt": session.stoppedAt.map { Self.timestamp($0) } ?? NSNull(),
            "stopReason": session.stopReason ?? NSNull(),
            "captures": session.captures,
            "interactionCaptures": session.interactionCaptures,
            "interactions": session.interactions,
            "bytes": session.recordedBytes,
            "label": session.environment.label ?? NSNull(),
            "notes": session.notes,
            "running": session.running,
        ]
    }

    // MARK: - Files

    private func directory(for name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func requireSessionName(_ name: String) throws {
        guard Self.isSessionName(name) else {
            throw GuestHarvestError.invalidSession(name)
        }
    }

    /// A session name is a timestamp, optionally with the counter a second
    /// start in the same second gets, and never a path.
    static func isSessionName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts[0].count == 8, parts[1].count == 6,
              parts.count == 2 || !parts[2].isEmpty
        else { return false }
        return parts.allSatisfy { part in part.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// The README's front matter: three lines, the middle one a JSON object.
    /// Absent, or written for another version, the folder is not this recorder's.
    private func readHeader(name: String) -> [String: Any]? {
        let url = directory(for: name).appendingPathComponent(Self.readmeName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
        guard lines.count >= 3, lines[0] == "---", lines[2] == "---",
              let data = lines[1].data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (body["formatVersion"] as? Int) == Self.formatVersion
        else { return nil }
        return body
    }

    /// The header and the notes, then the format description: a fixed template
    /// plus those values, so it can never claim more than the recorder observed.
    private func writeReadme(header: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let text = "---\n\(json)\n---\n" + Self.readmeBody(header: header)
        try text.write(
            to: directory.appendingPathComponent(Self.readmeName),
            atomically: true, encoding: .utf8,
        )
    }

    private static func readmeBody(header: [String: Any]) -> String {
        func string(_ key: String, _ missing: String = "(unknown)") -> String {
            guard let value = header[key] as? String, !value.isEmpty else { return missing }
            return value
        }
        func number(_ value: Any?) -> String {
            (value as? NSNumber)?.stringValue ?? "(unknown)"
        }
        let screen = header["screen"] as? [String: Any] ?? [:]
        let model = (header["model"] as? String).map { " (\($0))" } ?? ""
        let label = (header["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(none)"
        return """
        # vphone harvest session \(string("session"))

        Written by vphoned when the session started, and updated only when a note
        is added. It describes the folder and the format; it does not summarise
        what happened. The session's own facts are the JSON front matter above, so
        a machine does not have to read this prose.

        - format: vphone-harvest/\(formatVersion)
        - guest: \(string("vm"))\(model), iOS \(string("iosVersion"))
        - kernel: \(string("kernel")), vphoned \(string("vphonedHash"))
        - screen: \(number(screen["width"]))x\(number(screen["height"])) points
          at scale \(number(screen["scale"]))
        - started: \(string("startedAt")) (UTC; the session name is guest-local time)
        - time zone: \(string("timeZone"))
        - label: \(label)
        - interval: \(number(header["intervalSeconds"])) s, caps
          \(number(header["maxBytes"])) bytes and \(number(header["maxSeconds"])) s

        `at` is RFC 3339 UTC with milliseconds, `t` is milliseconds from
        `startedAt`. The replies carry whole seconds.

        ## Files

        - `session.jsonl` — one JSON object per event, one event per line, in
          `seq` order. Every input is logged, gestures or not, so this file is
          the replay.
        - `NNNNNN-HHMMSS-trigger.jpg` — screenshot in pixels.
        - `NNNNNN-HHMMSS-trigger.tree.json` — accessibility tree of the same
          moment. `frame` values are points; multiply by `coordinate_scale` to
          compare them with the JPEG. Absent when the walk could not verify a
          foreground app.

        ## session.jsonl

        Every line has `seq` (the append order) and `kind`.

        - `kind: "input"` — one served input: `t`, `at`, `method` (the vphoned
          RPC, e.g. `input.touch`), `params` (that call's parameters, verbatim)
          and `capture`, the frame its burst produced. `capture` is `null` when
          no frame can be claimed: an input served while a capture was already in
          flight names no frame, and the next frame shows its result.
        - `kind: "capture"` — one frame: `capture` (1-based frame number, also the
          file name prefix), `t`, `at`, `trigger` (`start`, `timer`,
          `interaction`), `gesture` (the gesture that ended the burst, or null),
          `input` (the `seq` of the input it belongs to, or null), `jpeg`, `tree`
          (file names, or null), `jpeg_bytes`, `tree_bytes`, `bytes` (their sum),
          `width`, `height` (JPEG pixels), `coordinate_scale` (pixels per point),
          `foreground` (`{bundle_id, pid, verified}`, or null), `ms` (how long the
          capture took) and `error` (what failed, or null).
        - `kind: "stop"` — the last line of a stopped session: `reason`
          (`stopped`, `size`, `time`, `error`, `interrupted`), the final
          `captures`, `interactionCaptures`, `interactions` and `bytes`, and
          `lastError`.

        A timer capture due within 200 ms of a burst takes the frame instead; it
        stays `trigger: "timer"` and carries the `input` the burst was waiting
        for. `interactionCaptures` counts those frames too.

        ## Replaying

        1. Start the guest on the same screen as the first frame
           (`000001-...-start.jpg` when the session has one).
        2. Send every `kind: "input"` line in `seq` order:
           `vphone-launchpad-cli guest rpc <vm> <method> '<params>'`.
        3. An x/y with `normalized: true` is a fraction of the screen; otherwise
           it is points. Divide the JPEG's pixels by `coordinate_scale` for points.
        4. Compare the JPEG of each `capture` with what the same input produces.
        """
    }

    /// Appends one event to the session log, assigning its `seq` and counting
    /// the line's bytes. The caller adds the image bytes, if any.
    @discardableResult
    private func appendEvent(
        _ kind: String, _ fields: [String: Any], to session: inout Session,
    ) throws -> Int {
        var line = fields
        line["seq"] = session.events + 1
        line["kind"] = kind
        let written = try appendLine(line, to: session.directory, named: Self.logName)
        session.events += 1
        session.recordedBytes += written
        return written
    }

    /// Appends one JSON line and closes the handle, so a crash keeps every line
    /// already written. Returns the bytes it added.
    private func appendLine(
        _ line: [String: Any], to directory: URL, named name: String,
    ) throws -> Int {
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        data.append(0x0A)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return data.count
    }

    /// The last complete line of a log, read from the end so a stopped session's
    /// counters never need a full scan. A partial line left by a crash is not a
    /// line: the seek stops at the newline before it.
    private static func lastEvent(of url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        var position = end
        var buffer = Data()
        let chunk: UInt64 = 8_192
        while position > 0 {
            let start = position > chunk ? position - chunk : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(position - start)) else { return nil }
            buffer = data + buffer
            if let newline = trimmed(buffer).lastIndex(of: 0x0A) {
                return event(from: buffer[buffer.index(after: newline)...])
            }
            position = start
        }
        return event(from: buffer)
    }

    /// Drops a crash's half-written last line, so the next append starts a line
    /// of its own.
    private static func ensureTrailingNewline(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return }
        try? handle.seek(toOffset: end - 1)
        if let last = try? handle.read(upToCount: 1), last == Data([0x0A]) { return }
        var position = end
        let chunk: UInt64 = 8_192
        while position > 0 {
            let start = position > chunk ? position - chunk : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(position - start)) else { return }
            if let newline = data.lastIndex(of: 0x0A) {
                let offset = start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
                try? handle.truncate(atOffset: offset)
                return
            }
            position = start
        }
        try? handle.truncate(atOffset: 0)
    }

    private static func trimmed(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex, data[data.index(before: end)] == 0x0A
            || data[data.index(before: end)] == 0x0D
        {
            end = data.index(before: end)
        }
        return data[data.startIndex..<end]
    }

    private static func event(from line: Data) -> [String: Any]? {
        let line = trimmed(line)
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        return object
    }

    /// Counts a log whose stop line is missing, the way the recorder would have
    /// counted it while running. Chunked, so a capped session is never loaded
    /// whole.
    private static func scanLog(
        _ url: URL,
    ) -> (events: Int, captures: Int, interactionCaptures: Int, interactions: Int, bytes: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var events = 0
        var captures = 0
        var interactionCaptures = 0
        var interactions = 0
        var bytes = 0
        var buffer = Data()
        func consume(_ line: Data) {
            let line = trimmed(line)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = object["kind"] as? String
            else { return }
            events += 1
            bytes += line.count + 1
            switch kind {
            case "capture":
                captures += 1
                let linked = !(object["input"] is NSNull) && object["input"] != nil
                if object["trigger"] as? String == "interaction" || linked {
                    interactionCaptures += 1
                }
                bytes += (object["jpeg_bytes"] as? Int ?? 0) + (object["tree_bytes"] as? Int ?? 0)
            case "input":
                interactions += 1
            default:
                break
            }
        }
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                consume(buffer[..<newline])
                buffer = buffer[buffer.index(after: newline)...]
            }
        }
        return (events, captures, interactionCaptures, interactions, bytes)
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: "; ")
    }
}

/// How many session directories survive a `harvest.start`.
enum GuestHarvestRetention {
    static let maxSessions = 5
    static let maxBytes = 2 << 30

    /// The names to delete so that the caps hold once the new session exists,
    /// oldest first. The running session is never named, even when it is the
    /// reason a cap cannot be met.
    static func plan(sessions: [(name: String, bytes: Int)], running: String?) -> [String] {
        var kept = sessions
        var deleted: [String] = []
        func victim() -> Int? {
            kept.lastIndex { $0.name != running }
        }
        while kept.count + 1 > maxSessions, let index = victim() {
            deleted.append(kept.remove(at: index).name)
        }
        while kept.reduce(0, { $0 + $1.bytes }) > maxBytes, let index = victim() {
            deleted.append(kept.remove(at: index).name)
        }
        return deleted
    }
}

enum GuestHarvestError: Error, CustomStringConvertible {
    case invalidSession(String)
    case missingSession(String)
    case archiveFailed(String)

    var description: String {
        switch self {
        case let .invalidSession(name):
            "\(name) is not a harvest session"
        case let .missingSession(name):
            "No harvest session \(name)"
        case let .archiveFailed(message):
            "The harvest archive failed: \(message)"
        }
    }
}
