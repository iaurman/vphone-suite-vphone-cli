import Foundation

// launchd starts this on demand for the Mach service named in the embedded
// launchd plist, and SMJobBless has already checked that the client that
// installed it satisfies SMAuthorizedClients. Each connection checks that again.
// Every privileged verb also needs the caller to hold an administrator-only
// authorization right, written here as root before any connection arrives.

VPhoneLaunchpadHelperAuthorization.registerRight()
// This process is root, so it installs the boot-time AMFI allow itself: the
// next launch, and the next boot, then need no administrator. It writes only
// when something changed, so a start that has nothing to do touches nothing.
try? VPhoneLaunchpadHelperBootScript.install()
let delegate = VPhoneLaunchpadHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: VPhoneLaunchpadHelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
