#!/bin/sh
# Build the names module.
#
#   rustup target add wasm32-unknown-unknown
#   ./build.sh
#
# Then point an item at it, reading the source that runs `emira watch`:
#
#   item "names" module="wasm" path="~/.config/bario/modules/emira-names.wasm" when="guide" {
#     config source="emira" max=7
#   }
set -e
cd "$(dirname "$0")"
cargo build --release --target wasm32-unknown-unknown
mkdir -p ~/.config/bario/modules
cp target/wasm32-unknown-unknown/release/emira_names.wasm ~/.config/bario/modules/emira-names.wasm
echo "installed ~/.config/bario/modules/emira-names.wasm"
