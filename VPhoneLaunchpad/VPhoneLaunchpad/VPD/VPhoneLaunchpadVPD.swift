import Foundation
import Observation
import VPD

// MARK: - Model adapter

/// The launchpad model as vpd's `VPDModel`.
///
/// Every action goes through `VPhoneLaunchpadMachineLibrary` directly: no
/// `vphone-launchpad-cli`, no control socket (`PLAN.md` §2, §9). The library
/// reports a failed start, stop, clone or rename through `actionError` and a
/// refreshed `state(of:)` instead of throwing, so each action checks the
/// resulting state and turns a failed one into `VPDModelError.unavailable`.
@MainActor
final class VPDLaunchpadModel: VPDModel {
    let library: VPhoneLaunchpadMachineLibrary
    private let leases: VPhoneLaunchpadLeases
    /// `~/Library/Application Support/vpd/template-names.json`.
    private let names = VPDTemplateNameRegistry()
    /// The same store the service allocates from: every library root, one
    /// reservation space. Never a per-root store.
    private let store: VPDPortMappingStore
    /// One DHCP snapshot per interval, single-flight, so `listVMs` costs one
    /// `vm leases` per TTL rather than one per machine.
    private let leaseCache: VPDLeaseCache

    init(
        library: VPhoneLaunchpadMachineLibrary,
        leases: VPhoneLaunchpadLeases,
        store: VPDPortMappingStore
    ) {
        self.library = library
        self.leases = leases
        self.store = store
        leaseCache = VPDLeaseCache(ttl: .seconds(5)) { [weak leases] in
            guard let leases else { return [] }
            return await Self.leaseSnapshot(leases)
        }
    }

    /// One `vm leases` run and its rows, for the DHCP fallback.
    private nonisolated static func leaseSnapshot(_ leases: VPhoneLaunchpadLeases) async -> [VPDDHCPLease] {
        await leases.refresh()
        let rows = await MainActor.run { leases.leases }
        return rows.compactMap { lease in
            guard let address = lease.address, !address.isEmpty else { return nil }
            return VPDDHCPLease(address: address, machine: lease.machine, mac: lease.mac)
        }
    }

    // MARK: Files

    private func machine(named name: String) -> VPhoneLaunchpadMachine? {
        library.machines.first { $0.name == name }
    }

    private func template(named name: String) throws -> VPhoneLaunchpadTemplate? {
        let templates = library.templates ?? []
        guard let id = try names.templateId(
            named: name,
            knownTemplateIds: templates.map(\.id)
        ) else { return nil }
        return templates.first { $0.id == id }
    }

    private static func state(_ state: VPhoneLaunchpadMachineLibrary.RunState) -> VPDVMState {
        switch state {
        case .stopped: .stopped
        case .running: .running
        case .busy: .busy
        }
    }

    // MARK: Listing

    func listVMs() async throws -> [VPDVM] {
        if library.templates == nil { await library.refreshTemplates() }

        var rows: [VPDVM] = []
        for machine in library.machines {
            // A machine being deleted, or one whose folder is gone, is not a
            // machine to allocate for. Both checks matter: `vm delete` runs as
            // a child process and the main actor suspends for the whole
            // removal, so this loop (the five-second refresh, vpcenter's
            // `GET /api/vms`, the start-page reconcile) can run while the
            // folder is gone or going. Writing a mapping then would create the
            // folder again and fail the removal with `ENOTEMPTY`, leaving an
            // orphan that held only `vpd-port-mapping.json` while the API
            // still answered 204.
            //
            // Why the library's in-memory mark instead of a lock file: the
            // only writer of a mapping is this process — `vphone-cli vm delete`
            // removes files and never writes one, and vpcenter/vpdc reach the
            // store over HTTP and the socket, both served from here. A shared
            // `flock` would have to be honoured by a child that does no mapping
            // I/O at all, and would leave a lock file next to every library, so
            // the mark closes the race that exists with much less. A second vpd
            // pointed at the same library is not covered by it; for that,
            // `VPDPortMappingStore.write` refuses a missing folder and the
            // removal lists the folder again when `rmdir` says it is not empty.
            guard !library.isBeingDeleted(machine.path) else { continue }
            guard FileManager.default.fileExists(atPath: machine.path.url.path) else { continue }
            // Every machine has a block, not only one that has already booted:
            // the mapping is the machine's own identity (a clone gets a fresh
            // one, disjoint from its source), and the window always has a port
            // to show. Allocation is idempotent and keeps a good file as is, so
            // this only fills in a machine that has none.
            _ = try? store.ensureMapping(forVM: machine.name)
            // The store finds the mapping in whichever root the machine lives.
            let mapping = try? store.currentMapping(forVM: machine.name)
            rows.append(VPDVM(
                name: machine.name,
                templateId: machine.template,
                isTemplate: false,
                state: Self.state(library.state(of: machine.path)),
                bundle: library.bundleVersion(for: machine.path),
                ports: mapping?.ports,
                guestIP: await guestIP(forVM: machine.name)
            ))
        }

        let templates = library.templates ?? []
        let display = names.displayNames(forTemplateIds: templates.map(\.id))
        for template in templates {
            rows.append(VPDVM(
                name: display[template.id] ?? template.id,
                templateId: template.id,
                isTemplate: true,
                state: .stopped, // a template never boots
                bundle: template.builtWithBundleVersion,
                ports: nil // a freeze drops the mapping
            ))
        }
        return rows
    }

