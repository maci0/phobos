# Linux build profiles

All profiles produce a static musl binary with Zig 0.17.0 and `ReleaseSmall`.
The executable includes SQLite and libc. It needs no host glibc, musl shared
library, or dynamic loader. CPU instructions, Linux execution mode, kernel
interfaces, configuration and device permissions still determine whether a
particular printer can run it.

## Profiles and minimum CPU features

| Profile | Zig target | Zig CPU | Minimum CPU and floating point |
| --- | --- | --- | --- |
| `armv6-hardfp` | `arm-linux-musleabihf` | `arm1176jzf_s` | ARM1176JZF-S class ARMv6 with VFPv2; hardware floating-point arguments |
| `armv7-soft` | `arm-linux-musleabi` | `generic+has_v7+aclass+soft_float` | ARMv7-A; software floating-point operations and integer-register arguments; no FPU requirement for phobos |
| `armv7-softfp-c` | `arm-linux-musleabi` | `generic+has_v7+aclass+vfp3` | ARMv7-A with VFPv3-D32; C uses hardware floating point with integer-register arguments, while Zig retains software helpers |
| `armv7-hardfp` | `arm-linux-musleabihf` | `generic+has_v7+aclass+vfp3d16` | ARMv7-A with VFPv3-D16; hardware floating-point arguments; no NEON requirement |
| `cortex-a7-hardfp` | `arm-linux-musleabihf` | `cortex_a7` | Cortex-A7 CPU features, including NEON and VFPv4; current Forge-X build profile |
| `aarch64` | `aarch64-linux-musl` | `baseline` | Baseline AArch64 with floating point and Advanced SIMD |
| `x86_64` | `x86_64-linux-musl` | `baseline` | Baseline x86-64, including SSE2 |

The generic ARMv7 profiles select the ISA (`has_v7`) and Application profile
(`aclass`) separately. Zig 0.17's `v7a` feature adds NEON and VFPv3-D32 as
dependencies, which would overstate the pure software and D16 requirements.

The ARM32 profiles need Linux support for 32-bit ARM execution. Hardware
floating-point profiles also need kernel support for the corresponding FPU
context. An AArch64 binary requires an AArch64 kernel. A 64-bit kernel can run
an ARM32 binary only when the CPU and kernel enable AArch32 compatibility.
The distro's `armel` or `armhf` userland does not select the calling convention
inside these static executables.

No numeric minimum kernel version is certified by this matrix. It checks the
ELF format and build target, without running foreign binaries or proving that
every optional kernel interface exists on a board. Hardware measurements and
their exact kernels are recorded separately in [PERFORMANCE.md](PERFORMANCE.md).

## Soft, softfp and hardfp

Soft and softfp use the ARM base calling convention: floating-point arguments
travel through integer registers. Hardfp uses VFP argument registers and is a
different ABI. Static linkage keeps the executable's internal ABI independent
of the installed distro's shared libraries.

`-Dsoftfp=true` is a C compilation option. It passes `-mfloat-abi=softfp` to
SQLite, both first-party C shims, and the local-time C test fixture. It accepts
only little-endian `arm-linux-musleabi` with VFPv3-D32 and rejects `soft_float`.
The option does not change Zig's floating-point lowering. With the pinned
compiler, `musleabi` Zig arithmetic still calls software helpers such as
`__aeabi_dadd`; the corresponding C arithmetic uses VFP instructions. The
`armv7-softfp-c` name describes this mixed implementation. It does not promise
that all floating-point operations use hardware or that it is faster than the
other profiles.

For example, compiling `double add(double a, double b) { return a + b; }` with
these C flags emits `VMOV` from integer registers, `VADD.F64`, and `VMOV` back:

```sh
zig cc -target arm-linux-musleabi -mcpu=generic+has_v7+aclass+vfp3 \
  -mfloat-abi=softfp -O2 -S float_probe.c -o float_probe.s
```

Without the explicit softfp flag the tested C compilation uses software
helpers. A CPU feature name alone does not establish the floating-point mode.
Use `armv7-soft` for the profile that does not require an FPU, or
`armv7-hardfp` for the generic hardware profile with the smaller D16 requirement.

## Build and validate artifacts

Run from a checkout with Zig 0.17.0, Bash, GNU `readelf`, `sha256sum`, `realpath`
and `timeout` available. The helper finds the checkout from `build.zig.zon` and
derives asset versions from that manifest.

