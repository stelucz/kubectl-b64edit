# encode.jq - reconcile an edited buffer back into a valid API object:
# re-encode changed values, restore untouched ones byte-for-byte, and pin
# back server-managed / identity fields so they can never be tampered with.
#
# Invoked as:
#   jq --slurpfile orig original.json --slurpfile pm pathmap.json \
#      -f encode.jq edited.json

def b64d_safe:
  . as $s | try ($s | @base64d) catch null;

def b64e:
  @base64;

($orig[0]) as $orig
| ($pm[0]) as $pm
| ($orig.kind) as $kind
| (if $kind == "Secret" then ["data"]
   elif $kind == "ConfigMap" then ["binaryData"]
   else null end) as $knownMapPath
| . as $edited

# Step 1: reconcile the well-known base64 map (Secret.data / ConfigMap.binaryData)
# as a whole, since keys may have been added or removed by the user.
| (if $knownMapPath == null then $edited else
    ($orig | getpath($knownMapPath) // {}) as $origMap
    | ($edited | getpath($knownMapPath) // {}) as $editedMap
    | ([$pm.keptEncoded[]? | select(.[0:1] == $knownMapPath) | .[1]]) as $keptKeys
    | ($origMap | with_entries(.value |= b64d_safe)) as $origPlainMap
    | ($editedMap
        | to_entries
        | map(
            . as $e
            | if ($keptKeys | index($e.key)) then
                $e
              elif ($origPlainMap[$e.key] != null and $origPlainMap[$e.key] == $e.value) then
                {key: $e.key, value: $origMap[$e.key]}
              else
                {key: $e.key, value: ($e.value | b64e)}
              end
          )
        | from_entries
      ) as $newMap
    | $edited | setpath($knownMapPath; $newMap)
  end) as $edited1

# Step 2: reconcile heuristically-decoded scalar paths outside the known map.
| (reduce ($pm.decoded[]? // empty) as $p (
    $edited1;
    if ($knownMapPath != null and $p[0:1] == $knownMapPath) then .
    else
      (. | getpath($p)) as $newv
      | if $newv == null or ($newv | type) != "string" then .
        else
          ($orig | getpath($p)) as $origB64
          | ($origB64 | b64d_safe) as $origPlain
          | if ($newv == $origPlain) then setpath($p; $origB64)
            else setpath($p; ($newv | b64e))
            end
        end
    end
  )) as $edited2

# Step 3: pin server-managed / identity fields back to the original values,
# regardless of what the editor buffer contained.
| $edited2
| .apiVersion = $orig.apiVersion
| .kind = $orig.kind
| .metadata.name = $orig.metadata.name
| .metadata.namespace = $orig.metadata.namespace
| .metadata.uid = $orig.metadata.uid
| .metadata.resourceVersion = $orig.metadata.resourceVersion
| (if $orig.metadata.generation then .metadata.generation = $orig.metadata.generation else . end)
| (if $orig.metadata.creationTimestamp then .metadata.creationTimestamp = $orig.metadata.creationTimestamp else . end)
| (if $orig.metadata.managedFields then .metadata.managedFields = $orig.metadata.managedFields else . end)
| (if (($orig.metadata.annotations // {}) | has("kubectl.kubernetes.io/last-applied-configuration")) then
     .metadata.annotations = ((.metadata.annotations // {}) + {
       "kubectl.kubernetes.io/last-applied-configuration":
         $orig.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]
     })
   else . end)
