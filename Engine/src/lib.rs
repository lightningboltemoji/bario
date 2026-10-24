//! bariowasm — bario's WASM engine: a narrow C ABI over wasmtime's Pulley interpreter, driven by
//! `Sources/BarioKit/Wasm/WasmtimeEngine.swift`. One engine per process, one module per `.wasm` file,
//! one instance per item or renderer. The host imports are bario's own, defined in Swift (`WasmHost`):
//! this crate only carries their calls across, so the ABI is written down in one place.
//!
//! Every call into an instance runs against that instance's deadline, and past it the guest is
//! interrupted where it stands (`.agents/knowledge/23-wasmtime.md`).
//!
//! # Safety
//!
//! Every `bw_` function takes what `WasmtimeEngine` gives it: handles this crate made and has not freed,
//! each used from one thread at a time, buffers valid for the lengths beside them — empty ones possibly
//! null — and out-pointers to write. That one contract covers them all, so it is said here rather than
//! on each.
#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use wasmtime::{
    Caller, Config, Engine, Extern, FuncType, Instance, Linker, Memory, Module, ResourceLimiter, Result,
    Store, Trap, UpdateDeadline, Val, ValType, WasmBacktrace,
};

pub const BW_OK: i32 = 0;
pub const BW_DEADLINE: i32 = 1;
pub const BW_TRAP: i32 = 2;
pub const BW_ERROR: i32 = 3;

pub const BW_I32: u32 = 0;
pub const BW_I64: u32 = 1;

/// Where every host import lives, as the PDKs declare them.
const NAMESPACE: &str = "bario";

/// What a module's start function gets, before anyone has set a deadline.
const START_BUDGET: Duration = Duration::from_secs(1);

pub struct BwEngine {
    engine: Engine,
    ticking: Arc<Ticking>,
    ticker: Option<JoinHandle<()>>,
}

/// The calls running, which the ticker ticks for: with none, it waits, and bario idles without a wake a
/// millisecond.
#[derive(Default)]
struct Ticking {
    /// Calls in flight, and whether the engine is going.
    state: Mutex<(usize, bool)>,
    wake: Condvar,
}

impl Ticking {
    fn state(&self) -> MutexGuard<'_, (usize, bool)> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Ticks until the guard is dropped.
    fn running(self: &Arc<Self>) -> Running {
        self.state().0 += 1;
        self.wake.notify_one();
        Running(self.clone())
    }

    /// Blocks while nothing runs; false once the engine is going.
    fn wait_for_calls(&self) -> bool {
        let mut state = self.state();
        while state.0 == 0 && !state.1 {
            state = self.wake.wait(state).unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        !state.1
    }

    fn stop(&self) {
        self.state().1 = true;
        self.wake.notify_one();
    }
}

struct Running(Arc<Ticking>);

impl Drop for Running {
    fn drop(&mut self) {
        self.0.state().0 -= 1;
    }
}

pub struct BwModule {
    module: Module,
}

/// Refuses a memory.grow past the cap: the guest sees -1, and a guest that cannot cope traps.
struct Limiter {
    cap: usize,
}

impl ResourceLimiter for Limiter {
    fn memory_growing(&mut self, _current: usize, desired: usize, _max: Option<usize>) -> Result<bool> {
        Ok(desired <= self.cap)
    }
    fn table_growing(&mut self, _current: usize, desired: usize, _max: Option<usize>) -> Result<bool> {
        Ok(desired <= 100_000)
    }
}

struct HostState {
    limiter: Limiter,
    deadline: Instant,
}

pub struct BwInstance {
    store: Store<HostState>,
    ticking: Arc<Ticking>,
    instance: Instance,
    memory: Option<Memory>,
}

/// A host import as Swift declares it: a name in `bario`, and its parameter and result types.
#[repr(C)]
pub struct BwImport {
    name: *const c_char,
    params: *const u32,
    nparams: usize,
    results: *const u32,
    nresults: usize,
}

/// Swift's side of every host import: `index` says which, `args` holds its parameters widened to i64,
/// and it writes its results the same way. False, after `bw_caller_fail`, traps the guest.
type HostFn = extern "C" fn(
    ctx: *mut c_void,
    index: usize,
    caller: *mut BwCaller<'_>,
    args: *const i64,
    nargs: usize,
    results: *mut i64,
    nresults: usize,
) -> bool;

/// The guest's memory while one of its host imports runs, and why that import failed if it did. Only
/// borrowed for the length of the call: nothing calls back into the guest from inside one, so its
/// memory cannot move under it.
pub struct BwCaller<'a> {
    memory: Option<&'a mut [u8]>,
    failure: Option<String>,
}