    func vm(named name: String) async throws -> VPDVM? {
        try await listVMs().first { $0.name == name }
    }

    // MARK: Run

    func startVM(named name: String) async throws -> VPDVM {
        guard let machine = machine(named: name) else {
            throw VPDModelError.notFound(name: name)
        }
        // The service reserves before it calls here; this covers a service
        // built with `allocatePortsBeforeStart: false`.
        _ = try store.ensureMapping(forVM: machine.name)

        library.actionError = nil
        // A VM started by vpd (the start page, vpcenter or vpdc-web) is a
        // WebRTC-only customer: it does not need a VZVirtualMachineView on the
        // host. The Launchpad GUI calls `library.start` itself with the
        // default `headless: false`, so it keeps its window choice.
        await library.start(machine.path, headless: true)
        // `start` reports its failure through `actionError`, not by throwing.
        guard library.state(of: machine.path) == .running else {
            throw VPDModelError.unavailable(
                library.actionError?.localizedDescription ?? "The VM did not start."
            )
        }
        return try await requireVM(named: name)
    }

    /// Boots a machine only with a MAC (and address) that no running machine
    /// already uses.
    ///
    /// The clone path gives a new-identity clone an empty MAC, which
    /// `vphone-vm` turns into a fresh, saved one on the first boot. A machine
    /// copied outside that path can still carry the source's MAC, and two
    /// guests sharing one MAC on the shared NAT bridge make the bridge move its
    /// forwarding entry between their ports: each guest receives packets meant
    /// for the other and answers with a reset. SSH and Frida then die
    /// mid-session ("Connection closed by remote host") while the VM is alive
    /// and its relays are still bound. Clear the duplicate before this boot, so
    /// the guest comes up with an identity of its own.
    fileprivate func makeNetworkIdentityUnique(beforeStarting path: VPhoneLaunchpadMachinePath) async throws {
        guard let target = machine(named: path.name) else { return }
        let mac = target.network.macAddress.trimmingCharacters(in: .whitespaces).lowercased()
        let address = target.network.ipv4?.address.trimmingCharacters(in: .whitespaces) ?? ""

        var arguments: [String] = []
        var replaced: [String] = []
        if !mac.isEmpty, let clash = runningMachine(besides: target, where: {
            $0.network.macAddress.trimmingCharacters(in: .whitespaces).lowercased() == mac
        }) {
            // `auto` clears it; the boot then generates and saves a new one.
            arguments += ["--mac", "auto"]
            replaced.append("MAC \(mac) (also used by running \(clash.name))")
        }
        if !address.isEmpty, let clash = runningMachine(besides: target, where: {
            $0.network.ipv4?.address.trimmingCharacters(in: .whitespaces) == address
        }) {
            arguments += ["--ip", "dhcp"]
            replaced.append("fixed address \(address) (also used by running \(clash.name))")
        }
        guard !arguments.isEmpty else { return }

        print("[vpd] \(target.name): replacing \(replaced.joined(separator: ", ")) before boot")
        await library.configure(
            path,
            cpu: nil,
            memoryMB: nil,
            network: nil,
            bridgeInterface: nil,
            networkArguments: arguments,
        )
        await library.refresh()

        // Refuse to boot on the old identity if the edit did not land: a broken
        // address is worse than a start that says why it did not happen.
        guard let updated = machine(named: path.name) else { return }
        if arguments.contains("--mac"), updated.network.macAddress.lowercased() == mac {
            throw VPhoneLaunchpadError(
                String(localized: "Unable to give \(target.name) its own MAC address"),
                detail: library.actionError?.localizedDescription
                    ?? "`vm config --mac auto` did not change the machine's MAC.",
            )
        }
    }

