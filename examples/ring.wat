;; The worked example from DESIGN.md section 9.2: a renderer module that registers a node type.
;;
;;   renderer "ring" path="~/.config/bario/renderers/ring.wat"
;;
;; From then on any module's content tree may say {"ring": {"value": 0.7}} and this draws it —
;; a track arc and a value arc, themed entirely from the outside:
;;
;;   #cpu ring { color: accent; --track: rgba(255,255,255,0.2); stroke-width: 3pt }
;;
;; `draw` is called by two stages: layout calls it with "measure":true to learn the natural
;; width, and commit calls it for the drawing, with the node's size and a frame at 0, 0 (the ops
;; are the node's own coordinates, wherever its bubble sits). Commit asks again only when the
;; payload, the style or the size changes, or when the renderer called request_frame while it
;; drew. It is written in WebAssembly text so it needs no toolchain; the same thing in Rust with
;; the PDK is a dozen lines.
(module
  (memory (export "memory") 1)
  (global $next (mut i32) (i32.const 4096))

  (func $alloc (export "alloc") (param $len i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $next))
    (global.set $next (i32.add (global.get $next) (i32.add (local.get $len) (i32.const 8))))
    (local.get $ptr))

  (func $pack (param $ptr i32) (param $len i32) (result i64)
    (i64.or (i64.shl (i64.extend_i32_u (local.get $ptr)) (i64.const 32))
            (i64.extend_i32_u (local.get $len))))

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

  ;; Decimal digits of a signed value at $dst, returning how many.
  (func $itoa (param $value i32) (param $dst i32) (result i32)
    (local $len i32) (local $scratch i32) (local $i i32) (local $sign i32) (local $magnitude i32)
    (local.set $magnitude (local.get $value))
    (if (i32.lt_s (local.get $value) (i32.const 0))
      (then
        (i32.store8 (local.get $dst) (i32.const 45))   ;; '-'
        (local.set $sign (i32.const 1))
        (local.set $magnitude (i32.sub (i32.const 0) (local.get $value)))))
    (local.set $scratch (i32.const 3072))
    (block $done
      (loop $again
        (i32.store8 (i32.add (local.get $scratch) (local.get $len))
                    (i32.add (i32.const 48) (i32.rem_u (local.get $magnitude) (i32.const 10))))
        (local.set $len (i32.add (local.get $len) (i32.const 1)))
        (local.set $magnitude (i32.div_u (local.get $magnitude) (i32.const 10)))
        (br_if $again (i32.gt_u (local.get $magnitude) (i32.const 0)))))
    (block $reversed
      (loop $again
        (br_if $reversed (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (i32.add (local.get $dst) (local.get $sign)) (local.get $i))
                    (i32.load8_u (i32.add (local.get $scratch)
                      (i32.sub (i32.sub (local.get $len) (i32.const 1)) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (i32.add (local.get $len) (local.get $sign)))

  ;; Where $needle starts inside $hay, or -1. Enough JSON parsing for one key.
  (func $find (param $hay i32) (param $hayLen i32) (param $needle i32) (param $needleLen i32)
              (result i32)
    (local $i i32) (local $j i32)
    (block $missing
      (loop $atNext
        (br_if $missing (i32.gt_s (local.get $i)
                                  (i32.sub (local.get $hayLen) (local.get $needleLen))))
        (local.set $j (i32.const 0))
        (block $mismatch
          (loop $atChar
            (br_if $mismatch
              (i32.ne (i32.load8_u (i32.add (i32.add (local.get $hay) (local.get $i)) (local.get $j)))
                      (i32.load8_u (i32.add (local.get $needle) (local.get $j)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br_if $atChar (i32.lt_u (local.get $j) (local.get $needleLen)))
            (return (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $atNext)))
    (i32.const -1))

  ;; The number after $at, as hundredths: "0.7" is 70, "1" is 100, "0.75" is 75.
  (func $hundredths (param $ptr i32) (param $at i32) (result i32)
    (local $i i32) (local $c i32) (local $whole i32) (local $frac i32) (local $digits i32)
    (local.set $i (local.get $at))
    ;; Skip anything that is not a digit: the closing quote, the colon, spaces.
    (block $atDigit
      (loop $skip
        (local.set $c (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
        (br_if $atDigit (i32.and (i32.ge_u (local.get $c) (i32.const 48))
                                 (i32.le_u (local.get $c) (i32.const 57))))
        (br_if $atDigit (i32.eq (local.get $c) (i32.const 125)))   ;; '}' — no number at all
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $skip (i32.lt_u (local.get $i) (i32.const 3000)))))
    (block $doneWhole
      (loop $again
        (local.set $c (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
        (br_if $doneWhole (i32.or (i32.lt_u (local.get $c) (i32.const 48))
                                  (i32.gt_u (local.get $c) (i32.const 57))))
        (local.set $whole (i32.add (i32.mul (local.get $whole) (i32.const 10))
                                   (i32.sub (local.get $c) (i32.const 48))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (if (i32.eq (local.get $c) (i32.const 46))                     ;; '.'
      (then
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (block $doneFrac
          (loop $again
            (br_if $doneFrac (i32.ge_u (local.get $digits) (i32.const 2)))
            (local.set $c (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
            (br_if $doneFrac (i32.or (i32.lt_u (local.get $c) (i32.const 48))
                                     (i32.gt_u (local.get $c) (i32.const 57))))
            (local.set $frac (i32.add (i32.mul (local.get $frac) (i32.const 10))
                                      (i32.sub (local.get $c) (i32.const 48))))
            (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $again)))
        (if (i32.eq (local.get $digits) (i32.const 1))
          (then (local.set $frac (i32.mul (local.get $frac) (i32.const 10)))))))
    (i32.add (i32.mul (local.get $whole) (i32.const 100)) (local.get $frac)))

  (data (i32.const 0) "\"value\"")
  (data (i32.const 8) "\"measure\":true")
  (data (i32.const 23) "{\"width\":28,\"height\":24}")
  (data (i32.const 48) "{\"ops\":[{\"stroke\":{\"color\":\"var(--track)\",\"width\":3},\"path\":[[\"arc\",14,12,9,0,360]]}")
  (data (i32.const 133) ",{\"stroke\":{\"color\":\"currentColor\",\"width\":3,\"cap\":\"round\"},\"path\":[[\"arc\",14,12,9,-90,")
  (data (i32.const 221) "]]}")
  (data (i32.const 225) "]}")

  (func (export "draw") (param $ptr i32) (param $len i32) (result i64)
    (local $out i32) (local $n i32) (local $at i32) (local $pct i32) (local $angle i32)

    ;; Measuring: the host only wants the natural size.
    (if (i32.ne (call $find (local.get $ptr) (local.get $len)
                            (i32.const 8) (i32.const 14))
                (i32.const -1))
      (then (return (call $pack (i32.const 23) (i32.const 24)))))

    (local.set $pct (i32.const 0))
    (local.set $at (call $find (local.get $ptr) (local.get $len)
                               (i32.const 0) (i32.const 7)))
    (if (i32.ne (local.get $at) (i32.const -1))
      (then (local.set $pct (call $hundredths (local.get $ptr)
                                  (i32.add (local.get $at) (i32.const 7))))))
    (if (i32.gt_s (local.get $pct) (i32.const 100)) (then (local.set $pct (i32.const 100))))

    (local.set $out (call $alloc (i32.const 512)))
    (local.set $n (call $copy (i32.const 48) (i32.const 84) (local.get $out)))

    ;; A zero-length arc is not worth drawing, and CoreGraphics agrees.
    (if (i32.gt_s (local.get $pct) (i32.const 0))
      (then
        (local.set $n (i32.add (local.get $n)
          (call $copy (i32.const 133) (i32.const 87)
                      (i32.add (local.get $out) (local.get $n)))))
        ;; -90 degrees is the top; a full turn is 360.
        (local.set $angle (i32.add (i32.const -90)
          (i32.div_s (i32.mul (local.get $pct) (i32.const 360)) (i32.const 100))))
        (local.set $n (i32.add (local.get $n)
          (call $itoa (local.get $angle) (i32.add (local.get $out) (local.get $n)))))
        (local.set $n (i32.add (local.get $n)
          (call $copy (i32.const 221) (i32.const 3)
                      (i32.add (local.get $out) (local.get $n)))))))

    (local.set $n (i32.add (local.get $n)
      (call $copy (i32.const 225) (i32.const 2)
                  (i32.add (local.get $out) (local.get $n)))))
    (call $pack (local.get $out) (local.get $n)))
)