/// One instance's way back to Swift, copied into each host import's closure.
#[derive(Clone, Copy)]
struct Host {
    call: HostFn,
    ctx: usize,
}

impl Host {
    fn call(
        &self,
        index: usize,
        returns_i64: &[bool],
        caller: &mut Caller<'_, HostState>,
        args: &[Val],
        results: &mut [Val],
    ) -> Result<()> {
        let args: Vec<i64> = args.iter().map(widen).collect();
        let mut out = vec![0i64; results.len()];
        let memory = match caller.get_export("memory") {
            Some(Extern::Memory(memory)) => Some(memory.data_mut(&mut *caller)),
            _ => None,
        };
        let mut borrowed = BwCaller { memory, failure: None };
        let ok = (self.call)(
            self.ctx as *mut c_void,
            index,
            &mut borrowed,
            args.as_ptr(),
            args.len(),
            out.as_mut_ptr(),
            out.len(),
        );
        if !ok {
            let failure = borrowed.failure.take().unwrap_or_else(|| "a host import failed".into());
            wasmtime::bail!(failure);
        }
        for ((slot, value), wide) in results.iter_mut().zip(out).zip(returns_i64) {
            *slot = if *wide { Val::I64(value) } else { Val::I32(value as i32) };
        }
        Ok(())
    }
}

// ---- helpers --------------------------------------------------------------------------------------

/// What Swift hands over. An empty buffer's pointer may be null, which a slice may never be.
unsafe fn borrowed<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if ptr.is_null() || len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } }
}

unsafe fn borrowed_mut<'a, T>(ptr: *mut T, len: usize) -> &'a mut [T] {
    if ptr.is_null() || len == 0 { &mut [] } else { unsafe { std::slice::from_raw_parts_mut(ptr, len) } }
}

