#!/usr/bin/env bash
# MVS AppImage Packaging Script
# Mirrors the Dockerfile layout and exclusion logic exactly.
# Usage:
#   ./package-appimage.sh                  # auto-detect arch, download from latest GitHub release
#   ./package-appimage.sh --arch amd64     # force amd64
#   ./package-appimage.sh --source PATH    # use local tarball instead of GitHub download
#
# System prerequisites (host must provide):
#   - gh (GitHub CLI) for default download path, or --source for local tarball
#   - libusb-1.0-0, libudev1, zlib1g (core runtime)
#   - libx11-6, libxcb-*, libgl1, libfontconfig1, ... (GUI X11 stack)
#   - These are NOT bundled - they must be on the target system.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mvs-appimage"
OUTPUT_DIR="${MVS_OUTPUT_DIR:-$PROJECT_ROOT/output}"

# AppImage metadata
APP_NAME="MVS"
APPIMAGE_TOOL_VERSION="continuous"
MVS_REPO="Alliance-Algorithm/hik-mvs"

# ── Argument parsing ──────────────────────────────────────────────────────────

TARGET_ARCH=""
SOURCE_TARBALL=""
RELEASE_TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --arch requires a value (amd64 or arm64)" >&2
                exit 1
            fi
            TARGET_ARCH="$2"
            shift 2
            ;;
        --source)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --source requires a path" >&2
                exit 1
            fi
            SOURCE_TARBALL="$2"
            shift 2
            ;;
        --release-tag)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --release-tag requires a value" >&2
                exit 1
            fi
            RELEASE_TAG="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--arch amd64|arm64] [--source PATH] [--release-tag TAG]"
            echo ""
            echo "Package the Hikvision MVS application as an AppImage."
            echo ""
            echo "Options:"
            echo "  --arch amd64|arm64       Target architecture (default: auto-detect from uname -m)"
            echo "  --source PATH            Direct path to MVS.tar.gz (bypass GitHub download)"
            echo "  --release-tag TAG        GitHub release tag to use (default: latest release)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--arch amd64|arm64] [--source PATH]" >&2
            exit 1
            ;;
    esac
done

# Auto-detect arch if not specified
if [[ -z "$TARGET_ARCH" ]]; then
    case "$(uname -m)" in
        x86_64)  TARGET_ARCH="amd64" ;;
        aarch64) TARGET_ARCH="arm64" ;;
        *)
            echo "Error: Unsupported host architecture: $(uname -m)" >&2
            echo "Use --arch to specify target explicitly." >&2
            exit 1
            ;;
    esac
fi

# ── Arch mapping (matches Dockerfile) ─────────────────────────────────────────

case "$TARGET_ARCH" in
    amd64)
        ARCH_TAG="x86_64"
        ARCH_DIR="64"
        ;;
    arm64)
        ARCH_TAG="aarch64"
        ARCH_DIR="aarch64"
        ;;
    *)
        echo "Error: Unsupported target arch: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

# appimagetool binary must match HOST arch (cross-packaging: x86 host → arm64 image)
ARCH="${ARCH_TAG}"   # runtime to embed (target)
export ARCH
case "$(uname -m)" in
    x86_64)  APPIMAGE_TOOL_SUFFIX="x86_64" ;;
    aarch64) APPIMAGE_TOOL_SUFFIX="aarch64" ;;
    *)
        echo "Error: Unsupported host architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

# ── Workspace ─────────────────────────────────────────────────────────────────

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

SRC="$WORKDIR/src"
APPDIR="$WORKDIR/AppDir"
mkdir -p "$SRC" "$OUTPUT_DIR"

# ── Locate source tarball ─────────────────────────────────────────────────────

DOWNLOAD_DIR="$WORKDIR/download"
if [[ -n "$SOURCE_TARBALL" ]]; then
    if [[ ! -f "$SOURCE_TARBALL" ]]; then
        echo "Error: Source tarball not found: $SOURCE_TARBALL" >&2
        exit 1
    fi
    [[ -n "$RELEASE_TAG" ]] || RELEASE_TAG="local"
