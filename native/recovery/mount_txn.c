/* Fixed-target mount transaction executor; WLAN requires an explicit run mode.
 * Caller MUST preflight approved kernel/cfg/ko hashes and serialize ALL other
 * privileged mount writers in this namespace. flock coordinates this executor
 * only; Linux has no compare-unique-ID-and-umount atomic syscall.
 * Build: tcc -Wall -Werror -DMT_ANDROID_AARCH64 -o mount-txn mount_txn.c
 */
#include "abi.h"
#include "command.h"
#ifndef MT_ANDROID_AARCH64
#error Explicit_Android_AArch64_ABI_required
#endif
extern long syscall(long, ...);
extern int mkdirat(int, const char *, mode_t);
extern int dup2(int, int);
extern pid_t setsid(void);
extern int sscanf(const char *, const char *, ...);
extern void *memcpy(void *, const void *, size_t);
extern int memcmp(const void *, const void *, size_t);
extern ssize_t fgetxattr(int, const char *, void *, size_t);
extern int fsetxattr(int, const char *, const void *, size_t, int);
extern int fchmod(int, mode_t);
#define NR_UMOUNT2 39
#define NR_MOUNT 40
#define NR_STATX 291
#define NR_OPEN_TREE 428
#define NR_MOVE_MOUNT 429
#define NR_MOUNT_SETATTR 442
#define AT_EMPTY_PATH 0x1000
#define UNIQUE 0x4000
#define INO 0x100
#define MS_PRIVATE (1UL << 18)
#define MNT_DETACH 2
#define CLONE_TREE 1
#define MOVE_F_EMPTY 4
#define LIMIT 131072
/* Lifecycle guard only: production transactions retain the legacy path/schema
 * so the unified module can restore existing journals. No runtime override. */
#if defined(MT_UNIFIED_MODULE) && defined(MT_MOUNT_TXN_TEST)
#error Unified_and_test_profiles_are_mutually_exclusive
#elif defined(MT_UNIFIED_MODULE)
#define MODULE_NAME "mt6639-hotspot"
#else
#define MODULE_NAME "mt6639-6g"
#endif
#ifdef MT_MOUNT_TXN_TEST
#define PREFIX "/data/local/tmp/mt6639-native-"
#define SCHEMA "MT6639-TEST-v3"
#else
#define PREFIX "/data/adb/mt6639-6g/transactions/t-"
#define SCHEMA "MT6639-PROD-v3"
#endif
struct xtime { long long sec; unsigned int nsec; int reserved; };
struct sx {
    unsigned int mask, blksize; unsigned long long attributes;
    unsigned int nlink, uid, gid; unsigned short mode, spare0;
    unsigned long long ino, size, blocks, attributes_mask;
    struct xtime atime, btime, ctime, mtime;
    unsigned int rdev_major, rdev_minor, dev_major, dev_minor;
    unsigned long long mnt_id; unsigned int dio_mem_align, dio_offset_align;
    unsigned long long spare[12];
};
typedef char sx_size_check[sizeof(struct sx) == 256 ? 1 : -1];
struct id { unsigned long long mount, ino; unsigned int major, minor; };
struct journal {
    char schema[16], boot[37], ns[128];
    struct id directory, target, box_base, box_owned, stage_empty, backing, owned;
    int wlan, scan, wifi, country_override;
    unsigned long long checksum;
};
struct attr { unsigned long long set, clear, propagation, userns; };
struct tx {
    int dir, parent, lock, log, wlan_requested, persistent, module_fd;
    char path[256], target[320], boot[37], ns[128];
    struct id module;
    struct journal r;
};
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
static int equal(const struct id *a, const struct id *b) {
    return a->mount == b->mount && a->ino == b->ino &&
           a->major == b->major && a->minor == b->minor;
}
static int backing_equal(const struct id *a, const struct id *b) {
    return a->ino == b->ino && a->major == b->major && a->minor == b->minor;
}
static int identity(int fd, const char *name, struct id *out) {
    struct sx s = {0};
    if (syscall(NR_STATX, fd, name, AT_EMPTY_PATH, UNIQUE | INO, &s) ||
        (s.mask & (UNIQUE | INO)) != (UNIQUE | INO) || !s.mnt_id || !s.ino) return 0;
    out->mount = s.mnt_id; out->ino = s.ino;
    out->major = s.dev_major; out->minor = s.dev_minor;
    return 1;
}
static int safe_file(int fd) {
    struct stat s;
    return fd >= 0 && !fstat(fd, &s) && S_ISREG(s.st_mode) && s.st_uid == 0 &&
           s.st_nlink == 1 && (s.st_mode & 07777) == 0600;
}
static int private_dir(int fd) {
    struct stat s;
    return fd >= 0 && !fstat(fd, &s) && S_ISDIR(s.st_mode) && s.st_uid == 0 &&
           (s.st_mode & 07777) == 0700;
}
/* Walk every component without following symlinks; keep the final directory FD.
 * All ancestors must be root-owned and non-group/world-writable, except the
 * conventional shell-owned /data/local/tmp in the isolated test profile.
 * Operations use pinned directory FDs, so rename of that ancestor cannot
 * redirect a mount or detach. */
