"""Offline native profile/build tests. Never runs the Android executor or mounts.

MT_MOUNT_TXN_CLANG selects clang for cross-object checks (no sysroot needed).
ANDROID_NDK_HOME enables real NDK link/ELF/reproducibility and ABI checks.
Run: python3 -m unittest discover -s tests -p test_mount_txn_build.py -v
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "native/recovery/mount_txn.c"
BUILD = ROOT / "tools/build_mount_txn.sh"
PROFILES = {"standalone": [], "unified": ["-DMT_UNIFIED_MODULE"],
            "test": ["-DMT_MOUNT_TXN_TEST"]}


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.clang = os.environ.get("MT_MOUNT_TXN_CLANG") or shutil.which("clang")
        if not cls.clang:
            raise unittest.SkipTest("clang required for offline AArch64 object checks")
        cls.text = SOURCE.read_text()

    def compile(self, *args):
        return run(self.clang, "--target=aarch64-linux-android24",
                   "-DMT_ANDROID_AARCH64", *args, str(SOURCE))

    def test_compile_all_profiles_and_object_strings(self):
        with tempfile.TemporaryDirectory() as tmp:
            for profile, flags in PROFILES.items():
                with self.subTest(profile=profile):
                    obj = Path(tmp) / (profile + ".o")
                    result = self.compile(*flags, "-std=c11", "-O2", "-Wall",
                                          "-Wextra", "-Werror", "-c", "-o", str(obj))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    data = obj.read_bytes()
                    self.assertEqual(data[:6], b"\x7fELF\x02\x01")
                    self.assertEqual(int.from_bytes(data[18:20], "little"), 183)
                    module = "mt6639-hotspot" if profile == "unified" else "mt6639-6g"
                    self.assertIn(module.encode() + b"\0", data)
                    other = b"mt6639-6g\0" if profile == "unified" else b"mt6639-hotspot\0"
                    self.assertNotIn(other, data)
                    prefix = ("/data/local/tmp/mt6639-native-" if profile == "test"
                              else "/data/adb/mt6639-6g/transactions/t-")
                    self.assertIn(prefix.encode(), data)
                    self.assertIn(b"MT6639-TEST-v3" if profile == "test" else b"MT6639-PROD-v3", data)

    def test_profiles_are_compile_time_and_conflicts_fail(self):
        result = self.compile("-DMT_UNIFIED_MODULE", "-DMT_MOUNT_TXN_TEST", "-fsyntax-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unified_and_test_profiles_are_mutually_exclusive", result.stderr)
        for profile, flags in PROFILES.items():
            result = self.compile(*flags, "-dM", "-E")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('#define MODULE_NAME "mt6639-hotspot"' if profile == "unified"
                          else '#define MODULE_NAME "mt6639-6g"', result.stdout)
        self.assertIn('openat(modules, MODULE_NAME,', self.text)

    def test_host_path_validation_preserves_legacy_authority(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        function = re.search(r"static int valid_path\([^\n]+\n.*?\n}", self.text, re.S).group()
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "paths.c"
            binary = Path(tmp) / "paths"
            src.write_text('#include <string.h>\n#define PREFIX "/data/adb/mt6639-6g/transactions/t-"\n'
                           + function + '\nint main(int n, char **v) { return n == 2 && valid_path(v[1]) ? 0 : 1; }\n')
            result = run(cc, "-Wall", "-Werror", str(src), "-o", str(binary))
            self.assertEqual(result.returncode, 0, result.stderr)
            for path, accepted in [("/data/adb/mt6639-6g/transactions/t-Old_123", True),
                                   ("/data/adb/mt6639-hotspot/transactions/t-new", False),
                                   ("/data/adb/mt6639-6g/transactions/t-", False),
                                   ("/data/adb/mt6639-6g/transactions/t-a/../b", False),
                                   ("/data/local/tmp/mt6639-native-test", False)]:
                self.assertEqual(run(str(binary), path).returncode == 0, accepted, path)

    def test_host_module_guard_is_pinned_and_strict(self):
        cc = shutil.which("cc")
        if not cc or os.geteuid() != 0:
            self.skipTest("host compiler and root-owned temporary fixtures required")
        private = re.search(r"static int private_dir\([^\n]+\n.*?\n}", self.text, re.S).group()
        below = re.search(r"static int module_below\([^\n]+\n.*?\n}", self.text, re.S).group()
        definitions = self.text[self.text.index("#if defined(MT_UNIFIED_MODULE)"):
                                self.text.index("struct xtime")]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            barrier = root / "barrier"
            barrier.mkdir(mode=0o700)
            modules = barrier / "modules"
            modules.mkdir()
            modules.chmod(0o777)  # Existing KSU exception remains valid.
            src = root / "guard.c"
            src.write_text('#define _GNU_SOURCE\n#include <sys/stat.h>\n#include <fcntl.h>\n'
                           '#include <unistd.h>\n#include <errno.h>\n' + definitions + private + below +
                           '\nint main(int n, char **v) { if (n != 2) return 9; '
                           'int b=open(v[1], O_RDONLY|O_DIRECTORY), f=module_below(b); '
                           'if(f>=0) close(f); if(b>=0) close(b); return f>=0 ? 0 : (f == -2 ? 2 : 1); }\n')
            for profile, flags in PROFILES.items():
                with self.subTest(profile=profile):
                    binary = root / profile
                    result = run(cc, "-Wall", "-Werror", *flags, str(src), "-o", str(binary))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    name = "mt6639-hotspot" if profile == "unified" else "mt6639-6g"
                    wrong = modules / ("mt6639-6g" if profile == "unified" else "mt6639-hotspot")
                    right = modules / name
                    wrong.mkdir(mode=0o755)
                    self.assertEqual(run(str(binary), str(barrier)).returncode, 2)
                    right.symlink_to(wrong)
                    self.assertEqual(run(str(binary), str(barrier)).returncode, 1)
                    right.unlink()
                    right.mkdir(mode=0o755)
                    self.assertEqual(run(str(binary), str(barrier)).returncode, 0)
                    right.chmod(0o777)
                    self.assertEqual(run(str(binary), str(barrier)).returncode, 1)
                    right.rmdir()
                    wrong.rmdir()

    def test_unified_recovery_barrier_fails_closed(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        barrier = re.search(r"static int unified_recovery_barrier\([^\n]+\n.*?\n}", self.text, re.S).group()
        recovery = re.search(r"static int recover\([^\n]+\n.*?\n}", self.text, re.S).group()
        self.assertLess(recovery.index("unified_recovery_barrier(t)"), recovery.index("recover_after_barrier(t)"))
        self.assertLess(recovery.index("recover_after_barrier(t)"), recovery.index("close(lock)"))
        self.assertIn("if (lock < 0) return 4;", recovery)
        self.assertIn("rc = prepared ? recover(t) : 5;", self.text)
        mock = r'''
#include <stddef.h>
#include <string.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
struct id { int value; };
struct tx { int persistent; struct id module; };
static int command_rc, calls, lock_held, lock_failure, replacement, fail_check;
static int module_open(struct tx *t) { (void)t; return 10; }
static int identity(int fd, const char *p, struct id *i) {
    (void)fd; (void)p; i->value = replacement && calls ? 2 : 1; return 1;
}
static int equal(const struct id *a, const struct id *b) { return a->value == b->value; }
static int directory(const char *p) { return strcmp(p, "/data/adb/mt6639-hotspot") ? -1 : 11; }
static int private_dir(int fd) { return fd == 11; }
static int safe_file(int fd) { return fd == 12; }
static int mock_openat(int fd, const char *p, int flags) {
    return fd == 11 && !strcmp(p, "action.lock") &&
        flags == (O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK) ? 12 : -1;
}
static int mock_fstat(int fd, struct stat *s) { (void)fd; s->st_size=0; return 0; }
static int mock_flock(int fd, int op) {
    if (fd != 12 || op != (LOCK_EX|LOCK_NB) || lock_failure) return -1;
    lock_held = 1; return 0;
}
static int mock_close(int fd) { if (fd == 12) lock_held = 0; return 0; }
#define openat mock_openat
#define fstat mock_fstat
#define flock mock_flock
#define close mock_close
static int mt_command(char *const argv[], int budget, char *out, size_t cap) {
    calls++;
    if (strcmp(argv[0], "/system/bin/sh") ||
        strcmp(argv[1], "/data/adb/modules/mt6639-hotspot/bin/radio-teardown.sh") ||
        budget != 400000 || !out || cap != 4096) return 99;
    if (calls == 1 && (argv[2] || lock_held)) return 99;
    if (calls == 2 && (!argv[2] || strcmp(argv[2], "check") || argv[3] || !lock_held)) return 99;
    return calls == 2 && fail_check ? fail_check : command_rc;
}
'''
        main = r'''
int main(void) {
    struct tx t = {0};
    int codes[] = {0, 1, 4, 64, 124, 125, 126, 127, -1};
    for (unsigned i = 0; i < sizeof codes / sizeof codes[0]; i++) {
        command_rc = codes[i]; calls = 0; lock_held = 0;
        int fd = unified_recovery_barrier(&t);
        if ((fd >= 0) != (command_rc == 0) || calls != (command_rc ? 1 : 2) ||
            lock_held != (command_rc == 0)) return 1;
        if (fd >= 0) mock_close(fd);
    }
    command_rc = 0;
    for (int failure = 1; failure <= 3; failure++) {
        calls = 0; lock_failure = failure == 1; replacement = failure == 2;
        fail_check = failure == 3 ? 124 : 0;
        if (unified_recovery_barrier(&t) >= 0 || lock_held) return 2;
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            src, binary = Path(tmp) / "barrier.c", Path(tmp) / "barrier"
            src.write_text(mock + barrier + main)
            result = run(cc, "-Wall", "-Wextra", "-Werror", str(src), "-o", str(binary))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(run(str(binary)).returncode, 0)
        for profile, flags in PROFILES.items():
            result = self.compile(*flags, "-E")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual("radio-teardown.sh" in result.stdout, profile == "unified")

    def test_long_budget_is_only_for_fixed_unified_barrier(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        text = (ROOT / "native/recovery/command.h").read_text()
        validation = text[text.index("    int budget_valid ="):text.index("    if (!argv || !argv[0] || !out")]
        harness = '#include <string.h>\n#include <stddef.h>\nstatic int valid(char *const argv[], int budget_ms) {\n' + validation + r'''
    (void)argv; return budget_valid;
}
int main(void) {
    char *stop[] = {"/system/bin/sh", "/data/adb/modules/mt6639-hotspot/bin/radio-teardown.sh", NULL};
    char *check[] = {stop[0], stop[1], "check", NULL};
    char *other[] = {stop[0], "/tmp/custom.sh", NULL};
    char *extra[] = {stop[0], stop[1], "check", "extra", NULL};
#ifdef MT_UNIFIED_MODULE
    int unified = 1;
#else
    int unified = 0;
#endif
    if (valid(stop,400000) != unified || valid(check,400000) != unified ||
        valid(other,400000) || valid(extra,400000) || valid(stop,400001) ||
        valid(stop,20001) || !valid(stop,20000) || valid(stop,0) || valid(NULL,400000)) return 1;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            src, binary = Path(tmp) / "budget.c", Path(tmp) / "budget"
            src.write_text(harness)
            for flags in PROFILES.values():
                result = run(cc, "-Wall", "-Wextra", "-Werror", *flags, str(src), "-o", str(binary))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(run(str(binary)).returncode, 0)

    def test_build_script_rejects_unsafe_output_and_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            for output, profile, expected in [(str(ROOT / "bad-native-output"), "unified", "outside"),
                                              (tmp + "/out", "arbitrary/path", "profile must"),
                                              (tmp + "/out", "unified", "source.properties")]:
                result = run("bash", str(BUILD), tmp, output, profile)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)


@unittest.skipUnless(os.environ.get("ANDROID_NDK_HOME"), "ANDROID_NDK_HOME required for real Android link tests")
class AndroidBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ndk = Path(os.environ["ANDROID_NDK_HOME"]).resolve()
        cls.tools = cls.ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.outputs = {}
        for profile in PROFILES:
            output = Path(cls.tmp.name) / profile
            result = run("bash", str(BUILD), str(cls.ndk), str(output), profile)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)
            cls.outputs[profile] = output

    def test_real_android_elf(self):
        for profile, output in self.outputs.items():
            with self.subTest(profile=profile):
                result = run(str(self.tools / "llvm-readelf"), "-h", "-l", "-d", str(output / "mount-txn"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(result.stdout, r"Machine:\s+AArch64")
                self.assertRegex(result.stdout, r"Type:\s+DYN")
                self.assertIn("/system/bin/linker64", result.stdout)
                self.assertIn("Shared library: [libc.so]", result.stdout)
                needed = re.findall(r"Shared library: \[([^]]+)\]", result.stdout)
                self.assertEqual(set(needed), {"libc.so", "libdl.so"})
                self.assertNotRegex(result.stdout, r"musl|libc\.so\.6|RPATH|RUNPATH|TEXTREL")
                self.assertIn("GNU_RELRO", result.stdout)

    def test_reproducible_binary_and_provenance(self):
        output = Path(self.tmp.name) / "repeat"
        result = run("bash", str(BUILD), str(self.ndk), str(output), "unified")
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.outputs["unified"] / "mount-txn"
        self.assertEqual(first.read_bytes(), (output / "mount-txn").read_bytes())
        provenance = (output / "mount-txn.provenance.txt").read_text()
        self.assertEqual(provenance, (first.parent / "mount-txn.provenance.txt").read_text())
        self.assertIn(hashlib.sha256(first.read_bytes()).hexdigest(), provenance)
        self.assertIn("module_guard=mt6639-hotspot", provenance)
        self.assertIn("schema=MT6639-PROD-v3", provenance)
        self.assertIn(hashlib.sha256(SOURCE.read_bytes()).hexdigest(), provenance)
        result = run("bash", str(BUILD), str(self.ndk), str(output), "unified")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output already exists", result.stderr)

    def test_manual_abi_matches_ndk_bionic(self):
        # Compile identical layout assertions against each independent definition.
        # No manual declarations are mixed with NDK headers and nothing executes.
        assertions = '''
_Static_assert(sizeof(struct stat) == 128, "stat size");
_Static_assert(__builtin_offsetof(struct stat, st_mode) == 16, "mode offset");
_Static_assert(__builtin_offsetof(struct stat, st_uid) == 24, "uid offset");
_Static_assert(__builtin_offsetof(struct stat, st_size) == 48, "size offset");
_Static_assert(__builtin_offsetof(struct stat, st_mtim) == 88, "mtime offset");
_Static_assert(sizeof(struct timespec) == 16, "timespec size");
_Static_assert(sizeof(struct pollfd) == 8, "pollfd size");
_Static_assert(sizeof(off_t) == 8, "off_t size");
_Static_assert(O_DIRECTORY == 040000 && O_NOFOLLOW == 0100000, "arm64 flags");
int *errno_abi(void) { return __errno(); }
'''
        for name, headers, flags in [
            ("manual", '#include "abi.h"\n', ["-DMT_ANDROID_AARCH64", "-I" + str(ROOT / "native/recovery")]),
            ("ndk", '#include <sys/stat.h>\n#include <fcntl.h>\n#include <poll.h>\n#include <errno.h>\n', [])
        ]:
            src = Path(self.tmp.name) / (name + ".c")
            src.write_text(headers + assertions)
            result = run(str(self.tools / "aarch64-linux-android24-clang"), "-std=c11",
                         "-Wall", "-Wextra", "-Werror", *flags, "-c", str(src),
                         "-o", str(src.with_suffix(".o")))
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