else
    if ! command -v gh &>/dev/null; then
        echo "Error: gh (GitHub CLI) is required for GitHub download." >&2
        echo "Install: https://cli.github.com/  or use --source PATH for a local tarball." >&2
        exit 1
    fi

    if [[ -n "$RELEASE_TAG" ]]; then
        echo "── Downloading from GitHub release ($RELEASE_TAG) ───────────────────────────"
    else
        echo "── Downloading from latest GitHub release ──────────────────────────────────"
        RELEASE_TAG=$(gh release list --repo "$MVS_REPO" --limit 1 --json tagName --jq '.[0].tagName')
        if [[ -z "$RELEASE_TAG" ]]; then
            echo "Error: No releases found in $MVS_REPO" >&2
            exit 1
        fi
    fi
    echo "       Release: $RELEASE_TAG"

    mkdir -p "$DOWNLOAD_DIR"
    if ! gh release download "$RELEASE_TAG" \
        --repo "$MVS_REPO" \
        --pattern "mvs-sdk-${ARCH_TAG}.tar.gz" \
        --dir "$DOWNLOAD_DIR"; then
        echo "Error: Failed to download mvs-sdk-${ARCH_TAG}.tar.gz from $MVS_REPO (tag: $RELEASE_TAG)" >&2
        exit 1
    fi
    SOURCE_TARBALL="$DOWNLOAD_DIR/mvs-sdk-${ARCH_TAG}.tar.gz"
    if [[ ! -f "$SOURCE_TARBALL" ]]; then
        echo "Error: Download completed but file not found: $SOURCE_TARBALL" >&2
        exit 1
    fi
    echo "       Downloaded: $SOURCE_TARBALL"
fi

# ── Banner ────────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  MVS AppImage Packaging                                          ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Target arch:  $TARGET_ARCH  (dir: $ARCH_DIR)"
echo "║  Release:      $RELEASE_TAG"
echo "║  Source:       $SOURCE_TARBALL"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Extract source tarball ────────────────────────────────────────────

echo "── [1/6] Extracting source tarball ─────────────────────────────────────────"
tar -xzf "$SOURCE_TARBALL" -C "$SRC"
echo "       Done."

# ── Step 2: Build AppDir structure (mirrors Dockerfile) ───────────────────────

echo "── [2/6] Building AppDir structure ─────────────────────────────────────────"

# Core library layout: matches /opt/mvs-usb3-core in Dockerfile
CORE_LIB="$APPDIR/mvs-usb3-core/lib/$ARCH_DIR"
mkdir -p "$CORE_LIB"
mkdir -p "$APPDIR/mvs-usb3-core/MVFG"

# GUI layout: matches /opt/mvs-gui in Dockerfile
GUI_BIN="$APPDIR/mvs-gui/bin"
mkdir -p "$GUI_BIN"

# --- 2a: Copy core SDK libraries (preserve symlinks) ---
echo "       Copying core libraries..."
cp -a "$SRC/lib/$ARCH_DIR/." "$CORE_LIB/"

# --- 2b: Remove excluded core libraries (exactly matches Dockerfile) ---
echo "       Removing excluded core libraries..."

# Always remove vendor libusb (use system libusb instead)
rm -f "$CORE_LIB/libusb-1.0.so.0"

# Arch-specific exclusions (mirrors Dockerfile lines 35-80)
if [[ "$TARGET_ARCH" == "amd64" ]]; then
    rm -f \
        "$CORE_LIB/libCLAllSerial_gcc485_v3_0.so" \
        "$CORE_LIB/libCLProtocol_gcc485_v3_0.so" \
        "$CORE_LIB/libCLSerCOM.so" \
        "$CORE_LIB/libCLSerHvc.so" \
        "$CORE_LIB/libGCBase_gcc485_v3_0.so" \
        "$CORE_LIB/libGenCP_gcc485_v3_0.so" \
        "$CORE_LIB/liblog4cpp_gcc485_v3_0.so" \
        "$CORE_LIB/libLog_gcc485_v3_0.so" \
        "$CORE_LIB/libMvCameraControlWrapper.so" \
        "$CORE_LIB/libMvCameraControlWrapper.so.4.7.0.1" \
        "$CORE_LIB/libMvCamLVision.so" \
        "$CORE_LIB/libMvCamLVision.so.4.7.0.3" \
        "$CORE_LIB/libMVGigEVisionSDK.so" \
        "$CORE_LIB/libMVGigEVisionSDK.so.4.7.1.1" \
        "$CORE_LIB/libMVFGControl.so" \
        "$CORE_LIB/libMvProducerVIR.so" \
        "$CORE_LIB/libMvLCProducer.so" \
        "$CORE_LIB/MvLCProducer.so" \
        "$CORE_LIB/MvProducerGEV.cti" \
        "$CORE_LIB/MvFGProducerCML.cti" \
        "$CORE_LIB/MvFGProducerCXP.cti" \
        "$CORE_LIB/MvFGProducerGEV.cti" \
        "$CORE_LIB/MvFGProducerXoF.cti"
