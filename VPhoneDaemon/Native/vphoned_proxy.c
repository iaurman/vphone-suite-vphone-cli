#include "vphoned_session.h"

#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static volatile sig_atomic_t stopping = 0;
static const char *pending_update = "/var/root/Library/Caches/vphoned.api-v2.pending";
/// Where a worker says it is still serving. A file, not an inherited
/// descriptor: startup closes descriptors it did not open, and the number a
/// beat was given comes back as a socket the API opened later, so a beat on an
/// inherited descriptor fails with ENOTCONN and ends a healthy worker.
static const char *beat = "/var/root/Library/Caches/vphoned.beat";

static void request_stop(int signal_number) {
    stopping = signal_number;
}

// MARK: - Arguments

static int worker_fd(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc != 3 || strcmp(argv[1], "--io") != 0) return -1;
    char *end = NULL;
    long value = strtol(argv[2], &end, 10);
    if (!end || *end != '\0' || value < 3 || value > INT_MAX) return -1;
    return (int)value;
}

int vp_native_process_mode(void) {
    int argc = *_NSGetArgc();
    if (argc == 1) return 0;
    if (vp_session_arguments_present()) return 2;
    return worker_fd() >= 0 ? 1 : -1;
}

int vp_native_heartbeat_interval(void) {
    return VP_HEARTBEAT_INTERVAL_SECONDS;
}

int vp_native_heartbeat_beat(void) {
    // Counted here so a reader can tell one beat from the next without a
    // clock: the guest's clock is moved to the host's, and a time would move
    // with it.
    static unsigned long beats = 0;
    beats += 1;
    int descriptor = open(beat, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (descriptor < 0) return errno;
    char text[32];
    int length = snprintf(text, sizeof(text), "%lu\n", beats);
    ssize_t written = write(descriptor, text, (size_t)length);
    close(descriptor);
    return written == length ? 0 : errno;
}

/// The count the worker last wrote, or -1 when nothing is there to read.
static long beat_count(void) {
    int descriptor = open(beat, O_RDONLY);
    if (descriptor < 0) return -1;
    char text[32];
    ssize_t length = read(descriptor, text, sizeof(text) - 1);
    close(descriptor);
    if (length <= 0) return -1;
    text[length] = '\0';
    return strtol(text, NULL, 10);
}

static void *watch_proxy(void *context) {
    int fd = (int)(intptr_t)context;
    char byte;
    while (read(fd, &byte, 1) < 0 && errno == EINTR) {}
    // Only the proxy owns the write end. Its death must not leave an
    // unaccounted worker holding the VSOCK ports open.
    fprintf(stderr, "vphoned: the proxy closed its pipe; ending\n");
    _exit(0);
}

int vp_native_watch_proxy(void) {
    int fd = worker_fd();
    if (fd < 0) return -1;
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes) != 0) return -1;
    int result = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (result == 0) result = pthread_attr_setstacksize(&attributes, 64 * 1024);
    pthread_t thread;
    if (result == 0) result = pthread_create(&thread, &attributes, watch_proxy, (void *)(intptr_t)fd);
    pthread_attr_destroy(&attributes);
    return result == 0 ? 0 : -1;
}

