//! Write a bario module in Rust.
//!
//! A module is a WebAssembly file that exports `render`, and optionally `init`, `poll` and
//! `on_event`. This crate is the whole ABI: the packed `(ptr, len)` return, the allocator the
//! host uses to hand you bytes, and the host imports.
//!
//! ```ignore
//! use bario_pdk::*;
//!
//! #[no_mangle]
//! pub extern "C" fn render(ptr: i32, len: i32) -> i64 {
//!     let state = input(ptr, len);
//!     let pct = state["pct"].as_f64().unwrap_or(0.0);
//!     output(&Render::new(row(vec![
//!         icon("bolt.fill"),
//!         text(&format!("{pct:.0}%")),
//!     ])))
//! }
//! ```
//!
//! Build it with:
//!
//! ```sh
//! cargo build --release --target wasm32-unknown-unknown
//! ```
//!
//! and point an item at the `.wasm` it produces.

use serde::Serialize;
use serde_json::{json, Value};
use std::alloc::{alloc as rust_alloc, dealloc as rust_dealloc, Layout};

// ---------------------------------------------------------------------------
// The ABI: three things, and they are the same three in every language.
// ---------------------------------------------------------------------------

/// The host calls this to get a buffer it can write bytes into. Eight extra bytes hold the
/// length, so `dealloc` can hand the same layout back to Rust.
#[no_mangle]
pub extern "C" fn alloc(len: i32) -> i32 {
    let size = len.max(0) as usize + 8;
    unsafe {
        let layout = Layout::from_size_align(size, 8).unwrap();
        let ptr = rust_alloc(layout);
        if ptr.is_null() {
            return 0;
        }
        (ptr as *mut u64).write(size as u64);
        ptr.add(8) as i32
    }
}

/// Optional, but exported here so the host can give memory back promptly.
#[no_mangle]
pub extern "C" fn dealloc(ptr: i32, _len: i32) {
    if ptr == 0 {
        return;
    }
    unsafe {
        let base = (ptr as *mut u8).sub(8);
        let size = (base as *const u64).read() as usize;
        rust_dealloc(base, Layout::from_size_align(size, 8).unwrap());
    }
}

/// `(ptr, len)` packed into one i64: high 32 bits the pointer, low 32 the length.
fn pack(ptr: i32, len: i32) -> i64 {
    ((ptr as u32 as u64) << 32 | len as u32 as u64) as i64
}

/// Read the JSON the host passed in.
pub fn input(ptr: i32, len: i32) -> Value {
    if ptr == 0 || len <= 0 {
        return json!({});
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr as *const u8, len as usize) };
    serde_json::from_slice(bytes).unwrap_or_else(|_| json!({}))
}

/// Hand JSON back to the host. The buffer is leaked deliberately: the host reads it and then
/// calls `dealloc`.
pub fn output<T: Serialize>(value: &T) -> i64 {
    let bytes = match serde_json::to_vec(value) {
        Ok(bytes) => bytes,
        Err(_) => return 0,
    };
    if bytes.is_empty() {
        return 0;
    }
    let ptr = alloc(bytes.len() as i32);
    if ptr == 0 {
        return 0;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, bytes.len());
    }
    pack(ptr, bytes.len() as i32)
}

/// Nothing to say.
pub const NOTHING: i64 = 0;

// ---------------------------------------------------------------------------
// Host imports
// ---------------------------------------------------------------------------

#[link(wasm_import_module = "bario")]
extern "C" {
    fn log(level: i32, ptr: i32, len: i32);
    fn now() -> i64;
    fn set(ptr: i32, len: i32);
    fn get(ptr: i32, len: i32) -> i32;
    fn read(ptr: i32);
    fn emit(ptr: i32, len: i32);
    fn subscribe(ptr: i32, len: i32);
    fn set_timer(ms: i32) -> i32;
    fn request_frame();
    fn exec(ptr: i32, len: i32) -> i32;
    fn read_file(ptr: i32, len: i32) -> i32;
    fn http(ptr: i32, len: i32) -> i32;
}

fn send(value: &Value) -> (i32, i32) {
    let bytes = serde_json::to_vec(value).unwrap_or_default();
    if bytes.is_empty() {
        return (0, 0);
    }
    let ptr = alloc(bytes.len() as i32);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, bytes.len());
    }
    (ptr, bytes.len() as i32)
}

/// A host import that produces bytes returns their length and stashes them; this copies them
/// out. One extra call, and no re-entrancy into the guest's allocator.
fn receive(len: i32) -> Value {
    if len <= 0 {
        return json!(null);
    }
    let buf = alloc(len);
    unsafe {
        read(buf);
        let bytes = std::slice::from_raw_parts(buf as *const u8, len as usize);
        let value = serde_json::from_slice(bytes).unwrap_or(json!(null));
        dealloc(buf, len);
        value
    }
}

pub fn info(message: &str) {
    unsafe { log(1, message.as_ptr() as i32, message.len() as i32) }
}

pub fn warn(message: &str) {
    unsafe { log(2, message.as_ptr() as i32, message.len() as i32) }
}