static int directory(const char *path) {
    char part[256]; const char *p = path; int fd, next; size_t n;
    struct stat s; int android_ancestor;
    if (*p++ != '/') return -1;
    fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    while (*p) {
        n = 0;
        while (p[n] && p[n] != '/') n++;
        if (!n || n >= sizeof part) { close(fd); return -1; }
        memcpy(part, p, n); part[n] = 0;
        next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next;
        if (fd < 0 || fstat(fd, &s) || !S_ISDIR(s.st_mode)) goto bad;
        android_ancestor = (size_t)(p - path) == 1 && !strcmp(part, "data") &&
                           s.st_uid == 1000 && (s.st_mode & 07777) == 0771;
#ifdef MT_MOUNT_TXN_TEST
        if ((size_t)(p - path) == 12 && !strcmp(part, "tmp") &&
            !strncmp(path, "/data/local/tmp/", 16) && s.st_uid == 2000 &&
            (s.st_mode & 07777) == 0771) android_ancestor = 1;
#endif
        if (!android_ancestor && (s.st_uid != 0 || (s.st_mode & 0022))) goto bad;
        p += n;
        if (*p == '/') { p++; if (!*p) goto bad; }
    }
    return fd;
bad:
    if (fd >= 0) close(fd);
    return -1;
}
static int valid_path(const char *p) {
    size_t n = strlen(PREFIX), i;
    if (strncmp(p, PREFIX, n) || !p[n] || strlen(p) >= 240) return 0;
    for (i = n; p[i]; i++)
        if (!((p[i] >= 'a' && p[i] <= 'z') || (p[i] >= 'A' && p[i] <= 'Z') ||
              (p[i] >= '0' && p[i] <= '9') || p[i] == '-' || p[i] == '_')) return 0;
    return 1;
}
static int allwrite(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) { ssize_t k = write(fd, p, n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return 0;
        p += k; n -= (size_t)k;
    }
    return 1;
}
static int bounded(int fd, void *buf, size_t cap, size_t *len) {
    size_t n = 0; char extra;
    while (n < cap) { ssize_t k = read(fd, (char *)buf + n, cap - n);
        if (k < 0 && errno == EINTR) continue;
        if (k < 0) return 0;
        if (!k) { *len = n; return 1; }
        n += (size_t)k;
    }
    if (read(fd, &extra, 1) != 0) return 0;
    *len = n; return 1;
}
static int context(char *boot, char *ns) {
    char b[38]; size_t n; ssize_t k;
    int fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return 0;
    k = bounded(fd, b, sizeof b, &n); close(fd);
    if (!k || n != 37 || b[36] != '\n') return 0;
    memcpy(boot, b, 36); boot[36] = 0;
    k = readlink("/proc/self/ns/mnt", ns, 127);
    if (k <= 0 || k >= 127) return 0;
    ns[k] = 0; return 1;
}
static long long now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return -1;
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
/* Binder is inaccessible directly in the KSU SELinux domain. Use only fixed
 * commands in shell domain; never interpolate a caller string into a shell. */
static int wlan_command(struct tx *t, const char *action, int budget, char *out, size_t cap, size_t *written) {
#ifdef MT_MOUNT_TXN_TEST
    char helper[100]; int fd, rc; struct stat s;
    fd = openat(t->dir, "wlan-helper", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 126;
    if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_uid || s.st_nlink != 1 ||
        (s.st_mode & 07777) != 0700) { close(fd); return 126; }
    snprintf(helper, sizeof helper, "/proc/self/fd/%d", fd);
    { char *args[] = {helper, (char *)action, t->path, NULL};
      rc = mt_command_n(args, budget, out, cap, written); }
    close(fd); return rc;
#else
    const char *cmd = NULL;
    char *args[] = {"/system/bin/runcon", "u:r:shell:s0", "/system/bin/sh", "-c", NULL, NULL};
    (void)t;
    if (!strcmp(action, "get-scan")) cmd = "exec /system/bin/cmd settings get global wifi_scan_always_enabled";
    else if (!strcmp(action, "get-wifi")) cmd = "exec /system/bin/cmd settings get global wifi_on";
    else if (!strcmp(action, "scan-off")) cmd = "exec /system/bin/cmd wifi set-scan-always-available disabled";
    else if (!strcmp(action, "scan-on")) cmd = "exec /system/bin/cmd wifi set-scan-always-available enabled";
    else if (!strcmp(action, "wifi-off")) cmd = "exec /system/bin/cmd wifi set-wifi-enabled disabled";
    else if (!strcmp(action, "wifi-on")) cmd = "exec /system/bin/cmd wifi set-wifi-enabled enabled";
    else if (!strcmp(action, "get-override")) cmd = "exec /system/bin/dumpsys wifi 2>/dev/null | /system/bin/grep -m 1 '^mOverrideCountryCode:'";
    else if (!strcmp(action, "get-country")) cmd = "exec /system/bin/cmd wifi get-country-code";
    else if (!strcmp(action, "country-us")) cmd = "exec /system/bin/cmd wifi force-country-code enabled US";
    else if (!strcmp(action, "country-cn")) cmd = "exec /system/bin/cmd wifi force-country-code enabled CN";
    else if (!strcmp(action, "country-auto")) cmd = "exec /system/bin/cmd wifi force-country-code disabled";
    else if (!strcmp(action, "scan-now")) cmd = "exec /system/bin/cmd wifi start-scan";
    else if (!strcmp(action, "get-link")) cmd = "exec /system/bin/cmd wifi status";
    else if (!strcmp(action, "get-ipv4")) cmd = "/system/bin/ip -4 -o addr show dev wlan0";
    if (!cmd) return 126;
    args[4] = (char *)cmd; return mt_command_n(args, budget, out, cap, written);
#endif
}
static int wlan_read(struct tx *t, const char *action) {
    char out[256]; size_t n = 0;
    if (wlan_command(t, action, 20000, out, sizeof out, &n)) return -1;
    if ((n != 1 && !(n == 2 && out[1] == '\n') &&
         !(n == 3 && out[1] == '\r' && out[2] == '\n')) ||
        (out[0] != '0' && out[0] != '1')) return -1;
    return out[0] - '0';
}
static int wlan_write(struct tx *t, const char *action, int budget) {
    char out[256]; return wlan_command(t, action, budget, out, sizeof out, NULL) == 0;
}
static int cycle_delay(int milliseconds) {
    long long start = now_ms(), current; struct timespec pause = {0, 20000000};
#ifdef MT_MOUNT_TXN_TEST
    milliseconds = 20;
#endif
    if (start < 0) return 0;
    do {
        nanosleep(&pause, NULL); current = now_ms();
        if (current < 0) return 0;
    } while (current - start < milliseconds);
    return 1;
}
static int contains(const char *h, size_t n, const char *needle) {
    size_t m = strlen(needle), i;
    if (n < m) return 0;
    for (i = 0; i + m <= n; i++) if (!memcmp(h + i, needle, m)) return 1;
    return 0;
}
static int country_parse(struct tx *t, int *override, char override_code[3],
                         char effective_code[3]) {
    static const char prefix[] = "mOverrideCountryCode: ";
    static const char effective[] = "Wifi Country Code = ";
    char out[256]; size_t n = 0, plen = sizeof prefix - 1;
    if (wlan_command(t, "get-override", 20000, out, sizeof out, &n)) return -1;
    if (n == plen + 5 && !memcmp(out, prefix, plen) &&
        !memcmp(out + plen, "null", 4) && out[plen + 4] == '\n') {
        *override = 0; override_code[0] = override_code[1] = override_code[2] = 0;
    }
    else if (n == plen + 3 && !memcmp(out, prefix, plen) &&
             out[plen] >= 'A' && out[plen] <= 'Z' &&
             out[plen + 1] >= 'A' && out[plen + 1] <= 'Z' && out[plen + 2] == '\n') {
        *override = 1; override_code[0] = out[plen]; override_code[1] = out[plen + 1];
        override_code[2] = 0;
    }
    else return -1;
    n = 0;
    plen = sizeof effective - 1;
    if (wlan_command(t, "get-country", 20000, out, sizeof out, &n) ||
        n != plen + 3 || memcmp(out, effective, plen) ||
        out[plen] < 'A' || out[plen] > 'Z' ||
        out[plen + 1] < 'A' || out[plen + 1] > 'Z' || out[plen + 2] != '\n') return -1;
    effective_code[0] = out[plen]; effective_code[1] = out[plen + 1];
    effective_code[2] = 0;
    return 0;
}
/* The stock device may have no override (auto country) or an explicit CN. Both
 * currently resolve the driver to CN. Any other baseline is outside this
 * version lock: reject before mounting rather than guess how to restore it. */
