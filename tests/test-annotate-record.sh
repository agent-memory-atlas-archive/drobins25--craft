#!/bin/bash
# test-annotate-record.sh - Coverage for hooks/scripts/annotate-record.sh: filing a
# dated annotate record from a run's history and sheet, graduating it, the
# orphan filing done by annotate-run.sh begin and sweep, and the session-start
# line that counts open records. Live session folders are fabricated on disk,
# so no listener runs here.
# Usage: bash tests/test-annotate-record.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
set +e

REC="$SCRIPTS_DIR/annotate-record.sh"
RUN="$SCRIPTS_DIR/annotate-run.sh"
SESSION_SCRIPT="$SCRIPTS_DIR/session-start.sh"
TODAY="$(date +%Y-%m-%d)"

TMP_ROOTS=()
cleanup() {
  local r
  for r in "${TMP_ROOTS[@]:-}"; do [ -n "$r" ] && rm -rf "$r"; done
  return 0
}
trap cleanup EXIT

new_root() {
  NEW_ROOT="$(mktemp -d)"
  TMP_ROOTS+=("$NEW_ROOT")
  mkdir -p "$NEW_ROOT/.craft"
}

# live <root> <id> <start_seq> <subject> - fabricates a live run folder
live() {
  LIVE="$1/.craft/annotations/$2"
  mkdir -p "$LIVE"
  printf '{"start_seq": %s, "subject": "%s", "started_at": "2026-10-04T10:00:00Z"}\n' "$3" "$4" > "$LIVE/run.json"
  : > "$LIVE/session.css"
}

# hist <live-dir> <json-line> - appends one history line
hist() { printf '%s\n' "$2" >> "$1/history.jsonl"; }

# file_rec <root> <id> <outcome> [extra args] - runs the filer, sets OUT and RC
file_rec() {
  local root="$1" id="$2" outcome="$3"; shift 3
  OUT="$(CRAFT_PROJECT_ROOT="$root" bash "$REC" file --session "$id" --outcome "$outcome" "$@" 2>/dev/null)"
  RC=$?
}

rd() { cat "$1" 2>/dev/null || echo MISSING; }

fm() { # <file> <key>
  awk -v k="$2" 'BEGIN{n=0} /^---$/{n++; next} n==1 && index($0, k ":")==1 {sub("^" k ": *", ""); print; exit}' "$1"
}

pins_json() { # <record.md> <python expr over p (list)>
  python3 - "$1" "$2" <<'PYEOF'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
body = re.search(r"## Pin Data\s*```json\n(.*?)\n```", text, re.S).group(1)
p = json.loads(body)
print(eval(sys.argv[2]))
PYEOF
}

S1='{"seq":1,"pins":[{"n":1,"text":"a","x":1,"y":2,"selector":"div.a","nearText":"near a","ts":1,"page":"http://x/p","box":{"x":1,"y":2,"width":3,"height":4},"component":"Hero","candidate":"c1"}],"sent_at":"2026-10-04T10:01:00Z"}'
S2='{"seq":2,"pins":[{"n":1,"text":"a2","x":1,"y":2,"selector":"div.a","nearText":"near a","ts":1,"page":"http://x/p"},{"n":2,"text":"b","x":5,"y":6,"selector":"div.b","nearText":"near b","ts":2,"page":"http://x/p"}],"sent_at":"2026-10-04T10:02:00Z"}'

begin_test "file assembles one pin per (page, ts) with the last text, in first-appearance order"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "hero polish"
hist "$LIVE" "$S1"; hist "$LIVE" "$S2"
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "it prints the record path" "$ROOT/.craft/annotations/$TODAY-hero-polish/record.md" "$OUT"
assert_eq "two pins, not three" "2" "$(pins_json "$OUT" 'len(p)')"
assert_eq "pin 1 carries the last text" "a2" "$(pins_json "$OUT" 'p[0]["text"]')"
assert_eq "pin 1 carries the last seq" "2" "$(pins_json "$OUT" 'p[0]["seq"]')"
assert_eq "pin 1 carries the last sent_at" "2026-10-04T10:02:00Z" "$(pins_json "$OUT" 'p[0]["sent_at"]')"
assert_eq "pin 2 is the new pin" "b" "$(pins_json "$OUT" 'p[1]["text"]')"
assert_eq "n is the record ordinal" "1,2" "$(pins_json "$OUT" '",".join(str(x["n"]) for x in p)')"
assert_eq "absent fields are null" "None" "$(pins_json "$OUT" 'p[0]["candidate"]')"
assert_eq "every record pin key is present" "True" "$(pins_json "$OUT" 'all(set(x) == {"n","seq","sent_at","text","selector","nearText","candidate","page","box","component","ts","x","y","resolved"} for x in p)')"
assert_contains "the reading list quotes the text verbatim" '^1\. "a2"' "$(rd "$OUT")"

