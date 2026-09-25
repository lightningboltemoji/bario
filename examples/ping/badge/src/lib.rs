//! One app's Dock badge, as Ping reads it: the app's icon beside its count, its word, or a dot,
//! and classes that say what state the badge is in, so the stylesheet decides how each one looks.
//!
//! It reads the state a `source` running `ping-dot-app watch` writes, and asks for nothing: no
//! network, no files, no processes. It hears the source change through a state subscription, keeps
//! its own app's part under its own key, and renders from that.
//!
//! ```kdl
//! source "ping" module="exec" interval="watch" max-backoff="5s" {
//!   command "/Applications/Ping.app/Contents/MacOS/ping-dot-app" "watch"
//! }
//!
//! item "slack" module="wasm" path="~/.config/bario/modules/ping-badge.wasm" {
//!   config app="Slack" warn=1 critical=10 hide="quiet"
//! }
//! ```
//!
//! - `app`: the app's title in the Dock. Required.
//! - `source`: the key the source writes under; `ping` unless it says otherwise.
//! - `warn`, `critical`: counts at or above which the item wears `.warn` or `.critical`.
//! - `icon`: `app` (the default) for the app's own icon, an SF Symbol name, or `none`.
//! - `dot`: what a bare dot shows beside the icon; `•` unless it says otherwise, and nothing for `""`.
//! - `hide`: `clear` hides the item while the app has no badge; `quiet` also while Ping has it
//!   acknowledged or snoozed. Without it the item stays, and says `.clear`.
//!
//! The item wears exactly one of `.clear`, `.dot`, `.count` and `.text`, and `.badged` with any
//! but the first. `.acknowledged` and `.snoozed` are Ping's own answers. `.absent` means the app is
//! not in the Dock at all. `.silent` means Ping has stopped answering, so what shows is the last
//! thing it said.

use bario_pdk::*;
use serde_json::{json, Value};
use std::sync::OnceLock;

struct Config {
    app: String,
    source: String,
    warn: Option<i64>,
    critical: Option<i64>,
    icon: String,
    dot: String,
    hide: Hide,
}

#[derive(PartialEq)]
enum Hide {
    Never,
    Clear,
    Quiet,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

fn config() -> &'static Config {
    CONFIG.get().expect("init runs before anything else")
}

fn text_or(value: &Value, fallback: &str) -> String {
    value.as_str().unwrap_or(fallback).to_string()
}

#[no_mangle]
pub extern "C" fn init(ptr: i32, len: i32) -> i64 {
    let given = input(ptr, len);
    let hide = match given["hide"].as_str() {
        Some("clear") => Hide::Clear,
        Some("quiet") => Hide::Quiet,
        Some(other) => {
            warn(&format!("hide takes \"clear\" or \"quiet\", not \"{other}\""));
            Hide::Never
        }
        None => Hide::Never,
    };
    let config = Config {
        app: text_or(&given["app"], ""),
        source: text_or(&given["source"], "ping"),
        warn: given["warn"].as_i64(),
        critical: given["critical"].as_i64(),
        icon: match &given["icon"] {
            Value::Bool(false) => "none".to_string(),
            other => text_or(other, "app"),
        },
        dot: text_or(&given["dot"], "•"),
        hide,
    };
    subscribe_to(&format!("state:{}.*", config.source));
    let _ = CONFIG.set(config);
    NOTHING
}

/// Once, when the item starts, for whatever the source wrote before `init` subscribed. Everything
/// after arrives as an event.
#[no_mangle]
pub extern "C" fn poll(_ptr: i32, _len: i32) -> i64 {
    heard()
}

#[no_mangle]
pub extern "C" fn on_event(ptr: i32, len: i32) -> i64 {
    if input(ptr, len)["name"] != "state" {
        return NOTHING;
    }
    heard()
}

fn heard() -> i64 {
    let patch = app();
    if patch.is_null() {
        NOTHING
    } else {
        output(&patch)
    }
}

/// This app's part of the source's latest reading, as a patch for the item's own state. A null
/// deletes its key, which is how a badge that went away leaves. Null while Ping has said nothing.
fn app() -> Value {
    let config = config();
    let dock = get_state_absolute(&config.source);
    let Some(apps) = dock["apps"].as_array() else { return Value::Null };
    let found = apps.iter().find(|app| app["name"] == config.app.as_str());
    let field = |key: &str| found.map_or(Value::Null, |app| app[key].clone());
    json!({
        "heard": true,
        "docked": found.is_some(),
        "badge": field("badge"),
        "count": field("count"),
        "acknowledged": field("acknowledged"),
        "path": field("path"),
        "snoozed": dock["snoozed"],
        "silent": dock["exit-code"].as_i64().unwrap_or(0) != 0,
    })
}

#[no_mangle]
pub extern "C" fn render(ptr: i32, len: i32) -> i64 {
    let config = config();
    if config.app.is_empty() {
        return output(&Render::new(text("ping-badge needs app=\"…\"")).class("error"));
    }
    let state = input(ptr, len);
    if state["heard"] != true {
        // Nothing from Ping yet: no bubble rather than an empty one.
        return output(&Render::hidden());
    }

    let badge = state["badge"].as_str();
    let count = state["count"].as_i64();
    let (kind, label) = match (badge, count) {
        (None, _) => ("clear", None),
        (Some(_), Some(count)) => ("count", Some(count.to_string())),
        (Some(""), None) => ("dot", Some(config.dot.clone())),
        (Some(word), None) => ("text", Some(word.to_string())),
    };
    let acknowledged = state["acknowledged"] == true;
    let snoozed = state["snoozed"] == true;
    let hidden = match config.hide {
        Hide::Never => false,
        Hide::Clear => kind == "clear",
        Hide::Quiet => kind == "clear" || acknowledged || snoozed,
    };

    let mut children = Vec::new();
    match (config.icon.as_str(), state["path"].as_str()) {
        ("none", _) => {}
        ("app", Some(path)) => children.push(json!({ "icon": { "file": path }, "class": "app" })),
        ("app", None) => {}
        (symbol, _) => children.push(icon(symbol)),
    }
    if let Some(label) = label.as_deref().filter(|label| !label.is_empty()) {
        children.push(text_class(label, "badge"));
    }
    if hidden || children.is_empty() {
        return output(&Render::hidden());
    }

    let mut render = Render::new(row(children)).class(kind);
    if kind != "clear" {
        render = render.class("badged");
    }
    if let Some(count) = count {
        if config.critical.is_some_and(|at| count >= at) {
            render = render.class("critical");
        } else if config.warn.is_some_and(|at| count >= at) {
            render = render.class("warn");
        }
    }
    for (on, class) in [
        (acknowledged, "acknowledged"),
        (snoozed, "snoozed"),
        (state["silent"] == true, "silent"),
        (state["docked"] != true, "absent"),
    ] {
        if on {
            render = render.class(class);
        }
    }

    let mut tooltip = match &label {
        Some(label) if kind == "count" => format!("{}: {label}", config.app),
        Some(_) if kind == "dot" => format!("{}: badged", config.app),
        Some(label) => format!("{}: \"{label}\"", config.app),
        None => format!("{}: nothing new", config.app),
    };
    if acknowledged {
        tooltip.push_str(", acknowledged");
    }
    if snoozed {
        tooltip.push_str(", snoozed");
    }
    output(&render.tooltip(&tooltip))
}
