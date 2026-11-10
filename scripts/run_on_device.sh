#!/usr/bin/env bash
# 本地开发循环：编译 Rust 适配层（arm64）→ hvigor 打包 → 安装到已连接设备 → 启动。
# 仅用于本机调试；正式构建请走 build_native.sh（双架构）+ DevEco 签名。
set -uo pipefail

DEVECO="${DEVECO_HOME:-/c/Program Files/Huawei/DevEco Studio}"
SDKLLVM="$DEVECO/sdk/default/openharmony/native/llvm/bin"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc.exe"
SDK_USER="${OHOS_SDK_USER:-/c/Users/mingh/AppData/Local/Huawei/Sdk}"
TARGET="${OHOS_TARGET:-aarch64-unknown-linux-ohos}"
BUNDLE="${DC_BUNDLE:-io.github.shaliuxin.deckcraft.hmos}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$("$HDC" list targets 2>/dev/null | tr -d '\r' | head -1)"
fi
[ -n "$DEVICE" ] || { echo "no device connected"; exit 1; }
echo "device=$DEVICE target=$TARGET bundle=$BUNDLE"

export CARGO_NET_OFFLINE=true
export DEVECO_SDK_HOME="$DEVECO/sdk"
export NODE_HOME="$DEVECO/tools/node"
export JAVA_HOME="$DEVECO/jbr"
export PATH="$DEVECO/jbr/bin:$DEVECO/tools/node:$DEVECO/tools/hvigor/bin:$PATH"

echo "--- [1/4] cargo build ---"
cd "$ROOT/native/rust" || exit 1
export CC_aarch64_unknown_linux_ohos="$SDKLLVM/clang.exe"
export AR_aarch64_unknown_linux_ohos="$SDKLLVM/llvm-ar.exe"
export CC_x86_64_unknown_linux_ohos="$SDKLLVM/clang.exe"
export AR_x86_64_unknown_linux_ohos="$SDKLLVM/llvm-ar.exe"
# DeckCraft 适配层是纯 Rust（无 C++ 内核），只需 CC/AR 两个变量；
# 连字符形式的 CC_<triple> 在 bash 里 export 不了，故用下划线形式，
# 完整的 --target/--sysroot 由 scripts/build_native.sh 统一处理（正式构建走它）。
cargo build --release --target "$TARGET" 2>&1 | tail -8
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "cargo build failed"; exit 1; }

echo "--- [2/4] assembleHap ---"
cd "$ROOT" || exit 1
node "$DEVECO/tools/hvigor/bin/hvigorw.js" assembleHap --no-daemon 2>&1 | tail -8
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "assembleHap failed"; exit 1; }

echo "--- [3/4] install ---"
cd "$ROOT/entry/build/default/outputs/default" || exit 1
"$HDC" -t "$DEVICE" uninstall "$BUNDLE" 2>&1 | tr -d '\r' | tail -1
"$HDC" -t "$DEVICE" install entry-default-signed.hap 2>&1 | tr -d '\r' | tail -2

echo "--- [4/4] launch ---"
"$HDC" -t "$DEVICE" shell hilog -r 2>&1 | tr -d '\r' | tail -1
"$HDC" -t "$DEVICE" shell aa start -b "$BUNDLE" -a EntryAbility 2>&1 | tr -d '\r' | tail -2
echo "done."
