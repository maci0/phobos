#!/usr/bin/env bash
# Build local release artifacts and check their ELF architecture and float ABI.
set -euo pipefail
export LC_ALL=C

BUILD_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
while [[ ! -f "$BUILD_ROOT/build.zig.zon" ]]; do
    [[ "$BUILD_ROOT" != / ]] || { echo 'build.zig.zon not found' >&2; exit 1; }
    BUILD_ROOT=$(dirname -- "$BUILD_ROOT")
done
cd -- "$BUILD_ROOT"

PROFILES=(armv6-hardfp armv7-soft armv7-softfp-c armv7-hardfp cortex-a7-hardfp aarch64 x86_64)
ZIG=${ZIG:-zig}
BUILD_JOBS=${BUILD_JOBS:-2}
BUILD_TIMEOUT_SECONDS=${BUILD_TIMEOUT_SECONDS:-600}
OUTPUT=
VERIFY_ONLY=false
SELECTED=()

fail() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: scripts/build-release.sh [--output DIR] [--verify-only] [PROFILE ...]
Build every profile by default, or select profiles from:
  armv6-hardfp armv7-soft armv7-softfp-c armv7-hardfp
  cortex-a7-hardfp aarch64 x86_64

Outputs must stay below the checkout's ignored .scratch directory.
--verify-only checks existing artifacts without compiling or executing them.
ZIG selects the compiler; BUILD_JOBS defaults to 2; BUILD_TIMEOUT_SECONDS to 600.
armv7-softfp-c uses VFPv3-D32 in C and software floating point in Zig.
USAGE
}

profile() {
    local name=$1
    SOFTFP=false
    ELF_CLASS=ELF32
    MACHINE=ARM
    FLOAT_ABI=hard
    case "$name" in
        armv6-hardfp)
            TARGET=arm-linux-musleabihf; CPU=arm1176jzf_s
            ASSET="phobos-v$VERSION-armv6-linux-musleabihf" ;;
        armv7-soft)
            TARGET=arm-linux-musleabi; CPU=generic+has_v7+aclass+soft_float; FLOAT_ABI=soft
            ASSET="phobos-v$VERSION-armv7-linux-musleabi-soft" ;;
        armv7-softfp-c)
            TARGET=arm-linux-musleabi; CPU=generic+has_v7+aclass+vfp3; FLOAT_ABI=soft; SOFTFP=true
            ASSET="phobos-v$VERSION-armv7-linux-musleabi-softfp-c" ;;
        armv7-hardfp)
            TARGET=arm-linux-musleabihf; CPU=generic+has_v7+aclass+vfp3d16
            ASSET="phobos-v$VERSION-armv7-linux-musleabihf" ;;
        cortex-a7-hardfp)
            TARGET=arm-linux-musleabihf; CPU=cortex_a7
            ASSET="phobos-v$VERSION-arm-linux-musleabihf" ;;
        aarch64)
            TARGET=aarch64-linux-musl; CPU=baseline; ELF_CLASS=ELF64; MACHINE=AArch64; FLOAT_ABI=none
            ASSET="phobos-v$VERSION-aarch64-linux-musl" ;;
        x86_64)
            TARGET=x86_64-linux-musl; CPU=baseline; ELF_CLASS=ELF64; MACHINE=X86-64; FLOAT_ABI=none
            ASSET="phobos-v$VERSION-x86_64-linux-musl" ;;
        *) fail "unknown profile: $name" ;;
    esac
}

verify() {
    local name=$1 binary=$2 header programs dynamic attributes
    header=$(readelf -hW -- "$binary")
    [[ $header =~ Class:[[:space:]]+$ELF_CLASS ]] || fail "$name: incorrect ELF class"
    [[ $header =~ Machine:[^$'\n']*$MACHINE ]] || fail "$name: incorrect ELF machine"
    [[ $header == *'little endian'* ]] || fail "$name: incorrect ELF byte order"
    programs=$(readelf -lW -- "$binary")
    dynamic=$(readelf -dW -- "$binary")
    [[ $programs != *INTERP* && $dynamic != *'(NEEDED)'* ]] || fail "$name: binary is dynamically linked"
    if [[ $MACHINE == ARM ]]; then
        [[ $header == *'Version5 EABI'* ]] || fail "$name: incorrect ARM EABI version"
        [[ $header == *"$FLOAT_ABI-float ABI"* ]] || fail "$name: incorrect ARM float ABI"
        attributes=$(readelf -AW -- "$binary")
        if [[ $FLOAT_ABI == hard ]]; then
            [[ $attributes == *'Tag_ABI_VFP_args: VFP registers'* ]] || fail "$name: missing VFP argument ABI"
        else
            [[ $attributes != *'Tag_ABI_VFP_args: VFP registers'* ]] || fail "$name: incompatible VFP argument ABI"
        fi
        case "$name" in
            armv6-hardfp) [[ $attributes == *'Tag_FP_arch: VFPv2'* ]] || fail "$name: unexpected FPU requirement" ;;
            armv7-soft) [[ $attributes != *Tag_FP_arch:* ]] || fail "$name: software profile requires an FPU" ;;
            armv7-softfp-c) [[ $attributes == *'Tag_FP_arch: VFPv3'* && $attributes != *'Tag_FP_arch: VFPv3-D16'* ]] || fail "$name: expected VFPv3-D32" ;;
            armv7-hardfp) [[ $attributes == *'Tag_FP_arch: VFPv3-D16'* ]] || fail "$name: expected VFPv3-D16" ;;
        esac
        if [[ $name == armv7-* ]]; then
            [[ $attributes != *Tag_Advanced_SIMD_arch:* ]] || fail "$name: generic profile unexpectedly requires NEON"
        fi
    fi
}

