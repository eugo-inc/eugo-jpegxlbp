#!/usr/bin/env bash
#
# Builds libjxl as a static XCFramework for Apple platforms (iOS device,
# iOS simulator, Mac Catalyst) and packages it under vendor/libjxl.xcframework.
#
# Run this on macOS with Xcode + CMake installed. Output is what the .xcodeproj
# expects in vendor/ — once built, just open the project in Xcode and build.
#
# Usage:
#   scripts/build-libjxl-xcframework.sh [options]
#
# Options:
#   --mcpu <model>          AArch64 baseline CPU model (default: apple-a12).
#                           Sets the minimum instruction set Highway/scalar code
#                           may use. Lower = wider device support, higher = better
#                           codegen. Apple's published mappings: apple-a12 (A12),
#                           apple-a14 (A14/M1), apple-a16 (A16), apple-m4, etc.
#                           Used as default for all platforms; override per
#                           platform with --ios-mcpu / --catalyst-mcpu below.
#   --mtune <model>         AArch64 tuning model (default: empty / not passed).
#                           When set, schedules code for that newer microarch
#                           while keeping the --mcpu instruction-set baseline.
#                           Pass e.g. apple-m4 to optimize for the newest CPUs
#                           while staying compatible with --mcpu.
#                           Omit for "best per-CPU" — but only useful if you ship
#                           per-CPU binaries.
#   --march <model>         x86_64 baseline CPU (default: empty). Required for
#                           Intel Mac / Intel Simulator slices. Mutually
#                           exclusive with --mcpu for those slices.
#
#   --ios-mcpu <model>      Override --mcpu for iOS device + iOS simulator
#   --ios-mtune <model>     slices specifically. Useful when iOS needs an
#   --ios-march <model>     older CPU baseline than Catalyst (Apple Silicon).
#                           Each defaults to the matching global flag.
#   --catalyst-mcpu <model> Override --mcpu / --mtune / --march for Mac
#   --catalyst-mtune <model> Catalyst slices specifically. Catalyst-only Macs
#   --catalyst-march <model> are M1+ today, so --catalyst-mcpu apple-a14 (or
#                           higher) is a safe perf win there. Each defaults
#                           to the matching global flag.
#   --libjxl-tag <tag>      libjxl git tag/ref (default: v0.11.1).
#   --min-ios <ver>         iOS deployment target (default: 15.0).
#   --skip-catalyst         Skip Mac Catalyst slices.
#   --skip-simulator        Skip iOS Simulator slices.
#   --skip-x86_64           Skip x86_64 slices everywhere (default: skip).
#   --include-x86_64        Include x86_64 simulator/Catalyst slices. Requires
#                           --march or it will fall back to --mcpu (which Clang
#                           rejects on x86_64).
#   --jobs <n>              Parallel build jobs (default: $(sysctl hw.ncpu)).
#   --out <dir>             Output directory (default: vendor).
#   --work <dir>            Build/scratch directory (default: .build/libjxl).
#   --keep-work             Don't delete the work dir after success.
#   -h, --help              Show this help.
#
# Notes:
#   - Builds DECODER ONLY. libjxl's encoder, jpegli, plugins, examples, tools,
#     tests, and viewers are all disabled. If you need encode (e.g. for the
#     preview extension to roundtrip via JPEG XL instead of JPEG) flip
#     JPEGXL_ENABLE_TOOLS / build libjxl.a (encoder+decoder) instead of
#     libjxl_dec.a in the cmake invocation below.
#   - Statically links Highway + Brotli + skcms into a single combined archive
#     per slice via libtool, so the resulting XCFramework is one .a per slice
#     and Xcode only has to add one Link Binary entry.
#   - The XCFramework includes a synthesized module.modulemap so Swift can
#     `import libjxl` directly.

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
MCPU="apple-a12"
MTUNE=""
MARCH=""
# Per-platform overrides; empty = fall back to MCPU/MTUNE/MARCH.
IOS_MCPU=""
IOS_MTUNE=""
IOS_MARCH=""
CAT_MCPU=""
CAT_MTUNE=""
CAT_MARCH=""
LIBJXL_TAG="v0.11.1"
MIN_IOS="15.0"
SKIP_CATALYST=0
SKIP_SIMULATOR=0
INCLUDE_X86_64=0
JOBS=""
OUT_DIR="vendor"
WORK_DIR=".build/libjxl"
KEEP_WORK=0

