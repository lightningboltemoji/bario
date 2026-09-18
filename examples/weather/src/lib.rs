//! The worked example from DESIGN.md §5 and §11: a weather bubble.
//!
//! It reads `city` and `units` from its config, fetches from wttr.in on each poll through the
//! gated `http` import, writes what it found into the store, and renders from the store. That
//! separation is the point: when the network is down, `poll` fails and `render` still shows
//! the last good reading, marked `.stale`.
//!
//! It never touches the filesystem, a socket, or a process. `permissions "net"` is all it asks
//! for, and all it gets.

use bario_pdk::*;
use serde_json::{json, Value};

/// wttr.in's one-line format: temperature, condition code, and the feels-like value.
const FORMAT: &str = "%t|%C|%f";

static mut CITY: String = String::new();
static mut UNITS: String = String::new();

fn city() -> String {
    let stored = unsafe { CITY.clone() };
    if stored.is_empty() { "Vancouver".to_string() } else { stored }
}

fn metric() -> bool {
    unsafe { UNITS != "imperial" }
}

#[no_mangle]
pub extern "C" fn init(ptr: i32, len: i32) -> i64 {
    let config = input(ptr, len);
    unsafe {
        CITY = config["city"].as_str().unwrap_or("Vancouver").to_string();
        UNITS = config["units"].as_str().unwrap_or("metric").to_string();
    }
    info(&format!("weather for {}", city()));
    NOTHING
}

#[no_mangle]
pub extern "C" fn poll(_ptr: i32, _len: i32) -> i64 {
    let url = format!(
        "https://wttr.in/{}?format={}&{}",
        urlencode(&city()),
        urlencode(FORMAT),
        if metric() { "m" } else { "u" }
    );
    let response = get_url(&url);

    if let Some(error) = response["error"].as_str() {
        warn(error);
        // Try again sooner than the configured interval, but not in a tight loop.
        poll_again_in(60_000);
        return output(&json!({ "error": error }));
    }
    let status = response["status"].as_i64().unwrap_or(0);
    let body = response["body"].as_str().unwrap_or("").trim().to_string();
    if status != 200 || body.is_empty() || body.contains("Unknown location") {
        poll_again_in(60_000);
        return output(&json!({ "error": format!("wttr.in said {status}") }));
    }

    let parts: Vec<&str> = body.split('|').collect();
    let temp = parts.first().copied().unwrap_or("").trim().to_string();
    let condition = parts.get(1).copied().unwrap_or("").trim().to_string();
    let feels = parts.get(2).copied().unwrap_or("").trim().to_string();

    output(&json!({
        "temp": temp,
        "condition": condition,
        "feels-like": feels,
        "icon": symbol_for(&condition),
        "error": Value::Null,
        "updated": epoch_ms(),
    }))
}

#[no_mangle]
pub extern "C" fn render(ptr: i32, len: i32) -> i64 {
    let state = input(ptr, len);
    let temp = state["temp"].as_str().unwrap_or("");
    if temp.is_empty() {
        // Nothing fetched yet: take up no room rather than showing an empty bubble.
        return output(&Render::hidden());
    }
    let icon_name = state["icon"].as_str().unwrap_or("cloud");
    let condition = state["condition"].as_str().unwrap_or("");
    let feels = state["feels-like"].as_str().unwrap_or("");

    let mut render = Render::new(row(vec![
        icon(icon_name),
        text_class(temp, "temp"),
    ]));
    if !condition.is_empty() {
        render = render.tooltip(&format!("{condition} in {}, feels like {feels}", city()));
    }
    if state["error"].is_string() {
        render = render.class("stale");
    }
    output(&render)
}

/// wttr.in's condition text, mapped onto SF Symbols. The module writes the symbol name into
/// state so `format="{icon} {temp}"` works without anyone learning symbol names.
fn symbol_for(condition: &str) -> &'static str {
    let lower = condition.to_lowercase();
    let has = |needle: &str| lower.contains(needle);
    if has("thunder") { return "cloud.bolt.rain.fill"; }
    if has("snow") || has("sleet") || has("ice") { return "cloud.snow.fill"; }
    if has("heavy rain") || has("torrential") { return "cloud.heavyrain.fill"; }
    if has("rain") || has("drizzle") || has("shower") { return "cloud.rain.fill"; }
    if has("fog") || has("mist") || has("haze") { return "cloud.fog.fill"; }
    if has("overcast") { return "cloud.fill"; }
    if has("cloud") || has("partly") { return "cloud.sun.fill"; }
    if has("clear") || has("sunny") { return "sun.max.fill"; }
    "thermometer.medium"
}

fn urlencode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}
