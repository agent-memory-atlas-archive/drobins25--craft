#!/bin/bash
# test-annotate-resolve.sh - Pin to source: annotate-resolve.sh turns the rules
# the page reports and the pin's component name into an honest location. A
# location is only ever recorded when the rule's selector text is found
# literally in a project file; everything else says which answer it got.
# Fixture roots live in a temp dir; no listener is needed.
# Usage: bash tests/test-annotate-resolve.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

RESOLVE="$SCRIPTS_DIR/annotate-resolve.sh"
SID="s1"
PAGE="http://localhost:5173/"
OUTSIDE="That page is outside this project, so there's no source file to point at."

TMP_ROOTS=()
cleanup() {
  local r
  for r in "${TMP_ROOTS[@]:-}"; do
    [ -n "$r" ] && rm -rf "$r"
  done
  return 0
}
trap cleanup EXIT

# new_root - a project with a stylesheet, a component, a map index and one live run
new_root() {
  NEW_ROOT="$(mktemp -d)"
  TMP_ROOTS+=("$NEW_ROOT")
  local r="$NEW_ROOT"
  mkdir -p "$r/src/styles" "$r/src/components" "$r/.craft/map" "$r/.craft/annotations/$SID"
  printf '/* toolbar */\n.toolbar { display: flex; }\n.toolbar .save { padding: 4px; }\n.card .title { color: red; }\n' > "$r/src/styles/toolbar.css"
  printf 'import x from "y";\nexport function SaveButton() {\n  return null;\n}\n' > "$r/src/components/SaveButton.jsx"
  write_index "$r" 2
  printf '{"start_seq": 0, "subject": "t", "started_at": "2026-10-04T10:00:00Z"}\n' > "$r/.craft/annotations/$SID/run.json"
  write_current "$r" "$PAGE"
}

write_index() {
  printf '{"version": %s, "areas": {"src": {"files": {"src/components/SaveButton.jsx": {"anchors": [{"anchor": "src/components/SaveButton.jsx#SaveButton", "startLine": 2}]}}}}}\n' "$2" > "$1/.craft/map/index.json"
}

# write_current <root> <page> [component] - one pin, ts 111, selector .toolbar > button.save
write_current() {
  python3 - "$1" "$2" "${3-SaveButton}" <<'PYEOF'
import json, sys
root, page, component = sys.argv[1:4]
pin = {"ts": 111, "page": page, "selector": ".toolbar > button.save", "nearText": "Save", "component": component or None, "text": "bigger"}
with open(root + "/.craft/annotations/s1/current.json", "w") as h:
    json.dump({"seq": 1, "cleared": False, "pins": [pin]}, h)
PYEOF
}

# item <href> <devId|-> <selector-of-rule> [component] - one probe item for pin 111
item() {
  python3 - "$1" "$2" "$3" "${4-SaveButton}" "${5-}" <<'PYEOF'
import json, sys
href, dev, rule, component, blocked = sys.argv[1:6]
item = {
    "page": "http://localhost:5173/", "ts": 111, "selector": ".toolbar > button.save",
    "found": True, "component": component or None, "inline": False,
    "blocked": [blocked] if blocked else [],
    "rules": [{"selector": rule, "href": None if href == "-" else href, "devId": None if dev == "-" else dev, "order": 3, "matches": 1}],
}
print(json.dumps([item]))
PYEOF
}

resolve_in() { local root="$1"; shift; bash "$RESOLVE" resolve --root "$root" --session "$SID" "$@" 2>&1; }
where_in() { bash "$RESOLVE" where --root "$1" --session "$SID" --ts "$2" 2>&1; }

# pyget <json> <expr over d> - evaluates a python expression against the parsed json
pyget() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