begin_test "a filed pin carries the resolution the run cached"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "resolved run"
hist "$LIVE" "$S1"; hist "$LIVE" "$S2"
cat > "$LIVE/resolutions.json" <<'JSON'
{"run": "0@2026-10-04T10:00:00Z",
 "pins": {"http://x/p": {"1": "div.a"}},
 "targets": {"http://x/p": {"div.a": {"component": "Hero", "component_file": "src/Hero.tsx", "rule": ".a", "rule_file": "src/a.css", "notes": []}}}}
JSON
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "the numeric ts finds its cached target" "src/Hero.tsx" "$(pins_json "$OUT" 'p[0]["resolved"]["component_file"]')"
assert_eq "a pin the run never resolved is null" "None" "$(pins_json "$OUT" 'p[1]["resolved"]')"

begin_test "a pin without a ts reads its target by selector"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "no ts"
hist "$LIVE" '{"seq":1,"pins":[{"n":1,"text":"t","selector":"div.z","page":"http://x/p"}],"sent_at":"2026-10-04T10:01:00Z"}'
printf '%s\n' '{"run": "0@2026-10-04T10:00:00Z", "pins": {}, "targets": {"http://x/p": {"div.z": {"rule": ".z"}}}}' > "$LIVE/resolutions.json"
file_rec "$ROOT" s1 nothing
assert_eq "selector-keyed lookup" ".z" "$(pins_json "$OUT" 'p[0]["resolved"]["rule"]')"

begin_test "a run with no cache files every pin with resolved null"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "no cache"
hist "$LIVE" "$S2"
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "every resolved is null" "True" "$(pins_json "$OUT" 'all(x["resolved"] is None for x in p)')"

begin_test "a cache from another run is ignored"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "stale cache"
hist "$LIVE" "$S1"
printf '%s\n' '{"run": "0@1999-01-01T00:00:00Z", "pins": {"http://x/p": {"1": "div.a"}}, "targets": {"http://x/p": {"div.a": {"rule": ".a"}}}}' > "$LIVE/resolutions.json"
file_rec "$ROOT" s1 nothing
assert_eq "resolved is null" "None" "$(pins_json "$OUT" 'p[0]["resolved"]')"

begin_test "filing survives an unreadable resolutions.json"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "bad cache"
hist "$LIVE" "$S1"
printf 'not json {' > "$LIVE/resolutions.json"
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "resolved is null" "None" "$(pins_json "$OUT" 'p[0]["resolved"]')"

begin_test "file includes only entries after the run's start seq"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 1 "later run"
hist "$LIVE" "$S1"; hist "$LIVE" "$S2"
file_rec "$ROOT" s1 nothing
assert_eq "only the seq 2 pins" "2" "$(pins_json "$OUT" 'len(p)')"
assert_eq "the pre-run pin text never appears" "a2" "$(pins_json "$OUT" 'p[0]["text"]')"
assert_eq "seq_from is the start seq" "1" "$(fm "$OUT" seq_from)"
assert_eq "seq_to is the last window seq" "2" "$(fm "$OUT" seq_to)"

begin_test "cleared entries add nothing and remove nothing"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "with a clear"
hist "$LIVE" "$S1"
hist "$LIVE" '{"seq":2,"cleared":true,"pins":[]}'
file_rec "$ROOT" s1 nothing
assert_eq "the pin sent before the clear survives" "1" "$(pins_json "$OUT" 'len(p)')"
assert_eq "its text is intact" "a" "$(pins_json "$OUT" 'p[0]["text"]')"

begin_test "a pin without ts is keyed by (page, selector, text)"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "no ts"
hist "$LIVE" '{"seq":1,"pins":[{"n":1,"text":"x","selector":"p","page":"P"}],"sent_at":"t1"}'
hist "$LIVE" '{"seq":2,"pins":[{"n":1,"text":"x","selector":"p","page":"P"},{"n":2,"text":"y","selector":"p","page":"P"}],"sent_at":"t2"}'
file_rec "$ROOT" s1 nothing
assert_eq "the repeat collapses, the new text stays" "2" "$(pins_json "$OUT" 'len(p)')"

