# JPEG XL Backport

This is a small sample project demonstrating how to backport JPEG XL support to older iOS and iPadOS versions.
It allows viewing JPEG XL images (`.jxl`) natively in the QuickLook Preview (e.g., in Files or Finder app). 
What's more, it automatically generates thumbnails for them.

It's implemented as a thin wrapper around [SDWebImageJPEGXLCoder](https://github.com/SDWebImage/SDWebImageJPEGXLCoder.git), which in turn wraps around reference JPEG XL implementation - [libjxl](https://github.com/SDWebImage/libjxl-Xcode).

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
        1. (!) There is a reported issue when `SDWebImageJPEGXLCoder` is built for macOS AppKit runtime: https://github.com/SDWebImage/SDWebImageJPEGXLCoder/issues/3
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
1. Adjust the Development Team for signing. Xcode may also ask you to adjust the bundle identifiers to unique strings. In this case, simply append a random number to the existing identifiers of both the host app and all app extensions.
2. Underlying dependencies (like `libjxl` and, transitively, `brotli`) hugely benefits from SIMD intrinsics, so the build is configured to minimally target Apple A12 (`-mcpu`) but also benefit from dynamic dispatch of instructions found in newer CPUs up to the latest (at the moment of writing) Apple M5 (`-mtune`). 
    1. If building for older devices, you should adjust the `-mcpu=` value appropriately for your target. 
    2. If you're building for newer devices, you can get higher performance in the same way - by adjusting `-mcpu` to your oldest supported CPU. If you only have 1 target CPU, you set it with `-mcpu` and remove `-mtune` entirely.
    3. For Intel Macs and iOS / iPadOS Simulators on them, you should use `-march` in place of `-mcpu`. Moreover, even if you support only 1 CPU model, you shouldn't remove `-mtune` but set it to be equal to the same value as `-mcpu`. For example, `-march=sapphirerapids -mtune=sapphirerapids`. A few exceptions apply:
        1. `-Xllvm` proxy-flag from `Other Swift Flags` requires special care. It doesn't support `-march` and `-mtune` - even on `x86_64`, it requires passing `-mcpu`. Good news, the CPU model names are the same for both `-march`, `-mtune`, and `-mcpu` on these platforms.
        2. `-target-cpu` from `Other Swift Flags` also requires passing the same CPU model value and doesn't have `-march` and `-mtune` analogues.
        3. @Important: When building for a Mac on the **same** Mac, you can simply pass `-march=native` and `-mtune=native` to allow the compiler to detect the CPU and squeeze every bit of performance out of it. Squirrels! 
    4. To reduce the build time and avoid cryptic errors, exclude architectures you don't want to build via `"Build Settings"#"Excluded Architectures"`. 
        1. By default, on macOS Catalyst, Xcode performs the multi-architecture (`x86_64` + `arm64`) build. 
        2. We, however, by default, exclude `x86_64`, as `arm64` is the most common use case for this app, but if you want to build `x86_64` Mac Catalyst or iOS / iPadOS Simulator variant, you should do it the other way round and replace `x86_64` with `arm64`.
    
> Be aware that Debug builds exhibit much lower performance than Release ones for `libjxl`. As a result, you shouldn't use them for benchmarking or daily use. They are subject to low-memory termination as App Extensions are limited to 50-100 MB of RAM, and the app quickly hits that limit in Debug builds, especially on older devices. 

---


## TODOs:

1. Redesign to propagate optimization flags down to SPM packages. This doesn't work out of the box, so the dependencies don't have the same optimizations as the app and extensions.

---
