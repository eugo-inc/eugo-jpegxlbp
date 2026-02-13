# JPEG XL Backport

This is a small sample project demonstrating backporting JPEG XL support for Files (Finder) app.
It adds support for viewing JPEG XL images (`.jxl`) in the Files QuickLook Preview. 
What's more, it automatically generates thumbnails for them.

It's implemented as a thin wrapper around [SDWebImageJPEGXLCoder](https://github.com/SDWebImage/SDWebImageJPEGXLCoder.git), which is in turn a wrapper around reference JPEG XL implementation - [libjxl](https://github.com/SDWebImage/libjxl-Xcode).
---


## Trivia

Apple OSs added native support for JPEG XL in 2023 release line:
1. iOS / iPadOS 17.0+
2. tvOS 17.0+
3. watchOS 10.0+
4. visionOS 1.0+
5. macOS Sonoma 14.0+. macOS 12.x (Monterey) and 13.x (Ventura) have partial support if Safari 17+ is installed, but it works only within a browser itself.

> If you're on any of the supported systems, you probably shouldn't use this app, because the system built-in JPEG XL implementation is faster and more resilient per my observations (even if it's also mostly a wrapper around the same `libjxl`).

For R'n'D purposes we have a zoo of devices "frozen" to iOS / iPadOS 15 and 16, which predates JPEG XL official introduction. To overcome that, this wrapper has been quickly coded.
---


## Requirements
1. OS: 
    1. iOS / iPadOS: 15 and 16. Newer versions are also supported, 
    2. macOS support is available via Mac Catalyst target, but it has never been tested. 
        1. (!) There is reported issue when `SDWebImageJPEGXLCoder` is built for macOS AppKit runtime: https://github.com/SDWebImage/SDWebImageJPEGXLCoder/issues/3
2. CPU: Apple A12+ - will almost certainly work on all modern `arm64` Apple Silicons, but hasn't been tested on older targets. You're welcome to adjust the build settings (see below) and share if older targets are supported!
3. Jailbreak: not required. Private APIs aren't used either.
---


## Architecture 
1. `jpegxlbp` - nothing but a host (container) app to register 2 App Extensions, actually doing all the hard work.
2. `previewext` - QuickLook Preview Extension.
3. `thumbext` - QuickLook Thumbnail Extension.
4. Extensions are self-contained and don't communicate with each other nor with the host app, so you can safely remove ones which you don't need in your use case. On jailbroken device, you in theory can install extensions without the host app.
---


## Build Instructions
1. Adjust the Development Team for signing. Xcode may also ask you to adjust the bundle identifiers to unique strings - in this case, simply append some random numbers to the existing identifiers of both the host app and all app extensions.
2. Underlying `libjxl` hugely benefits from SIMD intrinsics, so the build is configured to minimally target Apple A12 (`-mcpu`) but also benefit from dynmaic dispatch of instructions found in newer CPUs up to the latest (at the moment of writing) Apple M5 (`-mtune`). 
    1. If building for older devices, you should adjust `-mcpu=` value appropriately for your target. 
    2. If you're building for newer devices, you can get higher peformance in the same way - by adjusting `-mcpu` to your oldest target silicon. In case if you only have 1 target CPU, you should set that via `-mcpu` and remove `-mtune` entirely.
    3. For Intel Macs and iOS / iPadOS Simulators on them, you should use `-march` in place of `-mcpu`. Moreover, even if you support only 1 CPU , you shouldn't remove `-mtune` but set it to be equal to the same value as `-mcpu`. For example, `-march=sapphirerapids -mtune=sapphirerapids`.
    
> Be aware, that Debug builds exhibit much lower performance than Release ones for `libjxl`. As a result, you shouldn't use them for benchmarking or daily use - they are subject to law memory termination as App Extensions are limited to 5-10 MB RAM and it's quickly hit in Debug builds, especially on older devices. 
---


## TODOs:
1. Redesign to use 
