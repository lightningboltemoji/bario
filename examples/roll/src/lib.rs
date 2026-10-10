//! A `roll` node: text that changes by turning over, as on a drum. The old text slides out of the
//! node's box one way while the new slides in from the other, clipped to the box.
//!
//! ```kdl
//! renderer "roll" path="~/.config/bario/renderers/roll.wasm"
//! ```
//!
//! ```json
//! { "roll": { "text": "2", "from": "1", "direction": "up", "since": 1791593328754 } }
//! ```
//!
//! `up` sends `from` out of the top and brings `text` in from the bottom; `down` the reverse.
//! `since` is when the change happened, in epoch milliseconds, so the module that knows about the
//! change says when it was and the renderer only draws: it keeps no state, and a node drawn again
//! after the turn has settled is drawn still. Without `from`, `direction` or `since`, it is still.
//! Both lines are one box apart throughout, as a drum's faces are.
//!
//! Themed from the stylesheet, as custom properties on the node or anything above it:
//!
//! - `--roll-height`: the box the text turns in, so it can clip where the bubble's border starts
//!   rather than at the text's own line. The text's line height by default.
//! - `--roll-stiffness`: the spring's. A turn is a critically damped spring, emira's own `smooth`
//!   motion, so it never overshoots; 800 by default, as emira's, which settles a 21pt box in about
//!   200ms.
//! - `--roll-advance`: a character's width, in ems, since a renderer cannot measure text. 0.6 by
//!   default, which is every character of SF Mono and so of `ui-monospace`.

use bario_pdk::*;
use serde_json::{json, Value};

const STIFFNESS: f64 = 800.0;
/// Settled, and drawn still, once the text is this close to where it is going: half a pixel at 2x.
const SETTLED_PT: f64 = 0.25;
const ADVANCE_EM: f64 = 0.6;

#[no_mangle]
pub extern "C" fn draw(ptr: i32, len: i32) -> i64 {
    let request = input(ptr, len);
    let node = &request["node"];
    let style = &request["style"];
    let text = node["text"].as_str().unwrap_or("");
    let frame_height = request["frame"]["height"].as_f64().unwrap_or(0.0);

    if request["measure"] == true {
        let size = style["font"]["size"].as_f64().unwrap_or(12.0);
        let advance = custom(style, "--roll-advance").and_then(|v| v.parse().ok()).unwrap_or(ADVANCE_EM);
        let height = custom(style, "--roll-height").and_then(length).unwrap_or(frame_height);
        let width = text.chars().count() as f64 * size * advance;
        return output(&json!({ "width": width, "height": height }));
    }

    let width = request["frame"]["width"].as_f64().unwrap_or(0.0);
    let middle = frame_height / 2.0;
    let line = |text: &str, y: f64| json!({ "text": text, "at": [width / 2.0, y], "align": "center" });
    let clip = json!({ "clip": [["rect", 0, 0, width, frame_height]] });

    // -1 moves up the box, +1 down it.
    let sign = match node["direction"].as_str() {
        Some("up") => -1.0,
        Some("down") => 1.0,
        _ => 0.0,
    };
    let stiffness = custom(style, "--roll-stiffness").and_then(|v| v.parse().ok()).unwrap_or(STIFFNESS);
    // How far the new text still has to go, as a share of the box: 1 at `since`, falling to 0.
    let remaining = node["since"]
        .as_f64()
        .map_or(0.0, |since| spring(stiffness, (epoch_ms() as f64 - since).max(0.0) / 1000.0));
    let from = node["from"].as_str().filter(|from| *from != text);

    let (Some(from), true, true) = (from, sign != 0.0, remaining * frame_height > SETTLED_PT) else {
        return output(&json!({ "ops": [clip, line(text, middle)] }));
    };
    frame();
    output(&json!({ "ops": [
        clip,
        line(from, middle + sign * (1.0 - remaining) * frame_height),
        line(text, middle - sign * remaining * frame_height),
    ] }))
}

/// A critically damped spring of unit mass let go from rest, one unit from home: what is left of
/// that unit `t` seconds later. emira's `Spring`, the critical case.
fn spring(stiffness: f64, t: f64) -> f64 {
    let omega = stiffness.sqrt();
    (1.0 + omega * t) * (-omega * t).exp()
}

fn custom<'a>(style: &'a Value, name: &str) -> Option<&'a str> {
    style["custom"][name].as_str().map(str::trim)
}

/// `21pt` or `21`, in points.
fn length(text: &str) -> Option<f64> {
    text.strip_suffix("pt").unwrap_or(text).trim().parse().ok()
}
