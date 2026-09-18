;; A bario module with no toolchain at all: WebAssembly text, loaded as-is.
;;
;;   item "ticks" module="wasm" path="~/.config/bario/modules/counter.wat" interval="1s"
;;
;; It counts its own polls, writes the count into the state store, asks to be polled again a
;; second later, and renders a timer icon beside the number. Between them those four exports
;; are the whole module lifecycle from DESIGN.md section 5.
(module
  (import "bario" "log" (func $log (param i32 i32 i32)))
  (import "bario" "set_timer" (func $set_timer (param i32) (result i32)))

  ;; --- the bario ABI, the same thirty lines in any language --------------
  (memory (export "memory") 1)
  (global $next (mut i32) (i32.const 4096))   ;; the bump allocator starts past the data

  ;; The host calls this to get a buffer it can write bytes into.
  (func $alloc (export "alloc") (param $len i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $next))
    (global.set $next (i32.add (global.get $next) (i32.add (local.get $len) (i32.const 8))))
    (local.get $ptr))

  ;; (ptr, len) packed into one i64: high 32 bits the pointer, low 32 the length.
  (func $pack (param $ptr i32) (param $len i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (local.get $ptr)) (i64.const 32))
      (i64.extend_i32_u (local.get $len))))

  ;; Copy $len bytes from $src to $dst, and answer with $len so calls chain.
  (func $copy (param $src i32) (param $len i32) (param $dst i32) (result i32)
    (local $i i32)
    (block $done
      (loop $again
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $dst) (local.get $i))
                    (i32.load8_u (i32.add (local.get $src) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (local.get $len))

  ;; Decimal digits of $value at $dst, returning how many. Everything a module needs to put
  ;; a number in a string, which JSON always wants.
  (func $itoa (param $value i32) (param $dst i32) (result i32)
    (local $len i32) (local $scratch i32) (local $i i32)
    (local.set $scratch (i32.const 3072))
    (block $done
      (loop $again
        (i32.store8 (i32.add (local.get $scratch) (local.get $len))
                    (i32.add (i32.const 48) (i32.rem_u (local.get $value) (i32.const 10))))
        (local.set $len (i32.add (local.get $len) (i32.const 1)))
        (local.set $value (i32.div_u (local.get $value) (i32.const 10)))
        (br_if $again (i32.gt_u (local.get $value) (i32.const 0)))))
    (block $reversed
      (loop $again
        (br_if $reversed (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $dst) (local.get $i))
                    (i32.load8_u (i32.add (local.get $scratch)
                      (i32.sub (i32.sub (local.get $len) (i32.const 1)) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (local.get $len))

  ;; --- this module ------------------------------------------------------
  (data (i32.const 0) "counter ready")   ;; ready, 13 bytes
  (data (i32.const 14) "{\"content\":{\"row\":{\"gap\":4,\"align\":\"center\",\"children\":[{\"icon\":\"timer\",\"class\":\"icon\"},{\"text\":\"")   ;; prefix, 97 bytes
  (data (i32.const 112) "\",\"class\":\"count\"}]}}}")   ;; suffix, 22 bytes
  (data (i32.const 135) "{\"ticks\":")   ;; tick_prefix, 9 bytes
  (data (i32.const 145) "}")   ;; tick_suffix, 1 bytes
  (global $ticks (mut i32) (i32.const 0))

  (func (export "init") (param i32 i32)
    (call $log (i32.const 1) (i32.const 0) (i32.const 13)))

  (func (export "poll") (param i32 i32) (result i64)
    (local $out i32) (local $n i32)
    (global.set $ticks (i32.add (global.get $ticks) (i32.const 1)))
    (local.set $out (call $alloc (i32.const 64)))
    (local.set $n (call $copy (i32.const 135) (i32.const 9) (local.get $out)))
    (local.set $n (i32.add (local.get $n)
      (call $itoa (global.get $ticks) (i32.add (local.get $out) (local.get $n)))))
    (local.set $n (i32.add (local.get $n)
      (call $copy (i32.const 145) (i32.const 1)
                  (i32.add (local.get $out) (local.get $n)))))
    (drop (call $set_timer (i32.const 1000)))
    (call $pack (local.get $out) (local.get $n)))

  (func (export "render") (param i32 i32) (result i64)
    (local $out i32) (local $n i32)
    (local.set $out (call $alloc (i32.const 256)))
    (local.set $n (call $copy (i32.const 14) (i32.const 97) (local.get $out)))
    (local.set $n (i32.add (local.get $n)
      (call $itoa (global.get $ticks) (i32.add (local.get $out) (local.get $n)))))
    (local.set $n (i32.add (local.get $n)
      (call $copy (i32.const 112) (i32.const 22)
                  (i32.add (local.get $out) (local.get $n)))))
    (call $pack (local.get $out) (local.get $n)))
)