```sh
ZIG=/path/to/zig scripts/build-release.sh
ZIG=/path/to/zig scripts/build-release.sh armv7-soft armv7-softfp-c aarch64
scripts/build-release.sh --verify-only
```

By default, outputs live below `.scratch/release-v<version>/`, with separate
install prefixes and build logs under `profiles/<profile>/`. `--output DIR`
accepts another location below this checkout's ignored `.scratch/` directory.
The helper checks ELF32/ELF64, machine type, static linkage, ARM float argument
ABI, and the declared ARM FPU requirements. It writes ELF reports,
`profiles.tsv`, and `SHA256SUMS`, then checks every selected checksum.
`--verify-only` repeats those checks without compiling or executing artifacts,
preserving the recorded manifest. Building a selected subset replaces the
manifest with that subset.

`BUILD_JOBS` controls compiler parallelism (default 2), and
`BUILD_TIMEOUT_SECONDS` bounds each build (default 600 seconds). The helper
does not publish, deploy, run QEMU, or start a server. Separate install prefixes
leave `zig-out/bin/phobos` unchanged.

Asset suffixes follow the profile:

| Profile | Asset name, using version `0.2.1` as an example |
| --- | --- |
| `armv6-hardfp` | `phobos-v0.2.1-armv6-linux-musleabihf` |
| `armv7-soft` | `phobos-v0.2.1-armv7-linux-musleabi-soft` |
| `armv7-softfp-c` | `phobos-v0.2.1-armv7-linux-musleabi-softfp-c` |
| `armv7-hardfp` | `phobos-v0.2.1-armv7-linux-musleabihf` |
| `cortex-a7-hardfp` | `phobos-v0.2.1-arm-linux-musleabihf` (retained legacy filename) |
| `aarch64` | `phobos-v0.2.1-aarch64-linux-musl` |
| `x86_64` | `phobos-v0.2.1-x86_64-linux-musl` |

The direct Cortex-A7 build remains:

```sh
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 \
  -Doptimize=ReleaseSmall --prefix .scratch/cortex-a7
```

The mixed C softfp build adds the explicit option:

```sh
zig build -Dtarget=arm-linux-musleabi -Dcpu=generic+has_v7+aclass+vfp3 \
  -Dsoftfp=true -Doptimize=ReleaseSmall --prefix .scratch/armv7-softfp-c
```

Build-option validation has standalone unit and bounded fuzz tests:

```sh
zig test -target native-native-musl build.zig
```

## Board examples

These examples map processor families to candidate profiles. They are not a
per-printer compatibility list or an installation recommendation.

| Host family | Candidate profile and kernel condition |
| --- | --- |
| Raspberry Pi 1, original Zero and Zero W (ARM1176JZF-S) | `armv6-hardfp` with a 32-bit ARM kernel and VFP support |
| Early Raspberry Pi 2 (Cortex-A7) | `cortex-a7-hardfp` or `armv7-hardfp` with a 32-bit ARM kernel |
| Later Pi 2, Pi 3 and Zero 2 W (Cortex-A53 family) | `aarch64` with a 64-bit kernel; `armv7-hardfp` when AArch32 execution is enabled |
| Pi 4 and Pi 5 (Cortex-A72 and Cortex-A76) | `aarch64` with a 64-bit kernel |
| BIGTREETECH CB1 / CB1 eMMC (Allwinner H616, Cortex-A53) | `aarch64` with a 64-bit kernel; check the installed kernel and board image |
| x86-64 Linux hosts | `x86_64` |

Processor mappings come from the [Raspberry Pi processor documentation](https://www.raspberrypi.com/documentation/computers/processors.html)
and [BIGTREETECH's CB1 specifications](https://eu.biqu.equipment/collections/for-voron-printers/products/manta-m4p-m8p).
The [Klipper FAQ](https://www.klipper3d.org/FAQ.html#can-i-run-klipper-on-something-other-than-a-raspberry-pi-3)
recommends Zero 2 W and Pi 3/4/5, and advises against Pi 1, Pi 2 and original
Zero hosts because their processing capacity can cause print stalls. Klipper
also requires double-precision floating-point hardware on low-end hosts. A
phobos software-float executable does not remove those Klipper requirements.
