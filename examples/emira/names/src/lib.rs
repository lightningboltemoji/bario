//! emira's names guide as a bario module: one cell per column on the focused display, named after
//! its largest window, with a superscript count when it holds more than one, and the focused cell
//! marked `focused`.
//!
//! It reads the state a `source` running `emira watch` writes, and asks for nothing: no network, no
//! files, no processes. It hears the source change through a state subscription, keeps the part it
//! shows under its own key, and renders from that, so a bar redraw never asks emira anything.
//!
//! ```kdl
//! source "emira" module="exec" interval="watch" { command "emira" "watch" }
//!
//! item "names" module="wasm" path="~/.config/bario/modules/emira-names.wasm" when="guide" {
//!   config source="emira" max=7
//! }
//! ```
//!
//! `source` is the key the source writes under, and `max` keeps the columns nearest focus, with an
//! ellipsis where the others were; without it every column is named. A bario item is the same on
//! every bar, so the row follows focus rather than the display it is drawn on.

use bario_pdk::*;
use serde_json::{json, Value};

static mut SOURCE: String = String::new();
static mut MAX: usize = 0;

fn source() -> String {
    let stored = unsafe { (*std::ptr::addr_of!(SOURCE)).clone() };
    if stored.is_empty() { "emira".to_string() } else { stored }
}

#[no_mangle]
pub extern "C" fn init(ptr: i32, len: i32) -> i64 {
    let config = input(ptr, len);
    unsafe {
        SOURCE = config["source"].as_str().unwrap_or("emira").to_string();
        MAX = config["max"].as_u64().unwrap_or(0) as usize;
    }
    subscribe_to(&format!("state:{}.*", source()));
    NOTHING
}

/// Once, when the item starts, for whatever the source wrote before `init` subscribed. Everything
/// after arrives as an event.
#[no_mangle]
pub extern "C" fn poll(_ptr: i32, _len: i32) -> i64 {
    let patch = strip();
    if patch.is_null() { NOTHING } else { output(&patch) }
}

#[no_mangle]
pub extern "C" fn on_event(ptr: i32, len: i32) -> i64 {
    if input(ptr, len)["name"] != "state" {
        return NOTHING;
    }
    let patch = strip();
    if patch.is_null() { NOTHING } else { output(&patch) }
}

#[no_mangle]
pub extern "C" fn render(ptr: i32, len: i32) -> i64 {
    let state = input(ptr, len);
    let Some(cells) = state["cells"].as_array() else {
        // Nothing heard from the source yet: no bubble rather than an empty one.
        return output(&Render::hidden());
    };
    let layout = state["layout"].as_str().unwrap_or("strip");
    if cells.is_empty() {
        let workspace = state["workspace"].as_str().unwrap_or("");
        return output(&Render::new(text_class(workspace, "empty")).class(layout).class("empty"));
    }

    let more = || text_class("…", "more");
    let mut children: Vec<Value> = Vec::new();
    if state["before"].as_u64().unwrap_or(0) > 0 {
        children.push(more());
    }
    for cell in cells {
        let mut runs = vec![text_class(cell["app"].as_str().unwrap_or(""), "app")];
        let depth = cell["windows"].as_u64().unwrap_or(1);
        if depth > 1 {
            runs.push(text_class(&superscript(depth), "count"));
        }
        let mut classes = vec!["column"];
        if cell["focused"].as_bool().unwrap_or(false) {
            classes.push("focused");
        }
        children.push(json!({ "row": { "children": runs }, "class": classes }));
    }
    if state["after"].as_u64().unwrap_or(0) > 0 {
        children.push(more());
    }
    let tooltip = format!("workspace {}", state["workspace"].as_str().unwrap_or(""));
    output(&Render::new(json!({ "row": { "children": children }, "class": "names" }))
        .class(layout)
        .tooltip(&tooltip))
}

/// What the row shows, from the source's latest snapshot: the focused display's columns, cut to
/// `max` around focus, as a patch for this item's own state. Null while the source holds nothing.
fn strip() -> Value {
    let desktop = get_state_absolute(&source());
    let Some(displays) = desktop["displays"].as_array() else { return Value::Null };
    let empty = Vec::new();
    let display = displays.iter().find(|d| d["focused"] == true);
    let columns = display.and_then(|d| d["columns"].as_array()).unwrap_or(&empty);

    let limit = unsafe { MAX };
    let focus = columns.iter().position(|c| c["focused"] == true).unwrap_or(0);
    let shown = if limit > 0 { limit.min(columns.len()) } else { columns.len() };
    let start = focus.saturating_sub(shown / 2).min(columns.len() - shown);
    let cells: Vec<Value> = columns[start..start + shown]
        .iter()
        .map(|column| json!({
            "app": column["app"],
            "windows": column["windows"].as_array().map_or(1, |w| w.len()),
            "focused": column["focused"],
        }))
        .collect();

    json!({
        "cells": cells,
        "before": start,
        "after": columns.len() - start - shown,
        "layout": display.map_or(json!("strip"), |d| d["layout"].clone()),
        "workspace": display.map_or(json!(""), |d| d["workspace"].clone()),
    })
}

/// `2` as `²`: the count sits beside the name without taking a cell of its own.
fn superscript(number: u64) -> String {
    const DIGITS: [char; 10] = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
    number.to_string().chars().filter_map(|c| c.to_digit(10)).map(|d| DIGITS[d as usize]).collect()
}
