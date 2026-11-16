// VPhoneExecShim.c -- repair the guest's loss of EXEC on file-backed vm_remap.
//
// WHY (measured; notes/G1-remap-trust-matrix.md in the solve-problem project):
// this guest's vm_remap returns KERN_SUCCESS, and reports *cur_prot/*max_prot
// with EXECUTE, while the mapping it actually produced is r--/r-- (maximum
// r--): mprotect(RX) -> EACCES, vm_protect(setmax,RX) -> KERN_PROTECTION_FAILURE,
// and the first instruction fetch there is an uncatchable
// EXC_BAD_ACCESS / SIGKILL with termination namespace CODESIGNING "Invalid Page".
//
// That is the gate behind .NET MAUI / Mono (its interpreter fills a trampoline
// page with a shared copy of one of the app's own __TEXT pages), Multi-OS
// Engine / ART (the OAT image), and Flutter AOT (the callback page) — see
// ../../Research/Guest/flutter_aot_remap_compatibility.md, whose narrowly
// Flutter-filtered repair this generalises.
//
// The trust matrix says the filter must be about the MAPPING, not about
// signatures: an ad-hoc-signed app page, an ad-hoc dylib, a dyld-shared-cache
// system library and the cache's own metadata page all behaved identically,
// while an anonymous remap kept EXEC and a plain data file's map never had
// EXEC to lose.  So the repair happens only when all of this holds:
//
//   * the caller's destination is code-signing-COW / file-backed (SM_COW), has
//     no EXEC now, and its source page is executable or may become so
//     (source protection or maximum has EXECUTE);
//   * same task on both sides, no overlap, and at most 64 MiB;
//   * the process is an app (its main executable is inside a .app bundle), so
//     no daemon, and in particular not launchd, ever runs this.
//
// The repair is the shape upstream already validated (FlutterRemapFix): replace
// the just-created, not-yet-published destination atomically with private
// anonymous memory at the same address (VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE, so
// there is no unmapped window), copy the page in, then vm_protect(RX) — an
// anonymous page made executable that way runs on this guest.  Never RWX at
// once, and no kernel or signing change.
//
// Kill switches (checked once, all guest-side, no rebuild):
//   env  VPHONE_EXECSHIM=0|off|no      env DISABLE_TWEAKS=1 / _SafeMode=1
//   file /usr/lib/vphone-exceshim-off  file <app bundle>/vphone-exceshim.off
// Logging is off unless <app bundle>/vphone-exceshim.log exists (marker) or
// env VPHONE_EXECSHIM_LOG=1; the log goes to $HOME/tmp/vphone-exceshim.log,
// else /private/var/tmp/vphone-exceshim.log.
// <app bundle>/vphone-exceshim.verbose (or VPHONE_EXECSHIM_LOG=2) also records
// every remap this shim is handed and the verdict, which is how the interaction
// with FlutterRemapFix was measured (notes/G1-universal-shim.md §7).

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// mach_vm.h is unsupported on the iOS SDK, so the one symbol this interposes is
// declared here. SystemHook's own reference to it is a plain bind, exactly like
// the Flutter remap fix's vm_remap reference, so dyld's interpose table resolves
// it to libsystem_kernel and the call below reaches the real implementation.
extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t,
                                   int, vm_map_read_t, mach_vm_address_t, boolean_t, vm_prot_t *,
                                   vm_prot_t *, vm_inherit_t);

#define VP_EXECSHIM_GLOBAL_OFF "/usr/lib/vphone-exceshim-off"
#define VP_EXECSHIM_APP_OFF    "/vphone-exceshim.off"
#define VP_EXECSHIM_APP_LOG    "/vphone-exceshim.log"
#define VP_EXECSHIM_APP_VERBOSE "/vphone-exceshim.verbose"
#define VP_EXECSHIM_MAX_REPAIR (64u << 20)

typedef struct {
    int disabled;
    int app;
    int log;
    int verbose;
    char logpath[PATH_MAX];
} vpExecShimState;

static vpExecShimState g_state;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static int vpExecShimEnvIs(const char *name, const char *value) {
    const char *found = getenv(name);
    return found && strcmp(found, value) == 0;
}

// <directory of the main executable> + suffix, into `out`.
static int vpExecShimExecutableSibling(char *out, size_t size, const char *suffix) {
    char path[PATH_MAX];
    uint32_t used = sizeof(path);
    if (_NSGetExecutablePath(path, &used) != 0 || !path[0])
        return 0;
    char resolved[PATH_MAX];
    if (!realpath(path, resolved))
        return 0;
    char *slash = strrchr(resolved, '/');
    if (!slash)
        return 0;
    *slash = '\0';
    int written = snprintf(out, size, "%s%s", resolved, suffix);
    return written > 0 && (size_t)written < size;
}

