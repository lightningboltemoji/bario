//! emira's focused workspace as a bario module: its name, and nothing else, as a bubble.
//!
//! It reads the state a `source` running `emira watch` writes, and asks for nothing: no network, no
//! files, no processes. It hears the source change through a state subscription, keeps the name
//! under its own key, and renders from that, so a bar redraw never asks emira anything.
//!
//! ```kdl
//! source "emira" module="exec" interval="watch" { command "emira" "watch" }
//!
//! item "workspace" module="wasm" path="~/.config/bario/modules/emira-workspace.wasm" {
//!   config source="emira"
//! }
//! ```
//!
//! `source` is the key the source writes under. A bario item is the same on every bar, so the name
//! follows focus rather than the display it is drawn on.

use bario_pdk::*;
use serde_json::{json, Value};

static mut SOURCE: String = String::new();

fn source() -> String {
    let stored = unsafe { (*std::ptr::addr_of!(SOURCE)).clone() };
    if stored.is_empty() { "emira".to_string() } else { stored }
}

#[no_mangle]
pub extern "C" fn init(ptr: i32, len: i32) -> i64 {
    let config = input(ptr, len);
    unsafe {
        SOURCE = config["source"].as_str().unwrap_or("emira").to_string();
    }
    subscribe_to(&format!("state:{}.*", source()));
    NOTHING
}

/// Once, when the item starts, for whatever the source wrote before `init` subscribed. Everything
/// after arrives as an event.
#[no_mangle]
pub extern "C" fn poll(_ptr: i32, _len: i32) -> i64 {
    let patch = focused();
    if patch.is_null() { NOTHING } else { output(&patch) }
}

#[no_mangle]
pub extern "C" fn on_event(ptr: i32, len: i32) -> i64 {
    if input(ptr, len)["name"] != "state" {
        return NOTHING;
    }
    let patch = focused();
    if patch.is_null() { NOTHING } else { output(&patch) }
}

#[no_mangle]
pub extern "C" fn render(ptr: i32, len: i32) -> i64 {
    let state = input(ptr, len);
    match state["workspace"].as_str() {
        Some(name) if !name.is_empty() => output(&Render::new(text(name))),
        // Nothing heard from the source yet: no bubble rather than an empty one.
        _ => output(&Render::hidden()),
    }
}

/// The focused workspace's name, from the source's latest snapshot, as a patch for this item's own
/// state. Null while the source holds nothing.
fn focused() -> Value {
    let desktop = get_state_absolute(&source());
    match desktop["focus"]["workspace"].as_str() {
        Some(name) => json!({ "workspace": name }),
        None => Value::Null,
    }
}
