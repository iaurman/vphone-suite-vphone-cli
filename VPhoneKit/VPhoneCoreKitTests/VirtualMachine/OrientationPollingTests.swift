import Testing
@testable import VPhoneCoreKit

/// A headless launch has no window controller, so the host has to poll the
/// guest's orientation itself or no `rotation` ever reaches a viewer.
@Suite("Orientation polling")
struct OrientationPollingTests {
    @Test
    func `a headless launch polls and a windowed one does not`() {
        #expect(VPhoneOrientationPolling.needsOwnPoll(headless: true))
        // The window controller already reads it once a second; a second poll
        // would ask the guest twice for the same answer.
        #expect(VPhoneOrientationPolling.needsOwnPoll(headless: false) == false)
    }

    @Test
    func `the headless poll keeps the window controller cadence`() {
        #expect(VPhoneOrientationPolling.intervalSeconds(foldableGuest: false) == 1)
        // A foldable's panel is already moving, so the window reads it four
        // times a second; a headless viewer must not lag behind that.
        #expect(VPhoneOrientationPolling.intervalSeconds(foldableGuest: true) == 0.25)
    }
}
