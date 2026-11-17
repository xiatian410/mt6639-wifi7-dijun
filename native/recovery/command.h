/*
 * Real bounded native subprocess runner for Android AArch64 and host macOS.
 *
 * Interface:
 *   static int mt_command(char *const argv[], int budget_ms, char *out, size_t cap)
 *
 * Returns:
 *   0: actual child exit 0 + complete bounded output
 *   1: nonzero exit (exit status != 0 or terminated by signal)
 * 124: timeout
 * 125: overflow (captured output exceeds cap - 1 bytes)
 * 126: system / exec error
 *
 * Kernel Limitation Explanation:
 * Under a normal schedulable kernel, SIGKILL terminates all user-space tasks
 * and waitpid reaps the child within milliseconds. However, if a task enters
 * TASK_UNINTERRUPTIBLE (D-state, e.g. blocked in unkillable driver I/O or stuck
 * NFS/filesystem RPC), even SIGKILL cannot force immediate termination until
 * the kernel sleep completes. Therefore, this runner provides a bounded reap
 * loop rather than an absolute, unachievable guarantee against kernel lockups.
 */
#ifndef MT6639_COMMAND_H
#define MT6639_COMMAND_H

#if defined(__GNUC__) || defined(__clang__)
#define MT_CMD_UNUSED __attribute__((unused))
#else
#define MT_CMD_UNUSED
#endif

#ifdef MT_ANDROID_AARCH64
#include "abi.h"

/* Explicit declarations for Android AArch64 ABI (no Bionic development headers) */
extern int execv(const char *, char *const []);
extern int dup2(int, int);
extern int setpgid(pid_t, pid_t);
extern int fcntl(int, int, ...);
extern int pipe(int *);
extern long syscall(long, ...);
extern pid_t getppid(void);

#ifndef F_GETFD
#define F_GETFD 1
#endif
#ifndef F_SETFD
#define F_SETFD 2
#endif
#ifndef FD_CLOEXEC
#define FD_CLOEXEC 1
#endif
#ifndef F_GETFL
#define F_GETFL 3
#endif
#ifndef F_SETFL
#define F_SETFL 4
#endif
#ifndef POLLERR
#define POLLERR 0x0008
#endif
#ifndef POLLHUP
#define POLLHUP 0x0010
#endif

#else
/* Host (macOS / Linux) standard libc includes */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

static MT_CMD_UNUSED long long mt_cmd_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (long long)ts.tv_sec * 1000 + (long long)(ts.tv_nsec / 1000000);
}

static MT_CMD_UNUSED int mt_cmd_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static MT_CMD_UNUSED int mt_cmd_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/*
 * Kill direct child and its process group while child is still unreaped,
 * preventing PID reuse by the kernel before group cleanup completes.
 */
static MT_CMD_UNUSED int mt_cmd_kill_group_and_reap(pid_t pid, int *status) {
    long long start = mt_cmd_now_ms();
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 5000000; /* 5 ms */

    /* Kill process group first, then direct child */
    kill(-pid, SIGKILL);
    kill(pid, SIGKILL);

    /* Bounded reap loop */
    for (;;) {
        pid_t got = waitpid(pid, status, WNOHANG);
        if (got == pid) return 0;
        if (got < 0 && errno != EINTR) return -1;

        long long now = mt_cmd_now_ms();
        if (now < 0 || (now - start) > 1000) {
            /* Bounded timeout reached under kernel uninterruptible conditions */
            return -1;
        }
        if ((now - start) > 100) {
            kill(-pid, SIGKILL);
            kill(pid, SIGKILL);
        }
        nanosleep(&ts, &ts);
    }
}

/*
 * Bounded wait for normal child exit after pipe EOF.
 */