begin_test "file copies session.css byte-for-byte and writes every frontmatter key"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "sheet run"
hist "$LIVE" "$S1"
printf '/* annotate-key 1 */\n.a { color: red }\n/* annotate-key 2 */\n.b { gap: 4px }\n' > "$LIVE/session.css"
file_rec "$ROOT" s1 story
REC_DIR="$(dirname "$OUT")"
assert_eq "the sheet is a byte copy" "$(cat "$LIVE/session.css")" "$(cat "$REC_DIR/session.css")"
cmp -s "$LIVE/session.css" "$REC_DIR/session.css" && echo "  PASS: cmp agrees" && PASS=$((PASS + 1)) || { echo "  FAIL: cmp differs"; FAIL=$((FAIL + 1)); }
for key in source name created subject status outcome graduated_to session seq_from seq_to pin_count rule_count; do
  if grep -q "^$key:" "$OUT"; then echo "  PASS: frontmatter has $key"; PASS=$((PASS + 1)); else echo "  FAIL: frontmatter lacks $key"; FAIL=$((FAIL + 1)); fi
done
assert_eq "source" "annotate" "$(fm "$OUT" source)"
assert_eq "name is the folder" "$TODAY-sheet-run" "$(fm "$OUT" name)"
assert_eq "created is today" "$TODAY" "$(fm "$OUT" created)"
assert_eq "session" "s1" "$(fm "$OUT" session)"
assert_eq "outcome" "story" "$(fm "$OUT" outcome)"
assert_eq "graduated_to is empty" "" "$(fm "$OUT" graduated_to)"
assert_eq "rule_count counts keyed blocks" "2" "$(fm "$OUT" rule_count)"
assert_eq "pin_count" "1" "$(fm "$OUT" pin_count)"
assert_contains "the heading is the subject" '^# sheet run$' "$(rd "$OUT")"
assert_contains "the sheet sentence names session.css" 'session.css' "$(sed -n '/^## Sheet/,$p' "$OUT")"

begin_test "an empty or absent live sheet files an empty session.css"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "no sheet"
hist "$LIVE" "$S1"
rm -f "$LIVE/session.css"
file_rec "$ROOT" s1 nothing
assert_eq "session.css exists and is empty" "0" "$(wc -c < "$(dirname "$OUT")/session.css" | tr -d ' ')"

begin_test "file without run.json exits 1 and writes nothing; a second file after success also exits 1"
new_root; ROOT="$NEW_ROOT"
mkdir -p "$ROOT/.craft/annotations/s1"
file_rec "$ROOT" s1 nothing
assert_eq "no run.json -> exit 1" "1" "$RC"
assert_eq "no record folder written" "0" "$(find "$ROOT/.craft/annotations" -name record.md | wc -l | tr -d ' ')"
live "$ROOT" s2 0 "twice"
hist "$LIVE" "$S1"
file_rec "$ROOT" s2 nothing
assert_eq "first file succeeds" "0" "$RC"
assert_file_not_exists "run.json is removed" "$LIVE/run.json"
file_rec "$ROOT" s2 nothing
assert_eq "second file exits 1" "1" "$RC"
live "$ROOT" s3 0 "bad outcome"
file_rec "$ROOT" s3 bogus
assert_eq "an invalid outcome exits 1" "1" "$RC"
assert_file_exists "run.json stays after an invalid outcome" "$LIVE/run.json"

