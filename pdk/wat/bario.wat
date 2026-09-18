;; The bario ABI in WebAssembly text: paste this into your module.
;;
;; bario loads a .wat file directly — the engine sniffs the first four bytes and assembles
;; anything that is not a binary — so a module written this way needs no toolchain at all.
;;
;; What this gives you:
;;   $alloc(len) -> ptr        exported; the host calls it to hand you bytes
;;   $pack(ptr, len) -> i64    what every export returns; 0 means nothing to say
;;   $copy(src, len, dst)      the one string operation JSON needs
;;   $itoa(value, dst) -> len  the other one
;;
;; Your module then exports `render`, and optionally `init`, `poll` and `on_event`, each
;; taking (ptr: i32, len: i32) of JSON and returning a packed pair.
;;
;; Import whatever host functions you need before this block — WebAssembly requires every
;; import to precede every other module field:
;;
;;   (import "bario" "log" (func $log (param i32 i32 i32)))
;;   (import "bario" "set" (func $set (param i32 i32)))
;;   (import "bario" "set_timer" (func $set_timer (param i32) (result i32)))
;;
;; See examples/counter.wat for a complete module.

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