    private func runningMachine(
        besides target: VPhoneLaunchpadMachine,
        where matches: (VPhoneLaunchpadMachine) -> Bool,
    ) -> VPhoneLaunchpadMachine? {
        library.machines.first { other in
            other.path != target.path
                && library.state(of: other.path) == .running
                && matches(other)
        }
    }

    func stopVM(named name: String) async throws -> VPDVM {
        guard let machine = machine(named: name) else {
            throw VPDModelError.notFound(name: name)
        }
        library.actionError = nil
        await library.stop(machine.path)
        guard library.state(of: machine.path) != .running else {
            throw VPDModelError.unavailable(
                library.actionError?.localizedDescription ?? "The VM did not stop."
            )
        }
        return try await requireVM(named: name)
    }

    func restartVM(named name: String) async throws -> VPDVM {
        // Full stop + start, so vpdc and vpweb restart with the VM.
        _ = try await stopVM(named: name)
        return try await startVM(named: name)
    }

    // MARK: Clone, rename, delete

    func cloneVM(named name: String, as newName: String) async throws -> VPDVM {
        try await cloneVM(named: name, as: newName, newIdentity: true)
    }

    func cloneVM(
        named name: String,
        as newName: String,
        newIdentity: Bool
    ) async throws -> VPDVM {
        guard VPDVMName.isValid(newName) else {
            throw VPDModelError.invalidName(name: newName)
        }
        // vpd's API is keyed by name and a machine is looked up across every
        // library root, so two roots holding one name would make the first
        // machine answer for both. Reject the duplicate where the name is
        // allocated (`409 nameInUse`); the directory stays there, but nothing
        // creates a second machine with that name.
        if try await vm(named: newName) != nil {
            throw VPDModelError.nameInUse(name: newName)
        }

        if let existing = machine(named: name) {
            library.actionError = nil
            await library.clone(existing.path, as: newName, newIdentity: newIdentity)
        } else if let template = try template(named: name) {
            library.actionError = nil
            // A template is not a device to copy: `vm create --template` always
            // mints a new identity, so `newIdentity` is not a choice here. The
            // clone of a template is always a new device, whatever the caller
            // asked for; the API documents that.
            try await library.cloneFromTemplate(template, as: newName)
        } else {
            throw VPDModelError.notFound(name: name)
        }

        await library.refresh()
        guard let created = machine(named: newName) else {
            throw VPDModelError.unavailable(
                library.actionError?.localizedDescription ?? "The clone was not created."
            )
        }
        // A plain `vm clone` copies the source's `vpd-port-mapping.json` into
        // the new folder, where it still names the source. That file is not the
        // clone's mapping, so drop it and allocate the clone's own block now:
        // its four ports exist (and are disjoint from the source's and every
        // other machine's) before the first start, instead of only when the
        // guest boots. The guest address follows the new MAC, so a new-identity
        // clone also arrives on a free address of its own.
        do {
            _ = try? store.clearInheritedMapping(forVM: created.name)
            _ = try store.ensureMapping(forVM: created.name)
        } catch {
            throw VPDModelError.unavailable(
                "The clone \(created.name) was created, but no free port block could be reserved: \(error)"
            )
        }
        return try await requireVM(named: created.name)
    }

