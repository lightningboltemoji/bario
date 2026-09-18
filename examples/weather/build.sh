#!/bin/sh
# Build the weather module.
#
#   rustup target add wasm32-unknown-unknown
#   ./build.sh
#
# Then point an item at it:
#
#   item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
#     permissions "net"
#     config city="Vancouver" units="metric"
#   }
set -e
cd "$(dirname "$0")"
cargo build --release --target wasm32-unknown-unknown
mkdir -p ~/.config/bario/modules
cp target/wasm32-unknown-unknown/release/weather.wasm ~/.config/bario/modules/
echo "installed ~/.config/bario/modules/weather.wasm"