static int country_read(struct tx *t, int *override) {
    char override_code[3], code[3];
    if (country_parse(t, override, override_code, code) ||
        code[0] != 'C' || code[1] != 'N' ||
        (*override && (override_code[0] != 'C' || override_code[1] != 'N'))) return -1;
    return 0;
}
/* Business readiness is not implied by the wifi setting: both association and a
 * wlan0 IPv4 address must be observed. Failure to observe is a timeout, never a
 * claim that the radio is unusable. */
static int network_ready(struct tx *t) {
    char out[4096]; size_t n = 0;
    if (wlan_command(t, "get-link", 20000, out, sizeof out, &n) ||
        !contains(out, n, "Wifi is connected to")) return 0;
    n = 0;
    if (wlan_command(t, "get-ipv4", 20000, out, sizeof out, &n) ||
        !contains(out, n, " inet ")) return 0;
    return 1;
}
static int wait_network(struct tx *t, int budget) {
    long long start = now_ms(), current;
#ifdef MT_MOUNT_TXN_TEST
    struct timespec pause = {0, 20000000};
    budget = 1500;
#else
    /* cmd wifi is a binder round trip through a Java process; 1 s avoids
     * flooding the supplicant that is trying to associate. */
    struct timespec pause = {1, 0};
#endif
    if (start < 0) return 0;
    for (;;) {
        if (network_ready(t)) return 1;
        current = now_ms();
        if (current < 0 || current - start >= budget) return 0;
        nanosleep(&pause, NULL);
    }
}
static void event(struct tx *t, const char *stage, const char *outcome, const char *restoration) {
    struct id at = {0}; char b[700]; int n;
    identity(AT_FDCWD, t->target, &at);
    n = snprintf(b, sizeof b, "{\"event\":\"%s\",\"guardian_pid\":%d,\"operation\":\"%s\","
        "\"restoration\":\"%s\",\"target_unique_id\":%llu,\"dev_major\":%u,"
        "\"dev_minor\":%u,\"ino\":%llu,\"errno\":%d}\n", stage, getpid(), outcome,
        restoration, at.mount, at.major, at.minor, at.ino, errno);
    if (n > 0 && (size_t)n < sizeof b && t->log >= 0) {
        allwrite(t->log, b, (size_t)n); fsync(t->log);
    }
}
static int newfile(int dir, const char *name) {
    int fd = openat(dir, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (!safe_file(fd)) { if (fd >= 0) close(fd); return -1; }
    return fd;
}
static unsigned long long checksum(const struct journal *r) {
    const unsigned char *p = (const unsigned char *)r;
    size_t i, n = (size_t)((const char *)&r->checksum - (const char *)r);
    unsigned long long h = 14695981039346656037ULL;
    for (i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}
static int save(struct tx *t) {
    int fd, ok;
    t->r.checksum = checksum(&t->r);
    fd = newfile(t->dir, "prepared");
    if (fd < 0) return 0;
    ok = allwrite(fd, &t->r, sizeof t->r) && !fsync(fd);
    if (close(fd)) ok = 0;
    return ok && !fsync(t->dir);
}
static int load(struct tx *t) {
    static const char schema[16] = SCHEMA;
    size_t n; int fd, ok; struct journal r = {0}; struct id d;
    fd = openat(t->dir, "prepared", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (!safe_file(fd)) { if (fd >= 0) close(fd); return 0; }
    ok = bounded(fd, &r, sizeof r, &n); close(fd);
    if (!ok || n != sizeof r || r.checksum != checksum(&r) ||
        memcmp(r.schema, schema, sizeof schema)) return 0;
    if (memcmp(r.boot, t->boot, sizeof r.boot) || memcmp(r.ns, t->ns, sizeof r.ns) ||
        !identity(t->dir, "", &d) || !equal(&d, &r.directory) ||
        !r.owned.mount || !r.box_owned.mount || r.owned.mount == r.target.mount ||
        r.owned.mount == r.box_owned.mount || r.box_owned.mount == r.box_base.mount ||
        r.owned.mount == r.backing.mount || !backing_equal(&r.owned, &r.backing) ||
        !backing_equal(&r.box_owned, &r.box_base) ||
        r.stage_empty.mount != r.box_owned.mount || (r.wlan != 0 && r.wlan != 1) ||
        (r.wlan && ((r.scan != 0 && r.scan != 1) || r.wifi != 1 ||
                    (r.country_override != 0 && r.country_override != 1)))) return 0;
    t->r = r; return 1;
}
static int setup(struct tx *t, const char *path) {
    t->dir = t->parent = t->lock = t->log = -1;
    if (geteuid() || !valid_path(path) || !context(t->boot, t->ns)) return 0;
    snprintf(t->path, sizeof t->path, "%s", path);
    t->dir = directory(path);
    if (!private_dir(t->dir)) return 0;
#ifdef MT_MOUNT_TXN_TEST
    t->parent = directory(path);
    snprintf(t->target, sizeof t->target, "/proc/self/fd/%d/target", t->parent);
#else
    t->parent = directory("/odm/firmware");
    snprintf(t->target, sizeof t->target, "/proc/self/fd/%d/wifi.cfg", t->parent);
#endif
    return t->parent >= 0;
}
static int locks(struct tx *t, int create) {
    struct stat st;
    if (flock(t->parent, LOCK_EX | LOCK_NB)) return 0;
    t->lock = openat(t->dir, "guardlock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (t->lock < 0 && errno == ENOENT && create) t->lock = newfile(t->dir, "guardlock");
    return safe_file(t->lock) && !fstat(t->lock, &st) && !st.st_size &&
           !flock(t->lock, LOCK_EX | LOCK_NB);
}
static int snapshot(struct tx *t, struct id *box, struct id *stage, struct id *at) {
    return identity(t->dir, "stagebox", box) && identity(t->dir, "stagebox/stage", stage) &&
           identity(AT_FDCWD, t->target, at);
}
/* Snapshot the complete accepted state before any detach. Never infer ownership
 * from candidate bytes, backing inode alone, or missing visible candidate. */
static int recover_mount(struct tx *t) {
    struct id box, stage, at, empty_base, backing; const char *owned = NULL;
    char boxpath[320], stagepath[340]; int had = 0;
    if (!load(t) || !snapshot(t, &box, &stage, &at) ||
        !identity(t->dir, "candidate", &backing) || !equal(&backing, &t->r.backing)) return 4;
    empty_base = t->r.stage_empty; empty_base.mount = t->r.box_base.mount;
    if (equal(&box, &t->r.box_base)) {
        return equal(&stage, &empty_base) && equal(&at, &t->r.target) ? 5 : 4;
    }
    if (!equal(&box, &t->r.box_owned)) return 4;
    if (equal(&at, &t->r.owned) && equal(&stage, &t->r.stage_empty)) owned = t->target;
    else if (equal(&at, &t->r.target) && equal(&stage, &t->r.owned)) {
        snprintf(stagepath, sizeof stagepath, "/proc/self/fd/%d/stagebox/stage", t->dir); owned = stagepath;
    } else if (!equal(&at, &t->r.target) || !equal(&stage, &t->r.stage_empty)) return 4;
    if (owned) {
        struct id check;
        if (!identity(AT_FDCWD, owned, &check) || !equal(&check, &t->r.owned) ||
            syscall(NR_UMOUNT2, owned, MNT_DETACH)) return 4;
        had = 1;
    }
    if (!snapshot(t, &box, &stage, &at) || !equal(&box, &t->r.box_owned) ||
        !equal(&stage, &t->r.stage_empty) || !equal(&at, &t->r.target)) return 4;
    snprintf(boxpath, sizeof boxpath, "/proc/self/fd/%d/stagebox", t->dir);
    if (syscall(NR_UMOUNT2, boxpath, MNT_DETACH) || !snapshot(t, &box, &stage, &at) ||
        !equal(&box, &t->r.box_base) || !equal(&stage, &empty_base) ||
        !equal(&at, &t->r.target)) return 4;
    (void)had; return 0;
}
static int marker_state(struct tx *t, const char *name, const char *text) {
    char b[32]; size_t n; int fd, ok;
    fd = openat(t->dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    if (!safe_file(fd)) { close(fd); return -1; }
    ok = bounded(fd, b, sizeof b, &n) && n == strlen(text) && !memcmp(b, text, n);
    close(fd); return ok ? 1 : -1;
}
static int marker_write(struct tx *t, const char *name, const char *text) {
    int fd = newfile(t->dir, name), ok;
    if (fd < 0) return 0;
    ok = allwrite(fd, text, strlen(text)) && !fsync(fd) && !fsync(t->dir);
    if (close(fd)) ok = 0;
    return ok;
}
#ifdef MT_UNIFIED_MODULE
static int module_open(struct tx *t);
/* Stop first, then lock out new AP starts and recheck idle UNDER that lock.
 * Return the pinned action.lock FD; the caller holds it across all restoration.
 * The fixed helper verifies module integrity. Failures leave authority intact. */
static int unified_recovery_barrier(struct tx *t) {
    char output[4096]; struct id before, after; struct stat s;
    int module = -1, current = -1, work = -1, lock = -1;
    char *const stop_argv[] = {"/system/bin/sh",
        "/data/adb/modules/mt6639-hotspot/bin/radio-teardown.sh", NULL};
    char *const check_argv[] = {"/system/bin/sh",
        "/data/adb/modules/mt6639-hotspot/bin/radio-teardown.sh", "check", NULL};
    module = module_open(t);
    if (module < 0 || !identity(module, "", &before) ||
        (t->persistent && !equal(&before, &t->module)) ||
        mt_command(stop_argv, 400000, output, sizeof output) != 0) goto bad;
    work = directory("/data/adb/mt6639-hotspot");
    if (!private_dir(work)) goto bad;
    lock = openat(work, "action.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (!safe_file(lock) || fstat(lock, &s) || s.st_size || flock(lock, LOCK_EX | LOCK_NB)) goto bad;
    current = module_open(t);
    if (current < 0 || !identity(current, "", &after) || !equal(&before, &after) ||
        mt_command(check_argv, 400000, output, sizeof output) != 0) goto bad;
    close(current); current = module_open(t);
    if (current < 0 || !identity(current, "", &after) || !equal(&before, &after)) goto bad;
    close(current); close(module); close(work); return lock;
bad:
    if (current >= 0) close(current);
    if (module >= 0) close(module);
    if (work >= 0) close(work);
    if (lock >= 0) close(lock);
    return -1;
}
#endif
/* WLAN restoration runs only AFTER mount recovery succeeds. A foreign overlay
 * must block WLAN restoration against somebody else's config. */
static int recover_after_barrier(struct tx *t) {
    int rc = recover_mount(t), intent, done, netdone, ok, scan, wifi;
    if ((rc != 0 && rc != 5) || !t->r.wlan) return rc;
    intent = marker_state(t, "wlan-intent", "intent\n");
    done = marker_state(t, "wlan-restored", "restored\n");
    netdone = marker_state(t, "wlan-net-ready", "ready\n");
    if (intent < 0 || done < 0 || netdone < 0 || (!intent && (done || netdone))) return 6;
    if (!intent) return rc; /* No radio side effect could have started. */
    if (!done) {
        ok = wlan_write(t, "scan-off", 20000);
        if (!wlan_write(t, "country-cn", 20000)) ok = 0;
        if (!wlan_write(t, "wifi-off", 20000)) ok = 0;
        if (!cycle_delay(8000)) ok = 0;
        if (!wlan_write(t, "wifi-on", 20000)) ok = 0;
        if (!cycle_delay(12000)) ok = 0;
        if (!t->r.country_override && !wlan_write(t, "country-auto", 20000)) ok = 0;
        /* Scan stays off while the radio is down, but must be back before
         * waiting for association: a supplicant that cannot scan otherwise
         * only finds the AP after an unrelated later scan. */
        if (!wlan_write(t, t->r.scan ? "scan-on" : "scan-off", 20000)) ok = 0;
        if (!wlan_write(t, "scan-now", 20000)) ok = 0;
        /* Keep failed command status even if later readback happens to match. */
        scan = wlan_read(t, "get-scan"); wifi = wlan_read(t, "get-wifi");
        if (!ok || scan != t->r.scan || wifi != t->r.wifi ||
            !marker_write(t, "wlan-restored", "restored\n")) return 6;
    }
    /* Association readiness is a separate durable result. A completed restore
     * remains idempotent even if the user later disconnects Wi-Fi. */
    if (netdone) return rc;
    if (wait_network(t, 45000)) {
        return marker_write(t, "wlan-net-ready", "ready\n") ? rc : 6;
    }
    return rc == 0 || rc == 5 ? 7 : rc;
}
/* Both explicit recovery and guardian exit enter here. Never release the AP
 * action lock between idle verification and the final restoration result. */
static int recover(struct tx *t) {
#ifdef MT_UNIFIED_MODULE
    int lock = unified_recovery_barrier(t), rc;
    if (lock < 0) return 4; /* blocked; retain all journals */
    rc = recover_after_barrier(t);
    close(lock); return rc;
#else
    return recover_after_barrier(t);
#endif
}
static int candidate(struct tx *t) {
    static char bytes[LIMIT]; const char *old = "DisallowBand6G 1";
    size_t n, i, len = strlen(old), found = 0, pos = 0; int src, dst, ok;
    struct stat s; struct id a, b;
    src = open(t->target, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (src < 0) return 0;
    ok = !fstat(src, &s) && S_ISREG(s.st_mode) && s.st_uid == 0 && s.st_size > 0 &&
         s.st_size <= LIMIT && identity(src, "", &a) && equal(&a, &t->r.target) &&
         bounded(src, bytes, sizeof bytes, &n) && n == (size_t)s.st_size;
    if (!ok) { close(src); return 0; }
    for (i = 0; i + len <= n; i++) {
        if ((i == 0 || bytes[i - 1] == '\n') && !memcmp(bytes + i, old, len) &&
            (i + len == n || bytes[i + len] == '\n' ||
             (bytes[i + len] == '\r' && (i + len + 1 == n || bytes[i + len + 1] == '\n')))) {
            found++; pos = i + len - 1;
        }
    }
    if (found != 1) { close(src); return 0; }
    bytes[pos] = '0'; dst = newfile(t->dir, "candidate");
    if (dst < 0) { close(src); return 0; }
#ifndef MT_MOUNT_TXN_TEST
    /* The firmware consumer needs the original DAC/SELinux read access. Never
     * edit policy or relabel the stock file; label only this new candidate. */
    { char label[256]; ssize_t size = fgetxattr(src, "security.selinux", label, sizeof label);
      if (size <= 0 || size >= (ssize_t)sizeof label ||
          fsetxattr(dst, "security.selinux", label, (size_t)size, 0) ||
          (s.st_mode & 0022) || fchmod(dst, s.st_mode & 0777)) {
          close(src); close(dst); return 0;
      }
    }
#endif
    close(src);
    ok = allwrite(dst, bytes, n) && !fsync(dst) && identity(dst, "", &t->r.backing) &&
         identity(AT_FDCWD, t->target, &b) && equal(&b, &t->r.target);
    if (close(dst)) ok = 0;
    return ok;
}
static int prepare(struct tx *t, int *container, int *cover) {
    int stage, box; struct id parent; struct attr ro = {1, 0, 0, 0};
    snprintf(t->r.schema, sizeof t->r.schema, "%s", SCHEMA);
    memcpy(t->r.boot, t->boot, sizeof t->boot); memcpy(t->r.ns, t->ns, sizeof t->ns);
    t->r.wlan = t->wlan_requested;
    if (t->r.wlan) {
        t->r.scan = wlan_read(t, "get-scan");
        if (t->r.scan != 0 && t->r.scan != 1) return 0;
        t->r.wifi = wlan_read(t, "get-wifi");
        if (t->r.wifi != 1) return 0;
        if (country_read(t, &t->r.country_override)) return 0;
    }
    if (!identity(t->dir, "", &t->r.directory) ||
        !identity(t->parent, "", &parent) || !identity(AT_FDCWD, t->target, &t->r.target) ||
        parent.mount != t->r.target.mount || !candidate(t) || mkdirat(t->dir, "stagebox", 0700)) return 0;
    box = openat(t->dir, "stagebox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!private_dir(box)) { if (box >= 0) close(box); return 0; }
    stage = newfile(box, "stage");
    if (stage < 0) { close(box); return 0; }
    if (fsync(stage) || close(stage) || fsync(box)) { close(box); return 0; }
    close(box);
    if (!identity(t->dir, "stagebox", &t->r.box_base) ||
        !identity(t->dir, "stagebox/stage", &t->r.stage_empty) ||
        t->r.box_base.mount != t->r.directory.mount ||
        t->r.stage_empty.mount != t->r.box_base.mount) return 0;
    *container = (int)syscall(NR_OPEN_TREE, t->dir, "stagebox", CLONE_TREE | O_CLOEXEC);
    *cover = (int)syscall(NR_OPEN_TREE, t->dir, "candidate", CLONE_TREE | O_CLOEXEC);
    if (*container < 0 || *cover < 0 || !identity(*container, "", &t->r.box_owned) ||
        !identity(*cover, "", &t->r.owned) ||
        t->r.box_owned.mount == t->r.box_base.mount ||
        t->r.owned.mount == t->r.backing.mount ||
        t->r.owned.mount == t->r.box_owned.mount ||
        t->r.owned.mount == t->r.target.mount ||
        !backing_equal(&t->r.owned, &t->r.backing) ||
        !backing_equal(&t->r.box_owned, &t->r.box_base) ||
        syscall(NR_MOUNT_SETATTR, *cover, "", AT_EMPTY_PATH, &ro, sizeof ro)) return 0;
    t->r.stage_empty.mount = t->r.box_owned.mount;
    return !fsync(t->dir) && save(t);
}
static int cancel_state(struct tx *t) {
    char b[8]; size_t n; int fd, ok;
    fd = openat(t->dir, "cancel", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    if (!safe_file(fd)) { close(fd); return -1; }
    ok = bounded(fd, b, sizeof b, &n) && n == 7 && !memcmp(b, "cancel\n", 7);
    close(fd); return ok ? 1 : -1;
}
/* KSU may use root0777 for modules. Its strict root0700 parent is the access
 * barrier; allow only that one fixed intermediate component to be writable.
 * General directory() rules and the final module's rules remain strict. */
static int module_below(int barrier) {
    int modules, fd, missing; struct stat s;
    if (!private_dir(barrier)) return -1;
    modules = openat(barrier, "modules", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (modules < 0) return errno == ENOENT ? -2 : -1;
    if (fstat(modules, &s) || !S_ISDIR(s.st_mode) || s.st_uid) {
        close(modules); return -1;
    }
    fd = openat(modules, MODULE_NAME, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { missing = errno == ENOENT; close(modules); return missing ? -2 : -1; }
    close(modules);
    if (fstat(fd, &s) || !S_ISDIR(s.st_mode) || s.st_uid || (s.st_mode & 0022)) {
        close(fd); return -1;
    }
    return fd;
}
/* The production lifecycle source is fixed, never supplied by argv/env/config.
 * Keep its initial FD open so an unlinked directory's inode cannot be reused
 * to impersonate this boot's module. Test barrier is fixture-owned only. */
static int module_open(struct tx *t) {
    int barrier, fd;
#ifdef MT_MOUNT_TXN_TEST
    barrier = openat(t->dir, "module-control", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (barrier < 0) return errno == ENOENT ? -2 : -1;
#else
    (void)t; barrier = directory("/data/adb");
    if (barrier < 0) return -1;
#endif
    fd = module_below(barrier); close(barrier); return fd;
}
/* 0 enabled, 1 disable, 2 remove, 3 directory missing/replaced, -1 read error.
 * Any marker object stops the hold; malformed objects cannot hide a request. */
static int module_state(struct tx *t) {
    int fd, marker, i, state = 0; struct id at;
    static const char *names[] = {"disable", "remove"};
    fd = module_open(t);
    if (fd < 0) return fd == -2 ? 3 : -1;
    if (!identity(fd, "", &at)) state = -1;
    else if (!equal(&at, &t->module)) state = 3;
    for (i = 0; !state && i < 2; i++) {
        marker = openat(fd, names[i], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (marker >= 0) { close(marker); state = i + 1; }
        else if (errno != ENOENT) state = -1;
    }
    close(fd); return state;
}
static int inspect_module(const char *path) {
    struct tx t = {0}; int state;
#ifdef MT_MOUNT_TXN_TEST
    if (!path || !valid_path(path)) return 64;
    t.dir = directory(path);
    if (!private_dir(t.dir)) { if (t.dir >= 0) close(t.dir); return 64; }
#else
    (void)path;
#endif
    t.module_fd = module_open(&t);
    if (t.module_fd < 0) state = t.module_fd == -2 ? 3 : -1;
    else {
        state = identity(t.module_fd, "", &t.module) ? module_state(&t) : -1;
        close(t.module_fd);
    }
#ifdef MT_MOUNT_TXN_TEST
    close(t.dir);
#endif
    printf("{\"status\":\"%s\",\"module_state\":\"%s\",\"read_only\":true}\n",
        state == 0 ? "module_control_available" : "module_control_unavailable",
        state == 0 ? "enabled" : (state == 1 ? "disabled" : (state == 2 ? "removed" :
        (state == 3 ? "directory_changed" : "invalid"))));
    return state == 0 ? 0 : 4;
}
static int wait_hold(struct tx *t, long long deadline) {
    struct timespec pause = {0, 20000000}; int c; long long current;
    while (!stopping) {
        c = cancel_state(t); if (c) return c > 0 ? 1 : -1;
        current = now_ms(); if (current < 0) return -1;
        if (current >= deadline) return 0;
        nanosleep(&pause, NULL);
    }
    return 1;
}
static int wait_persistent(struct tx *t) {
    struct timespec pause = {0, 500000000}; int c;
    while (!stopping) {
        c = cancel_state(t); if (c) return c > 0 ? 1 : -1;
        c = module_state(t); if (c) return c < 0 ? -2 : c + 1;
        nanosleep(&pause, NULL);
    }
    return 1;
}
static int mark(struct tx *t, const char *stage, const char *fault, long long deadline, int *handshake) {
    event(t, stage, "pending", "pending");
#ifdef MT_MOUNT_TXN_TEST
    if (!strcmp(stage, fault)) {
        if (*handshake >= 0) {
            allwrite(*handshake, "T", 1); close(*handshake); *handshake = -1;
        }
        wait_hold(t, deadline); return 0;
    }
#else
    (void)fault; (void)deadline; (void)handshake;
#endif
    return !stopping && cancel_state(t) == 0 && (!t->persistent || module_state(t) == 0);
}
static int wlan_apply_step(struct tx *t, const char *action, long long deadline) {
    long long remaining = deadline - now_ms();
    if (stopping || cancel_state(t) != 0 || remaining <= 0 ||
        (t->persistent && module_state(t) != 0)) return 0;
    return wlan_write(t, action, remaining > 20000 ? 20000 : (int)remaining);
}
static int wlan_apply(struct tx *t, const char *fault, long long deadline, int *handshake) {
    if (!marker_write(t, "wlan-intent", "intent\n") ||
        !wlan_apply_step(t, "scan-off", deadline) ||
        !wlan_apply_step(t, "country-us", deadline) ||
        !wlan_apply_step(t, "wifi-off", deadline) ||
        !mark(t, "wlan-off", fault, deadline, handshake) || !cycle_delay(8000) ||
        !wlan_apply_step(t, "wifi-on", deadline) || !cycle_delay(12000) ||
        !mark(t, "wlan-ready", fault, deadline, handshake)) return 0;
    /* Association/L3/6GHz verification is separate, never inferred here. */
    event(t, "wlan-rebuilt", "commands_completed", "pending"); return 1;
}
static void guardian(struct tx *t, int handshake, int hold, const char *fault) {
    int box = -1, cover = -1, prepared = 0, published = 0, rc = 4, nullfd;
    long long start, deadline; struct id a; char boxpath[320];
    const char *operation = "failed";
    if (setsid() < 0) goto finish;
    /* Our private process owns every command child; never inherit auto-reap. */
    signal(17, SIG_DFL); /* Android AArch64 SIGCHLD */
    signal(SIGPIPE, SIG_IGN); signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, SIG_IGN);
    nullfd = open("/dev/null", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (nullfd < 0 || dup2(nullfd, 0) < 0 || dup2(t->log, 1) < 0 || dup2(t->log, 2) < 0) goto finish;
    close(nullfd);
    start = now_ms(); if (start < 0) goto finish; deadline = start + hold;
    if ((t->persistent && module_state(t) != 0) || !prepare(t, &box, &cover)) goto finish;
    prepared = 1;
    if (!mark(t, "prepared", fault, deadline, &handshake)) goto finish;
    if (!identity(AT_FDCWD, t->target, &a) || !equal(&a, &t->r.target) ||
        syscall(NR_MOVE_MOUNT, box, "", t->dir, "stagebox", MOVE_F_EMPTY) ||
        !identity(t->dir, "stagebox", &a) || !equal(&a, &t->r.box_owned)) goto finish;
    snprintf(boxpath, sizeof boxpath, "/proc/self/fd/%d/stagebox", t->dir);
    if (syscall(NR_MOUNT, (char *)0, boxpath, (char *)0, MS_PRIVATE, (void *)0) ||
        !mark(t, "container", fault, deadline, &handshake)) goto finish;
    if (syscall(NR_MOVE_MOUNT, cover, "", t->dir, "stagebox/stage", MOVE_F_EMPTY) ||
        !identity(t->dir, "stagebox/stage", &a) || !equal(&a, &t->r.owned)) goto finish;
    close(box); box = -1; close(cover); cover = -1;
    if (!mark(t, "staged", fault, deadline, &handshake) ||
        !identity(AT_FDCWD, t->target, &a) || !equal(&a, &t->r.target) ||
        syscall(NR_MOVE_MOUNT, t->dir, "stagebox/stage", AT_FDCWD, t->target, 0) ||
        !identity(AT_FDCWD, t->target, &a) || !equal(&a, &t->r.owned)) goto finish;
    published = 1; operation = "published";
    if (!allwrite(handshake, "R", 1)) operation = "launcher_lost";
    close(handshake); handshake = -1;
    event(t, "published", operation, "pending");
    if (t->r.wlan && !wlan_apply(t, fault, deadline, &handshake)) {
        operation = "wlan_apply_failed"; goto finish;
    }
    if (t->persistent) {
        event(t, "persistent-hold", "module_lifecycle_watch", "pending");
        rc = wait_persistent(t);
        operation = rc == -2 ? "module_control_invalid" : (rc == -1 ? "cancel_invalid" :
            (rc == 2 ? "module_disabled" : (rc == 3 ? "module_removed" :
            (rc == 4 ? "module_directory_changed" : "cancelled"))));
    } else {
        rc = wait_hold(t, deadline);
        operation = rc < 0 ? "cancel_invalid" : (rc ? "cancelled" : "deadline");
    }
finish:
    if (box >= 0) close(box);
    if (cover >= 0) close(cover);
    rc = prepared ? recover(t) : 5;
    if (t->persistent) close(t->module_fd);
    event(t, "terminal", operation, !prepared ? "no_mount_effects" :
          (rc == 0 || rc == 5 ? "restored" : (rc == 6 ? "settings_failed" :
          (rc == 7 ? "network_not_ready" : "blocked"))));
    if (handshake >= 0) { allwrite(handshake, "E", 1); close(handshake); }
    _exit(rc == 5 ? 0 : (rc == 6 || rc == 7 ? rc :
          ((rc == 0 && published && strcmp(operation, "wlan_apply_failed") &&
            strcmp(operation, "cancel_invalid") && strcmp(operation, "module_control_invalid")) ? 0 : 4)));
}
static int run(struct tx *t, int hold, const char *fault) {
    int p[2]; pid_t pid; char marker = 0; struct pollfd poller;
    if (t->persistent) {
        t->module_fd = module_open(t);
        if (t->module_fd < 0 || !identity(t->module_fd, "", &t->module) || module_state(t) != 0) {
            printf("{\"status\":\"module_control_unavailable\"}\n"); return 4;
        }
    }
    if (!locks(t, 1)) { printf("{\"status\":\"busy_or_invalid_lock\"}\n"); return 3; }
    /* Exclusive files deliberately make each transaction directory single-use. */
    t->log = newfile(t->dir, "guardian.log");
    if (t->log < 0 || cancel_state(t) != 0 || pipe(p)) return 4;
    pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return 4; }
    if (!pid) { close(p[0]); guardian(t, p[1], hold, fault); }
    close(p[1]);
    /* flock locks share an open file description across fork; close, NEVER
     * LOCK_UN, in launcher so the guardian alone retains both locks. */
    close(t->lock); t->lock = -1; close(t->parent); t->parent = -1;
    if (t->persistent) close(t->module_fd);
    poller.fd = p[0]; poller.events = POLLIN; poller.revents = 0;
    if (poll(&poller, 1, 5000) > 0 && (poller.revents & POLLIN)) read(p[0], &marker, 1);
    close(p[0]);
    if (marker == 'R') {
        if (t->persistent) printf("{\"status\":\"owned\",\"mode\":\"persistent\",\"guardian_pid\":%d}\n", pid);
        else printf("{\"status\":\"owned\",\"guardian_pid\":%d}\n", pid);
        return 0;
    }
#ifdef MT_MOUNT_TXN_TEST
    if (marker == 'T') { printf("{\"status\":\"test_ready\",\"stage\":\"%s\",\"guardian_pid\":%d}\n", fault, pid); return 0; }
#endif
    printf("{\"status\":\"handshake_failed\",\"guardian_pid\":%d,\"guardian_may_be_active\":true}\n", pid);
    return 4;
}
static int inspect(const char *path) {
    struct tx t = {0}; struct id at; char target[320];
    if (!context(t.boot, t.ns)) return 4;
#ifdef MT_MOUNT_TXN_TEST
    if (!path || !valid_path(path)) return 64;
    snprintf(target, sizeof target, "%s/target", path);
#else
    (void)path; snprintf(target, sizeof target, "/odm/firmware/wifi.cfg");
#endif
    if (!identity(AT_FDCWD, target, &at)) return 4;
    printf("{\"uid\":%u,\"boot\":\"%s\",\"mount_namespace\":\"%s\","
           "\"target_unique_id\":%llu,\"dev_major\":%u,\"dev_minor\":%u,\"ino\":%llu,"
           "\"caller_hash_preflight_required\":true}\n", geteuid(), t.boot, t.ns,
           at.mount, at.major, at.minor, at.ino);
    return 0;
}
int main(int argc, char **argv) {
    struct tx t = {0}; int hold, used = 0, rc, fd; const char *fault = "";
    if (argc >= 2 && !strcmp(argv[1], "inspect-module")) {
#ifdef MT_MOUNT_TXN_TEST
        return argc == 3 ? inspect_module(argv[2]) : 64;
#else
        return argc == 2 ? inspect_module(NULL) : 64;
#endif
    }
    if (argc >= 2 && !strcmp(argv[1], "inspect")) {
#ifdef MT_MOUNT_TXN_TEST
        return argc == 3 ? inspect(argv[2]) : 64;
#else
        return argc == 2 ? inspect(NULL) : 64;
#endif
    }
#ifndef MT_MOUNT_TXN_TEST
    if (argc == 2 && !strcmp(argv[1], "inspect-wlan")) {
        int scan = wlan_read(&t, "get-scan"), wifi = wlan_read(&t, "get-wifi"), over;
        char override_code[3], code[3];
        if (scan < 0 || wifi < 0 ||
            country_parse(&t, &over, override_code, code)) return 4;
        printf("{\"scan\":%d,\"wifi\":%d,\"country_override\":%d,"
               "\"override_code\":\"%s\",\"country_code\":\"%s\","
               "\"read_only\":true}\n",
               scan, wifi, over, override_code, code); return 0;
    }
#endif
    if (argc < 3 || !setup(&t, argv[2])) return 64;
    if (!strcmp(argv[1], "run-wlan-persistent")) {
        if (argc != 3) return 64;
        t.wlan_requested = 1; t.persistent = 1;
        /* Only stable hold is unbounded; all startup commands retain budgets. */
#ifdef MT_MOUNT_TXN_TEST
        /* Existing fake-Binder bounded cases use 1000 ms too. Keeping that
         * startup budget makes accidental deadline reuse observable in tests. */
        return run(&t, 1000, "");
#else
        return run(&t, 900000, "");
#endif
    }
    if (!strcmp(argv[1], "run") || !strcmp(argv[1], "run-wlan")) {
        t.wlan_requested = !strcmp(argv[1], "run-wlan");
        if (argc < 4 || sscanf(argv[3], "%d%n", &hold, &used) != 1 ||
            argv[3][used] || hold < 100 || hold > 900000) return 64;
#ifdef MT_MOUNT_TXN_TEST
        if (argc == 5) { fault = argv[4];
            if (strcmp(fault, "prepared") && strcmp(fault, "container") &&
                strcmp(fault, "staged") && strcmp(fault, "published") &&
                !(t.wlan_requested && (!strcmp(fault, "wlan-off") || !strcmp(fault, "wlan-ready")))) return 64;
        } else if (argc != 4) return 64;
#else
        if (argc != 4) return 64;
#endif
        return run(&t, hold, fault);
    }
    if (argc != 3) return 64;
    if (!strcmp(argv[1], "cancel")) {
        fd = newfile(t.dir, "cancel");
        if (fd < 0) rc = cancel_state(&t) == 1 ? 0 : 4;
        else { rc = allwrite(fd, "cancel\n", 7) && !fsync(fd) && !fsync(t.dir) ? 0 : 4; close(fd); }
        printf("{\"status\":\"%s\"}\n", rc ? "cancel_failed" : "cancel_requested"); return rc;
    }
    if (!strcmp(argv[1], "recover")) {
        if (!locks(&t, 0)) { printf("{\"status\":\"busy_or_invalid_lock\"}\n"); return 3; }
        t.log = openat(t.dir, "guardian.log", O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (!safe_file(t.log)) return 4;
        rc = recover(&t); event(&t, "recovery", "separate_recovery",
            rc == 0 || rc == 5 ? "restored" : (rc == 6 ? "settings_failed" :
            (rc == 7 ? "network_not_ready" : "blocked")));
        printf("{\"status\":\"%s\",\"restoration\":\"%s\"}\n", rc == 5 ? "idle" :
            (rc == 0 ? "recovered" : (rc == 7 ? "network_not_ready" : "blocked")),
            rc == 0 || rc == 5 ? "restored" : (rc == 6 ? "settings_failed" :
            (rc == 7 ? "network_not_ready" : "blocked")));
        return rc == 5 ? 0 : rc;
    }
    return 64;
}