static MT_CMD_UNUSED int mt_cmd_reap_normal(pid_t pid, int *status, long long deadline) {
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 2000000; /* 2 ms */

    for (;;) {
        pid_t got = waitpid(pid, status, WNOHANG);
        if (got == pid) return 0;
        if (got < 0 && errno != EINTR) return 126;

        long long now = mt_cmd_now_ms();
        if (now < 0 || now >= deadline) {
            mt_cmd_kill_group_and_reap(pid, status);
            return now < 0 ? 126 : 124;
        }
        nanosleep(&ts, &ts);
    }
}

static void mt_cmd_child_error(int fd) {
    int error = errno ? errno : 1;
    (void)write(fd, &error, sizeof error); _exit(127);
}
/* Caller must exclusively own child reaping and keep SIGCHLD at default;
 * auto-reap/external waiters invalidate the unreaped-PID ownership contract. */
static MT_CMD_UNUSED int mt_command_n(char *const argv[], int budget_ms, char *out, size_t cap, size_t *written) {
    if (written) *written = 0;
    int budget_valid = budget_ms >= 1 && budget_ms <= 20000;
#ifdef MT_UNIFIED_MODULE
    /* Only the fixed AP teardown barrier needs a longer bounded subprocess.
     * Keep every other command, and standalone/test builds, capped at 20s. */
    if (budget_ms == 400000 && argv && argv[0] && argv[1] &&
        !strcmp(argv[0], "/system/bin/sh") &&
        !strcmp(argv[1], "/data/adb/modules/mt6639-hotspot/bin/radio-teardown.sh") &&
        (!argv[2] || (!strcmp(argv[2], "check") && !argv[3]))) budget_valid = 1;
#endif
    if (!argv || !argv[0] || !out || cap < 2 || !budget_valid) {
        if (out && cap > 0) out[0] = '\0';
        return 126;
    }
    /* Absolute path check: argv[0] must start with '/' */
    if (argv[0][0] != '/') {
        out[0] = '\0';
        return 126;
    }

    out[0] = '\0';

    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};

    if (pipe(out_pipe) != 0) {
        return 126;
    }
    if (pipe(err_pipe) != 0) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        return 126;
    }

    if (mt_cmd_set_cloexec(out_pipe[0]) < 0 ||
        mt_cmd_set_cloexec(out_pipe[1]) < 0 ||
        mt_cmd_set_cloexec(err_pipe[0]) < 0 ||
        mt_cmd_set_cloexec(err_pipe[1]) < 0 ||
        mt_cmd_set_nonblock(out_pipe[0]) < 0 ||
        mt_cmd_set_nonblock(err_pipe[0]) < 0) {
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        return 126;
    }

    long long start_ms = mt_cmd_now_ms();
    if (start_ms < 0) {
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        return 126;
    }
    long long deadline_ms = start_ms + budget_ms;

#ifdef MT_ANDROID_AARCH64
    pid_t owner = getpid();
