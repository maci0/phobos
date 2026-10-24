# Linux build profiles

The current build helper produces static musl binaries with Zig 0.17.0 and
`ReleaseFast`. Published v0.2.2 assets used `ReleaseSmall`. `ReleaseSmall` remains
available through direct Zig builds when executable size matters more than speed.
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
| `ad5x-mipsel` | `mipsel-linux-musleabihf` | `mips32r5+fp64+nan2008` | Little-endian MIPS32r5, o32 hard float, 64-bit FPU registers and NaN2008; experimental AD5X profile |

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

For v0.2.3, all seven release assets pass ELF/ABI/static-link and checksum
validation. Native x86-64 and AArch64 CI run the complete suites and release-asset
smoke checks. All five ARM32 daemon assets pass real Klippy, full 262-object
subscriptions, private Fluidd database keys, directory capacity, history and
advancing temperature stores inside the Forge-X 1.4.2 chroot. Separate C/Zig
floating-point probes also pass for all five. The Cortex-A7 asset is installed
on the printer. [Verification](perf/optimization-20261023/verification.json)
records asset hashes and the scope of each check.

Current [benchmarks](PERFORMANCE.md) compare these release binaries with
Moonraker in two isolated KVM studies and fresh physical-printer trials.
Scheduling delays remain recorded; fixed frequency and universal zero steal
are not established. Other physical printer models are not certified.

For the archived v0.2.1 release, all five ARM32 assets passed startup, real
Klippy object queries, copied SQLite history/float comparisons and directory-stat checks inside
the Forge-X 1.4.2 chroot on Cortex-A7/Linux 5.4.61. The
[smoke record](perf/arm32-smoke-v0.2.1.json) identifies the exact asset hashes.
Running the ARMv6 asset on ARMv7 does not certify native ARMv6 hardware.
The v0.2.1 AArch64 asset was built and ELF-checked without execution; current
native AArch64 CI is a separate validation, not a physical-printer test.

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
other profiles. This profile disables full LTO: with Zig 0.17, full LTO changes
C floating-point calls to VFP registers while the Zig callers keep the base
calling convention. The other release profiles retain full LTO.

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
ABI and FPU requirements, and the AD5X MIPS ISA/float ABI. It writes ELF reports,
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
  -Doptimize=ReleaseFast --prefix .scratch/cortex-a7
```

The mixed C softfp build adds the explicit option:

```sh
zig build -Dtarget=arm-linux-musleabi -Dcpu=generic+has_v7+aclass+vfp3 \
  -Dsoftfp=true -Doptimize=ReleaseFast --prefix .scratch/armv7-softfp-c
```

Build-option validation has standalone unit and bounded fuzz tests:

```sh
zig test -target native-native-musl build.zig
```

An opt-in runtime probe uses the same C flags and release LTO policy as the
application. It compares four C `double` return values and one floating-point
argument/result call with the values seen through Zig. Build it for the target,
then run it on matching hardware. Exit status 0 and matching hex pairs mean
all five checks passed:

```sh
zig build float-abi-probe -Dtarget=arm-linux-musleabi \
  -Dcpu=generic+has_v7+aclass+vfp3 -Dsoftfp=true \
  -Doptimize=ReleaseFast --prefix .scratch/armv7-softfp-c
```

Copy `.scratch/armv7-softfp-c/bin/float-abi-probe` to matching ARM hardware and
execute it there with no arguments. Do not run this ARM executable on the
build host.

The build step never runs the target executable. Normal application builds do
not build or install this probe.

## AD5X MIPS

The `ad5x-mipsel` profile matches the ELF ABI attributes of the BusyBox binary
inside the official [Z-Mod 1.7.4 AD5X archive](https://github.com/ghzserg/zmod/releases/tag/1.7.4).
It requires MIPS32r5, little-endian o32, NaN2008 and FP64 hard float, with no
MSA or other ISA extension. The shipped executable is static musl and does not
use the archive's `/lib/ld-linux-mipsn8.so.1` loader. A generic MIPS32r2 or
legacy-NaN build is not the selected AD5X profile.
`file` and the ELF header label this ISA family MIPS32r2; `readelf -A` reports
the stricter MIPS32r5 requirement in the MIPS ABI attributes.

```sh
scripts/build-release.sh --output .scratch/ad5x-build ad5x-mipsel
scripts/build-release.sh --verify-only --output .scratch/ad5x-build ad5x-mipsel
```

Its asset suffix is `mipsel-linux-musleabihf`. This profile was added after
v0.3.0; that published release has no MIPS asset. A source build still derives
its filename version from `build.zig.zon`. The direct build is:

```sh
zig build -Dtarget=mipsel-linux-musleabihf -Dcpu=mips32r5+fp64+nan2008 \
  -Doptimize=ReleaseFast --prefix .scratch/ad5x-mips
```

The helper validates the actual ELF's byte order, o32/NaN2008 flags, MIPS32r5
ISA, FP64 hard-float attributes, lack of ISA extensions, static linkage and
checksum. Regression tests build real ELF fixtures with incorrect byte order,
NaN mode, float ABI, ISA or MSA requirements and require rejection. The shared
serial adapter uses Linux's baud bits rather than speed fields absent from
MIPS `termios`.

These are build and ABI checks, not an AD5X hardware certification. The C/Zig
floating-point probe can be built with the same target and CPU arguments, but
must be run on matching hardware before claiming runtime ABI verification.
Z-Mod's print macros and integration gaps remain as described in the
[README](../README.md#try-on-a-z-mod-ad5m-printer); a MIPS binary does not add a
Z-Mod compatibility profile. No AD5X installation or production switch is
claimed by these commands.

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
| FlashForge AD5X with Z-Mod | `ad5x-mipsel`; experimental build, hardware/kernel execution and firmware integration unverified |

Processor mappings come from the [Raspberry Pi processor documentation](https://www.raspberrypi.com/documentation/computers/processors.html)
and [BIGTREETECH's CB1 specifications](https://github.com/bigtreetech/docs/blob/master/docs/CB1.md).
The [Klipper FAQ](https://www.klipper3d.org/FAQ.html#can-i-run-klipper-on-something-other-than-a-raspberry-pi-3)
recommends Zero 2 W and Pi 3/4/5, and advises against Pi 1, Pi 2 and original
Zero hosts because their processing capacity can cause print stalls. Klipper
also requires double-precision floating-point hardware on low-end hosts. A
phobos software-float executable does not remove those Klipper requirements.