begin_test "status mapping: nothing open, abandon abandoned, tweak with graduated-to graduated, zero pins and empty sheet abandoned"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" a 0 "one"; hist "$LIVE" "$S1"; file_rec "$ROOT" a nothing
assert_eq "nothing -> open" "open" "$(fm "$OUT" status)"
live "$ROOT" b 0 "two"; hist "$LIVE" "$S1"; file_rec "$ROOT" b abandon
assert_eq "abandon -> abandoned" "abandoned" "$(fm "$OUT" status)"
live "$ROOT" c 0 "three"; hist "$LIVE" "$S1"; file_rec "$ROOT" c tweak --graduated-to tweak-three
assert_eq "tweak with a name -> graduated" "graduated" "$(fm "$OUT" status)"
assert_eq "graduated_to carries the name" "tweak-three" "$(fm "$OUT" graduated_to)"
live "$ROOT" d 0 "four"; hist "$LIVE" "$S1"; file_rec "$ROOT" d tweak
assert_eq "tweak without a name stays open" "open" "$(fm "$OUT" status)"
live "$ROOT" e 0 "five"; file_rec "$ROOT" e nothing
assert_eq "zero pins and empty sheet -> abandoned" "abandoned" "$(fm "$OUT" status)"
live "$ROOT" f 0 "six"; printf '/* annotate-key 1 */\n.a{}\n' > "$LIVE/session.css"; file_rec "$ROOT" f nothing
assert_eq "zero pins but a non-empty sheet -> open" "open" "$(fm "$OUT" status)"
live "$ROOT" g 0 "seven"; hist "$LIVE" "$S1"; file_rec "$ROOT" g error
assert_eq "error -> open" "open" "$(fm "$OUT" status)"
assert_eq "error outcome recorded" "error" "$(fm "$OUT" outcome)"

