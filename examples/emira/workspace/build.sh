#!/bin/sh
# Build the workspace module.
#
#   rustup target add wasm32-unknown-unknown
#   ./build.sh
#
# Then point an item at it, reading the source that runs `emira watch`:
#
#   item "workspace" module="wasm" path="~/.config/bario/modules/emira-workspace.wasm" {
#     config source="emira"
#   }
set -e
cd "$(dirname "$0")"
cargo build --release --target wasm32-unknown-unknown
mkdir -p ~/.config/bario/modules
cp target/wasm32-unknown-unknown/release/emira_workspace.wasm ~/.config/bario/modules/emira-workspace.wasm
echo "installed ~/.config/bario/modules/emira-workspace.wasm"