begin_test "a bundle stylesheet is never reported as a source location"
new_root; R="$NEW_ROOT"
OUT="$(item "http://localhost:5173/assets/index-abc.css" - ".ghost" | resolve_in "$R")"
assert_eq "no rule file" "None" "$(pyget "$OUT" 'd["111"]["rule_file"]')"
assert_eq "no rule line" "None" "$(pyget "$OUT" 'd["111"]["rule_line"]')"
assert_eq "no rule route" "None" "$(pyget "$OUT" 'd["111"]["rule_via"]')"
assert_eq "the rule text is kept" ".ghost" "$(pyget "$OUT" 'd["111"]["rule"]')"
assert_eq "the bundle is named" "True" "$(pyget "$OUT" '"unresolved: bundle" in d["111"]["notes"]')"

begin_test "a dev-server stylesheet resolves to file and line"
new_root; R="$NEW_ROOT"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css?t=99" - ".toolbar .save" | resolve_in "$R")"
assert_eq "rule file" "src/styles/toolbar.css" "$(pyget "$OUT" 'd["111"]["rule_file"]')"
assert_eq "rule line" "3" "$(pyget "$OUT" 'd["111"]["rule_line"]')"
assert_eq "rule route" "stylesheet" "$(pyget "$OUT" 'd["111"]["rule_via"]')"
assert_eq "no notes on a clean hit" "[]" "$(pyget "$OUT" 'd["111"]["notes"]')"
assert_eq "rule matches carried" "1" "$(pyget "$OUT" 'd["111"]["rule_matches"]')"

begin_test "a Vite style element resolves through its dev id"
new_root; R="$NEW_ROOT"
OUT="$(item - "$R/src/styles/toolbar.css" ".toolbar .save" | resolve_in "$R")"
assert_eq "rule file via dev id" "src/styles/toolbar.css" "$(pyget "$OUT" 'd["111"]["rule_file"]')"
assert_eq "rule line via dev id" "3" "$(pyget "$OUT" 'd["111"]["rule_line"]')"
OUT="$(item - "/elsewhere/other.css" ".toolbar .save" | resolve_in "$R")"
assert_eq "a dev id outside the root is unmapped, then found by class name" "class-search" "$(pyget "$OUT" 'd["111"]["rule_via"]')"
OUT="$(item - - ".toolbar .save" | resolve_in "$R")"
assert_eq "a style element with no href and no dev id records no rule" "True" "$(pyget "$OUT" '"no rule" in d["111"]["notes"] and d["111"]["rule_file"] is None')"

begin_test "a bundle with a unique class-search hit is labelled class-search and unresolved: bundle"
new_root; R="$NEW_ROOT"
OUT="$(item "http://localhost:5173/assets/index-abc.css" - ".card .title" | resolve_in "$R")"
assert_eq "found by class name" "class-search" "$(pyget "$OUT" 'd["111"]["rule_via"]')"
assert_eq "the file" "src/styles/toolbar.css" "$(pyget "$OUT" 'd["111"]["rule_file"]')"
assert_eq "the line" "4" "$(pyget "$OUT" 'd["111"]["rule_line"]')"
assert_eq "still labelled a bundle" "True" "$(pyget "$OUT" '"unresolved: bundle" in d["111"]["notes"]')"
printf '.card .title { margin: 0; }\n' > "$R/src/styles/other.css"
R2="$(mktemp -d)"; TMP_ROOTS+=("$R2")
cp -R "$R/." "$R2/"
OUT="$(item "http://localhost:5173/assets/index-abc.css" - ".card .title" | resolve_in "$R2")"
assert_eq "two files with the text is no location" "None" "$(pyget "$OUT" 'd["111"]["rule_file"]')"

begin_test "a mapped file without the selector text records no rule"
new_root; R="$NEW_ROOT"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".nowhere .at-all" | resolve_in "$R")"
assert_eq "no rule recorded" "True" "$(pyget "$OUT" '"no rule" in d["111"]["notes"] and d["111"]["rule_file"] is None and d["111"]["rule_via"] is None')"
assert_eq "a different selector sharing a prefix is not a hit" "True" "$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .sav" | resolve_in "$R" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["111"]["rule_file"] is None)')"

