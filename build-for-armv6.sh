#!/bin/bash
# USE WITH SUDO
# build-armv6.sh - Build Node.js for ARMv6 locally
# Equivalent of the GitHub Actions build workflow
#
# Usage:
#   ./build-armv6.sh [branch]
#
# Examples:
#   ./build-armv6.sh          # uses default branch v26.x
#   ./build-armv6.sh v24.x    # builds v24.x
#
# Requirements:
#   - Ubuntu/Debian host (x86_64)
#   - sudo access (for apt)
#   - curl, wget, git

# ── sudo check ────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

set -e

# ── Config ────────────────────────────────────────────────────
NODE_BRANCH="${1:-v26.x}"
TOOLCHAIN_URL="https://github.com/tttapa/toolchains/releases/download/1.3.1/x-tools-armv6-rpi-linux-gnueabihf-gcc13.tar.xz"
TOOLCHAIN_DIR="/opt/tttapa-toolchains"
TOOLCHAIN_BIN="$TOOLCHAIN_DIR/armv6-rpi-linux-gnueabihf/bin"
WORK_DIR="$(pwd)"
NODE_SRC="$WORK_DIR/node"
RELEASE_DIR="$WORK_DIR/node-release"

start=$(date +%s)

echo "=================================================="
echo " Building Node.js ARMv6 from branch: $NODE_BRANCH"
echo "=================================================="

# ── Step 1: Install build dependencies ────────────────────────
echo -e "\n=== Step 1: Install build dependencies ==="
sudo apt-get update
sudo apt-get install -y \
    curl \
    ccache \
    gcc-multilib \
    g++-multilib \
    python3 \
    pkg-config \
    libc6-dev \
    make \
    git

# ── Step 2: Install Rust ───────────────────────────────────────
echo -e "\n=== Step 2: Install Rust ==="
if ! command -v rustup &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    echo "Rust already installed: $(rustc --version)"
fi
source "$HOME/.cargo/env"

# ── Step 3: Install tttapa ARMv6 toolchain ────────────────────
echo -e "\n=== Step 3: Install tttapa ARMv6 toolchain ==="
if [ ! -f "$TOOLCHAIN_BIN/armv6-rpi-linux-gnueabihf-g++" ]; then
    wget "$TOOLCHAIN_URL" -O /tmp/tttapa-toolchain.tar.xz
    mkdir -p "$TOOLCHAIN_DIR"
    tar -xf /tmp/tttapa-toolchain.tar.xz \
        --strip-components=1 \
        -C "$TOOLCHAIN_DIR" \
        x-tools/armv6-rpi-linux-gnueabihf
    rm /tmp/tttapa-toolchain.tar.xz
else
    echo "Toolchain already installed at $TOOLCHAIN_BIN"
fi
export PATH="$TOOLCHAIN_BIN:$PATH"
"$TOOLCHAIN_BIN/armv6-rpi-linux-gnueabihf-g++" --version

# ── Step 4: Configure cross-compilation environment ───────────
echo -e "\n=== Step 4: Configure cross-compilation environment ==="
rustup target add i686-unknown-linux-gnu
rustup target add arm-unknown-linux-gnueabihf

CROSS_GCC="$TOOLCHAIN_BIN/armv6-rpi-linux-gnueabihf-gcc -march=armv6zk"
CROSS_GXX="$TOOLCHAIN_BIN/armv6-rpi-linux-gnueabihf-g++ -march=armv6zk"

export CC="ccache $CROSS_GCC"
export CXX="ccache $CROSS_GXX"
export CC_host="ccache gcc -m32 -msse2"
export CXX_host="ccache g++ -m32 -msse2"
export CC_target="ccache $CROSS_GCC"
export CXX_target="ccache $CROSS_GXX"
export CARGO_TARGET_I686_UNKNOWN_LINUX_GNU_LINKER="gcc"
export CARGO_TARGET_ARM_UNKNOWN_LINUX_GNUEABIHF_LINKER="$CROSS_GCC"

# ── Step 5: Clone Node.js - latest release tag ─────────
echo -e "\n=== Step 5: Clone Node.js ($NODE_BRANCH) ==="
if [ ! -d "$NODE_SRC/.git" ]; then
  MAJOR=$(echo "$NODE_BRANCH" | grep -oE '^[0-9]+' || echo "$NODE_BRANCH" | sed 's/^v//;s/\.x$//')

  # List remote tags matching this major version, sorted by version, take latest.
  # Node tags releases as vX.Y.Z with no extra suffix on the main repo.
  LATEST_TAG=$(git ls-remote --tags --refs https://github.com/nodejs/node.git \
    | awk -F'/' '{print $NF}' \
    | grep -E "^v${MAJOR}\.[0-9]+\.[0-9]+$" \
    | sort -V \
    | tail -1)

  if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: could not resolve latest tag for branch $NODE_BRANCH"
    exit 1
  fi

  git clone --branch "$LATEST_TAG" --depth 1 --single-branch \
              https://github.com/nodejs/node.git node
            echo "Cloned $(cd node && git rev-parse HEAD)"
  NODE_VERSION="${LATEST_TAG#v}"
  echo "Node v$NODE_VERSION"
