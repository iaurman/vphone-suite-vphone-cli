import Foundation
import VPhoneCoreKit

/// Polls vphoned's `display.orientation` for a launch with no window
/// controller.
///
/// A windowed VM reads the guest's interface orientation in
/// `VPhoneVirtualMachineWindowController.pollOrientation()`: the window has to
/// turn and reshape, and `VPhoneGuestControl.interfaceOrientation` is what its
/// orientation observer forwards to vpdc. A **headless** launch has no window
/// controller, so nothing assigns that property and the observer never fires.
/// The WebRTC viewer then keeps drawing the panel portrait while the guest
/// turns underneath it.
///
/// This is the missing reader. It asks the same method at the same cadence,
/// only assigns an orientation that differs from the last one it reported, and
/// forwards the raw degrees so vpdc fills in the sequence number. A guest
/// without the `display_orientation` capability stays portrait, exactly as a
/// windowed one does.
@MainActor
final class VPhoneGuestOrientationPoll {
    private let control: VPhoneGuestControl
    private let intervalSeconds: Double
    private let onChange: (Int) -> Void
    private var task: Task<Void, Never>?
    private var inFlight = false
    /// The last degrees reported, so a guest that is not turning costs one
    /// assignment per poll and no vpdc message.
    private var lastDegrees: Int?

    init(
        control: VPhoneGuestControl,
        intervalSeconds: Double,
        onChange: @escaping (Int) -> Void,
    ) {
        self.control = control
        self.intervalSeconds = intervalSeconds
        self.onChange = onChange
    }

    func start() {
        guard task == nil else { return }
        let interval = Self.duration(intervalSeconds)
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One read. Overlapping reads are dropped rather than queued: a guest that
    /// answers slowly must not build a backlog of stale orientations.
    private func pollOnce() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        // The guest has to be connected and must advertise the method; without
        // it every read is refused and the panel stays portrait.
        guard control.isConnected, control.guestCapabilities.contains("display_orientation") else {
            return
        }
        // A rotation this process started is being applied; a read taken across
        // it can predate the turn and undo it, exactly as in the window.
        guard !control.isChangingOrientation else { return }
        guard let result = try? await control.call("display.orientation"),
              let degrees = (result["degrees"] as? NSNumber)?.intValue
        else { return }
        guard !control.isChangingOrientation else { return }
        guard degrees != lastDegrees else { return }
        lastDegrees = degrees
        onChange(degrees)
    }

    private static func duration(_ seconds: Double) -> Duration {
        .milliseconds(Int((max(seconds, 0.05) * 1000).rounded()))
    }
}