elif [[ "$TARGET_ARCH" == "arm64" ]]; then
    rm -f \
        "$CORE_LIB/libCLAllSerial_gcc494_v3_0.so" \
        "$CORE_LIB/libCLProtocol_gcc494_v3_0.so" \
        "$CORE_LIB/libCLSerCOM.so" \
        "$CORE_LIB/libGCBase_gcc494_v3_0.so" \
        "$CORE_LIB/libGenCP_gcc494_v3_0.so" \
        "$CORE_LIB/liblog4cpp_gcc494_v3_0.so" \
        "$CORE_LIB/libLog_gcc494_v3_0.so" \
        "$CORE_LIB/libMvCameraControlWrapper.so" \
        "$CORE_LIB/libMvCameraControlWrapper.so.4.7.0.1" \
        "$CORE_LIB/libMvCamLVision.so" \
        "$CORE_LIB/libMvCamLVision.so.4.7.0.3" \
        "$CORE_LIB/libMVGigEVisionSDK.so" \
        "$CORE_LIB/libMVGigEVisionSDK.so.4.7.1.1" \
        "$CORE_LIB/MvProducerGEV.cti"
fi

# --- 2c: Copy GUI binaries ---
echo "       Copying GUI files..."
cp -a "$SRC/bin/." "$GUI_BIN/"

# --- 2d: Remove excluded GUI items (matches Dockerfile lines 85-108) ---
echo "       Removing excluded GUI items..."
rm -rf \
    "$GUI_BIN/ScriptServer" \
    "$GUI_BIN/FrameGrabberXml" \
    "$GUI_BIN/VirtualCamera" \
    "$GUI_BIN/VirtualFrameGrabber"

rm -f \
    "$GUI_BIN/CPU_FM.sh" \
    "$GUI_BIN/IOMMU_Open.sh" \
    "$GUI_BIN/MVS.desktop" \
    "$GUI_BIN/cpDesktop.sh" \
    "$GUI_BIN/enable_coredump.sh" \
    "$GUI_BIN/script_self_starting.sh" \
    "$GUI_BIN/sdk_sym.tar" \
    "$GUI_BIN/set_env_path.sh" \
    "$GUI_BIN/set_rp_filter.sh" \
    "$GUI_BIN/set_sdk_version.sh" \
    "$GUI_BIN/set_socket_buffer_size.sh" \
    "$GUI_BIN/set_usb_priority.sh" \
    "$GUI_BIN/set_usbfs_memory_size.sh" \
    "$GUI_BIN/set_virtualserial_priority.sh" \
    "$GUI_BIN/User_Manual_of_Client_Software_Chinese.pdf" \
    "$GUI_BIN/User_Manual_of_Client_Software_English.pdf" \
    "$GUI_BIN/User_Manual_of_MvToolkit_Chinese.pdf" \
    "$GUI_BIN/User_Manual_of_MvToolkit_English.pdf"

echo "       Setting up writable runtime paths..."
if [ -d "$GUI_BIN/Cfg" ]; then
    mv "$GUI_BIN/Cfg" "$GUI_BIN/Cfg.orig"
fi
ln -sf "/tmp/mvs-runtime/cfg" "$GUI_BIN/Cfg"
rm -rf "$GUI_BIN/Temp"
ln -sf "/tmp/mvs-runtime/temp" "$GUI_BIN/Temp"

echo "       AppDir structure ready."

# ── Step 3: Create AppRun (entry point script) ────────────────────────────────

echo "── [3/6] Creating AppRun entry point ───────────────────────────────────────"

# Based on analyze.md recommended launcher (auto-detects arch via uname -m)
# Adapted for AppImage: paths are relative to APPDIR instead of hardcoded /opt/*
cat > "$APPDIR/AppRun" << 'APPRUN_EOF'
#!/bin/sh
set -eu

# AppImage mount path (runtime provides $APPDIR, fallback to readlink)
APPDIR="${APPDIR:-$(dirname "$(readlink -f "$0")")}"

GUI_ROOT="$APPDIR/mvs-gui"
CORE_ROOT="$APPDIR/mvs-usb3-core"

# Validate essential files exist
if [ ! -x "$GUI_ROOT/bin/MVS" ]; then
    echo "Error: MVS binary not found in AppImage" >&2
    exit 1
fi
if [ ! -d "$GUI_ROOT/bin/Cfg.orig" ]; then
    echo "Error: Cfg.orig not found in AppImage (corrupt package)" >&2
    exit 1
fi

export MVCAM_SDK_PATH="$CORE_ROOT"
export MVCAM_COMMON_RUNENV="$CORE_ROOT/lib"
export ALLUSERSPROFILE="$CORE_ROOT/MVFG"
export QT_PLUGIN_PATH="$GUI_ROOT/bin/QtPlugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$GUI_ROOT/bin/QtPlugins/platforms"

