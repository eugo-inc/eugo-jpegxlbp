# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Backport of native JPEG XL (`.jxl`) viewing/thumbnailing to iOS / iPadOS 15 and 16 (which predate Apple's built-in support added in iOS 17). Implemented as a thin Swift wrapper around [SDWebImageJPEGXLCoder](https://github.com/SDWebImage/SDWebImageJPEGXLCoder), which in turn wraps `libjxl`. Mac Catalyst is configured but untested. There is no test suite.

## Build / run

Building requires macOS + Xcode (this is an Xcode project, not SPM-buildable on its own). The shared schemes are `jpegxlbp`, `previewext`, `thumbext`.

```bash
# Build the host app for an iOS Simulator
xcodebuild -project jpegxlbp.xcodeproj -scheme jpegxlbp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build a single extension
xcodebuild -project jpegxlbp.xcodeproj -scheme previewext \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Mac Catalyst (untested upstream)
xcodebuild -project jpegxlbp.xcodeproj -scheme jpegxlbp \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

Notes when building:
- Adjust the Development Team for signing; Xcode may require unique bundle IDs (defaults: `io.eugo.experiments.jpegxlbp[.previewext|.thumbext]`).
- `EXCLUDED_ARCHS = x86_64` is set, so Catalyst/Simulator builds default to `arm64` only. Flip it if you need `x86_64`.
- **Always benchmark / daily-drive Release builds.** Debug builds of `libjxl` are dramatically slower and routinely hit the 50–100 MB extension memory cap, especially on older devices.
- SPM dependencies (`SDWebImage` ≥ 5.21.6, `SDWebImageJPEGXLCoder` ≥ 0.2.0) are pinned in `jpegxlbp.xcodeproj/project.pbxproj`. Resolution happens automatically in Xcode; for CI use `-resolvePackageDependencies`.

### CPU-tuning flags (load-bearing)

`libjxl`/`brotli` SIMD perf depends on the build flags hard-coded in `project.pbxproj`:

- C/C++/ObjC: `-mcpu=apple-a12 -mtune=apple-m4`
- Swift: `OTHER_SWIFT_FLAGS = -target-cpu apple-a12 -Xcc -mcpu=apple-a12 -Xcc -mtune=apple-m4 -Xllvm -mcpu=apple-a12`

When changing CPU targets, update **all four places** consistently. On Intel hosts (`x86_64` Mac / Simulator) use `-march=...` for clang but keep `-mcpu` for the `-Xllvm` and `-target-cpu` Swift flags — they have no `-march` equivalent. README.md has the full rationale; keep it as the source of truth and update it alongside any flag change.

Caveat noted in README TODOs: these flags are **not** propagated into SPM dependencies, so `libjxl` itself is not built with the same `-mcpu`/`-mtune`. Don't assume the dependency picked up your tuning.

## Architecture

Three independent targets, all Swift, no shared code:

1. `jpegxlbp/` — UIKit host app. Its only real job is to be a container that ships the two app extensions and to declare the JPEG XL UTIs (`public.jpeg-xl`, `org.jpeg-xl`) and `CFBundleDocumentTypes` in `Info.plist`. The view controller is empty.
2. `previewext/` — `QLPreviewProvider` (`PreviewProvider.swift`). Invoked **once per image** by QuickLook. Decodes the `.jxl` into a `UIImage` via `SDImageJPEGXLCoder.shared`, then re-encodes to JPEG at `compressionQuality: 1.0` and returns it as a `QLPreviewReply(dataOfContentType: .jpeg, ...)`. The force-unwrap on `jpegData` is intentional — the decoded image is guaranteed valid at that point.
3. `thumbext/` — `QLThumbnailProvider` (`ThumbnailProvider.swift`). Invoked **per N images**, where the system reuses the process across many requests; this makes it OOM-prone. Uses `SDImageCoderOption` keys (`decodeThumbnailPixelSize`, `decodeScaleFactor`, `decodePreserveAspectRatio`) to avoid full-resolution decoding, and draws into the current graphics context (one of the three `QLThumbnailReply` modes — only one is meant to be used).

Extensions don't IPC with each other or the host app and are self-contained — either can be removed without affecting the other. On a jailbroken device, extensions can in theory be installed without the host.

### When touching extension code

- The thumbnail extension is the memory-sensitive one. Decoding at full resolution there is a regression even if the preview extension does it. Always pass thumbnail-pixel-size options.
- `QLPreviewReply` has multiple constructors (data-of-content-type, file-URL, drawing-context). The preview extension uses the data form; the thumbnail extension uses the drawing form. Don't mix them — pick one per `QLThumbnailReply`.
- `Info.plist` for each extension wires up `NSExtensionPointIdentifier`, `NSExtensionPrincipalClass`, and `QLSupportedContentTypes`. If you add a new file format, you must touch all three plus the host app's UTI declarations.
- Both extensions must remain compatible with iOS 15 (the `IPHONEOS_DEPLOYMENT_TARGET` for the extension targets); APIs newer than iOS 15 require `@available` guards.
