#!/usr/bin/env bash
# Offline Android/Bionic build only; never executes the resulting helper.
# Usage: build_mount_txn.sh NDK_ROOT OUTPUT_DIRECTORY unified|standalone|test
# Requires official Linux x86_64 NDK r27c (27.2.12479018), bash, sha256sum,
# realpath and standard host utilities. Download/verification is caller-owned.
# No musl sysroot, VNDK-only link or custom startup shim is supported.
set -euo pipefail
export LC_ALL=C
umask 022
fail() { printf 'build_mount_txn: %s\n' "$*" >&2; exit 64; }
[[ $# == 3 ]] || fail 'usage: NDK_ROOT OUTPUT_DIRECTORY unified|standalone|test'
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ndk=$(realpath -e -- "$1")
out=$(realpath -m -- "$2")
case "$out/" in "$repo/"*) fail 'output must be outside the checkout';; esac
profile=$3
flags=(-DMT_ANDROID_AARCH64)
case "$profile" in
    unified) flags+=(-DMT_UNIFIED_MODULE); module=mt6639-hotspot;;
    standalone) module=mt6639-6g;;
    test) flags+=(-DMT_MOUNT_TXN_TEST); module=mt6639-6g;;
    *) fail 'profile must be unified, standalone or test';;
esac
[[ -f "$ndk/source.properties" ]] || fail 'missing NDK source.properties (no libc fallback)'
grep -Eq '^Pkg.Revision *= *27\.2\.12479018\r?$' "$ndk/source.properties" || fail 'requires official NDK r27c (27.2.12479018)'
toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
cc=$toolchain/bin/clang
readelf=$toolchain/bin/llvm-readelf
sysroot=$toolchain/sysroot
libs=$sysroot/usr/lib/aarch64-linux-android/24
for file in "$cc" "$toolchain/bin/ld.lld" "$readelf" "$libs/crtbegin_dynamic.o" "$libs/crtend_android.o" "$libs/libc.so"; do
    [[ -f "$file" ]] || fail "missing Android toolchain input: $file"
done
# Do not let host include/library search variables contaminate the Android link.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH COMPILER_PATH GCC_EXEC_PREFIX
mkdir -p -- "$out"
out=$(realpath -e -- "$out")
case "$out/" in "$repo/"*) fail 'output must be outside the checkout';; esac
[[ ! -e "$out/mount-txn" && ! -e "$out/mount-txn.provenance.txt" ]] || fail 'output already exists; use a fresh output directory'
stage=$(mktemp -d "$out/.mount-txn.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
flags=(--target=aarch64-linux-android24 --sysroot="$sysroot" -std=c11
    -O2 -Wall -Wextra -Werror -fPIE -fstack-protector-strong
    -ffile-prefix-map="$repo"=. "${flags[@]}"
    -fuse-ld=lld -pie -Wl,--build-id=sha1 -Wl,-z,relro,-z,now,-z,noexecstack
    -Wl,-z,max-page-size=16384 -Wl,--no-undefined)
"$cc" "${flags[@]}" "$repo/native/recovery/mount_txn.c" -o "$stage/mount-txn"
"$readelf" -h -l -d -n "$stage/mount-txn" > "$stage/elf.txt"
grep -Eq 'Machine: +AArch64' "$stage/elf.txt" || fail 'not AArch64'
grep -Eq 'Type: +DYN' "$stage/elf.txt" || fail 'not PIE'
grep -Fq '/system/bin/linker64' "$stage/elf.txt" || fail 'not Android dynamic linker'
grep -Fq 'Shared library: [libc.so]' "$stage/elf.txt" || fail 'not linked against Bionic libc.so'
if grep -Eq 'musl|libc\.so\.6|RPATH|RUNPATH|TEXTREL' "$stage/elf.txt"; then
    fail 'unexpected host libc, search path or text relocations'
fi
{
    printf 'format=mt6639-mount-txn-build-v1\nprofile=%s\nmodule_guard=%s\n' "$profile" "$module"
    printf 'target=aarch64-linux-android24\nndk_revision=27.2.12479018\n'
    printf 'abi=manual Bionic LP64 AArch64; NDK Bionic CRT and libc stubs\n'
    if [[ $profile == test ]]; then
        printf 'transaction_prefix=/data/local/tmp/mt6639-native-\nschema=MT6639-TEST-v3\n'
    else
        printf 'transaction_prefix=/data/adb/mt6639-6g/transactions/t-\nschema=MT6639-PROD-v3\n'
    fi
    printf 'scope=build/static ELF checks only; not device, mount, SELinux or WLAN validation\n'
    printf 'compiler='; "$cc" --version
    printf 'command='; printf '%q ' "$cc" "${flags[@]}" "$repo/native/recovery/mount_txn.c" -o '<OUTPUT>/mount-txn'; printf '\n'
    printf '\nSHA256 inputs (absolute paths):\n'
    sha256sum "$repo/native/recovery/mount_txn.c" "$repo/native/recovery/abi.h" \
        "$repo/native/recovery/command.h" "$repo/tools/build_mount_txn.sh" \
        "$ndk/source.properties" "$cc" "$toolchain/bin/ld.lld" \
        "$libs/crtbegin_dynamic.o" "$libs/crtend_android.o" "$libs/libc.so" \
        "$libs/libdl.so" "$toolchain/lib/clang/18/lib/linux/libclang_rt.builtins-aarch64-android.a"
    printf '\nSHA256 output:\n'
    (cd -- "$stage" && sha256sum mount-txn)
    printf '\nELF inspection:\n'; while IFS= read -r line; do printf '%s\n' "$line"; done < "$stage/elf.txt"
} > "$stage/mount-txn.provenance.txt"
mv -- "$stage/mount-txn" "$stage/mount-txn.provenance.txt" "$out/"
printf 'binary=%s/mount-txn\nprovenance=%s/mount-txn.provenance.txt\n' "$out" "$out"
sha256sum "$out/mount-txn"
