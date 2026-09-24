# emira's names guide as a bario content tree: one snapshot from `emira watch` in, one line out.
#
#   item "names" module="exec" interval="watch" {
#     command "emira watch | jq -c --unbuffered --argjson max 7 -f ~/.config/bario/emira/names.jq"
#   }
#
# One cell per column on the focused display, named after its largest window, with a superscript
# count when it holds more than one; the focused cell has the class `focused`. A bario item is the
# same on every bar, so the row follows focus rather than the display it is drawn on.
#
# `--argjson max N` keeps the N columns nearest focus and puts … where the others were. Without it,
# every column is named. An empty workspace is one cell with its address, and the class `empty`.

def superscript: tostring | explode | map([8304, 185, 178, 179, 8308, 8309, 8310, 8311, 8312, 8313][. - 48]) | implode;

def cell: {
  row: {children: ([{text: .app, class: "app"}]
                   + if (.windows | length) > 1 then [{text: (.windows | length | superscript), class: "count"}]
                     else [] end)},
  class: (["column"] + if .focused then ["focused"] else [] end)
};

def more: {text: "…", class: "more"};

(first(.displays[] | select(.focused)) // {columns: [], workspace: "", layout: "strip"}) as $display
| $display.columns as $columns
| ($columns | length) as $count
| ($ARGS.named.max // 0) as $limit
| (first($columns | to_entries[] | select(.value.focused) | .key) // 0) as $focus
| (if $limit > 0 and $count > $limit
   then [[$focus - ($limit / 2 | floor), 0] | max, $count - $limit] | min
   else 0 end) as $start
| (if $limit > 0 and $count > $limit then $limit else $count end) as $shown
| {
    content: (if $count == 0
              then {text: $display.workspace, class: "empty"}
              else {row: {children: ([if $start > 0 then more else empty end]
                                     + [$columns[$start:$start + $shown][] | cell]
                                     + [if $start + $shown < $count then more else empty end])},
                    class: "names"}
              end),
    class: $display.layout
  }
