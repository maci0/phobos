#!/usr/bin/env bash
# Install only the two Linux toolchains used by hosted CI runners.
set -euo pipefail
BUILD_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
while [[ ! -f "$BUILD_ROOT/build.zig.zon" ]]; do
    [[ $BUILD_ROOT != / ]] || { echo 'build.zig.zon not found' >&2; exit 1; }
    BUILD_ROOT=$(dirname -- "$BUILD_ROOT")
done
cd -- "$BUILD_ROOT"
case "$(uname -m)" in
    x86_64) arch=x86_64; checksum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
    aarch64) arch=aarch64; checksum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
    *) echo 'CI requires Linux x86-64 or AArch64' >&2; exit 1 ;;
esac
[[ $(uname -s) == Linux ]]
archive="zig-$arch-linux-0.17.0.tar.xz"
directory="$BUILD_ROOT/.scratch/toolchains"
mkdir -p "$directory"
curl --fail --location --retry 3 --output "$directory/$archive" "https://ziglang.org/download/0.17.0/$archive"
printf '%s  %s\n' "$checksum" "$directory/$archive" | sha256sum --check
tar -xJf "$directory/$archive" -C "$directory"
[[ $("$directory/zig-$arch-linux-0.17.0/zig" version) == 0.17.0 ]]
printf '%s\n' "$directory/zig-$arch-linux-0.17.0" >> "$GITHUB_PATH"
