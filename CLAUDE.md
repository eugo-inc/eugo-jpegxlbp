# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Backport of native JPEG XL (`.jxl`) viewing/thumbnailing to iOS / iPadOS 15 and 16 (which predate Apple's built-in support added in iOS 17). Decoding goes through a vendored libjxl XCFramework via a thin Swift wrapper (`Shared/JXLDecoder.swift`); SPM dependencies have been removed so we control libjxl's build flags. Mac Catalyst is configured but untested. There is no test suite.

## Build / run

Building requires macOS + Xcode (this is an Xcode project). Two-step build:

```bash
# 1. Build the libjxl XCFramework (one-time, or whenever you change CPU flags
#    or libjxl version). Output: vendor/libjxl.xcframework/.
scripts/build-libjxl-xcframework.sh                    # defaults: apple-a12, no -mtune
scripts/build-libjxl-xcframework.sh --mcpu apple-a14   # newer CPU baseline
scripts/build-libjxl-xcframework.sh --mcpu apple-a12 --mtune apple-m4

# Per-platform overrides (Catalyst is M1+ today, so it can take a higher
# baseline than what iOS device slices need):
scripts/build-libjxl-xcframework.sh \
  --ios-mcpu apple-a12 --ios-mtune apple-m4 \
  --catalyst-mcpu apple-a14 --catalyst-mtune apple-m4

# 2. Build the app / extension as usual via Xcode or xcodebuild.
xcodebuild -project jpegxlbp.xcodeproj -scheme jpegxlbp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
xcodebuild -project jpegxlbp.xcodeproj -scheme previewext \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
xcodebuild -project jpegxlbp.xcodeproj -scheme jpegxlbp \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

`vendor/libjxl.xcframework/` is `.gitignore`d — every fresh checkout must run the script before opening Xcode, or Xcode shows a missing-reference warning.

Notes when building:
- Adjust the Development Team for signing; Xcode may require unique bundle IDs (defaults: `io.eugo.experiments.jpegxlbp[.previewext|.thumbext]`).
- `EXCLUDED_ARCHS = x86_64` is set, so Catalyst/Simulator builds default to `arm64` only. Flip it if you need `x86_64`, and pass `--include-x86_64 --march=...` to the libjxl script.
- **Always benchmark / daily-drive Release builds.** Debug builds of `libjxl` are dramatically slower and routinely hit the 50–100 MB extension memory cap, especially on older devices.

### CPU-tuning flags

Two places hold CPU flags and **must stay in sync**:

1. The XCFramework build — pass `--mcpu` (and optionally `--mtune`/`--march`) to `scripts/build-libjxl-xcframework.sh`. This is what governs libjxl/Highway/Brotli codegen, which is the perf-critical part. The script also accepts per-platform overrides: `--ios-mcpu`/`--ios-mtune`/`--ios-march` for iOS device + simulator slices, `--catalyst-mcpu`/`--catalyst-mtune`/`--catalyst-march` for Catalyst slices. Each per-platform flag falls back to the corresponding global flag when unset, so the simple form (`--mcpu X`) still applies everywhere.
2. The Xcode project — `OTHER_CFLAGS`, `OTHER_CPLUSPLUSFLAGS`, and `OTHER_SWIFT_FLAGS` in the project-level Debug+Release configs in `project.pbxproj` (currently `-mcpu=apple-a12 -mtune=apple-m4`). This governs our Swift code (which is small) and how Swift cross-imports libjxl. There's no per-platform split here — Xcode applies these uniformly across iOS / Catalyst targets.

`-mcpu` vs `-mtune` on AArch64: `-mcpu=X` sets *both* the instruction-set baseline and the tuning model for X. `-mtune=Y` then *overrides* tuning to Y while keeping the X instruction-set baseline. So `-mcpu=apple-a12 -mtune=apple-m4` means "binary runs on A12+, scheduled for M4." Drop `-mtune` only if you ship per-CPU binaries — for a single fat binary that supports A12 through current chips, the dual flag is correct.

Per-platform note: Catalyst-only Macs are M1+ (i.e., A14-equivalent at minimum), so `--catalyst-mcpu apple-a14` (or higher) is a free perf win that doesn't affect iOS device support. The script's iOS slices are the constraint, not Catalyst.

Note that libjxl uses [Highway](https://github.com/google/highway) for SIMD and dispatches at *runtime* — so `--mcpu` mainly governs which Highway baselines compile in (NEON, SVE, etc.) and scalar codegen, not which SIMD path actually runs. The biggest wins from raising `--mcpu` come on devices that gain new ISA features (e.g., SVE on M4+).

On Intel hosts (`x86_64` Mac/Simulator) use `--march=...` for clang flags. Apple Swift's `-target-cpu` and `-Xllvm -mcpu` have no `-march` equivalent and require `-mcpu`-style values even on x86 — see README.md for the full rationale.

## Architecture

Three independent Swift targets and one shared file:

1. `jpegxlbp/` — UIKit host app. Its only real job is to be a container that ships the two app extensions and to declare the JPEG XL UTIs (`public.jpeg-xl`, `org.jpeg-xl`) and `CFBundleDocumentTypes` in `Info.plist`. The view controller is empty.
2. `previewext/` — `QLPreviewProvider` (`PreviewProvider.swift`). Invoked **once per image** by QuickLook. Decodes the `.jxl` via `JXLDecoder.decode`, then re-encodes to JPEG at `compressionQuality: 1.0` and returns it as a `QLPreviewReply(dataOfContentType: .jpeg, ...)`. The force-unwrap on `jpegData` is intentional — the decoded image is guaranteed valid at that point.
3. `thumbext/` — `QLThumbnailProvider` (`ThumbnailProvider.swift`). Invoked **per N images** because the system reuses the process across many requests; this makes it OOM-prone. Calls `JXLDecoder.decode(_:maxDimension:)` with the request's max size (× scale) so we never hold a full-resolution decode in memory longer than necessary. Draws the result into the current graphics context (one of the three `QLThumbnailReply` modes — only one is meant to be used).
4. `Shared/JXLDecoder.swift` — small wrapper around the `JxlDecoder*` C API. Single static `decode(_:maxDimension:)` entry point returning a `UIImage`. RGBA8, straight (un-premultiplied) alpha — see the comment at the `CGImageAlphaInfo.last` site if you change the pixel format. Both extension targets compile this file in directly (no framework boundary).

Extensions don't IPC with each other or the host app and are self-contained — either can be removed without affecting the other. On a jailbroken device, extensions can in theory be installed without the host.

### When touching extension code

- The thumbnail extension is the memory-sensitive one. Always pass `maxDimension:` to `JXLDecoder.decode` there. The current libjxl 0.11 API has no zero-copy "decode at smaller size" for non-progressive images, so the wrapper does decode-then-CG-downscale; if libjxl gains progressive-only-low-passes API in future, that's the place to rework.
- `QLPreviewReply` has multiple constructors (data-of-content-type, file-URL, drawing-context). The preview extension uses the data form; the thumbnail extension uses the drawing form. Don't mix them — pick one per `QLThumbnailReply`.
- `Info.plist` for each extension wires up `NSExtensionPointIdentifier`, `NSExtensionPrincipalClass`, and `QLSupportedContentTypes`. If you add a new file format, you must touch all three plus the host app's UTI declarations.
- Both extensions must remain compatible with iOS 15 (the `IPHONEOS_DEPLOYMENT_TARGET` for the extension targets); APIs newer than iOS 15 require `@available` guards.

### When touching the libjxl integration

- `scripts/build-libjxl-xcframework.sh` builds **decoder only** (`jxl_dec` static lib + Highway + Brotli + skcms, all merged via `libtool -static` into a single archive per slice). If you ever need encode (e.g., to roundtrip the preview extension via JXL instead of JPEG), flip `JPEGXL_ENABLE_TOOLS` in the cmake invocation and harvest `libjxl.a` instead of `libjxl_dec.a`.
- The XCFramework includes a synthesized `module.modulemap` named `libjxl` (umbrella'd over the `jxl/` headers) so `import libjxl` works from Swift. Don't rename the module without updating `Shared/JXLDecoder.swift`.
- Static XCFrameworks (this one) are linked at build time, not embedded — App Extensions on iOS forbid embedded frameworks, so static is the only viable choice anyway.