/// Milliseconds since the epoch.
pub fn epoch_ms() -> i64 {
    unsafe { now() }
}

/// Merge a patch into this item's subtree of the state store.
pub fn set_state(patch: &Value) {
    let (ptr, len) = send(patch);
    unsafe { set(ptr, len) };
    dealloc(ptr, len);
}

/// Read a key from this item's subtree, or anywhere with `get_state_absolute`.
pub fn get_state(key: &str) -> Value {
    let (ptr, len) = send(&json!(key));
    let size = unsafe { get(ptr, len) };
    dealloc(ptr, len);
    receive(size)
}

pub fn get_state_absolute(path: &str) -> Value {
    let (ptr, len) = send(&json!({ "key": path, "absolute": true }));
    let size = unsafe { get(ptr, len) };
    dealloc(ptr, len);
    receive(size)
}

pub fn emit_event(name: &str, payload: Value) {
    let (ptr, len) = send(&json!({ "name": name, "payload": payload }));
    unsafe { emit(ptr, len) };
    dealloc(ptr, len);
}

/// `state:battery.*`, `click:volume`, `system:wake`.
pub fn subscribe_to(topic: &str) {
    let (ptr, len) = send(&json!(topic));
    unsafe { subscribe(ptr, len) };
    dealloc(ptr, len);
}

/// Ask to be polled again in `ms`, instead of on the configured interval.
pub fn poll_again_in(ms: i32) {
    unsafe {
        set_timer(ms);
    }
}

/// Ask to be drawn again in the next frame, at the display's refresh rate. Call it from
/// `draw`, every frame the animation should continue; a call made while measuring asks for
/// nothing. Renderer modules only, and only for drawings that change shape: a drawing that only
/// turns, moves or fades is cheaper as a CSS `animation`, which costs no frames at all.
///
/// `draw` runs when the host commits a frame, not when it lays one out, and the `frame` it is
/// given is the node's own: `x` and `y` are 0, and `width` and `height` its size.
pub fn frame() {
    unsafe { request_frame() }
}

/// Needs `permissions "exec"`.
pub fn run(argv: &[&str]) -> Value {
    let (ptr, len) = send(&json!(argv));
    let size = unsafe { exec(ptr, len) };
    dealloc(ptr, len);
    receive(size)
}

/// Needs an `fs` grant covering the path.
pub fn file(path: &str) -> Value {
    let (ptr, len) = send(&json!(path));
    let size = unsafe { read_file(ptr, len) };
    dealloc(ptr, len);
    receive(size)
}

/// Needs `permissions "net"`. `{ "status": 200, "body": "…" }`, or `{ "error": "…" }`.
pub fn fetch(request: Value) -> Value {
    let (ptr, len) = send(&request);
    let size = unsafe { http(ptr, len) };
    dealloc(ptr, len);
    receive(size)
}

pub fn get_url(url: &str) -> Value {
    fetch(json!({ "method": "GET", "url": url }))
}

// ---------------------------------------------------------------------------
// Content trees
// ---------------------------------------------------------------------------

/// What `render` returns. The same shape as `schema/content.json`.
#[derive(Serialize)]
pub struct Render {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub classes: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tooltip: Option<String>,
    #[serde(skip_serializing_if = "is_true")]
    pub visible: bool,
}

fn is_true(value: &bool) -> bool {
    *value
}

impl Render {
    pub fn new(content: Value) -> Self {
        Render { content: Some(content), classes: vec![], tooltip: None, visible: true }
    }

    pub fn hidden() -> Self {
        Render { content: None, classes: vec![], tooltip: None, visible: false }
    }

    pub fn class(mut self, name: &str) -> Self {
        self.classes.push(name.to_string());
        self
    }

    pub fn tooltip(mut self, text: &str) -> Self {
        self.tooltip = Some(text.to_string());
        self
    }
}

pub fn text(value: &str) -> Value {
    json!({ "text": value })
}

/// A text node the stylesheet can address: `#weather .temp { … }`.
pub fn text_class(value: &str, class: &str) -> Value {
    json!({ "text": value, "class": class })
}

/// An SF Symbol name.
pub fn icon(name: &str) -> Value {
    json!({ "icon": name, "class": "icon" })
}

pub fn meter(value: f64, width: f64) -> Value {
    json!({ "meter": { "value": value, "width": width } })
}

pub fn graph(values: &[f64], width: f64) -> Value {
    json!({ "graph": { "values": values, "width": width } })
}

pub fn row(children: Vec<Value>) -> Value {
    json!({ "row": { "gap": 4, "align": "center", "children": children } })
}

pub fn column(children: Vec<Value>) -> Value {
    json!({ "column": { "children": children } })
}

pub fn spacer() -> Value {
    json!({ "spacer": {} })
}

/// A vector drawing the host paints. See DESIGN.md section 9.1 for the op set.
pub fn canvas(width: f64, ops: Vec<Value>) -> Value {
    json!({ "canvas": { "width": width, "ops": ops } })
}
