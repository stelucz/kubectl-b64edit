# decode.jq - build an editable buffer from a fetched Kubernetes resource,
# inlining base64 values as plaintext and recording which paths were touched.
#
# Invoked as:
#   jq --argjson minlen <n> --argjson only_known <true|false> \
#      -f decode.jq original.json
#
# Output: { buffer: <doc with decoded values>, decoded: [path...], keptEncoded: [path...] }
# Paths are jq path arrays (e.g. ["data","tls.crt"]).

def b64d_safe:
  . as $s | try ($s | @base64d) catch null;

def b64e_safe($plain):
  try ($plain | @base64) catch null;

# Strict base64 charset/length/padding check before we even try decoding.
def looks_like_b64($minlen):
  (type == "string")
  and (length >= $minlen)
  and (length % 4 == 0)
  and (test("^[A-Za-z0-9+/]+={0,2}$"));

# Reject decoded content that is binary/non-text (keeps gzip/binary blobs encoded).
def is_printable_text:
  (test("[\u0000-\u0008\u000B\u000C\u000E-\u001F]") | not);

# A value only round-trips cleanly if re-encoding the decoded text reproduces
# the exact original string (kills non-canonical padding / stray whitespace).
def roundtrips($orig):
  . as $decoded
  | (b64e_safe($decoded)) as $re
  | ($re != null) and ($re == $orig);

def is_known_map_path($kind; $p):
  ($kind == "Secret" and $p[0:1] == ["data"] and ($p | length) == 2)
  or ($kind == "ConfigMap" and $p[0:1] == ["binaryData"] and ($p | length) == 2);

(. 
  | del(.metadata.managedFields)
  | (if .metadata.annotations then
       .metadata.annotations |= del(."kubectl.kubernetes.io/last-applied-configuration")
     else . end)
) as $root
| ($root.kind) as $kind
| [$root | paths(scalars)] as $allpaths
| reduce $allpaths[] as $p (
    {buffer: $root, decoded: [], keptEncoded: []};
    . as $acc
    | ($root | getpath($p)) as $v
    | if ($v | type) != "string" then $acc
      elif is_known_map_path($kind; $p) then
        ($v | b64d_safe) as $dec
        | if ($dec != null) and ($dec | roundtrips($v)) and ($dec | is_printable_text) then
            $acc
            | .buffer |= setpath($p; $dec)
            | .decoded |= (. + [$p])
          else
            $acc | .keptEncoded |= (. + [$p])
          end
      elif ($only_known | not) and ($v | looks_like_b64($minlen)) then
        ($v | b64d_safe) as $dec
        | if ($dec != null) and ($dec | roundtrips($v)) and ($dec | is_printable_text) then
            $acc
            | .buffer |= setpath($p; $dec)
            | .decoded |= (. + [$p])
          else
            $acc
          end
      else
        $acc
      end
  )