begin_test "the winning rule is the most specific candidate"
new_root; R="$NEW_ROOT"
OUT="$(python3 - <<'PYEOF' | resolve_in "$R"
import json
rules = [
    {"selector": ".card .title", "href": "http://localhost:5173/src/styles/toolbar.css", "devId": None, "order": 1, "matches": 1},
    {"selector": ".toolbar .save", "href": "http://localhost:5173/src/styles/toolbar.css", "devId": None, "order": 2, "matches": 1},
    {"selector": "button", "href": "http://localhost:5173/src/styles/toolbar.css", "devId": None, "order": 9, "matches": 40},
]
print(json.dumps([{"page": "http://localhost:5173/", "ts": 111, "selector": ".toolbar > button.save", "found": True, "component": "SaveButton", "inline": False, "blocked": [], "rules": rules}]))
PYEOF
)"
assert_eq "two classes beat one class and a bare type" ".toolbar .save" "$(pyget "$OUT" 'd["111"]["rule"]')"

begin_test "no candidate rule records no rule, or a bundle when a sheet was blocked"
new_root; R="$NEW_ROOT"
OUT="$(printf '[{"page":"http://localhost:5173/","ts":111,"selector":".toolbar > button.save","found":true,"component":"SaveButton","inline":false,"blocked":[],"rules":[{"selector":"button","href":null,"devId":null,"order":1,"matches":9}]}]' | resolve_in "$R")"
assert_eq "no rule" "True" "$(pyget "$OUT" 'd["111"]["notes"] == ["no rule"]')"
OUT="$(printf '[{"page":"http://localhost:5173/","ts":111,"selector":".toolbar > button.save","found":true,"component":"SaveButton","inline":false,"blocked":["https://cdn.example/x.css"],"rules":[]}]' | resolve_in "$R")"
assert_eq "a blocked sheet means bundle" "True" "$(pyget "$OUT" '"unresolved: bundle" in d["111"]["notes"] and "no rule" not in d["111"]["notes"]')"

begin_test "the component resolves through the map index"
new_root; R="$NEW_ROOT"
# the map says the component lives in a file grep would never find
mkdir -p "$R/lib"; printf 'nothing here\n' > "$R/lib/Mapped.jsx"
printf '{"version": 2, "areas": {"lib": {"files": {"lib/Mapped.jsx": {"anchors": [{"anchor": "lib/Mapped.jsx#SaveButton", "startLine": 7}]}}}}}\n' > "$R/.craft/map/index.json"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" | resolve_in "$R")"
assert_eq "component file from the index" "lib/Mapped.jsx" "$(pyget "$OUT" 'd["111"]["component_file"]')"
assert_eq "component line from the index" "7" "$(pyget "$OUT" 'd["111"]["component_line"]')"
assert_eq "route is map" "map" "$(pyget "$OUT" 'd["111"]["component_via"]')"

begin_test "the component resolves through grep when the index is absent"
new_root; R="$NEW_ROOT"; rm "$R/.craft/map/index.json"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" | resolve_in "$R")"
assert_eq "component file by grep" "src/components/SaveButton.jsx" "$(pyget "$OUT" 'd["111"]["component_file"]')"
assert_eq "component line by grep" "2" "$(pyget "$OUT" 'd["111"]["component_line"]')"
assert_eq "route is grep" "grep" "$(pyget "$OUT" 'd["111"]["component_via"]')"

begin_test "an other-version index is ignored"
new_root; R="$NEW_ROOT"
printf '{"version": 3, "areas": {"lib": {"files": {"lib/Wrong.jsx": {"anchors": [{"anchor": "lib/Wrong.jsx#SaveButton", "startLine": 7}]}}}}}\n' > "$R/.craft/map/index.json"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" | resolve_in "$R")"
assert_eq "grep answered instead" "grep" "$(pyget "$OUT" 'd["111"]["component_via"]')"
assert_eq "the real file" "src/components/SaveButton.jsx" "$(pyget "$OUT" 'd["111"]["component_file"]')"