while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --list) printf '%s\n' "${PROFILES[@]}"; exit 0 ;;
        --output) (($# >= 2)) || fail '--output requires a directory'; OUTPUT=$2; shift 2 ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        -*) fail "unknown option: $1" ;;
        *) SELECTED+=("$1"); shift ;;
    esac
done
[[ $BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_JOBS must be a positive integer'
[[ $BUILD_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_TIMEOUT_SECONDS must be a positive integer'
VERSION=
version_pattern='^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([A-Za-z0-9.+-]+)"'
while IFS= read -r line; do
    if [[ $line =~ $version_pattern ]]; then VERSION=${BASH_REMATCH[1]}; break; fi
done < build.zig.zon
[[ -n $VERSION ]] || fail 'package version not found'
((${#SELECTED[@]})) || SELECTED=("${PROFILES[@]}")
for selected in "${SELECTED[@]}"; do profile "$selected"; done
for tool in readelf sha256sum realpath timeout; do command -v "$tool" >/dev/null || fail "required command missing: $tool"; done
if ! $VERIFY_ONLY; then command -v "$ZIG" >/dev/null || fail "compiler not found: $ZIG"; fi
OUTPUT=$(realpath -m -- "${OUTPUT:-$BUILD_ROOT/.scratch/release-v$VERSION}")
case "$OUTPUT/" in "$BUILD_ROOT"/.scratch/*) ;; *) fail 'output must be below this checkout .scratch directory' ;; esac
if $VERIFY_ONLY; then
    [[ -f $OUTPUT/SHA256SUMS ]] || fail 'recorded SHA256SUMS is missing'
else
    mkdir -p -- "$OUTPUT"
fi
manifest=$(mktemp "$OUTPUT/.SHA256SUMS.XXXXXX")
metadata=$(mktemp "$OUTPUT/.profiles.XXXXXX")
trap 'rm -f -- "$manifest" "$metadata"' EXIT
printf 'profile\ttarget\tcpu\tc_softfp\tasset\n' > "$metadata"
if ! $VERIFY_ONLY; then rm -f -- "$OUTPUT/SHA256SUMS"; fi
for selected in "${SELECTED[@]}"; do
    profile "$selected"
    prefix="$OUTPUT/profiles/$selected"
    binary="$OUTPUT/$ASSET"
    if ! $VERIFY_ONLY; then
        mkdir -p -- "$prefix"
        printf 'building %s (%s, %s)\n' "$selected" "$TARGET" "$CPU"
        if ! timeout "$BUILD_TIMEOUT_SECONDS" "$ZIG" build -Doptimize=ReleaseSmall -Dtarget="$TARGET" -Dcpu="$CPU" -Dsoftfp="$SOFTFP" -j"$BUILD_JOBS" --prefix "$prefix" > "$prefix/build.log" 2>&1; then
            cat "$prefix/build.log" >&2
            fail "$selected: build failed"
        fi
        cp -- "$prefix/bin/phobos" "$binary"
    fi
    verify "$selected" "$binary"
    if $VERIFY_ONLY; then
        recorded=false
        while read -r checksum filename; do
            if [[ $filename == "$ASSET" && $checksum =~ ^[0-9a-fA-F]{64}$ ]]; then recorded=true; break; fi
        done < "$OUTPUT/SHA256SUMS"
        $recorded || fail "$selected: checksum is not recorded"
    else
        readelf -hW -lW -AW -- "$binary" > "$OUTPUT/$ASSET.elf.txt"
        (cd -- "$OUTPUT" && sha256sum -- "$ASSET") >> "$manifest"
        printf '%s\t%s\t%s\t%s\t%s\n' "$selected" "$TARGET" "$CPU" "$SOFTFP" "$ASSET" >> "$metadata"
    fi
    printf 'verified %s\n' "$ASSET"
done
if ! $VERIFY_ONLY; then
    mv -- "$manifest" "$OUTPUT/SHA256SUMS"
    mv -- "$metadata" "$OUTPUT/profiles.tsv"
fi
(cd -- "$OUTPUT" && sha256sum --check SHA256SUMS)
printf 'artifacts: %s\n' "$OUTPUT"
