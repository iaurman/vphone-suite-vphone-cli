import Foundation

// MARK: - Guest orientation polling

/// How the host learns that the guest's interface turned.
///
/// `vphoned`'s `display.orientation` is the only source: SpringBoard is asked
/// for the interface orientation and the host turns the picture to match. Two
/// launch shapes need different owners for the poll.
///
/// * A windowed launch already polls it from
///   `VPhoneVirtualMachineWindowController.pollOrientation()`, once a second
///   (four times a second for a foldable), because the window itself has to
///   turn and reshape. vpdc must not add a second poll: two readers of the same
///   method would double the guest traffic and could report the same turn with
///   different sequence numbers.
/// * A headless launch has no window controller at all, so nothing polled, and
///   the WebRTC viewer never received a `rotation` message. The guest turned and
///   the page kept drawing the panel portrait.
public enum VPhoneOrientationPolling {
    /// Whether this launch has to poll the guest's orientation itself.
    ///
    /// Only headless does. A windowed launch reads it, and that read is the one
    /// forwarded to vpdc.
    public static func needsOwnPoll(headless: Bool) -> Bool {
        headless
    }

    /// How often a headless poll asks. The window controller's cadence, so a
    /// guest turned from either path reaches the viewer at the same speed: a
    /// foldable turns four times a second because its panel is already moving.
    public static func intervalSeconds(foldableGuest: Bool) -> Double {
        foldableGuest ? 0.25 : 1
    }
}
