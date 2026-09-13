# Node.js for ARMv6

Since node v24+ is not officially supported anymore on ARMv6, like on ARMv7, I decided to try to make it myself.
I currently don't own a ARMv6 device, so I tested the binary only on qemu.
Welcome for any feedback if this works on real device.

Various patches are required depending on whether the major version is v24 or v26.

- For **v26.x.x**, building requires two patches:
    - `deps/v8/src/strings/string-hasher.cc` — fixes an x86_64-only SSE2 intrinsic that breaks 32-bit host compilation
    - `out/deps/crates/node_crates.*.mk` — fixes incorrect shared output paths for host/target Rust crates in cross-compile builds

- For **v24.x**
    - `deps/v8/src/compiler/turboshaft/int64-lowering-reducer.h` — adds the missing `template` disambiguator to `__ Tuple<Word32, Word32>(...)` in `LowerClz`/`LowerCtz` (something which v26.x already includes upstream).
    - above patches are not needed


- ARMv6 specific patches:
    - `configure.py` - restore armv6 target in node build configure
    - `yield-processor.h` - fixes the `isb` instruction incorrect gating on __ARM_ARCH >= 6, which breaks assembly on plain ARMv6/ARMv6K/ARMv6ZK targets (it's only valid for ARMv6T2 or ARMv7, so for ARMv6ZK build we will change gate to ARMv7)
    - `json-stringifier.cc` - skip broken SIMD fast path on scalar-only targets, fallback to existing scalar function
    - `string-hasher.cc` - Skip broken SIMD path on scalar-only Highway targets (v25.x+ only)
    - `flag-definitions.h` Disable Maglev by default (broken integer-division codegen on armv6zk without hardware divide)



## Download
Go to [releases](https://github.com/4meters/node-for-armv6/releases)

Binaries are built with `--partly-static`, because many systems still use gcc/g++12 libs.

### Install with nvm

If you just want to use node on armv6, you can download the latest release, then use [nvm](https://www.nvmnode.com/):

```bash
VERSION="v26.x.x" # replace this with your version
tar -xzf node-$VERSION-linux-armv6zk.tar.gz -C "$NVM_DIR/versions/node/"
nvm use $VERSION
```

## How to build

If you prefer to build node yourself, you can do so using the `./build-for-armv6.sh` on an Ubuntu or Debian x86_64 machine. Just run:


```bash
chmod +x ./build-for-armv6.sh

# Build latest release on default branch (v26.x)
sudo ./build-for-armv6.sh

# Build a specific branch
sudo ./build-for-armv6.sh v24.x
```

This will install the required packages automatically.

The output file is a `node-$VERSION-linux-armv6zk.tar.gz` archive in the current directory, which can similarly be unpacked and used with nvm.

## Additional info (mostly armv7 related)

See [nodejs/node issue #61794](https://github.com/nodejs/node/issues/61794#issuecomment-5302695402)
