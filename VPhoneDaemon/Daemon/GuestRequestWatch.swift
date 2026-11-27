import Foundation

/// Names the request that never comes back.
///
/// Every handler runs on the event loop that also accepts connections, so one
/// native call that blocks takes the whole API down and leaves a worker that is
/// alive but answers nothing. Until now that state left the log completely
/// empty, which is why the stalls of November 2026 could only be seen from the
/// host as a flood of refused probes. The request in flight is recorded here,
/// and reported from a queue of its own for as long as it stays in flight, so
/// the next one says which call hung.
final class GuestRequestWatch: @unchecked Sendable {
    static let shared = GuestRequestWatch()

    private struct Request {
        let label: String
        let started: UInt64
        var reported: Int
    }

    /// A request still running after this long is reported once.
    static let firstReport: TimeInterval = 10
    /// Then again this often, so a long stall keeps naming the same call.
    static let repeatInterval: TimeInterval = 60
    /// How often the in-flight requests are examined.
    static let tick: TimeInterval = 5

    private let lock = NSLock()
    private var requests: [UInt64: Request] = [:]
    private var nextToken: UInt64 = 1
    private var monitor: DispatchSourceTimer?

    /// Whether a request in flight for `elapsed` seconds, already reported
    /// `reported` times, is due to be reported again.
    static func isReportDue(elapsed: TimeInterval, reported: Int) -> Bool {
        reported == 0
            ? elapsed >= firstReport
            : elapsed >= firstReport + Double(reported) * repeatInterval
    }

    /// Starts watching one request, named `<method> <path>`.
    func begin(_ label: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        requests[token] = Request(
            label: label,
            started: DispatchTime.now().uptimeNanoseconds,
            reported: 0,
        )
        return token
    }

    func end(_ token: UInt64) {
        lock.lock()
        requests.removeValue(forKey: token)
        lock.unlock()
    }

    /// The requests in flight, for tests.
    var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// Starts the reporting timer, once. It lives on a queue of its own, so a
    /// handler that blocks an event loop cannot stop it.
    func startMonitoring() {
        lock.lock()
        if monitor != nil {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
            label: "vphoned.request-watch", qos: .utility,
        ))
        timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
        timer.setEventHandler { [weak self] in self?.report() }
        timer.resume()
        monitor = timer
        lock.unlock()
    }

    private func report() {
        let now = DispatchTime.now().uptimeNanoseconds
        var lines: [String] = []
        lock.lock()
        for (token, request) in requests {
            let elapsed = Double(now - request.started) / 1_000_000_000
            guard Self.isReportDue(elapsed: elapsed, reported: request.reported) else { continue }
            requests[token]?.reported += 1
            lines.append("\(request.label) has not returned after \(Int(elapsed)) s")
        }
        lock.unlock()
        for line in lines {
            NSLog("vphoned: %@", line)
        }
    }
}