static void pause_before_retry(void) {
    // A fixed delay, however often the worker fails: during boot the worker
    // can exit several times, and a growing backoff kept the API down for
    // tens of seconds after the guest was otherwise ready.
    struct timespec remaining = {.tv_sec = 1, .tv_nsec = 0};
    while (!stopping && nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

static void stop_worker(pid_t pid, int write_fd) {
    close(write_fd);
    kill(pid, SIGTERM);
    for (int tries = 0; tries < 30; tries++) {
        pid_t waited = waitpid(pid, NULL, WNOHANG);
        if (waited == pid || (waited < 0 && errno == ECHILD)) return;
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&delay, NULL);
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

// MARK: - Heartbeat

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

/// Waits for `child`. Returns 0 once it was reaped, 1 when the proxy itself was
/// asked to stop, 2 when the worker went silent for longer than the beats allow
/// and must be killed, and 3 when `waitpid` lost it: a lost child is not a
/// clean exit, and reporting it as one restarts launchd in a loop.
///
/// The beat is written by the worker's serving path, not by a thread of its
/// own, which is what makes silence mean something: a worker whose API is
/// wedged still holds port 1339 and still looks alive to launchd, and only a
/// missing beat says that it no longer works.
static int supervise(pid_t child, int *status) {
    double last = monotonic_seconds();
    // Startup runs before the API binds, so the first beat is allowed longer
    // than the ones that follow.
    double limit = VP_HEARTBEAT_GRACE_SECONDS;
    long seen = beat_count();
    for (;;) {
        pid_t waited = waitpid(child, status, WNOHANG);
        if (waited == child) return 0;
        if (waited < 0 && errno != EINTR) return 3;
        if (stopping) return 1;
        struct timespec delay = {.tv_sec = 1, .tv_nsec = 0};
        nanosleep(&delay, NULL);
        long current = beat_count();
        if (current >= 0 && current != seen) {
            seen = current;
            last = monotonic_seconds();
            limit = VP_HEARTBEAT_TIMEOUT_SECONDS;
        } else if (monotonic_seconds() - last > limit) {
            return 2;
        }
    }
}

/// Reaps a worker that was killed. A worker stuck inside the kernel may not die
/// at once, and a second worker started over it would find port 1339 taken, so
/// this waits for it, saying so once a minute.
static void reap_killed(pid_t child, int *status) {
    double last = monotonic_seconds();
    for (;;) {
        pid_t waited = waitpid(child, status, WNOHANG);
        if (waited == child) return;
        if (waited < 0 && errno != EINTR) return;
        double now = monotonic_seconds();
        if (now - last >= 60) {
            fprintf(stderr, "vphoned proxy: worker %d did not exit after SIGKILL; still waiting\n",
                    (int)child);
            last = now;
        }
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&delay, NULL);
    }
}

int vp_native_run_proxy(void) {
    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return 1;

    struct sigaction action = {.sa_handler = request_stop};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    while (!stopping) {
        int io_fds[2];
        if (pipe(io_fds) != 0) return 1;
        posix_spawn_file_actions_t file_actions;
        int error = vp_spawn_file_actions_init(&file_actions);
        if (error == 0) error = vp_spawn_file_actions_addclose(&file_actions, io_fds[1]);
        if (error != 0) {
            vp_spawn_file_actions_destroy(&file_actions);
            close(io_fds[0]);
            close(io_fds[1]);
            return 1;
        }

        char io_argument[24];
        snprintf(io_argument, sizeof(io_argument), "%d", io_fds[0]);
        char *arguments[] = {executable, "--io", io_argument, NULL};
        pid_t child = -1;
        // A beat left by the previous worker would otherwise pass for this one.
        unlink(beat);
        error = vp_spawn(&child, executable, &file_actions, NULL, arguments, environ);
        vp_spawn_file_actions_destroy(&file_actions);
        close(io_fds[0]);
        if (error != 0) {
            fprintf(stderr, "vphoned proxy: posix_spawn failed: %s\n", strerror(error));
            close(io_fds[1]);
            pause_before_retry();
            continue;
        }

        if (stopping) {
            stop_worker(child, io_fds[1]);
            break;
        }

        int status = 0;
        int outcome = supervise(child, &status);
        if (outcome == 3) {
            fprintf(stderr, "vphoned proxy: worker %d is no longer waitable: %s; retrying\n",
                    (int)child, strerror(errno));
            close(io_fds[1]);
            pause_before_retry();
            continue;
        }
        if (outcome == 1) {
            stop_worker(child, io_fds[1]);
            break;
        }
        if (outcome == 2) {
            fprintf(stderr,
                    "vphoned proxy: worker %d stopped beating for %d s; killing it and starting another\n",
                    (int)child, VP_HEARTBEAT_TIMEOUT_SECONDS);
            kill(child, SIGKILL);
            // Closing the io pipe also asks the worker's watch thread to end
            // it; that thread may be the only one left running.
            close(io_fds[1]);
            reap_killed(child, &status);
            pause_before_retry();
            continue;
        }
        close(io_fds[1]);
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            // agent.apply_update exits the worker after installing the
            // cached binary. launchd restarts us into that new image.
            fprintf(stderr, "vphoned proxy: worker %d exited cleanly; launchd starts the next image\n",
                    (int)child);
            return 0;
        }
        if (access(pending_update, F_OK) == 0) {
            // A cached worker failed before binding. The next launchd
            // start falls back to the bundled binary.
            return 1;
        }
        if (WIFSIGNALED(status)) {
            fprintf(stderr, "vphoned proxy: worker %d killed by signal %d; retrying\n",
                    (int)child, WTERMSIG(status));
        } else {
            fprintf(stderr, "vphoned proxy: worker %d exited with status %d; retrying\n",
                    (int)child, WEXITSTATUS(status));
        }
        pause_before_retry();
    }
    return 0;
}