else
  echo "Node source already cloned at $NODE_SRC"
  EXISTING_TAG=$(git -C "$NODE_SRC" tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  EXISTING_TAG="${EXISTING_TAG:-$(git -C "$NODE_SRC" describe --tags --abbrev=0 2>/dev/null)}"
  [ -z "$EXISTING_TAG" ] && { echo "ERROR: could not determine NODE_VERSION from existing checkout"; exit 1; }
  NODE_VERSION="${EXISTING_TAG#v}"
  echo "Using existing checkout at tag $EXISTING_TAG -> NODE_VERSION=$NODE_VERSION"
fi

# ── Step 6a: Patch string-hasher (v25.x+ only) ───────────────────────────────
echo -e "\n=== Step 6: Patch string-hasher (v25.x+ only) ==="
FILE="$NODE_SRC/deps/v8/src/strings/string-hasher.cc"

if [ -f "$NODE_SRC/.patched-sse2" ]; then
    echo "Already patched (found .patched-sse2), skipping"
elif ! grep -q "#ifdef __SSE2__" "$FILE"; then
	echo "WARN: #ifdef __SSE2__ not found in $FILE — not patching"
else
    if ! grep -q "#ifdef __SSE2__" "$FILE"; then
        echo "ERROR: #ifdef __SSE2__ not found in $FILE — file structure may have changed"
        exit 1
    fi

    if ! grep -q "_mm_cvtsi128_si64" "$FILE"; then
        echo "ERROR: No _mm_cvtsi128_si64 found in $FILE — patch may not be needed"
        exit 1
    fi

    COUNT=$(grep -c "#ifdef __SSE2__" "$FILE")
    sed -i 's/#ifdef __SSE2__/#if defined(__SSE2__) \&\& defined(__x86_64__)/g' "$FILE"
    touch "$NODE_SRC/.patched-sse2"
    echo "Patched $COUNT occurrence(s) in $FILE"
fi

# ── Step 6b: Patch V8 int64-lowering Tuple template disambiguation (v24.x only) ───────────────────────────────
echo -e "\n=== Step 6b: Patch V8 int64-lowering Tuple template disambiguation (v24.x only) ==="

FILE="$NODE_SRC/deps/v8/src/compiler/turboshaft/int64-lowering-reducer.h"
if [ -f "$FILE" ] && grep -q "__ Tuple<" "$FILE"; then
	sed -i 's/__ Tuple</__ template Tuple</g' "$FILE"
	echo "Patched Tuple template disambiguation in $FILE"
else
	echo "No unfixed '__ Tuple<' occurrences in $FILE, skipping (v25.x+ already upstream-fixed)"
fi

## Step 7a-7d - ARMv6 specific patches
echo -e "\n=== Step 7a-7d - ARMv6 specific patches ==="

## Step 7a Patch configure.py
echo -e "\n=== Step 7a: Patch configure.py - restore armv6 ==="
if [ -f "$NODE_SRC/.patched-configure-py" ]; then
    echo "Already patched (found .patched-configure-py), skipping"
else
  cd $NODE_SRC

  # Insert the is_arch_armv6 function after the is_arch_armv7 return statement
	sed -i -e "s/return cc_macros_cache.get('__ARM_ARCH') == '7'/&\n\ndef is_arch_armv6():\n  \"\"\"Check for ARMv6 instructions\"\"\"\n  cc_macros_cache = cc_macros()\n  return cc_macros_cache.get('__ARM_ARCH') == '6'/" \
       -e "s/o\['variables'\]\['arm_version'\] = 'default'/o['variables']['arm_version'] = '6' if is_arch_armv6() else 'default'/" \
       configure.py

	touch "$NODE_SRC/.patched-configure-py"
	echo "Patched configure.py"
fi

## Step 7b Patch yield-processor.h in V8
# Fixes deps/v8/src/base/platform/yield-processor.h: the `isb` instruction
# (used as a busy-wait hint) is only valid in ARM-mode assembly starting
# ARMv7 (or ARMv6T2). V8 incorrectly gates it on __ARM_ARCH >= 6, which
# breaks assembly on plain ARMv6/ARMv6K/ARMv6ZK targets. Falls back to a
# plain no-op on those, which is a safe (if slightly less efficient)
# substitute since YIELD_PROCESSOR is only a spin-wait hint, not a barrier.
echo -e "\n=== Step 7b: Patch yield-processor.h for armv6zk ==="
if [ -f "$NODE_SRC/.patched-yield-processor" ]; then
  echo "Already patched (found .patched-yield-processor), skipping"
else
	sed -i 's/__ARM_ARCH >= 6/__ARM_ARCH >= 7/g' "$NODE_SRC/deps/v8/src/base/platform/yield-processor.h"
	touch "$NODE_SRC/.patched-yield-processor"
	echo "Patched yield-processor.h"
fi

## Step 7c Patch json-stringifier.cc in V8
echo -e "\n=== Step 7c: Patch json-stringifier.cc in V8 ==="
if [ -f "$NODE_SRC/.patched-json-stringifier" ]; then
  echo "Already patched (found .patched-json-stringifier), skipping"
else
	FILE="$NODE_SRC/deps/v8/src/json/json-stringifier.cc"

	if [ ! -f "$FILE" ]; then
		echo "ERROR: $FILE not found"
	fi
	if grep -q "HWY_TARGET != HWY_SCALAR" "$FILE"; then
		echo "Already patched, skipping"
	fi
	# Insert #if before the threshold definition and #endif before the SWAR return
	sed -i -e "/constexpr int kUseSimdLengthThreshold = 32;/i #if HWY_TARGET != HWY_SCALAR" \
		   -e "/return AppendStringSWAR(chars, length, 0, 0, no_gc);/i #endif" "$FILE"

	touch "$NODE_SRC/.patched-json-stringifier"
	echo "Patched json-stringifier.cc"
fi

# ── Step 7d: Skip broken SIMD path in string-hasher.cc on scalar-only Highway targets ──
echo -e "\n=== Step 7d: Patch string-hasher.cc IsOnly8BitSIMD (v25.x+ only)==="
if [ -f "$NODE_SRC/.patched-simd-string-hasher" ]; then
  echo "Already patched (found .patched-simd-string-hasher), skipping"
else
	if [ -f "$NODE_SRC/deps/v8/src/strings/string-hasher.cc" ]; then
		FILE="$NODE_SRC/deps/v8/src/strings/string-hasher.cc"

		if [ ! -f "$FILE" ] || grep -q "HWY_TARGET != HWY_SCALAR" "$FILE"; then
			echo "File missing or already patched, skipping"
		fi

		sed -i -e "/const uint16_t\* end = chars + len;/d" \
			-e "s/bool IsOnly8BitSIMD(const uint16_t\* chars, unsigned len) {/&\n  const uint16_t* end = chars + len;\n#if HWY_TARGET != HWY_SCALAR/" \
			-e "s|^\([[:space:]]*\)\/\/ Handle remaining characters\.|#endif\n\1// Handle remaining characters.|" \
			"$FILE"
		touch "$NODE_SRC/.patched-simd-string-hasher"
		echo "Patched string-hasher.cc IsOnly8BitSIMD"
	else
		echo "Skipping patch, not needed"
	fi
fi

## Step 7e: Disable Maglev by default (broken integer-division codegen on armv6zk without hardware divide)
echo -e "\n=== Step 7e: Patch flag-definitions.h - disable maglev by default ==="
if [ -f "$NODE_SRC/.patched-maglev-default" ]; then
    echo "Already patched (found .patched-maglev-default), skipping"
else
    FILE="$NODE_SRC/deps/v8/src/flags/flag-definitions.h"

    if ! grep -q 'DEFINE_BOOL(maglev, true,' "$FILE"; then
        echo "WARN: 'DEFINE_BOOL(maglev, true,' not found in $FILE — not patching (may not apply to this V8 version)"
    else
        sed -i 's/DEFINE_BOOL(maglev, true,/DEFINE_BOOL(maglev, false,/' "$FILE"
        touch "$NODE_SRC/.patched-maglev-default"
        echo "Patched $FILE — maglev now defaults to off"
    fi
fi

# ── Step 8: Configure Node.js ─────────────────────────────────
echo -e "\n=== Step 8: Configure Node.js ==="
cd "$NODE_SRC"
./configure --dest-cpu arm --partly-static

# ── Step 9: Patch node_crates mk files ────────────────────────
echo -e "\n=== Step 9: Patch node_crates mk files ==="
if [ -f "$NODE_SRC/.patched-node-crates" ]; then
    echo "Already patched (found .patched-node-crates), skipping"
else
    node_crates_host_file="${NODE_SRC}/out/deps/crates/node_crates.host.mk"
    if [[ -f "$node_crates_host_file" ]]; then
      sed -i 's|mkdir -p $(obj)/gen//release; cargo rustc --release --frozen --target-dir "$(obj)/gen"|mkdir -p $(obj)/gen/i686-unknown-linux-gnu/release; cargo rustc --release --frozen --target i686-unknown-linux-gnu --target-dir "$(obj)/gen"|g' "$node_crates_host_file"
      sed -i 's|$(obj)/gen//release/libnode_crates.a|$(obj)/gen/i686-unknown-linux-gnu/release/libnode_crates.a|g' "$node_crates_host_file"
    fi
    node_crates_target_file="${NODE_SRC}/out/deps/crates/node_crates.target.mk"
    if [[ -f "$node_crates_target_file" ]]; then
      sed -i 's|mkdir -p $(obj)/gen//release; cargo rustc --release --frozen --target-dir "$(obj)/gen"|mkdir -p $(obj)/gen/arm-unknown-linux-gnueabihf/release; cargo rustc --release --frozen --target arm-unknown-linux-gnueabihf --target-dir "$(obj)/gen"|g' "$node_crates_target_file"
      sed -i 's|$(obj)/gen//release/libnode_crates.a|$(obj)/gen/arm-unknown-linux-gnueabihf/release/libnode_crates.a|g' "$node_crates_target_file"
    fi
    mksnapshot_file="${NODE_SRC}/out/tools/v8_gypfiles/mksnapshot.host.mk"
    if [[ -f "$mksnapshot_file" ]]; then
      sed -i 's|$(obj)/gen//release/libnode_crates.a|$(obj)/gen/i686-unknown-linux-gnu/release/libnode_crates.a|g' "$mksnapshot_file"
    fi

    for f in \
    "${NODE_SRC}/out/node.target.mk" \
    "${NODE_SRC}/out/embedtest.target.mk" \
    "${NODE_SRC}/out/cctest.target.mk" \
    "${NODE_SRC}/out/node_mksnapshot.target.mk"
    do
      if [[ -f "$f" ]]; then
          sed -i 's|$(obj)/gen//release/libnode_crates.a|$(obj)/gen/arm-unknown-linux-gnueabihf/release/libnode_crates.a|g' \
          "$f"
      fi
    done

    if [[ -f "$node_crates_host_file" ]] && [[ -f "$node_crates_target_file" ]]; then
      touch "$NODE_SRC/.patched-node-crates"
      echo "=== Patch verification ==="
      grep "cargo rustc" "$NODE_SRC/out/deps/crates/node_crates.host.mk"
      grep "cargo rustc" "$NODE_SRC/out/deps/crates/node_crates.target.mk"
    fi
fi

# ── Step 10: Build ─────────────────────────────────────────────
echo -e "\n=== Step 10: Build ==="
cd "$NODE_SRC"
make -j$(($(nproc)+1))

# ── Step 11: Package ──────────────────────────────────────────
echo -e "\n=== Step 11: Package ==="
MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
RELEASE_NAME="node-v${NODE_VERSION}-linux-armv6zk"

make -C "$NODE_SRC" install DESTDIR="$RELEASE_DIR"

mv "$RELEASE_DIR/usr/local" "$RELEASE_DIR/v${NODE_VERSION}"

cp "$NODE_SRC/README.md"    "$RELEASE_DIR/v${NODE_VERSION}/"
cp "$NODE_SRC/LICENSE"      "$RELEASE_DIR/v${NODE_VERSION}/"
cp "$NODE_SRC/CHANGELOG.md" "$RELEASE_DIR/v${NODE_VERSION}/" 2>/dev/null || \
    cp "$NODE_SRC/doc/changelogs/CHANGELOG_V${MAJOR}.md" \
       "$RELEASE_DIR/v${NODE_VERSION}/CHANGELOG.md" 2>/dev/null || \
    echo "CHANGELOG not found, skipping"

cd "$RELEASE_DIR"
tar -czf "$WORK_DIR/$RELEASE_NAME.tar.gz" "v${NODE_VERSION}/"

echo ""
echo "=================================================="
echo " Done! Output: $WORK_DIR/$RELEASE_NAME.tar.gz"
echo "=================================================="

end=$(date +%s)
elapsed=$((end - start))
printf "Execution time: %02d:%02d:%02d\n" "$((elapsed / 3600))" "$(((elapsed % 3600) / 60))" "$((elapsed % 60))"