arch="$(uname -m)"
case "$arch" in
    x86_64)
        export LD_LIBRARY_PATH="$GUI_ROOT/bin:$CORE_ROOT/lib/64:$CORE_ROOT/lib/64/ThirdParty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    aarch64)
        export LD_LIBRARY_PATH="$GUI_ROOT/bin:$CORE_ROOT/lib/aarch64:$CORE_ROOT/lib/aarch64/ThirdParty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    *)
        echo "Error: Unsupported architecture: $arch" >&2
        exit 1
        ;;
esac

# Set up writable runtime directories
# The squashfs symlinks (e.g. /tmp/mvs-runtime/cfg) resolve through the bridge below.
RUNTIME="/tmp/mvs-runtime-$(id -u)"

umask 077
mkdir -p "$RUNTIME/temp" "$RUNTIME/cfg"

# Bridge: make the fixed path point to the per-UID dir
if [ -e /tmp/mvs-runtime ] && [ ! -L /tmp/mvs-runtime ]; then
    echo "Error: /tmp/mvs-runtime exists and is not a symlink" >&2
    exit 1
fi
ln -sfn "$RUNTIME" /tmp/mvs-runtime

# One-time config copy
if [ ! -f "$RUNTIME/cfg/Features.xml" ]; then
    cp -a "$GUI_ROOT/bin/Cfg.orig/." "$RUNTIME/cfg/"
fi

exec "$GUI_ROOT/bin/MVS" -platform xcb "$@"
APPRUN_EOF

chmod +x "$APPDIR/AppRun"
echo "       AppRun created."

echo "── [4/6] Creating desktop entry + icon ─────────────────────────────────────"

cat > "$APPDIR/MVS.desktop" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=MVS
Comment=Hikvision Machine Vision Software
Exec=AppRun
Icon=MVS
Categories=Development;
Terminal=false
DESKTOP_EOF

echo "       MVS.desktop created."

if [[ -f "$PROJECT_ROOT/mvs.svg" ]]; then
    cp "$PROJECT_ROOT/mvs.svg" "$APPDIR/MVS.svg"
    echo "       MVS.svg copied from project."
else
    echo "       Warning: mvs.svg not found, icon will be missing" >&2
fi

# ── Step 5: Download appimagetool ─────────────────────────────────────────────

echo "── [5/6] Preparing appimagetool ────────────────────────────────────────────"

APPIMAGE_TOOL_NAME="appimagetool-${APPIMAGE_TOOL_SUFFIX}.AppImage"
APPIMAGE_TOOL_PATH="$CACHE_DIR/$APPIMAGE_TOOL_NAME"
APPIMAGE_TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/${APPIMAGE_TOOL_VERSION}/${APPIMAGE_TOOL_NAME}"

mkdir -p "$CACHE_DIR"

if [[ -f "$APPIMAGE_TOOL_PATH" ]]; then
    echo "       Using cached: $APPIMAGE_TOOL_PATH"
else
    echo "       Downloading appimagetool for ${APPIMAGE_TOOL_SUFFIX}..."
    if command -v curl &>/dev/null; then
        curl -fSL --progress-bar -o "$APPIMAGE_TOOL_PATH" "$APPIMAGE_TOOL_URL"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$APPIMAGE_TOOL_PATH" "$APPIMAGE_TOOL_URL"
    else
        echo "Error: Neither curl nor wget found. Install one to proceed." >&2
        exit 1
    fi
    chmod +x "$APPIMAGE_TOOL_PATH"
    echo "       Downloaded to: $APPIMAGE_TOOL_PATH"
fi

# ── Step 6: Package AppImage ──────────────────────────────────────────────────

echo "── [6/6] Creating AppImage ─────────────────────────────────────────────────"

OUTPUT_FILE="$OUTPUT_DIR/mvs-app-${RELEASE_TAG}-${ARCH_TAG}.AppImage"

# Use --appimage-extract-and-run for CI compatibility (no FUSE needed)
# Falls back gracefully on systems WITH fuse too
"$APPIMAGE_TOOL_PATH" --appimage-extract-and-run \
    "$APPDIR" \
    "$OUTPUT_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  AppImage created successfully!                                  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Output:   $OUTPUT_FILE"
echo "║  Size:     $(du -h "$OUTPUT_FILE" | cut -f1)"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Verify dependencies:"
echo "     $OUTPUT_FILE --appimage-extract >/dev/null 2>&1"
echo "     LD_LIBRARY_PATH=squashfs-root/mvs-gui/bin:squashfs-root/mvs-usb3-core/lib/64:squashfs-root/mvs-usb3-core/lib/64/ThirdParty ldd squashfs-root/mvs-gui/bin/MVS | grep 'not found'"
echo "  2. Test without hardware:  $OUTPUT_FILE --appimage-extract-and-run --help"
echo "  3. Test with camera:     ./$OUTPUT_FILE"