    /// Deletes `name` and clones `source` onto it.
    ///
    /// The machine keeps its name and its port block: the block is read before
    /// the delete and put back after the clone, which is the whole point of the
    /// operation — a caller that already has the VM open on those four ports
    /// keeps opening it there. The clone's own block, allocated by `cloneVM`,
    /// is released by writing over it.
    ///
    /// If another machine took the block while the clone ran (a start or a
    /// clone that allocated in that window), the replacement keeps the block
    /// the clone was given instead: the alternative is a machine with no ports.
    func replaceVM(
        named name: String,
        with source: String,
        newIdentity: Bool
    ) async throws -> VPDVM {
        guard source != name else {
            throw VPDModelError.invalidName(name: source)
        }
        guard !name.hasPrefix(VPDVM.templateNamePrefix) else {
            throw VPDModelError.templateProtected(name: name)
        }
        guard machine(named: name) != nil else {
            if try template(named: name) != nil {
                throw VPDModelError.templateNotOperable(name: name, operation: "替换")
            }
            throw VPDModelError.notFound(name: name)
        }
        let saved = try? store.currentMapping(forVM: name)
        try await deleteVM(named: name)
        let created = try await cloneVM(named: source, as: name, newIdentity: newIdentity)
        if let saved {
            let mapping = VPDPortMapping(
                vm: name,
                basePort: saved.basePort,
                updatedAt: Date(),
                location: saved.location
            )
            if (try? store.adopt(mapping, forVM: name)) == nil {
                print("[vpd] replace: \(name) could not keep block \(saved.basePort); "
                    + "the replacement keeps the block it was cloned with")
            }
        }
        return try await requireVM(named: created.name)
    }

    func renameVM(named name: String, to newName: String) async throws -> VPDVM {
        guard VPDVMName.isValid(newName) else {
            throw VPDModelError.invalidName(name: newName)
        }
        // One name space across every root, for the same reason clone checks:
        // the model's lookups are by name. The router checks this too; the
        // model must not rely on that.
        if newName != name, try await vm(named: newName) != nil {
            throw VPDModelError.nameInUse(name: newName)
        }
        if let existing = machine(named: name) {
            library.actionError = nil
            await library.rename(existing.path, to: newName)
            guard machine(named: newName) != nil else {
                throw VPDModelError.unavailable(
                    library.actionError?.localizedDescription ?? "The rename failed."
                )
            }
            // The moved directory still carries a file that says
            // `"vm": "<old>"`. Rewriting it keeps the machine's four ports;
            // an unrewritten file would be rejected and reallocated.
            _ = try store.rename(name, to: newName)
            return try await requireVM(named: newName)
        }
        if let template = try template(named: name) {
            // The directory ID is content-derived and never changes; only the
            // registry entry does. Machines and templates share one name
            // space, so pass the machine names: a collision throws
            // `.nameInUse`, which the router answers 409.
            let machines = library.machines.map(\.name)
            try names.setDisplayName(newName, forTemplateId: template.id, inUse: machines)
            return try await requireVM(named: newName)
        }
        throw VPDModelError.notFound(name: name)
    }

    /// Deletes a machine. A running one is stopped first: the vpd API is the
    /// one surface where a caller cannot be expected to know it has to stop
    /// the machine itself, and a delete that silently did nothing is worse
    /// than one that also stops it. A machine that will not stop refuses with
    /// the stop's own error.
    ///
    /// Success means the machine's folder is gone, not that its row is: a
    /// folder left behind keeps the name and the four ports reserved, so it is
    /// an error, not a 204 (see the folder check at the end).
    func deleteVM(named name: String) async throws {
        if try template(named: name) != nil {
            // The HTTP layer answers 409 first; this is the model's own guard.
            throw VPDModelError.templateNotOperable(name: name, operation: "deleted")
        }
        guard let existing = machine(named: name) else {
            throw VPDModelError.notFound(name: name)
        }
        // `library.stop` asks the guest first and falls back to `vm stop`, the
        // same pair the Stop button uses.
        if library.state(of: existing.path) != .stopped {
            library.actionError = nil
            await library.stop(existing.path)
        }
        guard library.state(of: existing.path) == .stopped else {
            throw VPDModelError.unavailable(
                library.actionError?.localizedDescription
                    ?? "Unable to stop \(name) before deleting it."
            )
        }

        // While this runs the main actor is suspended on the child process, so
        // `listVMs` may run for the same machine; `library.delete` marks it as
        // being deleted for exactly that window. The reservation file goes
        // first, so the store is not holding a file it would rewrite inside a
        // folder the removal is walking; a failed delete only costs the block,
        // which `ensureMapping` hands out again on the next use.
        _ = try? VPDMappingExclusions.removeMapping(inMachineDirectory: existing.path.url)

        library.actionError = nil
        await library.delete(existing.path)
        // The machine row is not the evidence: `library.machines` only lists
        // folders with a `config.plist`, and `vm delete` can remove a folder
        // while leaving the list unchanged. The folder itself is what a delete
        // promises to remove — a leftover `vpd-port-mapping.json` folder would
        // otherwise keep the name and four ports reserved forever while this
        // answered success.
        guard !FileManager.default.fileExists(atPath: existing.path.url.path) else {
            throw VPDModelError.unavailable(
                library.actionError?.localizedDescription
                    ?? "The folder of \(name) is still there after the delete."
            )
        }
        // Drop the row now rather than at the next five-second refresh: the
        // name is free again, and nothing should offer the machine.
        await library.refresh()
    }

