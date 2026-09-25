#!/bin/sh
# Build the badge module.
#
#   rustup target add wasm32-unknown-unknown
#   ./build.sh
#
# Then read Ping's stream with a source, and point an item per app at the module:
#
#   source "ping" module="exec" interval="watch" max-backoff="5s" {
#     command "/Applications/Ping.app/Contents/MacOS/ping-dot-app" "watch"
#   }
#   item "slack" module="wasm" path="~/.config/bario/modules/ping-badge.wasm" {
#     config app="Slack" critical=10
#   }
set -e
cd "$(dirname "$0")"
cargo build --release --target wasm32-unknown-unknown
mkdir -p ~/.config/bario/modules
cp target/wasm32-unknown-unknown/release/ping_badge.wasm ~/.config/bario/modules/ping-badge.wasm
echo "installed ~/.config/bario/modules/ping-badge.wasm"
