#!/bin/sh
# Build the roll renderer.
#
#   rustup target add wasm32-unknown-unknown
#   ./build.sh
#
# Then register it, and any module may draw a `roll` node:
#
#   renderer "roll" path="~/.config/bario/renderers/roll.wasm"
set -e
cd "$(dirname "$0")"
cargo build --release --target wasm32-unknown-unknown
mkdir -p ~/.config/bario/renderers
cp target/wasm32-unknown-unknown/release/roll.wasm ~/.config/bario/renderers/roll.wasm
echo "installed ~/.config/bario/renderers/roll.wasm"
