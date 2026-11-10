import AppKit
import Foundation
import Virtualization
import VPDC
import VPhoneCoreKit

/// The VM's `VZGraphicsDisplay`, for vpdc's capture queue.
///
/// `VZGraphicsDisplay` is an AppKit object and not `Sendable`, but it never
/// changes for the life of a VM: the box is written once on the main thread
/// and read from the capture queue and the main thread afterwards.
final class VPhoneVPDCDisplayBox: @unchecked Sendable {
    weak var display: VZGraphicsDisplay?
}

/// vpdc, running inside this `vphone-vm` process: the per-VM WebRTC side of
/// `PLAN.md` §3.
///
/// It is created for a normal windowed launch only. `--headless`, DFU, a
/// template build and a template-setup boot have no `VZGraphicsDisplay` worth
/// capturing, and must not open LAN ports for an image that is being prepared
/// rather than run.
///
/// The vpd connection, the port block, the relays, the gateway and the audio
/// tap all live in `VPDCController`; this type only supplies the two pieces
/// that need `vphone-vm` itself: the windowed display, and the guest's
/// rotation as the window controller already polls it. It is deliberately not
/// actor-isolated: the VM's stop notification arrives off the main thread and
/// must still be able to release the audio tap and the ports.
final class VPhoneVirtualMachineVPDC: @unchecked Sendable {
    let controller: VPDCController
    private let log: VPDCLog
    /// The windowed display, read on the main thread for its frame size.
    private let display: @Sendable () -> VZGraphicsDisplay?
    /// The size the controller starts with. The observer only forwards a real
    /// change, so the first read costs nothing when the display matches the
    /// manifest.
    private let initialPanelSize: CGSize
    /// `sizeObserver` is written on the main actor and cleared from the VM's
    /// stop queue, so it needs a lock.
    private let lock = NSLock()
    private var sizeObserver: Task<Void, Never>?
    /// The display's frame size is checked about as often as the window
    /// controller already asks the guest for its orientation.
    private static let sizePollInterval: Duration = .seconds(1)

    /// Fails (returns nil) when vpdc must not run for this launch.
    init?(
        command: VPhoneBootCommand,
        options: VPhoneVirtualMachine.Options,
        display: @escaping @Sendable () -> VZGraphicsDisplay?,
    ) {
        let machineDirectory = options.configURL.deletingLastPathComponent()
        // A template build boots inside `<library>/.templates/.building-…`,
        // and a template-setup boot runs on the machine that carries the
        // record a freeze reads. Neither may publish ports.
        let isTemplateBuild = machineDirectory.pathComponents.contains(VPhoneMachineTemplates.directoryName)
        let isTemplateSetup = FileManager.default.fileExists(
            atPath: machineDirectory.appendingPathComponent(VPhoneMachineTemplates.recordFileName).path,
        )
        let decision = VPDCLaunchDecisionPolicy.decision(
            headless: command.headless,
            dfu: command.dfu,
            templateSetup: isTemplateSetup || isTemplateBuild,
            transient: isTemplateBuild,
        )
        guard decision.isEnabled else {
            print("[vpdc] not started: \(decision.reason ?? "")")
            return nil
        }

        // Every vpdc appends to one file: the VM name makes relay and media
        // lines attributable without cross-referencing the port block.
        let log = VPDCLog(
            level: .info,
            fileURL: VPDCLogLocation.defaultFileURL(),
            label: machineDirectory.lastPathComponent,
        )
        self.log = log
        self.display = display
        initialPanelSize = CGSize(width: options.screenWidth, height: options.screenHeight)

        var dependencies = VPDCDependencies.live(client: VPDClient(log: log), log: log)
        // The windowed display, through the same private screenshot call the
        // window and the recorder use. Frames stay in the panel's own
        // orientation; the viewer turns the picture.
        dependencies.makeVideo = { panel, _ in
            VideoPipeline(
                source: VZDisplayVideoSource(panelSize: panel, display: display, log: log),
                encoder: VideoToolboxH264Encoder(log: log),
                log: log,
            )
        }

        let vpdcOptions = VPDCOptions(
            vmName: VPhoneDockName.name(forConfig: options.configURL),
            machineDirectory: machineDirectory,
            panelSize: CGSize(width: options.screenWidth, height: options.screenHeight),
            audioEnabled: true,
            gatewayBinary: GatewayBinaryLocator.locate(),
        )
        let controller = VPDCController(options: vpdcOptions, dependencies: dependencies, log: log)
        controller.onEvent = { event in
            print("[vpdc] \(event)")
        }
        self.controller = controller
    }

    func start() {
        controller.start()
        startSizeObserver()
    }

    /// Idempotent, and the one place the audio tap and the four ports are
    /// released. Every path that ends the VM calls it.
    func stop() {
        let observer = lock.withLock { () -> Task<Void, Never>? in
            defer { sizeObserver = nil }
            return sizeObserver
        }
        observer?.cancel()
        controller.stop()
    }

    /// Forwards the guest's framebuffer size when it changes under a running
    /// VM (a foldable, or an external display).
    ///
    /// `VZGraphicsDisplay` has no notification for its size, so this reads
    /// `sizeInPixels` on the main thread once a second — the same cadence as
    /// the window controller's orientation poll — and forwards only a change.
    /// The controller re-encodes at the new size, forces an IDR and tells
    /// `vpweb`, so the size viewers are offered follows the panel.
    private func startSizeObserver() {
        let display = display
        let initial = initialPanelSize
        let observer = Task { @MainActor [weak self] in
            var last = initial
            while !Task.isCancelled {
                if let size = display()?.sizeInPixels, size.width >= 16, size.height >= 16,
                   size != last
                {
                    last = size
                    self?.controller.panelSizeChanged(size)
                }
                try? await Task.sleep(for: Self.sizePollInterval)
            }
        }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            defer { sizeObserver = observer }
            return sizeObserver
        }
        previous?.cancel()
    }

    /// The guest's interface orientation, as `display.orientation` reports it.
    /// The controller derives `(360 - raw) % 360` and the sequence number.
    func guestOrientationChanged(rawDegrees: Int) {
        controller.guestOrientationChanged(rawDegrees: rawDegrees)
    }

    /// The guest's framebuffer changed size. The observer above calls this;
    /// it is also the seam a test or a future notification would use.
    func panelSizeChanged(_ size: CGSize) {
        controller.panelSizeChanged(size)
    }

    deinit {
        // A path that ended the VM without calling `stop()` still releases
        // the tap and the ports.
        controller.stop()
    }
}