# ---- argparse ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mcpu)             MCPU="$2"; shift 2 ;;
    --mtune)            MTUNE="$2"; shift 2 ;;
    --march)            MARCH="$2"; shift 2 ;;
    --ios-mcpu)         IOS_MCPU="$2"; shift 2 ;;
    --ios-mtune)        IOS_MTUNE="$2"; shift 2 ;;
    --ios-march)        IOS_MARCH="$2"; shift 2 ;;
    --catalyst-mcpu)    CAT_MCPU="$2"; shift 2 ;;
    --catalyst-mtune)   CAT_MTUNE="$2"; shift 2 ;;
    --catalyst-march)   CAT_MARCH="$2"; shift 2 ;;
    --libjxl-tag)       LIBJXL_TAG="$2"; shift 2 ;;
    --min-ios)          MIN_IOS="$2"; shift 2 ;;
    --skip-catalyst)    SKIP_CATALYST=1; shift ;;
    --skip-simulator)   SKIP_SIMULATOR=1; shift ;;
    --skip-x86_64)      INCLUDE_X86_64=0; shift ;;
    --include-x86_64)   INCLUDE_X86_64=1; shift ;;
    --jobs)             JOBS="$2"; shift 2 ;;
    --out)              OUT_DIR="$2"; shift 2 ;;
    --work)             WORK_DIR="$2"; shift 2 ;;
    --keep-work)        KEEP_WORK=1; shift ;;
    -h|--help)          sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; /^set /d'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$JOBS" ]] && JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Resolve per-platform CPU flags by falling back to the globals when the
# per-platform override wasn't passed. Note: an explicit empty value via the
# CLI ("--ios-mtune ''") still falls through to the global because of the :-
# operator — which is the right call for ergonomics. To omit a flag for one
# platform but keep it on another, leave the global unset and only set the
# platform that needs it.
IOS_MCPU="${IOS_MCPU:-$MCPU}"
IOS_MTUNE="${IOS_MTUNE:-$MTUNE}"
IOS_MARCH="${IOS_MARCH:-$MARCH}"
CAT_MCPU="${CAT_MCPU:-$MCPU}"
CAT_MTUNE="${CAT_MTUNE:-$MTUNE}"
CAT_MARCH="${CAT_MARCH:-$MARCH}"

# ---- preflight --------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS (uses Xcode/xcodebuild/lipo)" >&2
  exit 1
fi
for tool in xcodebuild xcrun cmake git libtool lipo; do
  command -v "$tool" >/dev/null || { echo "error: missing $tool" >&2; exit 1; }
done

# repo root = parent of scripts/
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
WORK_DIR="$REPO_ROOT/$WORK_DIR"
OUT_DIR="$REPO_ROOT/$OUT_DIR"
SRC_DIR="$WORK_DIR/src"

mkdir -p "$WORK_DIR" "$OUT_DIR"

# ---- clone libjxl -----------------------------------------------------------
if [[ ! -d "$SRC_DIR/.git" ]]; then
  echo "==> Cloning libjxl@$LIBJXL_TAG"
  git clone --depth 1 --branch "$LIBJXL_TAG" --recursive \
    https://github.com/libjxl/libjxl.git "$SRC_DIR"
else
  echo "==> Reusing existing libjxl checkout at $SRC_DIR (delete to refresh)"
fi