    // MARK: Ports and address

    func mappings() async throws -> [VPDPortMapping] {
        // One store, every root: the same view allocation uses.
        try store.allMappings()
    }

    func guestIP(forVM name: String) async -> String? {
        guard let machine = machine(named: name) else { return nil }
        if let address = machine.network.ipv4?.address, !address.isEmpty {
            return address // the manifest first
        }
        // DHCP fallback through the shared cache: one `vm leases` per TTL, not
        // one per machine per list.
        return await leaseCache.address(
            forMachine: machine.name,
            mac: machine.network.macAddress
        )
    }

    func health() async -> VPDHealthSnapshot {
        VPDHealthSnapshot(
            isHealthy: library.hasListed && library.listError == nil,
            detail: library.listError
        )
    }

    private func requireVM(named name: String) async throws -> VPDVM {
        guard let vm = try await vm(named: name) else {
            throw VPDModelError.notFound(name: name)
        }
        return vm
    }
}

// MARK: - The one library addition vpd needs

extension VPhoneLaunchpadMachineLibrary {
    /// A machine cloned from a template, with the bundle the template was
    /// built with. vpd's `clone` path for a template source.
    ///
    /// There is no `--new-identity` switch here: `vm create --template` always
    /// mints a new identity, because a template is not a device to copy. Only
    /// a machine-to-machine clone can choose, and `cloneVM` asks for a new
    /// identity there so both machines can run at once.
    ///
    /// `bundles` is private in the library, so this cannot live outside the
    /// module. The steps are the creation pipeline's: `vm create --template`
    /// with `--skip-first-boot`, then the clone is bound to the template's
    /// bundle so its first boot, and every later one, uses that version.
    func cloneFromTemplate(
        _ template: VPhoneLaunchpadTemplate,
        as newName: String,
        cpuCount: Int = 4,
        memoryMB: Int = 8192,
        network: String = "nat"
    ) async throws {
        guard let version = template.builtWithBundleVersion,
              let commandLine = coreBundles.commandLine(version: version)
        else {
            throw VPhoneLaunchpadError(
                String(localized: "The Core Bundle the template was built with is not installed."),
                detail: template.builtWithBundleVersion,
            )
        }
        let arguments = VPhoneLaunchpadTemplateCommands.clone(
            newName,
            template: template.id,
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            network: network,
        ) + ["--library-root", template.libraryRoot]
        let result = try await commandLine.run(arguments)
        guard result.succeeded else {
            throw VPhoneLaunchpadError(
                String(localized: "Unable to Create \(newName)"),
                detail: result.tail,
            )
        }
        await refresh()
        let target = Path(libraryRoot: template.libraryRoot, name: newName)
        // The template's own build recorded the guest environment and boot
        // chain it was frozen with, as `VPhoneLaunchpadCreationPipeline` does.
        var binding = VPhoneLaunchpadMachineBinding.load(target) ?? VPhoneLaunchpadMachineBinding(
            bundle: version,
            bootChain: template.bootChainBundleVersion,
            guestEnvironment: template.builtWithBundleVersion,
        )
        binding.bundle = version
        do {
            try bind(target, binding)
        } catch {
            actionError = VPhoneLaunchpadError(actionFailure: error)
        }
    }
}

// MARK: - Runtime

/// Per-host overrides for the parts of the port layout that are otherwise
/// fixed: vpd's HTTP port and the 7xxx band the VM blocks are handed out from.
///
/// Several Macs can sit behind one public address, each owning a different
/// band (host A 7000–7099, host B 7100–7199), and a host whose :6780 is taken
/// needs vpd somewhere else. Read once from
/// `~/Library/Application Support/vpd/runtime.json`:
///
///     {"httpPort": 7199, "vmPortRange": [7100, 7190]}
///
/// The file is optional. Without it, or with a value that cannot work, the
/// defaults below apply and the app behaves exactly as it did before.
struct VPhoneLaunchpadVPDRuntime {
    var httpPort: UInt16 = VPDDefaults.httpPort
    var portRange: ClosedRange<Int> = VPDPortMapping.defaultRange

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/vpd/runtime.json")