unsafe fn name<'a>(ptr: *const c_char) -> Result<&'a str> {
    if ptr.is_null() {
        wasmtime::bail!("no name");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

unsafe fn set_err(err: *mut *mut c_char, msg: String) {
    if !err.is_null() {
        let c = CString::new(msg.replace('\0', " ")).unwrap();
        unsafe { *err = c.into_raw() };
    }
}

unsafe fn put_bytes(out: *mut *mut u8, out_len: *mut usize, bytes: Vec<u8>) {
    let b = bytes.into_boxed_slice();
    unsafe {
        *out_len = b.len();
        *out = Box::into_raw(b) as *mut u8;
    }
}

/// Reports a result as bario's status codes: anything that fails is `BW_ERROR`, with its reason.
unsafe fn report(result: Result<()>, err: *mut *mut c_char) -> i32 {
    match result {
        Ok(()) => BW_OK,
        Err(error) => {
            unsafe { set_err(err, format!("{error:#}")) };
            BW_ERROR
        }
    }
}

/// One line, for a log: wasmtime renders a trap with its backtrace on lines of their own, and the frames
/// name functions by index or by mangled name, which says little to anyone reading a bar's log. The
/// cause is what WasmKit used to say.
fn describe(error: &wasmtime::Error) -> String {
    if error.downcast_ref::<WasmBacktrace>().is_none() {
        return format!("{error:#}");
    }
    if let Some(Trap::Interrupt) = error.downcast_ref::<Trap>() {
        return "ran past its deadline and was interrupted".into();
    }
    let cause = error.root_cause().to_string();
    cause.strip_prefix("wasm trap: ").unwrap_or(&cause).to_string()
}

/// WebAssembly text to a binary, with an error that says where: `line:column: message`.
fn assemble(text: &str) -> Result<Vec<u8>> {
    let located = |error: wast::Error| {
        let (line, column) = error.span().linecol_in(text);
        wasmtime::format_err!("{}:{}: {}", line + 1, column + 1, error.message())
    };
    let buffer = wast::parser::ParseBuffer::new(text).map_err(located)?;
    let mut wat = wast::parser::parse::<wast::Wat>(&buffer).map_err(located)?;
    wat.encode().map_err(located)
}

fn widen(value: &Val) -> i64 {
    match value {
        Val::I32(value) => *value as i64,
        Val::I64(value) => *value,
        _ => 0,
    }
}

fn val_type(raw: u32) -> Result<ValType> {
    match raw {
        BW_I32 => Ok(ValType::I32),
        BW_I64 => Ok(ValType::I64),
        _ => wasmtime::bail!("no such type: {raw}"),
    }
}

fn guest_range(size: usize, ptr: u32, len: u32, what: &str) -> Result<std::ops::Range<usize>> {
    let (p, l) = (ptr as usize, len as usize);
    match p.checked_add(l) {
        Some(end) if end <= size => Ok(p..end),
        _ => wasmtime::bail!("{what} of {l} bytes at {p} is past the end of a {size} byte memory"),
    }
}

fn read(memory: Option<&[u8]>, ptr: u32, out: &mut [u8]) -> Result<()> {
    let Some(data) = memory else { wasmtime::bail!("the module exports no memory") };
    let range = guest_range(data.len(), ptr, out.len() as u32, "read")?;
    out.copy_from_slice(&data[range]);
    Ok(())
}

fn write(memory: Option<&mut [u8]>, ptr: u32, bytes: &[u8]) -> Result<()> {
    let Some(data) = memory else { wasmtime::bail!("the module exports no memory") };
    let range = guest_range(data.len(), ptr, bytes.len() as u32, "write")?;
    data[range].copy_from_slice(bytes);
    Ok(())
}

// ---- engine ---------------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_engine_new(err: *mut *mut c_char) -> *mut BwEngine {
    let made = (|| -> Result<BwEngine> {
        let mut config = Config::new();
        config.target("pulley64")?;
        config.epoch_interruption(true);
        let engine = Engine::new(&config)?;
        let ticking = Arc::new(Ticking::default());
        // A tick a millisecond while a call runs: its deadline callback checks the wall clock at every
        // tick, so a budget ends within a tick of when it should whatever the ticker's jitter.
        let (epochs, calls) = (engine.clone(), ticking.clone());
        let ticker = std::thread::Builder::new()
            .name("bariowasm-epoch".into())
            .spawn(move || {
                while calls.wait_for_calls() {
                    std::thread::sleep(Duration::from_millis(1));
                    epochs.increment_epoch();
                }
            })?;
        Ok(BwEngine { engine, ticking, ticker: Some(ticker) })
    })();
    match made {
        Ok(engine) => Box::into_raw(Box::new(engine)),
        Err(error) => {
            unsafe { set_err(err, format!("{error:#}")) };
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_engine_free(engine: *mut BwEngine) {
    if engine.is_null() {
        return;
    }
    let mut engine = unsafe { Box::from_raw(engine) };
    engine.ticking.stop();
    if let Some(ticker) = engine.ticker.take() {
        let _ = ticker.join();
    }
}

// ---- module ---------------------------------------------------------------------------------------

/// WebAssembly text in, the binary out; the caller frees it with `bw_bytes_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_wat2wasm(
    text: *const u8,
    len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    err: *mut *mut c_char,
) -> i32 {
    let text = unsafe { borrowed(text, len) };
    let assembled = std::str::from_utf8(text)
        .map_err(|error| wasmtime::format_err!("not UTF-8: {error}"))
        .and_then(assemble);
    let result = assembled.map(|bytes| unsafe { put_bytes(out, out_len, bytes) });
    unsafe { report(result, err) }
}

/// A binary module, validated and compiled to Pulley bytecode.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_module_compile(
    engine: *const BwEngine,
    wasm: *const u8,
    len: usize,
    err: *mut *mut c_char,
) -> *mut BwModule {
    let engine = unsafe { &*engine };
    let bytes = unsafe { borrowed(wasm, len) };
    match Module::new(&engine.engine, bytes) {
        Ok(module) => Box::into_raw(Box::new(BwModule { module })),
        Err(error) => {
            unsafe { set_err(err, format!("{error:#}")) };
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_module_free(module: *mut BwModule) {
    if !module.is_null() {
        drop(unsafe { Box::from_raw(module) });
    }
}

// ---- instance -------------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_new(
    engine: *const BwEngine,
    module: *const BwModule,
    memory_cap: u64,
    imports: *const BwImport,
    nimports: usize,
    call: HostFn,
    ctx: *mut c_void,
    err: *mut *mut c_char,
) -> *mut BwInstance {
    let (engine, module) = unsafe { (&*engine, &*module) };
    let imports = unsafe { borrowed(imports, nimports) };
    let host = Host { call, ctx: ctx as usize };
    let made = (|| -> Result<BwInstance> {
        let mut linker = Linker::new(&engine.engine);
        for (index, import) in imports.iter().enumerate() {
            let name = unsafe { name(import.name) }?;
            let params = unsafe { borrowed(import.params, import.nparams) };
            let results = unsafe { borrowed(import.results, import.nresults) };
            let returns_i64: Vec<bool> = results.iter().map(|raw| *raw == BW_I64).collect();
            let ty = FuncType::new(
                &engine.engine,
                params.iter().map(|raw| val_type(*raw)).collect::<Result<Vec<_>>>()?,
                results.iter().map(|raw| val_type(*raw)).collect::<Result<Vec<_>>>()?,
            );
            linker.func_new(NAMESPACE, name, ty, move |mut caller, args, results| {
                host.call(index, &returns_i64, &mut caller, args, results)
            })?;
        }

        let state = HostState {
            limiter: Limiter { cap: memory_cap as usize },
            deadline: Instant::now() + START_BUDGET,
        };
        let mut store = Store::new(&engine.engine, state);
        store.limiter(|state| &mut state.limiter);
        store.set_epoch_deadline(1);
        store.epoch_deadline_callback(|context| {
            Ok(if Instant::now() >= context.data().deadline { UpdateDeadline::Interrupt } else { UpdateDeadline::Continue(1) })
        });
        // A module's start function is a call like any other.
        let _running = engine.ticking.running();
        let instance = linker.instantiate(&mut store, &module.module)?;
        let memory = instance.get_memory(&mut store, "memory");
        Ok(BwInstance { store, ticking: engine.ticking.clone(), instance, memory })
    })();
    match made {
        Ok(instance) => Box::into_raw(Box::new(instance)),
        Err(error) => {
            unsafe { set_err(err, describe(&error)) };
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_free(instance: *mut BwInstance) {
    if !instance.is_null() {
        drop(unsafe { Box::from_raw(instance) });
    }
}

/// Every call from now on, together, ends `seconds` from now: past it, the guest is interrupted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_set_deadline(instance: *mut BwInstance, seconds: f64) {
    let instance = unsafe { &mut *instance };
    instance.store.data_mut().deadline = Instant::now() + Duration::from_secs_f64(seconds.max(0.0));
}

/// Whether the instance exports a function `name`, and if so how many parameters and results it has.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_func(
    instance: *mut BwInstance,
    name: *const c_char,
    nparams: *mut usize,
    nresults: *mut usize,
) -> bool {
    let instance = unsafe { &mut *instance };
    let Ok(name) = (unsafe { self::name(name) }) else { return false };
    let Some(func) = instance.instance.get_func(&mut instance.store, name) else { return false };
    let ty = func.ty(&instance.store);
    unsafe {
        if !nparams.is_null() {
            *nparams = ty.params().len();
        }
        if !nresults.is_null() {
            *nresults = ty.results().len();
        }
    }
    true
}

/// Calls the export `name` with `args`, writing its results into `results`. `BW_DEADLINE` is the
/// deadline interrupting it, `BW_TRAP` any other way the guest failed, `BW_ERROR` a call that could not
/// be made.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_call(
    instance: *mut BwInstance,
    name: *const c_char,
    args: *const i64,
    nargs: usize,
    results: *mut i64,
    nresults: usize,
    err: *mut *mut c_char,
) -> i32 {
    let instance = unsafe { &mut *instance };
    let (args, results) = unsafe { (borrowed(args, nargs), borrowed_mut(results, nresults)) };
    let prepared = (|| -> Result<_> {
        let name = unsafe { self::name(name) }?;
        let func = instance
            .instance
            .get_func(&mut instance.store, name)
            .ok_or_else(|| wasmtime::format_err!("the module exports no `{name}`"))?;
        let ty = func.ty(&instance.store);
        if ty.params().len() != args.len() || ty.results().len() > results.len() {
            wasmtime::bail!("`{name}` is called with the wrong number of arguments or results");
        }
        let params = ty
            .params()
            .zip(args)
            .map(|(ty, value)| match ty {
                ValType::I32 => Ok(Val::I32(*value as i32)),
                ValType::I64 => Ok(Val::I64(*value)),
                other => wasmtime::bail!("`{name}` takes a {other}, and bario only passes i32 and i64"),
            })
            .collect::<Result<Vec<_>>>()?;
        let out = vec![Val::I32(0); ty.results().len()];
        Ok((func, params, out))
    })();
    let (func, params, mut out) = match prepared {
        Ok(prepared) => prepared,
        Err(error) => return unsafe { report(Err(error), err) },
    };

    instance.store.set_epoch_deadline(1);
    let running = instance.ticking.running();
    let called = func.call(&mut instance.store, &params, &mut out);
    drop(running);
    match called {
        Ok(()) => {
            for (slot, value) in results.iter_mut().zip(&out) {
                *slot = widen(value);
            }
            BW_OK
        }
        Err(error) => {
            let status = match error.downcast_ref::<Trap>() {
                Some(Trap::Interrupt) => BW_DEADLINE,
                _ => BW_TRAP,
            };
            unsafe { set_err(err, describe(&error)) };
            status
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_read(
    instance: *const BwInstance,
    ptr: u32,
    out: *mut u8,
    len: usize,
    err: *mut *mut c_char,
) -> i32 {
    let instance = unsafe { &*instance };
    let out = unsafe { borrowed_mut(out, len) };
    let memory = instance.memory.map(|memory| memory.data(&instance.store));
    unsafe { report(read(memory, ptr, out), err) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_instance_write(
    instance: *mut BwInstance,
    ptr: u32,
    bytes: *const u8,
    len: usize,
    err: *mut *mut c_char,
) -> i32 {
    let instance = unsafe { &mut *instance };
    let bytes = unsafe { borrowed(bytes, len) };
    let memory = instance.memory.map(|memory| memory.data_mut(&mut instance.store));
    unsafe { report(write(memory, ptr, bytes), err) }
}

// ---- inside a host import -----------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_caller_read(
    caller: *mut BwCaller<'_>,
    ptr: u32,
    out: *mut u8,
    len: usize,
    err: *mut *mut c_char,
) -> i32 {
    let caller = unsafe { &*caller };
    let out = unsafe { borrowed_mut(out, len) };
    unsafe { report(read(caller.memory.as_deref(), ptr, out), err) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_caller_write(
    caller: *mut BwCaller<'_>,
    ptr: u32,
    bytes: *const u8,
    len: usize,
    err: *mut *mut c_char,
) -> i32 {
    let caller = unsafe { &mut *caller };
    let bytes = unsafe { borrowed(bytes, len) };
    unsafe { report(write(caller.memory.as_deref_mut(), ptr, bytes), err) }
}

/// Why the host import failed: the guest traps with this once the import returns false.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_caller_fail(caller: *mut BwCaller<'_>, message: *const c_char) {
    let caller = unsafe { &mut *caller };
    let message = if message.is_null() { String::new() } else { unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned() };
    caller.failure = Some(message);
}

// ---- memory handed out ------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bw_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