begin_test "an unknown or ambiguous component is said, not guessed"
new_root; R="$NEW_ROOT"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" "Ghostly" | resolve_in "$R")"
assert_eq "not found" "True" "$(pyget "$OUT" '"component not found" in d["111"]["notes"] and d["111"]["component_file"] is None')"
printf 'export function SaveButton() {}\n' > "$R/src/components/Dup.tsx"
rm "$R/.craft/map/index.json"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" | resolve_in "$R")"
assert_eq "ambiguous across two files" "True" "$(pyget "$OUT" '"component ambiguous" in d["111"]["notes"] and d["111"]["component_file"] is None')"

begin_test "a two-character component name records no component name"
new_root; R="$NEW_ROOT"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" "Ab" | resolve_in "$R")"
assert_eq "component null" "None" "$(pyget "$OUT" 'd["111"]["component"]')"
assert_eq "note says so" "True" "$(pyget "$OUT" '"no component name" in d["111"]["notes"]')"
OUT="$(item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" "" | resolve_in "$R")"
assert_eq "a missing name says so too" "True" "$(pyget "$OUT" '"no component name" in d["111"]["notes"] and d["111"]["component_via"] is None')"

begin_test "external pins print no probe"
new_root; R="$NEW_ROOT"; write_current "$R" "https://example.com/"
OUT="$(bash "$RESOLVE" probe --root "$R" --session "$SID" 2>&1)"
assert_eq "nothing is printed" "" "$OUT"
OUT="$(printf '[]' | resolve_in "$R")"
assert_eq "resolve maps no external pin" "{}" "$OUT"

begin_test "a project pin prints one function line and writes nothing"
new_root; R="$NEW_ROOT"
OUT="$(bash "$RESOLVE" probe --root "$R" --session "$SID" 2>&1)"
assert_eq "one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_contains_literal "it is a function" "() =>" "$OUT"
assert_contains_literal "it asks the overlay for the component" "__craftAnnotateComponentOf" "$OUT"
assert_contains_literal "it names the pin's selector" ".toolbar > button.save" "$OUT"
assert_contains_literal "it reads the sheets" "styleSheets" "$OUT"
assert_file_not_exists "no cache is written by probe" "$R/.craft/annotations/$SID/resolutions.json"

begin_test "a cached target is not probed again; a stale-run cache is ignored"
new_root; R="$NEW_ROOT"
item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" | resolve_in "$R" > /dev/null
assert_file_exists "the cache is written" "$R/.craft/annotations/$SID/resolutions.json"
assert_eq "the cache names the run" "0@2026-10-04T10:00:00Z" "$(pyget "$(cat "$R/.craft/annotations/$SID/resolutions.json")" 'd["run"]')"
OUT="$(bash "$RESOLVE" probe --root "$R" --session "$SID" 2>&1)"
assert_eq "a cached target prints no probe" "" "$OUT"
printf '{"start_seq": 4, "subject": "t", "started_at": "2026-10-04T11:00:00Z"}\n' > "$R/.craft/annotations/$SID/run.json"
OUT="$(bash "$RESOLVE" probe --root "$R" --session "$SID" 2>&1)"
assert_contains_literal "a new run probes again" "() =>" "$OUT"

begin_test "an ancestor target maps the pin to the ancestor's resolution"
new_root; R="$NEW_ROOT"
OUT="$(bash "$RESOLVE" probe --root "$R" --session "$SID" --target "111=.card" 2>&1)"
assert_contains_literal "the probe aims at the ancestor" '".card"' "$OUT"
OUT="$(python3 -c '
import json
print(json.dumps([{"page": "http://localhost:5173/", "ts": 111, "selector": ".card", "found": True, "component": "SaveButton", "inline": False, "blocked": [], "rules": [{"selector": ".card .title", "href": "http://localhost:5173/src/styles/toolbar.css", "devId": None, "order": 1, "matches": 1}]}]))
' | resolve_in "$R" --target "111=.card")"
assert_eq "the pin carries the ancestor's rule" ".card .title" "$(pyget "$OUT" 'd["111"]["rule"]')"
assert_contains_literal "where reads the ancestor's resolution" ".card .title in src/styles/toolbar.css:4" "$(where_in "$R" 111)"