static int vpExecShimMarkerExists(const char *suffix) {
    char probe[PATH_MAX];
    return vpExecShimExecutableSibling(probe, sizeof(probe), suffix) && access(probe, F_OK) == 0;
}

static void vpExecShimInit(void) {
    if (vpExecShimEnvIs("VPHONE_EXECSHIM", "0") || vpExecShimEnvIs("VPHONE_EXECSHIM", "off") ||
        vpExecShimEnvIs("VPHONE_EXECSHIM", "no") || vpExecShimEnvIs("DISABLE_TWEAKS", "1") ||
        vpExecShimEnvIs("_SafeMode", "1") || vpExecShimEnvIs("_MSSafeMode", "1") ||
        access(VP_EXECSHIM_GLOBAL_OFF, F_OK) == 0 ||
        vpExecShimMarkerExists(VP_EXECSHIM_APP_OFF)) {
        g_state.disabled = 1;
        return;
    }
    // Apps only: the main executable lives inside a .app bundle. Daemons,
    // xpcproxy and launchd never satisfy this, so none of them runs the repair.
    char executable[PATH_MAX];
    uint32_t used = sizeof(executable);
    if (_NSGetExecutablePath(executable, &used) != 0 || !executable[0] ||
        !strstr(executable, ".app/"))
        return;
    g_state.app = 1;
    g_state.verbose = vpExecShimEnvIs("VPHONE_EXECSHIM_LOG", "2") ||
                      vpExecShimMarkerExists(VP_EXECSHIM_APP_VERBOSE);
    if (!g_state.verbose && !vpExecShimEnvIs("VPHONE_EXECSHIM_LOG", "1") &&
        !vpExecShimMarkerExists(VP_EXECSHIM_APP_LOG))
        return;
    const char *home = getenv("HOME");
    if (home && home[0])
        snprintf(g_state.logpath, sizeof(g_state.logpath), "%s/tmp/vphone-exceshim.log", home);
    else
        snprintf(g_state.logpath, sizeof(g_state.logpath), "/private/var/tmp/vphone-exceshim.log");
    g_state.log = 1;
}

static void vpExecShimLog(const char *format, ...) {
    if (!g_state.log)
        return;
    int fd = open(g_state.logpath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    char buffer[512];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);
    if (length > 0) {
        ssize_t written = write(fd, buffer, (size_t)(length < (int)sizeof(buffer) ? length : (int)sizeof(buffer)));
        (void)written;
    }
    close(fd);
}

static const char *vpExecShimProt(vm_prot_t protection) {
    static char buffers[8][4];
    static unsigned index;
    char *text = buffers[index++ & 7];
    text[0] = (protection & VM_PROT_READ) ? 'r' : '-';
    text[1] = (protection & VM_PROT_WRITE) ? 'w' : '-';
    text[2] = (protection & VM_PROT_EXECUTE) ? 'x' : '-';
    text[3] = '\0';
    return text;
}

static const char *vpExecShimShare(unsigned char shareMode) {
    switch (shareMode) {
        case SM_COW: return "COW";
        case SM_PRIVATE: return "PRIVATE";
        case SM_EMPTY: return "EMPTY";
        case SM_SHARED: return "SHARED";
        case SM_TRUESHARED: return "TRUESHARED";
        case SM_PRIVATE_ALIASED: return "PRIV_ALIASED";
        case SM_SHARED_ALIASED: return "SHARED_ALIASED";
        case SM_LARGE_PAGE: return "LARGE";
        default: return "?";
    }
}

// Present and maximum protection of the range containing `address`, plus the
// share mode of its mapping (SM_COW for a file-backed copy-on-write entry).
static int vpExecShimRegion(vm_address_t address, vm_prot_t *protection, vm_prot_t *maximum,
                            unsigned char *shareMode) {
    vm_address_t start = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t basic;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    memset(&basic, 0, sizeof(basic));
    if (vm_region_64(mach_task_self(), &start, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&basic, &count, &object) != KERN_SUCCESS) {
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        return 0;
    }
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (protection) *protection = basic.protection;
    if (maximum) *maximum = basic.max_protection;
    if (shareMode) {
        vm_address_t extendedStart = address;
        vm_size_t extendedSize = 0;
        vm_region_extended_info_data_t extended;
        mach_msg_type_number_t extendedCount = VM_REGION_EXTENDED_INFO_COUNT;
        mach_port_t extendedObject = MACH_PORT_NULL;
        memset(&extended, 0, sizeof(extended));
        *shareMode = SM_EMPTY;
        if (vm_region_64(mach_task_self(), &extendedStart, &extendedSize, VM_REGION_EXTENDED_INFO,
                         (vm_region_info_t)&extended, &extendedCount, &extendedObject) == KERN_SUCCESS)
            *shareMode = extended.share_mode;
        if (extendedObject != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), extendedObject);
    }
    return 1;
}

