//! emira's focused workspace as a bario module: its name, and nothing else, as a bubble.
//!
//! It reads the state a `source` running `emira watch` writes, and asks for nothing: no network, no
//! files, no processes. It hears the source change through a state subscription, keeps the name
//! under its own key, and renders from that, so a bar redraw never asks emira anything.
//!
//! ```kdl
//! source "emira" module="exec" interval="watch" { command "emira" "watch" }
//! renderer "roll" path="~/.config/bario/renderers/roll.wasm"
//!
//! item "workspace" module="wasm" path="~/.config/bario/modules/emira-workspace.wasm" {
//!   config source="emira" roll=#true
//! }
//! ```
//!
//! `source` is the key the source writes under. A bario item is the same on every bar, so the name
//! follows focus rather than the display it is drawn on.
//!
//! `roll` draws the name as a `roll` node (`examples/roll`), which turns over as emira pans: to a
//! workspace after the last in key order (`1`…`9`, `0`, `a`…`z`), the old name leaves by the top and
//! the new one comes up from below, and back the other way. It turns only when emira pans, which
//! is when the display now focused shows a workspace it did not before. Focus moving to a display
//! that was already showing its workspace pans nothing, so the name changes still.

use bario_pdk::*;
use serde_json::{json, Map, Value};

/// emira's addresses, in the order its keys sit and its workspaces stack.
const ORDER: &str = "1234567890abcdefghijklmnopqrstuvwxyz";

static mut SOURCE: String = String::new();
static mut ROLL: bool = false;

fn source() -> String {
    let stored = unsafe { (*std::ptr::addr_of!(SOURCE)).clone() };
    if stored.is_empty() { "emira".to_string() } else { stored }
}

#[no_mangle]
pub extern "C" fn init(ptr: i32, len: i32) -> i64 {
    let config = input(ptr, len);
    unsafe {
        SOURCE = config["source"].as_str().unwrap_or("emira").to_string();
        ROLL = config["roll"].as_bool().unwrap_or(false);
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
    let name = match state["workspace"].as_str() {
        Some(name) if !name.is_empty() => name,
        // Nothing heard from the source yet: no bubble rather than an empty one.
        _ => return output(&Render::hidden()),
    };
    if !unsafe { ROLL } {
        return output(&Render::new(text(name)));
    }
    let mut roll = json!({ "text": name });
    if let (Some(from), Some(direction)) = (state["from"].as_str(), state["direction"].as_str()) {
        roll["from"] = json!(from);
        roll["direction"] = json!(direction);
        roll["since"] = state["since"].clone();
    }
    output(&Render::new(json!({ "roll": roll })))
}

/// The focused workspace's name, from the source's latest snapshot, as a patch for this item's own
/// state, with how it turns when it changes. Null while the source holds nothing.
///
/// The focused display's workspace, not `focus.workspace`: an empty workspace focuses no window, so
/// `focus` is null there, and the bubble would keep the workspace just left.
fn focused() -> Value {
    let desktop = get_state_absolute(&source());
    let empty = Vec::new();
    let displays = desktop["displays"].as_array().unwrap_or(&empty);
    let display = displays.iter().find(|d| d["focused"] == true);
    let Some(name) = display.and_then(|d| d["workspace"].as_str()).or_else(|| desktop["focus"]["workspace"].as_str())
    else {
        return Value::Null;
    };

    // What every display shows, so the next change can tell which of them emira panned.
    let shown: Map<String, Value> = displays
        .iter()
        .filter_map(|d| Some((id(&d["id"])?, d["workspace"].clone())))
        .collect();
    let mut patch = json!({ "workspace": name, "shown": shown });

    let was = get_state("workspace");
    let Some(was) = was.as_str().filter(|was| *was != name) else { return patch };
    let before = display.and_then(|d| id(&d["id"])).map(|id| get_state("shown")[&id].clone());
    let before = before.as_ref().and_then(Value::as_str);
    match (before.filter(|before| *before != name).and_then(rank), rank(name)) {
        (Some(before), Some(after)) => {
            patch["from"] = json!(was);
            patch["direction"] = json!(if after > before { "up" } else { "down" });
            patch["since"] = json!(epoch_ms());
        }
        _ => {
            patch["from"] = Value::Null;
            patch["direction"] = Value::Null;
        }
    }
    patch
}

fn rank(name: &str) -> Option<usize> {
    if name.chars().count() == 1 { ORDER.find(name) } else { None }
}

/// A display's id as a key: emira's are strings, but a number would do as well.
fn id(value: &Value) -> Option<String> {
    match value {
        Value::String(id) => Some(id.clone()),
        Value::Number(id) => Some(id.to_string()),
        _ => None,
    }
}