begin_test "a slug collision gets -2, an empty subject falls back to annotate"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" a 0 "Same Name!"; hist "$LIVE" "$S1"; file_rec "$ROOT" a nothing
assert_eq "first slug" "$ROOT/.craft/annotations/$TODAY-same-name/record.md" "$OUT"
live "$ROOT" b 0 "Same Name!"; hist "$LIVE" "$S1"; file_rec "$ROOT" b nothing
assert_eq "second slug is suffixed" "$ROOT/.craft/annotations/$TODAY-same-name-2/record.md" "$OUT"
live "$ROOT" c 0 ""; hist "$LIVE" "$S1"; file_rec "$ROOT" c nothing
assert_eq "empty subject" "$ROOT/.craft/annotations/$TODAY-annotate/record.md" "$OUT"
live "$ROOT" d 0 "this subject is a very long run of words that goes well past the fifty character cap"; hist "$LIVE" "$S1"; file_rec "$ROOT" d nothing
SLUGLEN=$(basename "$(dirname "$OUT")"); SLUGLEN=$(( ${#SLUGLEN} - 11 ))
if [ "$SLUGLEN" -le 50 ]; then echo "  PASS: slug is capped at 50"; PASS=$((PASS + 1)); else echo "  FAIL: slug is $SLUGLEN chars"; FAIL=$((FAIL + 1)); fi

begin_test "a subject with YAML-special characters keeps the frontmatter parseable"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" a 0 "fix: the \\\"hero\\\" # block"; hist "$LIVE" "$S1"; file_rec "$ROOT" a nothing
assert_eq "frontmatter parses with a yaml-like reader" "True" "$(python3 - "$OUT" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
end = lines.index("---", 1)
print(all(": " in l or l.endswith(":") for l in lines[1:end]) and lines[0] == "---")
PYEOF
)"

begin_test "the live session folder keeps everything except run.json; no owner.pid lands in the record"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "keeps"; hist "$LIVE" "$S1"
echo 4242 > "$LIVE/port"; echo 1 > "$LIVE/owner.pid"; echo 2 > "$LIVE/listener.pid"
echo '{"seq":1}' > "$LIVE/current.json"; echo "- note" > "$LIVE/listener.log"
file_rec "$ROOT" s1 nothing
for f in history.jsonl session.css port owner.pid listener.pid current.json listener.log; do
  assert_file_exists "live $f kept" "$LIVE/$f"
done
assert_file_not_exists "run.json removed" "$LIVE/run.json"
for f in owner.pid port listener.pid; do
  assert_file_not_exists "record has no $f" "$(dirname "$OUT")/$f"
done

begin_test "graduate rewrites status, graduated_to and outcome and nothing else"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "grad"; hist "$LIVE" "$S1"; file_rec "$ROOT" s1 nothing
BEFORE="$(cat "$OUT")"
NAME="$(basename "$(dirname "$OUT")")"
GOUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to hero-polish 2>/dev/null)"; GRC=$?
assert_eq "graduate exits 0" "0" "$GRC"
assert_eq "it prints the record path" "$OUT" "$GOUT"
assert_eq "status graduated" "graduated" "$(fm "$OUT" status)"
assert_eq "graduated_to set" "hero-polish" "$(fm "$OUT" graduated_to)"
assert_eq "outcome defaults to story" "story" "$(fm "$OUT" outcome)"
DIFFN="$(diff <(echo "$BEFORE") "$OUT" | grep -c '^[<>]' || true)"
assert_eq "exactly three lines changed (six diff lines)" "6" "$DIFFN"
CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to tweak-x --outcome tweak >/dev/null 2>&1
assert_eq "outcome tweak accepted" "tweak" "$(fm "$OUT" outcome)"
CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record nope --to x >/dev/null 2>&1; GRC=$?
assert_eq "a missing record exits 1" "1" "$GRC"

begin_test "begin files a stale run before starting the new one"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "stale run"; hist "$LIVE" "$S1"
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" begin --session s1 --subject "fresh" >/dev/null 2>&1
STALE="$ROOT/.craft/annotations/$TODAY-stale-run/record.md"
assert_file_exists "the stale run was filed" "$STALE"
assert_eq "filed as error" "error" "$(fm "$STALE" outcome)"
assert_eq "filed open" "open" "$(fm "$STALE" status)"
assert_eq "the new run starts after the old window" "1" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start_seq"])' "$LIVE/run.json")"
assert_contains "run.json now names the new subject" 'fresh' "$(rd "$LIVE/run.json")"

begin_test "sweep files an orphaned run, then reaps the live folder; the record survives"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "orphan"; hist "$LIVE" "$S1"
echo 999999 > "$LIVE/owner.pid"
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" sweep >/dev/null 2>&1; RC=$?
assert_eq "sweep exits 0" "0" "$RC"
OR="$ROOT/.craft/annotations/$TODAY-orphan/record.md"
assert_file_exists "the orphan was filed" "$OR"
assert_eq "outcome error" "error" "$(fm "$OR" outcome)"
assert_eq "status open" "open" "$(fm "$OR" status)"
assert_dir_not_exists "the live folder is gone" "$ROOT/.craft/annotations/s1"
assert_file_exists "the sheet copy survives" "$ROOT/.craft/annotations/$TODAY-orphan/session.css"

begin_test "sweep reaps a dead-owner dir with no run.json without filing anything"
new_root; ROOT="$NEW_ROOT"
mkdir -p "$ROOT/.craft/annotations/s1"; echo 999999 > "$ROOT/.craft/annotations/s1/owner.pid"
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" sweep >/dev/null 2>&1
assert_dir_not_exists "reaped" "$ROOT/.craft/annotations/s1"
assert_eq "nothing filed" "0" "$(find "$ROOT/.craft/annotations" -name record.md | wc -l | tr -d ' ')"

# --- session start ---
ss() { # <root> - runs session-start from the root, prints its output
  (cd "$1" && unset PROJECT_ROOT CRAFT_PROJECT_ROOT CRAFT_MULTI_PROJECT && export CLAUDE_ENV_FILE="$(mktemp)" && bash "$SESSION_SCRIPT" 2>/dev/null) || true
}
mkrec() { # <root> <name> <status>
  mkdir -p "$1/.craft/annotations/$2"
  printf -- '---\nsource: annotate\nname: %s\nstatus: %s\n---\n\n# x\n' "$2" "$3" > "$1/.craft/annotations/$2/record.md"
}
mkdir -p "$TMPDIR" 2>/dev/null || true

begin_test "session start shows Annotations: 1 awaiting destination with one open record"
new_root; ROOT="$NEW_ROOT"
echo 'PROJECT_ROOT="'"$ROOT"'"' > /dev/null
printf 'CURRENT_CYCLE=""\n' > "$ROOT/.craft/.global-state"
mkrec "$ROOT" 2026-10-04-a open
mkrec "$ROOT" 2026-10-04-b graduated
mkrec "$ROOT" 2026-10-04-c abandoned
mkdir -p "$ROOT/.craft/annotations/live-1"; echo '{}' > "$ROOT/.craft/annotations/live-1/current.json"
OUTS="$(ss "$ROOT")"
assert_contains_literal "the segment counts only the open record" "| Annotations: 1 awaiting destination (2026-10-04-a)" "$OUTS"

begin_test "no Annotations segment for graduated, abandoned or live-only folders"
new_root; ROOT="$NEW_ROOT"
printf 'CURRENT_CYCLE=""\n' > "$ROOT/.craft/.global-state"
mkrec "$ROOT" 2026-10-04-b graduated
mkrec "$ROOT" 2026-10-04-c abandoned
mkdir -p "$ROOT/.craft/annotations/live-1"
OUTS="$(ss "$ROOT")"
assert_not_contains "no segment" "Annotations:" "$OUTS"

finish_tests "test-annotate-record"
