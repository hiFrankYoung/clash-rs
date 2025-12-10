#!/bin/bash

set -e  # Exit on errors
set -o pipefail  # Fail pipeline if any command fails

# Print usage information
usage() {
    cat << EOF
Usage: $0 [PLATFORMS...]

Build XCFramework for specified Apple platforms.

PLATFORMS:
  ios           Build for iOS device (aarch64-apple-ios)
  ios-sim       Build for iOS Simulator (x86_64 + aarch64 universal)
  macos         Build for macOS (x86_64 + aarch64 universal)

Examples:
  $0                    # Build all platforms (default)
  $0 ios                # Build iOS device only
  $0 ios-sim macos      # Build iOS Simulator and macOS
  $0 ios macos        # Build iOS device and macOS

EOF
    exit 1
}

# Parse command line arguments
REQUESTED_PLATFORMS=()
if [ $# -eq 0 ]; then
    # No arguments: build all platforms
    REQUESTED_PLATFORMS=("ios" "ios-sim" "macos")
else
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            ios|ios-sim|macos)
                REQUESTED_PLATFORMS+=("$arg")
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Error: Unknown platform '$arg'"
                echo ""
                usage
                ;;
        esac
    done
fi

# Remove duplicates
REQUESTED_PLATFORMS=($(echo "${REQUESTED_PLATFORMS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

echo "Building for platforms: ${REQUESTED_PLATFORMS[@]}"

# All available targets
ALL_IOS_DEVICE_ARCHS=("aarch64-apple-ios")
ALL_IOS_SIM_ARCHS=("x86_64-apple-ios" "aarch64-apple-ios-sim")
ALL_MACOS_ARCHS=("aarch64-apple-darwin" "x86_64-apple-darwin")

# Determine which targets to build based on requested platforms
BUILD_TARGETS=()
BUILD_IOS_DEVICE=false
BUILD_IOS_SIM=false
BUILD_MACOS=false

for platform in "${REQUESTED_PLATFORMS[@]}"; do
    case "$platform" in
        ios)
            BUILD_IOS_DEVICE=true
            BUILD_TARGETS+=("${ALL_IOS_DEVICE_ARCHS[@]}")
            ;;
        ios-sim)
            BUILD_IOS_SIM=true
            BUILD_TARGETS+=("${ALL_IOS_SIM_ARCHS[@]}")
            ;;
        macos)
            BUILD_MACOS=true
            BUILD_TARGETS+=("${ALL_MACOS_ARCHS[@]}")
            ;;
    esac
done

# Remove duplicate targets
BUILD_TARGETS=($(echo "${BUILD_TARGETS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

# Variables
CRATE_NAME="clash-ffi"
LIB_NAME="clashrs"
OUTPUT_DIR="build"

HEADERS_DIR="${OUTPUT_DIR}/Headers"
HEADER_FILE="${HEADERS_DIR}/${LIB_NAME}/${LIB_NAME}.h"
MODULEMAP_FILE="${HEADERS_DIR}/${LIB_NAME}/module.modulemap"
XCFRAMEWORK_DIR="${OUTPUT_DIR}/${LIB_NAME}.xcframework"

# Ensure the toolchain from rust-toolchain.toml is installed and switched
echo "Ensuring the Rust toolchain from rust-toolchain.toml is installed..."
if [ -f "rust-toolchain.toml" ]; then
    rustup show active-toolchain &> /dev/null || rustup install $(cat rust-toolchain.toml | grep -E 'channel\s*=' | cut -d'"' -f2)
else
    echo "Error: rust-toolchain.toml not found. Please ensure it exists in the project directory."
    exit 1
fi

# Force the use of the correct toolchain by running all cargo commands through `cargo +<toolchain>`
TOOLCHAIN=$(cat rust-toolchain.toml | grep -E 'channel\s*=' | cut -d'"' -f2)
echo "Using toolchain: $TOOLCHAIN"

# Ensure necessary tools are installed
echo "Checking for required tools..."
if ! command -v cbindgen &> /dev/null; then
    echo "Installing cbindgen..."
    cargo +$TOOLCHAIN install cbindgen
fi

# Install necessary Rust targets
echo "Installing necessary Rust targets..."
for target in "${BUILD_TARGETS[@]}"; do
    rustup target add "$target" --toolchain $TOOLCHAIN || echo "Target $target is Tier 3 and may need local stdlib build."
done

# Generate C header file using cbindgen
echo "Generating C header file..."
cbindgen --config $CRATE_NAME/cbindgen.toml --crate $CRATE_NAME --output $HEADER_FILE
echo "Creating modulemap..."
cat > "$MODULEMAP_FILE" <<EOF
module $LIB_NAME {
    umbrella header "$(basename $HEADER_FILE)"
    export *
}
EOF

# Create output directory
mkdir -p "$OUTPUT_DIR"
mkdir -p "$HEADERS_DIR"

# Build for selected targets
echo "Building library for selected targets: ${BUILD_TARGETS[@]}"
for target in "${BUILD_TARGETS[@]}"; do
    echo "Building $target..."
    cargo +$TOOLCHAIN build --target "$target" --release
    mkdir -p "$OUTPUT_DIR/$target"
    cp "target/$target/release/lib${LIB_NAME}.a" "$OUTPUT_DIR/$target/"
done

# Create universal binaries and XCFramework based on selected platforms
XCFRAMEWORK_ARGS=()

# iOS Simulator universal binary (if needed)
if [ "$BUILD_IOS_SIM" = true ]; then
    echo "Creating iOS Simulator universal binary..."
    mkdir -p "$OUTPUT_DIR/ios-simulator-universal"
    lipo -create \
        "$OUTPUT_DIR/x86_64-apple-ios/lib${LIB_NAME}.a" \
        "$OUTPUT_DIR/aarch64-apple-ios-sim/lib${LIB_NAME}.a" \
        -output "$OUTPUT_DIR/ios-simulator-universal/lib${LIB_NAME}.a"
    XCFRAMEWORK_ARGS+=(-library "$OUTPUT_DIR/ios-simulator-universal/lib${LIB_NAME}.a" -headers "$HEADERS_DIR")
fi

# iOS Device (if needed)
if [ "$BUILD_IOS_DEVICE" = true ]; then
    XCFRAMEWORK_ARGS+=(-library "$OUTPUT_DIR/aarch64-apple-ios/lib${LIB_NAME}.a" -headers "$HEADERS_DIR")
fi

# macOS universal binary (if needed)
if [ "$BUILD_MACOS" = true ]; then
    echo "Creating macOS universal binary..."
    mkdir -p "$OUTPUT_DIR/macos-universal"
    lipo -create \
        "$OUTPUT_DIR/aarch64-apple-darwin/lib${LIB_NAME}.a" \
        "$OUTPUT_DIR/x86_64-apple-darwin/lib${LIB_NAME}.a" \
        -output "$OUTPUT_DIR/macos-universal/lib${LIB_NAME}.a"
    XCFRAMEWORK_ARGS+=(-library "$OUTPUT_DIR/macos-universal/lib${LIB_NAME}.a" -headers "$HEADERS_DIR")
fi

# Create XCFramework
echo "Creating XCFramework..."
rm -rf "$XCFRAMEWORK_DIR"
xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$XCFRAMEWORK_DIR"

echo "XCFramework created at $XCFRAMEWORK_DIR"

# Cleanup all intermediate files, keep only the XCFramework
echo "Cleaning up intermediate files..."
find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 ! -name "$(basename $XCFRAMEWORK_DIR)" -exec rm -rf {} +

echo "Done!"