    static func load() -> VPhoneLaunchpadVPDRuntime {
        var runtime = VPhoneLaunchpadVPDRuntime()
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else { return runtime }

        if let port = object["httpPort"] as? Int, (1...65535).contains(port) {
            runtime.httpPort = UInt16(port)
        } else if object["httpPort"] != nil {
            print("[vpd] runtime.json: httpPort must be 1...65535; using \(runtime.httpPort)")
        }

        if let pair = object["vmPortRange"] as? [Int], pair.count == 2,
           pair[0] >= 1, pair[1] <= 65535,
           pair[1] - pair[0] + 1 >= VPDPortMapping.blockSize {
            runtime.portRange = pair[0]...pair[1]
        } else if object["vmPortRange"] != nil {
            print("[vpd] runtime.json: vmPortRange must be [lower, upper] holding a "
                + "\(VPDPortMapping.blockSize)-port block; using \(runtime.portRange)")
        }
        return runtime
    }
}

/// vpd, as one object the app model owns: the per-user LaunchAgent, the port
/// reservation store that every library root shares, the unix control socket
/// and the REST API and web UI on `VPhoneLaunchpadVPDRuntime.httpPort`.
///
/// Nothing here needs root and nothing shells out to `vphone-launchpad-cli`.
@MainActor
final class VPhoneLaunchpadVPD {
    let store: VPDPortMappingStore
    let model: VPDLaunchpadModel
    let service: VPDService
    private let library: VPhoneLaunchpadMachineLibrary
    private let publisher: VPDGuestIPPublisher
    /// The period the guest's address is re-read from the manifest and the
    /// DHCP leases. vpdc only hears about a change, never each poll.
    private static let guestIPInterval: Duration = .seconds(10)
    private var guestIPTask: Task<Void, Never>?
    private(set) var endpoints: VPDService.Endpoints?

    init(
        library: VPhoneLaunchpadMachineLibrary,
        leases: VPhoneLaunchpadLeases,
        roots: [URL]
    ) {
        self.library = library
        let runtime = VPhoneLaunchpadVPDRuntime.load()
        // One store for the whole app: vpd and the model see the same files.
        let store = VPDPortMappingStore(machinesRoots: roots, range: runtime.portRange)
        self.store = store
        model = VPDLaunchpadModel(library: library, leases: leases, store: store)

        var configuration = VPDService.Configuration(machinesRoots: roots)
        // The listener is on every interface; the defaults are unchanged and
        // the JSON + same-origin guard in `VPDHTTPRequestPolicy` stays on.
        configuration.http.port = runtime.httpPort
        // The allocation band follows the store so both sides agree on which
        // blocks exist (see `VPhoneLaunchpadVPDRuntime`).
        configuration.mappingRange = runtime.portRange
        // A stopped VM keeps its own WebRTC base port alive with a small start
        // page; the port is handed to vpweb on start and returned on stop.
        configuration.enableVMPortals = true
        configuration.portalReconcileInterval = .seconds(3)
        // A previous instance may still be releasing the HTTP port when the
        // LaunchAgent restarts the app. vpd retries the bind itself; this is
        // the one place that decides how long, and the app does not need a
        // second loop.
        configuration.retryPolicy = VPDService.RetryPolicy(
            attempts: 3,
            initialDelay: .seconds(1),
            maximumDelay: .seconds(5),
            multiplier: 3,
        )
        service = VPDService(model: model, mappingStore: store, configuration: configuration)
        publisher = service.makeGuestIPPublisher()
    }

    // MARK: LaunchAgent

    /// Writes (or refreshes) `~/Library/LaunchAgents/com.vphone.vpd.agent.plist`
    /// so the app comes back at login. Idempotent: `.unchanged` writes nothing.
    @discardableResult
    func installLaunchAgent(appBundleAt bundleURL: URL) -> VPDLaunchAgentInstaller.Outcome? {
        let installer = VPDLaunchAgentInstaller()
        do {
            let outcome = try installer.install(appBundleAt: bundleURL)
            if outcome == .updated {
                Self.reloadLaunchAgent(at: installer.plistURL)
            }
            return outcome
        } catch {
            // The app still works for this session without the agent.
            print("[vpd] LaunchAgent not installed: \(VPhoneLaunchpadError.message(for: error))")
            return nil
        }
    }

