# JPEG XL Backport

This is a small sample project demonstrating how to backport JPEG XL support to older iOS and iPadOS versions.
It allows viewing JPEG XL images (`.jxl`) natively in the QuickLook Preview (e.g., in Files or Finder app). 
What's more, it automatically generates thumbnails for them.

It's implemented as a thin Swift wrapper around the reference JPEG XL implementation, [`libjxl`](https://github.com/libjxl/libjxl). `libjxl` is built locally as a static `XCFramework` (see [Build Instructions](#build-instructions)) so we control its compilation flags directly — earlier revisions used `SDWebImageJPEGXLCoder` via SPM, but Swift Package Manager doesn't propagate the consumer's `-mcpu`/`-mtune` into dependency builds, leaving `libjxl`'s SIMD/Highway codegen un-tuned.

---


## Trivia
[JPEG XL](https://jpegxl.info) is the newest JPEG format, providing on average 55% smaller file sizes than standard JPEG images and 25% smaller than AVIF. At the same time, the resultant file maintains mathematically proven quality equal to that of the original image. In some of our tests, it achieved an enormous 90% compression ratio, and it's in a lossless mode!

Apple added native support for JPEG XL in the 2023 OS release line:
1. iOS / iPadOS 17.0+
2. tvOS 17.0+
3. watchOS 10.0+
4. visionOS 1.0+
5. macOS Sonoma 14.0+. macOS 12.x (Monterey) and 13.x (Ventura) has partial support if Safari 17+ is installed, but it works only within the browser itself.

> If you're on any of the supported systems, you probably shouldn't use this app, because the system's built-in JPEG XL implementation is faster and more reliable per my observations (even if it's also mostly a wrapper around the same `libjxl`).

For R'n'D purposes, we have a zoo of devices "frozen" to iOS / iPadOS 15 and 16, which predates the official introduction of JPEG XL. To overcome that, this wrapper has been quickly coded.

---


## Requirements

1. OS: 
    1. iOS / iPadOS: 15 and 16. 
        1. Newer versions are also supported, but as said, you probably don't want to use this backport on them due to native JPEG XL support.
        2. The iOS / iPadOS Simulator target is supported and tested thoroughly during development. Be aware that you'll need to manually [inject](https://stackoverflow.com/questions/48884248/how-can-i-add-files-to-the-ios-simulator) your test files into the simulator, as it refuses to copy-paste unsupported image formats.
    2. macOS support is available via the Mac Catalyst target, but it has never been tested.
2. CPU: Apple A12+ - will almost certainly work on all modern `arm64` Apple Silicons, but hasn't been tested on older targets. You're welcome to adjust the build settings (see below) and let me know if older targets are supported!
3. Jailbreak: not required. Private APIs aren't used either.

---


## Architecture 

1. `jpegxlbp` - nothing but a host (container) app to register 2 App Extensions, actually doing all the hard work.
2. `previewext` - QuickLook Preview Extension. OS invokes it per image, then offloads.
3. `thumbext` - QuickLook Thumbnail Extension. OS invokes that per N images, where N depends on the current load, scrolling speed, and hundreds of other factors. This means that any state (such as a decoder cache) persists N images before the system unloads it. This makes such extensions more prone to OOM death.
4. Extensions are self-contained and don't communicate with each other nor with the host app, so you can safely remove ones that you don't need in your use case. On a jailbroken device, you, in theory, can install extensions without the host app.

---


## Build Instructions

Building is a two-step process: first build the `libjxl` `XCFramework`, then build the app/extensions in Xcode.

### 1. Build the `libjxl` `XCFramework`

```bash
scripts/build-libjxl-xcframework.sh                                 # defaults: --mcpu apple-a12, no -mtune
scripts/build-libjxl-xcframework.sh --mcpu apple-a12 --mtune apple-m4  # current project default
scripts/build-libjxl-xcframework.sh --mcpu apple-a14                 # newer device baseline (M1+/A14+)

# Different baselines per platform — Catalyst-only Macs are M1+, so they can
# afford a higher --mcpu than what iOS devices need:
scripts/build-libjxl-xcframework.sh \
  --ios-mcpu apple-a12 --ios-mtune apple-m4 \
  --catalyst-mcpu apple-a14 --catalyst-mtune apple-m4

scripts/build-libjxl-xcframework.sh --help                           # full list of flags
```