# ---- per-slice build helper -------------------------------------------------
# build_slice <slice_name> <sdk> <arch> <cmake_system_name> \
#             <mcpu> <mtune> <march> [<extra_cmake_args>...]
build_slice() {
  local slice="$1"; shift
  local sdk="$1"; shift
  local arch="$1"; shift
  local system_name="$1"; shift
  local slice_mcpu="$1"; shift
  local slice_mtune="$1"; shift
  local slice_march="$1"; shift

  local build_dir="$WORK_DIR/build/$slice"
  local install_dir="$WORK_DIR/install/$slice"
  local sdk_path; sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  # Compose -mcpu / -mtune / -march into a single CFLAGS/CXXFLAGS string.
  local cpu_flags=""
  if [[ "$arch" == "x86_64" ]]; then
    if [[ -n "$slice_march" ]]; then
      cpu_flags="-march=$slice_march"
      [[ -n "$slice_mtune" ]] && cpu_flags="$cpu_flags -mtune=$slice_mtune"
    else
      echo "warn: building $slice ($arch) without --march; codegen will be generic" >&2
    fi
  else
    cpu_flags="-mcpu=$slice_mcpu"
    [[ -n "$slice_mtune" ]] && cpu_flags="$cpu_flags -mtune=$slice_mtune"
  fi

  echo "==> Configuring $slice ($arch, $sdk) [$cpu_flags]"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  cmake -S "$SRC_DIR" -B "$build_dir" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME="$system_name" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG $cpu_flags" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG $cpu_flags" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DJPEGXL_STATIC=ON \
    -DJPEGXL_ENABLE_TOOLS=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_VIEWERS=OFF \
    -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF \
    -DJPEGXL_ENABLE_JPEGLI=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON \
    -DJPEGXL_BUNDLE_LIBPNG=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF \
    -DJPEGXL_FORCE_SYSTEM_HWY=OFF \
    "$@"

  echo "==> Building $slice"
  cmake --build "$build_dir" --target jxl_dec --target hwy --parallel "$JOBS"
  # Brotli + skcms targets — names vary slightly across libjxl tags; harvest
  # whatever exists.
  cmake --build "$build_dir" --parallel "$JOBS" --target \
    brotlidec brotlicommon skcms 2>/dev/null || true

  # ---- gather & merge static archives into one combined.a ----
  local merged="$install_dir/lib/libjxl-combined.a"
  mkdir -p "$install_dir/lib" "$install_dir/include"

  # Collect every .a we care about. Use find to be tolerant of layout changes
  # between libjxl versions.
  local archives=()
  while IFS= read -r a; do archives+=("$a"); done < <(
    find "$build_dir" -type f \( \
      -name 'libjxl_dec.a' -o \
      -name 'libjxl_dec-static.a' -o \
      -name 'libhwy.a' -o \
      -name 'libbrotlidec.a' -o \
      -name 'libbrotlicommon.a' -o \
      -name 'libskcms.a' \
    \) 2>/dev/null | sort -u
  )

  if [[ ${#archives[@]} -eq 0 ]]; then
    echo "error: no static archives found in $build_dir" >&2
    exit 1
  fi

  echo "==> Merging ${#archives[@]} archives -> $merged"
  libtool -static -o "$merged" "${archives[@]}"

  # Headers — libjxl ships them under build/lib/include/jxl/ generated from
  # the source tree.
  rm -rf "$install_dir/include"
  mkdir -p "$install_dir/include/jxl"
  # Copy public headers (source-side + generated).
  cp -R "$SRC_DIR"/lib/include/jxl/. "$install_dir/include/jxl/" 2>/dev/null || true
  # Generated headers (jxl_export.h, version.h, etc.) live under the build dir.
  find "$build_dir" -path '*/lib/include/jxl/*.h' -exec cp {} "$install_dir/include/jxl/" \; 2>/dev/null || true
}

# ---- iOS device (arm64) -----------------------------------------------------
build_slice ios-arm64 iphoneos arm64 iOS \
  "$IOS_MCPU" "$IOS_MTUNE" "$IOS_MARCH"

# ---- iOS simulator ----------------------------------------------------------
if [[ "$SKIP_SIMULATOR" -eq 0 ]]; then
  build_slice ios-sim-arm64 iphonesimulator arm64 iOS \
    "$IOS_MCPU" "$IOS_MTUNE" "$IOS_MARCH" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  if [[ "$INCLUDE_X86_64" -eq 1 ]]; then
    build_slice ios-sim-x86_64 iphonesimulator x86_64 iOS \
      "$IOS_MCPU" "$IOS_MTUNE" "$IOS_MARCH"
  fi
fi

# ---- Mac Catalyst -----------------------------------------------------------
# Catalyst uses macosx SDK + special triple. CMake's iOS toolchain doesn't
# directly support Catalyst, so we set platform flags explicitly.
if [[ "$SKIP_CATALYST" -eq 0 ]]; then
  CATALYST_FLAGS_ARM="-target arm64-apple-ios${MIN_IOS}-macabi"
  CATALYST_FLAGS_X64="-target x86_64-apple-ios${MIN_IOS}-macabi"
  build_slice catalyst-arm64 macosx arm64 Darwin \
    "$CAT_MCPU" "$CAT_MTUNE" "$CAT_MARCH" \
    -DCMAKE_C_FLAGS="$CATALYST_FLAGS_ARM" \
    -DCMAKE_CXX_FLAGS="$CATALYST_FLAGS_ARM"
  if [[ "$INCLUDE_X86_64" -eq 1 ]]; then
    build_slice catalyst-x86_64 macosx x86_64 Darwin \
      "$CAT_MCPU" "$CAT_MTUNE" "$CAT_MARCH" \
      -DCMAKE_C_FLAGS="$CATALYST_FLAGS_X64" \
      -DCMAKE_CXX_FLAGS="$CATALYST_FLAGS_X64"
  fi
fi

# ---- lipo per-platform fat slices where needed ------------------------------
fat() {
  local out_lib="$1"; shift
  echo "==> Lipo'ing $(basename "$(dirname "$out_lib")") ($(echo "$@" | tr ' ' ',' ))"
  lipo -create "$@" -output "$out_lib"
}

# Sim: we have arm64 always; add x86_64 if requested.
SIM_DIR="$WORK_DIR/install/ios-sim-fat"
rm -rf "$SIM_DIR"; mkdir -p "$SIM_DIR/lib" "$SIM_DIR/include"
if [[ "$SKIP_SIMULATOR" -eq 0 ]]; then
  cp -R "$WORK_DIR/install/ios-sim-arm64/include/." "$SIM_DIR/include/"
  if [[ "$INCLUDE_X86_64" -eq 1 ]]; then
    fat "$SIM_DIR/lib/libjxl-combined.a" \
      "$WORK_DIR/install/ios-sim-arm64/lib/libjxl-combined.a" \
      "$WORK_DIR/install/ios-sim-x86_64/lib/libjxl-combined.a"
  else
    cp "$WORK_DIR/install/ios-sim-arm64/lib/libjxl-combined.a" "$SIM_DIR/lib/"
  fi
fi

# Catalyst: same pattern.
CAT_DIR="$WORK_DIR/install/catalyst-fat"
rm -rf "$CAT_DIR"; mkdir -p "$CAT_DIR/lib" "$CAT_DIR/include"
if [[ "$SKIP_CATALYST" -eq 0 ]]; then
  cp -R "$WORK_DIR/install/catalyst-arm64/include/." "$CAT_DIR/include/"
  if [[ "$INCLUDE_X86_64" -eq 1 ]]; then
    fat "$CAT_DIR/lib/libjxl-combined.a" \
      "$WORK_DIR/install/catalyst-arm64/lib/libjxl-combined.a" \
      "$WORK_DIR/install/catalyst-x86_64/lib/libjxl-combined.a"
  else
    cp "$WORK_DIR/install/catalyst-arm64/lib/libjxl-combined.a" "$CAT_DIR/lib/"
  fi
fi

# ---- module.modulemap for Swift `import libjxl` -----------------------------
write_modulemap() {
  local include_dir="$1"
  cat > "$include_dir/module.modulemap" <<'EOF'
module libjxl {
    umbrella "jxl"
    export *
    module * { export * }
    link "c++"
}
EOF
}

write_modulemap "$WORK_DIR/install/ios-arm64/include"
[[ "$SKIP_SIMULATOR" -eq 0 ]] && write_modulemap "$SIM_DIR/include"
[[ "$SKIP_CATALYST"  -eq 0 ]] && write_modulemap "$CAT_DIR/include"

# ---- create XCFramework -----------------------------------------------------
XCF="$OUT_DIR/libjxl.xcframework"
rm -rf "$XCF"

XCF_ARGS=(
  -library "$WORK_DIR/install/ios-arm64/lib/libjxl-combined.a"
  -headers "$WORK_DIR/install/ios-arm64/include"
)
if [[ "$SKIP_SIMULATOR" -eq 0 ]]; then
  XCF_ARGS+=(
    -library "$SIM_DIR/lib/libjxl-combined.a"
    -headers "$SIM_DIR/include"
  )
fi
if [[ "$SKIP_CATALYST" -eq 0 ]]; then
  XCF_ARGS+=(
    -library "$CAT_DIR/lib/libjxl-combined.a"
    -headers "$CAT_DIR/include"
  )
fi

echo "==> Creating $XCF"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$XCF"

if [[ "$KEEP_WORK" -eq 0 ]]; then
  echo "==> Cleaning $WORK_DIR (pass --keep-work to preserve)"
  rm -rf "$WORK_DIR"
fi

echo
echo "Done. Open jpegxlbp.xcodeproj — the project already references $XCF."