#endif
    pid_t pid = fork();
    if (pid < 0) {
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        return 126;
    }

    if (pid == 0) {
        /* Child: create own process group */
        if (setpgid(0, 0)) mt_cmd_child_error(err_pipe[1]);
#ifdef MT_ANDROID_AARCH64
        if (syscall(167, 1, SIGKILL, 0, 0, 0) || getppid() != owner)
            mt_cmd_child_error(err_pipe[1]);
#endif

        /* stdin -> /dev/null */
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) {
            if (devnull != 0) {
                if (dup2(devnull, 0) < 0) mt_cmd_child_error(err_pipe[1]);
                close(devnull);
            }
        } else {
            mt_cmd_child_error(err_pipe[1]);
        }

        /* stdout and stderr -> out_pipe[1] */
        if (dup2(out_pipe[1], 1) < 0 || dup2(out_pipe[1], 2) < 0)
            mt_cmd_child_error(err_pipe[1]);

        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);

        execv(argv[0], argv);

        /* Exec failure: communicate error to parent and exit */
        int exec_err = errno ? errno : 1;
        (void)write(err_pipe[1], &exec_err, sizeof(exec_err));
        close(err_pipe[1]);
        _exit(127);
    }

    /* Parent */
    (void)setpgid(pid, pid);
    close(out_pipe[1]);
    close(err_pipe[1]);

    size_t used = 0;
    int timed_out = 0;
    int overflowed = 0;
    int exec_failed = 0;
    int pipe_eof = 0;
    int err_eof = 0;

    while (!pipe_eof) {
        long long now_ms = mt_cmd_now_ms();
        if (now_ms < 0 || now_ms >= deadline_ms) {
            timed_out = 1;
            break;
        }
        long long remain = deadline_ms - now_ms;
        int poll_wait = (remain > 50) ? 50 : (int)remain;
        if (poll_wait <= 0) poll_wait = 1;

        struct pollfd pfds[2];
        int nfds = 0;
        int err_idx = -1;
        int out_idx = -1;

        if (!err_eof && err_pipe[0] >= 0) {
            err_idx = nfds++;
            pfds[err_idx].fd = err_pipe[0];
            pfds[err_idx].events = POLLIN;
            pfds[err_idx].revents = 0;
        }
        out_idx = nfds++;
        pfds[out_idx].fd = out_pipe[0];
        pfds[out_idx].events = POLLIN;
        pfds[out_idx].revents = 0;

        int prc = poll(pfds, nfds, poll_wait);
        if (prc < 0) {
            if (errno == EINTR) continue;
            exec_failed = 1;
            break;
        }

        /* Check exec failure pipe */
        if (err_idx >= 0 && (pfds[err_idx].revents & (POLLIN | POLLHUP | POLLERR))) {
            int err_val = 0;
            ssize_t en = read(err_pipe[0], &err_val, sizeof(err_val));
            if (en > 0) {
                exec_failed = 1;
                break;
            } else if (en == 0 || (en < 0 && errno != EINTR && errno != EAGAIN)) {
                err_eof = 1;
                close(err_pipe[0]);
                err_pipe[0] = -1;
            }
        }

        /* Check stdout/stderr capture pipe */
        if (pfds[out_idx].revents & (POLLIN | POLLHUP | POLLERR)) {
            for (;;) {
                char chunk[256];
                ssize_t n = read(out_pipe[0], chunk, sizeof(chunk));
                if (n > 0) {
                    size_t space = (used + 1 < cap) ? (cap - 1 - used) : 0;
                    if ((size_t)n <= space) {
                        size_t i;
                        for (i = 0; i < (size_t)n; i++) {
                            out[used + i] = chunk[i];
                        }
                        used += (size_t)n;
                        out[used] = '\0';
                    } else {
                        size_t i;
                        for (i = 0; i < space; i++) {
                            out[used + i] = chunk[i];
                        }
                        used += space;
                        out[used] = '\0';
                        overflowed = 1;
                        break;
                    }
                } else if (n == 0) {
                    pipe_eof = 1;
                    break;
                } else {
                    if (errno == EINTR) continue;
                    if (errno == EAGAIN) break;
                    exec_failed = 1;
                    break;
                }
            }
            if (overflowed || exec_failed) break;
        }
    }

    if (err_pipe[0] >= 0) close(err_pipe[0]);
    close(out_pipe[0]);

    int child_status = 0;
    if (written) *written = used;

    if (exec_failed) {
        mt_cmd_kill_group_and_reap(pid, &child_status);
        out[0] = '\0';
        if (written) *written = 0;
        return 126;
    }
    if (overflowed) {
        mt_cmd_kill_group_and_reap(pid, &child_status);
        return 125;
    }
    if (timed_out) {
        mt_cmd_kill_group_and_reap(pid, &child_status);
        return 124;
    }

    /* Normal completion: reap unreaped direct child */
    { int result = mt_cmd_reap_normal(pid, &child_status, deadline_ms);
      if (result) return result; }

    if (WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0) {
        return 0;
    } else {
        return 1;
    }
}
static inline int mt_command(char *const argv[], int budget_ms, char *out, size_t cap) {
    return mt_command_n(argv, budget_ms, out, cap, NULL);
}

#endif /* MT6639_COMMAND_H */