The script clones [`libjxl`](https://github.com/libjxl/libjxl) at the configured tag (default `v0.11.1`), builds the **decoder-only** path (no encoder, tools, plugins, examples, or tests), merges the resulting static archives — `libjxl_dec`, `libhwy`, `libbrotli{dec,common}`, `libskcms` — into a single `.a` per slice via `libtool`, and packages the result as `vendor/libjxl.xcframework/`. The bundle includes a synthesized `module.modulemap` so Swift can `import libjxl` directly.

`vendor/libjxl.xcframework/` is `.gitignore`d. Re-run the script whenever you change CPU flags, the `libjxl` tag, or pull a fresh checkout.

### 2. Build the app/extensions in Xcode

1. Open `jpegxlbp.xcodeproj`.
2. Adjust the Development Team for signing. Xcode may also ask you to adjust the bundle identifiers to unique strings. In this case, simply append a random number to the existing identifiers of both the host app and all app extensions.
3. Build / run as usual.

### CPU-tuning flags

Performance-critical code (`libjxl`, [`Highway`](https://github.com/google/highway), `brotli`, `skcms`) is built by `scripts/build-libjxl-xcframework.sh`, so the **script's `--mcpu` / `--mtune` / `--march` flags are the perf knob that actually matters**. The Xcode project also carries identical flags in `OTHER_CFLAGS`, `OTHER_CPLUSPLUSFLAGS`, and `OTHER_SWIFT_FLAGS` (project-level Debug + Release) so our small Swift wrapper and any future C/C++ source compiles consistently. Keep both sets in sync when retargeting.

1. **`-mcpu` vs `-mtune` on AArch64.** `-mcpu=X` sets *both* the instruction-set baseline and the tuning model for X. `-mtune=Y` *overrides* tuning to Y while keeping the X instruction-set baseline. The default `--mcpu apple-a12 --mtune apple-m4` produces "one binary, runs on A12+, scheduled for M4." If you ship per-CPU binaries, drop `--mtune` entirely and let `--mcpu` imply the tuning. Don't try to mirror the value (`--mcpu X --mtune X`) — it's the same as `--mcpu X` alone.
2. **Per-platform baselines.** `--mcpu`/`--mtune`/`--march` set the global default. `--ios-*` and `--catalyst-*` override those for the corresponding slices. Catalyst-only Macs are M1+, so a higher Catalyst baseline (`--catalyst-mcpu apple-a14` or higher) is a free perf win without affecting iOS device support. iOS device + iOS simulator slices both follow the `--ios-*` settings.
3. **`Highway` runtime SIMD dispatch.** `Highway` picks the best available SIMD path *at runtime*, so static `--mcpu` mainly controls which `Highway` baselines compile in (NEON, SVE, etc.) and scalar codegen — not which path actually runs. The biggest wins from raising `--mcpu` come on devices with new ISA features (e.g., SVE on M4+).
4. **Intel x86_64.** For x86_64 Mac / Simulator slices, use `--march=...` (clang doesn't accept `-mcpu` on x86). The Swift-side `-target-cpu` and `-Xllvm -mcpu` flags in `project.pbxproj` *do* take `-mcpu`-style values even on x86 — they have no `-march` / `-mtune` equivalents. CPU model names are the same across `-march`, `-mtune`, and `-mcpu`. When building on the same Mac you'll target, `--march native` / `--mtune native` lets clang detect and squeeze everything out. Squirrels!
5. **Excluded architectures.** `EXCLUDED_ARCHS = x86_64` is set in `project.pbxproj`, so Catalyst / Simulator builds default to `arm64` only. To build `x86_64` slices, flip that to `arm64` and pass `--include-x86_64 --march=...` to the `libjxl` script.

> Debug builds of `libjxl` are dramatically slower than Release. They're subject to low-memory termination as App Extensions are capped at 50–100 MB of RAM, and the app quickly hits that limit in Debug, especially on older devices. Always benchmark / daily-drive Release.

---
