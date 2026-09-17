# summary.jq - print a key-name-only change summary (never prints values,
# since values may be secret material).
#
# Invoked as: jq -r --slurpfile orig original.json -f summary.jq final.json

($orig[0]) as $orig
| ($orig.kind) as $kind
| (if $kind == "Secret" then ["data"]
   elif $kind == "ConfigMap" then ["binaryData"]
   else null end) as $mapPath
| . as $final
| (if $mapPath == null then {} else ($orig | getpath($mapPath) // {}) end) as $om
| (if $mapPath == null then {} else ($final | getpath($mapPath) // {}) end) as $fm
| (($om | keys) - ($fm | keys)) as $removed
| (($fm | keys) - ($om | keys)) as $added
| (($om | keys) - $removed) as $common
| ($common | map(select($om[.] != $fm[.]))) as $modified
| (if $mapPath == null then $orig else ($orig | delpaths([$mapPath])) end) as $o2
| (if $mapPath == null then $final else ($final | delpaths([$mapPath])) end) as $f2
| (
    ($added[] | "  + " + . + "  (added)"),
    ($removed[] | "  - " + . + "  (removed)"),
    ($modified[] | "  ~ " + . + "  (modified)"),
    (if $o2 != $f2 then
       "  ! other fields outside " + (($mapPath // ["spec/metadata"]) | join(".")) + " changed too"
     else empty end)
  )