    /// `launchd` reads the directory at login, so a changed plist only takes
    /// effect in this session once it is booted out and back in. No root.
    private static func reloadLaunchAgent(at plistURL: URL) {
        let label = VPDLaunchAgentInstaller.label
        let domain = "gui/\(getuid())"
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "\(domain)/\(label)"]
        bootout.standardError = FileHandle.nullDevice
        bootout.standardOutput = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", domain, plistURL.path]
        bootstrap.standardError = FileHandle.nullDevice
        bootstrap.standardOutput = FileHandle.nullDevice
        try? bootstrap.run()
        bootstrap.waitUntilExit()
    }

    // MARK: Service

    /// Starts the socket and the listener, repairs overlapping reservations,
    /// and re-adopts the machines that are already running.
    ///
    /// `VPDService` retries a listener that cannot bind (see
    /// `configuration.retryPolicy`); if it still fails, nothing is left
    /// listening and the `willStart` hook must not stay behind, or a machine
    /// started from the window would reserve ports for a service that cannot
    /// answer for them.
    func start() async {
        service.setVPDCExitHandler { [weak self] vm, pid in
            // Called on the watcher's queue: hop for the model.
            Task { @MainActor in
                print("[vpd] vpdc for \(vm) exited (pid \(pid))")
                await self?.library.refresh()
                await self?.service.reconcilePortals()
            }
        }

        do {
            endpoints = try await service.start()
        } catch {
            // Both transports are already rolled back by `start()`.
            library.willStart = nil
            print("[vpd] not started: \(VPhoneLaunchpadError.message(for: error))")
            return
        }

        // Every start reserves the VM's four ports first, whether it came from
        // the REST API, the window or the control socket. No free block means
        // the start fails instead of booting a guest nothing can reach. The
        // hook goes on only once there is a listener to answer the block.
        library.willStart = { [store, weak self] machine in
            // The same base port is the stopped-VM start page. Free it before
            // the guest boots; vpweb binds it when vpdc comes up.
            self?.service.closePortal(forVM: machine.name)
            _ = try store.ensureMapping(forVM: machine.name)
            // Every start, from the REST API, the window or the control socket:
            // a guest that would share a MAC with a running guest must get its
            // own before it boots (see `makeNetworkIdentityUnique`).
            try await self?.model.makeNetworkIdentityUnique(beforeStarting: machine)
        }

        do {
            // Oldest file wins; spans every configured root. Before adoption,
            // so a re-adopted machine is told its final block.
            let resolutions = try service.resolvePortConflicts()
            for resolution in resolutions {
                print(
                    "[vpd] \(resolution.vm): moved \(resolution.previousBasePort) → \(resolution.mapping.basePort)"
                        + (resolution.keptBy.map { ", \($0) kept its block" } ?? ""),
                )
            }
        } catch {
            print("[vpd] port conflicts not resolved: \(VPhoneLaunchpadError.message(for: error))")
        }

        await adoptRunningMachines()
        startGuestIPPolling()
    }

    /// Every machine that is already up, so a restarted vpd (or app) hands its
    /// vpdc the same block it had.
    private func adoptRunningMachines() async {
        for machine in library.machines where library.state(of: machine.path) == .running {
            do {
                let mapping = try await service.adoptRunningVM(
                    named: machine.name,
                    guestIP: await model.guestIP(forVM: machine.name),
                )
                print("[vpd] adopted \(machine.name) on \(mapping.basePort)")
            } catch {
                print("[vpd] \(machine.name) not adopted: \(VPhoneLaunchpadError.message(for: error))")
            }
        }
    }

    /// Feeds the guest-address publisher: the manifest first, DHCP leases as
    /// fallback, deduplicated, so only a real change reaches vpdc.
    private func startGuestIPPolling() {
        guestIPTask?.cancel()
        guestIPTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for machine in library.machines where library.state(of: machine.path) != .stopped {
                    guard let address = await model.guestIP(forVM: machine.name) else { continue }
                    publisher.update(address, forVM: machine.name)
                }
                try? await Task.sleep(for: Self.guestIPInterval)
            }
        }
    }

    func stop() {
        guestIPTask?.cancel()
        guestIPTask = nil
        // No listener means no block to hand out: leave no hook that would
        // reserve ports for a service that cannot answer for them.
        library.willStart = nil
        service.stop()
        endpoints = nil
    }
}