begin_test "a not-found element is not cached"
new_root; R="$NEW_ROOT"
OUT="$(printf '[{"page":"http://localhost:5173/","ts":111,"selector":".toolbar > button.save","found":false,"component":null,"inline":false,"blocked":[],"rules":[]}]' | resolve_in "$R")"
assert_eq "the pin maps to null" "None" "$(pyget "$OUT" 'd["111"]')"
OUT="$(bash "$RESOLVE" probe --root "$R" --session "$SID" 2>&1)"
assert_contains_literal "so it is probed again" "() =>" "$OUT"

begin_test "where prints one line for a resolved pin"
new_root; R="$NEW_ROOT"
item "http://localhost:5173/src/styles/toolbar.css" - ".toolbar .save" | resolve_in "$R" > /dev/null
LINE="$(where_in "$R" 111)"
assert_eq "exactly one line" "1" "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')"
assert_eq "component and rule" "SaveButton in src/components/SaveButton.jsx:2; rule .toolbar .save in src/styles/toolbar.css:3" "$LINE"

begin_test "where words every other answer plainly"
new_root; R="$NEW_ROOT"
assert_eq "an unresolved pin" "not resolved - the element was not on the page when it was sent" "$(where_in "$R" 111)"
item "http://localhost:5173/assets/index-abc.css" - ".card .title" "Ghostly" | resolve_in "$R" > /dev/null
assert_eq "class-search and a missing component" "Ghostly (not found in this project); rule .card .title in src/styles/toolbar.css:4 (found by class name - the browser reported a built bundle)" "$(where_in "$R" 111)"
new_root; R="$NEW_ROOT"
item "http://localhost:5173/assets/index-abc.css" - ".ghost" "Ab" | resolve_in "$R" > /dev/null
assert_eq "a bundle and no component name" "no component name; rule .ghost comes from a built bundle - no source file found" "$(where_in "$R" 111)"
new_root; R="$NEW_ROOT"
printf '[{"page":"http://localhost:5173/","ts":111,"selector":".toolbar > button.save","found":true,"component":"SaveButton","inline":true,"blocked":[],"rules":[]}]' | resolve_in "$R" > /dev/null
assert_eq "no rule" "SaveButton in src/components/SaveButton.jsx:2; no stylesheet rule - the change belongs in the component" "$(where_in "$R" 111)"

begin_test "where on a blocked sheet with no rule uses the plural wording"
new_root; R="$NEW_ROOT"
printf '[{"page":"http://localhost:5173/","ts":111,"selector":".toolbar > button.save","found":true,"component":"SaveButton","inline":false,"blocked":["https://cdn.example/x.css"],"rules":[]}]' | resolve_in "$R" > /dev/null
assert_eq "plural subject, plural verb" "SaveButton in src/components/SaveButton.jsx:2; the matching rules come from a built bundle - no source file found" "$(where_in "$R" 111)"

begin_test "where on an external pin says the page is outside the project"
new_root; R="$NEW_ROOT"; write_current "$R" "https://example.com/"
LINE="$(where_in "$R" 111)"
assert_eq "the one outside line" "$OUTSIDE" "$LINE"
assert_not_contains "never the unresolved wording" "not resolved" "$LINE"
rm -f "$R/.craft/annotations/$SID/resolutions.json"
assert_eq "it reads no cache" "$OUTSIDE" "$(where_in "$R" 111)"

begin_test "bad input fails with a usage message"
new_root; R="$NEW_ROOT"
OUT="$(bash "$RESOLVE" resolve --root "$R" 2>&1 < /dev/null || true)"
assert_contains_literal "a session is required" "--session" "$OUT"
OUT="$(bash "$RESOLVE" nonsense --root "$R" --session "$SID" 2>&1 < /dev/null || true)"
assert_contains_literal "unknown verb refused" "usage" "$OUT"
OUT="$(printf 'not json' | resolve_in "$R")"
assert_eq "garbage on stdin maps nothing" "{}" "$OUT"

finish_tests "test-annotate-resolve"