// Replace `target` with private anonymous memory at the same address, copy the
// source bytes in, and make it RX. The caller has not published the mapping
// yet, so VM_FLAGS_OVERWRITE is atomic and leaves no unmapped window.
static kern_return_t vpExecShimRepair(vm_address_t target, vm_address_t source, vm_size_t size,
                                      vm_inherit_t inheritance) {
    vm_address_t address = target;
    kern_return_t result = vm_allocate(mach_task_self(), &address, size,
                                       VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
    if (result != KERN_SUCCESS)
        return result;
    if (address != target) {
        vm_deallocate(mach_task_self(), address, size);
        return KERN_FAILURE;
    }
    // The fresh anonymous mapping defaults to VM_INHERIT_NONE; honour a caller
    // that asked for something else, as FlutterRemapFix does. A failure here is
    // not fatal for the code page itself.
    if (inheritance != VM_INHERIT_NONE)
        vm_inherit(mach_task_self(), target, size, inheritance);
    memcpy((void *)target, (const void *)source, size);
    result = vm_protect(mach_task_self(), target, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (result != KERN_SUCCESS)
        return result;
    vm_prot_t current = 0;
    vm_prot_t maximum = 0;
    if (!vpExecShimRegion(target, &current, &maximum, NULL) ||
        (current & VM_PROT_EXECUTE) == 0)
        return KERN_PROTECTION_FAILURE;
    return KERN_SUCCESS;
}

static void vpExecShimMaybeRepair(vm_map_t targetTask, vm_address_t *target, vm_size_t size,
                                  vm_map_read_t sourceTask, vm_address_t source, boolean_t copy,
                                  int flags, void *caller, vm_inherit_t inheritance,
                                  vm_prot_t *current, vm_prot_t *maximum) {
    pthread_once(&g_once, vpExecShimInit);
    // Nothing below costs anything unless logging or the repair is possible.
    if (!g_state.verbose && (g_state.disabled || !g_state.app))
        return;

    vm_address_t destination = target ? *target : 0;
    vm_prot_t destinationProtection = 0, destinationMaximum = 0;
    vm_prot_t sourceProtection = 0, sourceMaximum = 0;
    unsigned char shareMode = SM_EMPTY;
    const char *decision = "repair";
    int repair = 1;

    if (g_state.disabled) { decision = "disabled"; repair = 0; }
    else if (!g_state.app) { decision = "not-an-app-process"; repair = 0; }
    else if (!target || !destination || !source || !size) { decision = "bad-arguments"; repair = 0; }
    else if (size > VP_EXECSHIM_MAX_REPAIR) { decision = "too-big"; repair = 0; }
    else if (targetTask != mach_task_self() || sourceTask != mach_task_self()) { decision = "cross-task"; repair = 0; }
    else if ((destination <= source ? source - destination < size : destination - source < size))
        { decision = "overlaps-source"; repair = 0; }
    else if (!vpExecShimRegion(destination, &destinationProtection, &destinationMaximum, &shareMode))
        { decision = "no-destination-region"; repair = 0; }
    else if (shareMode != SM_COW) { decision = "not-file-backed"; repair = 0; }
    else if (destinationProtection & VM_PROT_EXECUTE) { decision = "already-executable"; repair = 0; }
    else if (!vpExecShimRegion(source, &sourceProtection, &sourceMaximum, NULL))
        { decision = "no-source-region"; repair = 0; }
    else if ((sourceProtection & VM_PROT_READ) == 0) { decision = "source-unreadable"; repair = 0; }
    else if (!((sourceProtection & VM_PROT_EXECUTE) || (sourceMaximum & VM_PROT_EXECUTE) ||
               (current && (*current & VM_PROT_EXECUTE)) ||
               (maximum && (*maximum & VM_PROT_EXECUTE))))
        { decision = "source-not-executable"; repair = 0; }

    if (g_state.verbose) {
        char callerImage[128] = "-";
        Dl_info info;
        if (caller && dladdr(caller, &info) && info.dli_fname) {
            const char *slash = strrchr(info.dli_fname, '/');
            snprintf(callerImage, sizeof(callerImage), "%s", slash ? slash + 1 : info.dli_fname);
        }
        vpExecShimLog("remap caller=%s size=%llu copy=%d flags=0x%x src=%p(%s/%s) "
                      "dst=%p(%s/%s share=%s) reported=%s/%s -> %s\n",
                      callerImage, (unsigned long long)size, (int)copy, flags, (void *)source,
                      vpExecShimProt(sourceProtection), vpExecShimProt(sourceMaximum),
                      (void *)destination, vpExecShimProt(destinationProtection),
                      vpExecShimProt(destinationMaximum), vpExecShimShare(shareMode),
                      vpExecShimProt(current ? *current : 0),
                      vpExecShimProt(maximum ? *maximum : 0), decision);
    }
    if (!repair)
        return;

    kern_return_t result = vpExecShimRepair(destination, source, size, inheritance);
    if (result != KERN_SUCCESS) {
        os_log_error(OS_LOG_DEFAULT, "vphone exec shim: remap repair failed: %{public}d", result);
        vpExecShimLog("repair failed dst=%p src=%p size=%llu kr=%d dst %s/%s src %s/%s\n",
                      (void *)destination, (void *)source, (unsigned long long)size, result,
                      vpExecShimProt(destinationProtection), vpExecShimProt(destinationMaximum),
                      vpExecShimProt(sourceProtection), vpExecShimProt(sourceMaximum));
        // Report the native result: the caller sees exactly what it would have
        // without this shim, and the copy at least keeps the bytes readable.
        return;
    }
    // The mapping is really RX now. Keep the maximum conservative but truthful.
    if (current) *current = (vm_prot_t)((*current | VM_PROT_READ | VM_PROT_EXECUTE) & ~VM_PROT_WRITE);
    if (maximum) *maximum = (vm_prot_t)(*maximum | VM_PROT_EXECUTE);
    vpExecShimLog("repaired dst=%p src=%p size=%llu dst was %s/%s -> r-x\n", (void *)destination,
                  (void *)source, (unsigned long long)size, vpExecShimProt(destinationProtection),
                  vpExecShimProt(destinationMaximum));
}

// dyld does not apply an image's own interposition to its imports, so this call
// reaches the real libsystem vm_remap and does not recurse.
static kern_return_t vpExecShimRemap(vm_map_t targetTask, vm_address_t *target, vm_size_t size,
                                     vm_address_t mask, int flags, vm_map_read_t sourceTask,
                                     vm_address_t source, boolean_t copy, vm_prot_t *current,
                                     vm_prot_t *maximum, vm_inherit_t inheritance) {
    void *caller = __builtin_return_address(0);
    kern_return_t result = vm_remap(targetTask, target, size, mask, flags, sourceTask, source,
                                    copy, current, maximum, inheritance);
    if (result == KERN_SUCCESS)
        vpExecShimMaybeRepair(targetTask, target, size, sourceTask, source, copy, flags, caller,
                              inheritance, current, maximum);
    return result;
}

static kern_return_t vpExecShimMachRemap(vm_map_t targetTask, mach_vm_address_t *target,
                                         mach_vm_size_t size, mach_vm_offset_t mask, int flags,
                                         vm_map_read_t sourceTask, mach_vm_address_t source,
                                         boolean_t copy, vm_prot_t *current, vm_prot_t *maximum,
                                         vm_inherit_t inheritance) {
    void *caller = __builtin_return_address(0);
    kern_return_t result = mach_vm_remap(targetTask, target, size, mask, flags, sourceTask, source,
                                         copy, current, maximum, inheritance);
    if (result == KERN_SUCCESS && target) {
        // vm_address_t/mach_vm_address_t are both 64-bit here, so the shared
        // repair path takes the mach address unchanged.
        vm_address_t address = (vm_address_t)*target;
        vpExecShimMaybeRepair(targetTask, &address, (vm_size_t)size, sourceTask,
                              (vm_address_t)source, copy, flags, caller, inheritance, current,
                              maximum);
    }
    return result;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} vpExecShimInterposition[] = {
    {(const void *)&vpExecShimRemap, (const void *)&vm_remap},
    {(const void *)&vpExecShimMachRemap, (const void *)&mach_vm_remap},
};
