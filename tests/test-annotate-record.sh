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

begin_test "a pin withdrawn by DELETE-then-SEND is left out of the record"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "withdrawn pin"
hist "$LIVE" "$S2"
hist "$LIVE" '{"seq":3,"pins":[{"n":1,"text":"a2","x":1,"y":2,"selector":"div.a","nearText":"near a","ts":1,"page":"http://x/p"}],"deleted":[2],"sent_at":"2026-10-04T10:03:00Z"}'
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "only the kept pin is filed" "1" "$(pins_json "$OUT" 'len(p)')"
assert_eq "the kept pin is pin 1" "a2" "$(pins_json "$OUT" 'p[0]["text"]')"
assert_eq "pin_count counts the kept pin" "1" "$(fm "$OUT" pin_count)"
assert_eq "the key set is unchanged" "True" "$(pins_json "$OUT" 'all(set(x) == {"n","seq","sent_at","text","selector","nearText","candidate","page","box","component","ts","x","y","resolved"} for x in p)')"
assert_not_contains "the reading list drops it" '"b"' "$(sed -n '/^## Pins/,/^## Pin Data/p' "$OUT")"

begin_test "a deleted ts given as a string withdraws the pin, and a clear alone withdraws nothing"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "string ts"
hist "$LIVE" "$S2"
hist "$LIVE" '{"seq":3,"pins":[],"deleted":["1"],"sent_at":"t3"}'
hist "$LIVE" '{"seq":4,"cleared":true,"pins":[]}'
file_rec "$ROOT" s1 nothing
assert_eq "pin 1 is withdrawn, pin 2 stays" "b" "$(pins_json "$OUT" 'p[0]["text"]')"
assert_eq "one pin remains" "1" "$(pins_json "$OUT" 'len(p)')"

begin_test "the new Sheet sentence is written on new records"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "sheet sentence"
hist "$LIVE" "$S1"
file_rec "$ROOT" s1 nothing
assert_contains_literal "sentence is exact" '`session.css` beside this file holds every change shown live, one keyed block per pin. Its look ports verbatim; a block that stands in for content graduates as a requirement quoting the pin.' "$(sed -n '/^## Sheet/,$p' "$OUT")"
assert_not_contains "the old claim is gone" 'normative' "$(rd "$OUT")"

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

# --- cut-short records: list, close, resume, send ---
# mkcut <root> <name> <status> <outcome> <pin_count> <subject> [session.css text]
mkcut() {
  local dir="$1/.craft/annotations/$2"
  mkdir -p "$dir"
  printf -- '---\nsource: annotate\nname: %s\nsubject: %s\nstatus: %s\noutcome: %s\ngraduated_to:\npin_count: %s\n---\n\n# x\n' "$2" "$6" "$3" "$4" "$5" > "$dir/record.md"
  printf '%s' "${7:-}" > "$dir/session.css"
}
# mkpins <root> <name> <pin json list> - appends a Pin Data block to a record
mkpins() {
  printf '\n## Pin Data\n\n```json\n%s\n```\n' "$3" >> "$1/.craft/annotations/$2/record.md"
}
rec() { # <root> <args...> - runs annotate-record.sh with the root given, sets OUT and RC
  local root="$1"; shift
  OUT="$(CRAFT_PROJECT_ROOT="$root" bash "$REC" "$@" 2>&1)"
  RC=$?
}

begin_test "cut-short lists only open records with outcome error, newest first"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-old open error 1 "old run"
mkcut "$ROOT" 2026-10-02-mid open error 3 "mid run"
mkcut "$ROOT" 2026-10-03-new open error 2 "new run"
mkcut "$ROOT" 2026-10-04-done open nothing 5 "finished run"
mkcut "$ROOT" 2026-10-05-dropped abandoned error 4 "dropped run"
mkcut "$ROOT" 2026-10-06-sent graduated error 6 "sent run"
touch -t 202610010900 "$ROOT/.craft/annotations/2026-10-01-old/record.md"
touch -t 202610030900 "$ROOT/.craft/annotations/2026-10-03-new/record.md"
touch -t 202610020900 "$ROOT/.craft/annotations/2026-10-02-mid/record.md"
rec "$ROOT" cut-short
assert_eq "cut-short exits 0" "0" "$RC"
assert_eq "three cut-short runs, newest first" "CUT 2026-10-03-new PINS 2 new run
CUT 2026-10-02-mid PINS 3 mid run
CUT 2026-10-01-old PINS 1 old run" "$OUT"

begin_test "cut-short breaks a tie by name descending, prints nothing when none, and reads a quoted subject"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a open error 0 "first"
mkcut "$ROOT" 2026-10-01-b open error 0 "fix: the \"hero\""
touch -t 202610010900 "$ROOT/.craft/annotations/2026-10-01-a/record.md" "$ROOT/.craft/annotations/2026-10-01-b/record.md"
sed -i.bak 's/^subject: .*/subject: "fix: the \\"hero\\""/' "$ROOT/.craft/annotations/2026-10-01-b/record.md"
rec "$ROOT" cut-short
assert_eq "the later name comes first, the subject is decoded" "CUT 2026-10-01-b PINS 0 fix: the \"hero\"
CUT 2026-10-01-a PINS 0 first" "$OUT"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a open nothing 1 "finished"
rec "$ROOT" cut-short
assert_eq "no cut-short runs prints nothing" "" "$OUT"
assert_eq "and exits 0" "0" "$RC"
new_root; ROOT="$NEW_ROOT"
rec "$ROOT" cut-short
assert_eq "no annotations folder prints nothing" "" "$OUT"
assert_eq "and exits 0" "0" "$RC"

begin_test "cut-short writes nothing"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a open error 2 "keep me"
BEFORE="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
BEFORE_M="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$ROOT/.craft/annotations/2026-10-01-a/record.md")"
rec "$ROOT" cut-short
AFTER="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
AFTER_M="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$ROOT/.craft/annotations/2026-10-01-a/record.md")"
assert_eq "no file changed or appeared" "$BEFORE" "$AFTER"
assert_eq "the record's modification time is unchanged" "$BEFORE_M" "$AFTER_M"
assert_dir_not_exists "no dashboard graph was made" "$ROOT/.craft/graph"

begin_test "close marks an open record abandoned and keeps its files"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a open error 2 "close me" ".x{}"
R="$ROOT/.craft/annotations/2026-10-01-a/record.md"
BEFORE="$(cat "$R")"
rec "$ROOT" close --record 2026-10-01-a
assert_eq "close exits 0" "0" "$RC"
assert_eq "close prints the record path" "$R" "$OUT"
assert_eq "status is abandoned" "abandoned" "$(fm "$R" status)"
assert_eq "outcome is untouched" "error" "$(fm "$R" outcome)"
assert_eq "only the status line changed" "$(printf '%s\n' "$BEFORE" | sed 's/^status: open$/status: abandoned/')" "$(cat "$R")"
assert_eq "the sheet copy is kept" ".x{}" "$(rd "$ROOT/.craft/annotations/2026-10-01-a/session.css")"
rec "$ROOT" cut-short
assert_eq "it is no longer listed" "" "$OUT"

begin_test "close on an abandoned record is a no-op"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a abandoned error 2 "already"
R="$ROOT/.craft/annotations/2026-10-01-a/record.md"
BEFORE="$(cat "$R")"
rec "$ROOT" close --record 2026-10-01-a
assert_eq "close exits 0" "0" "$RC"
assert_eq "it prints the path" "$R" "$OUT"
assert_eq "the record is unchanged" "$BEFORE" "$(cat "$R")"

begin_test "close refuses a graduated record and a missing one"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a graduated error 2 "moved on"
R="$ROOT/.craft/annotations/2026-10-01-a/record.md"
BEFORE="$(cat "$R")"
rec "$ROOT" close --record 2026-10-01-a
assert_eq "close exits 1" "1" "$RC"
assert_contains "it says the record stays as it is" "record 2026-10-01-a is graduated, so it stays as it is" "$OUT"
assert_eq "the record is unchanged" "$BEFORE" "$(cat "$R")"
rec "$ROOT" close --record nope
assert_eq "a missing record exits 1" "1" "$RC"
assert_contains "it says no such record" "no such record: nope" "$OUT"
rec "$ROOT" close
assert_eq "close with no record exits 1" "1" "$RC"

begin_test "graduate accepts outcome todo and still refuses others"
new_root; ROOT="$NEW_ROOT"
mkcut "$ROOT" 2026-10-01-a open error 2 "send me"
R="$ROOT/.craft/annotations/2026-10-01-a/record.md"
rec "$ROOT" graduate --record 2026-10-01-a --to todo-ref --outcome todo
assert_eq "graduate exits 0" "0" "$RC"
assert_eq "status graduated" "graduated" "$(fm "$R" status)"
assert_eq "graduated_to set" "todo-ref" "$(fm "$R" graduated_to)"
assert_eq "outcome is todo" "todo" "$(fm "$R" outcome)"
rec "$ROOT" graduate --record 2026-10-01-a --to x --outcome nothing
assert_eq "an unknown outcome exits 1" "1" "$RC"

# resume fixture: an open record OLD holding one pin and a keyed sheet, and a live session
OLD_PIN='[{"n":1,"seq":1,"sent_at":"2026-10-04T10:01:00Z","text":"a","selector":"div.a","nearText":"near a","candidate":"c1","page":"http://x/p","box":null,"component":"Hero","ts":1,"x":1,"y":2,"resolved":null}]'
OLD_SHEET='/* annotate-key 1 */
.a { color: red; }
'
resume_fixture() { # sets ROOT, OLD (record name), LIVE
  new_root; ROOT="$NEW_ROOT"; OLD=2026-10-01-old-run
  mkcut "$ROOT" "$OLD" open error 1 "old run" "$OLD_SHEET"
  mkpins "$ROOT" "$OLD" "$OLD_PIN"
  live "$ROOT" s1 0 "placeholder"
  rm -f "$LIVE/run.json"
}
begin_run() { # <args...> - runs begin on s1, sets OUT and RC
  OUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" begin --session s1 "$@" 2>&1)"
  RC=$?
}

begin_test "begin --resume seeds the sheet from the record and names it in run.json"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
assert_eq "begin exits 0" "0" "$RC"
assert_eq "output stays RUN <start_seq>" "RUN 0" "$OUT"
assert_eq "session.css matches the record byte for byte" "0" "$(cmp -s "$LIVE/session.css" "$ROOT/.craft/annotations/$OLD/session.css"; echo $?)"
assert_eq "run.json names the resumed record" "$OLD" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["resumes"])' "$LIVE/run.json")"
assert_eq "run.json keeps the subject" "picked up" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subject"])' "$LIVE/run.json")"

begin_test "begin --resume refuses a record that is not open and writes nothing"
resume_fixture
mkcut "$ROOT" 2026-10-02-closed abandoned error 1 "closed" ".z{}"
for bad in 2026-10-02-closed no-such-record; do
  begin_run --subject "x" --resume "$bad"
  assert_eq "$bad: exits 1" "1" "$RC"
  assert_contains "$bad: says there is no open record" "no open record to resume: $bad" "$OUT"
  assert_file_not_exists "$bad: no run.json" "$LIVE/run.json"
  assert_eq "$bad: the sheet is not seeded" "" "$(cat "$LIVE/session.css")"
done

begin_test "begin --resume drops an empty prior run instead of filing it"
resume_fixture
live "$ROOT" s1 0 "empty prior"
BEFORE_N="$(find "$ROOT/.craft/annotations" -name record.md | wc -l | tr -d ' ')"
begin_run --subject "picked up" --resume "$OLD"
assert_eq "begin exits 0" "0" "$RC"
assert_eq "no new record folder" "$BEFORE_N" "$(find "$ROOT/.craft/annotations" -name record.md | wc -l | tr -d ' ')"
assert_eq "the new run names the resumed record" "$OLD" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["resumes"])' "$LIVE/run.json")"

begin_test "begin --resume still files a prior run that has pins"
resume_fixture
live "$ROOT" s1 0 "prior with pins"; hist "$LIVE" "$S1"
begin_run --subject "picked up" --resume "$OLD"
assert_eq "begin exits 0" "0" "$RC"
assert_file_exists "the prior run was filed" "$ROOT/.craft/annotations/$TODAY-prior-with-pins/record.md"

begin_test "a resumed run's record carries the old pins first and graduates the old record"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
hist "$LIVE" '{"seq":1,"pins":[{"n":1,"text":"b","x":5,"y":6,"selector":"div.b","nearText":"near b","ts":2,"page":"http://x/p"}],"sent_at":"2026-10-04T10:05:00Z"}'
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
NEWREC="$OUT"; NEWNAME="$(basename "$(dirname "$NEWREC")")"
assert_eq "two pins in the new record" "2" "$(pins_json "$NEWREC" 'len(p)')"
assert_eq "the old pin is first" "a" "$(pins_json "$NEWREC" 'p[0]["text"]')"
assert_eq "the new pin follows" "b" "$(pins_json "$NEWREC" 'p[1]["text"]')"
assert_eq "n is renumbered" "1,2" "$(pins_json "$NEWREC" '",".join(str(x["n"]) for x in p)')"
assert_eq "pin_count counts the merge" "2" "$(fm "$NEWREC" pin_count)"
assert_eq "the new record is open" "open" "$(fm "$NEWREC" status)"
OLDREC="$ROOT/.craft/annotations/$OLD/record.md"
assert_eq "the old record is graduated" "graduated" "$(fm "$OLDREC" status)"
assert_eq "graduated_to names the new record" "$NEWNAME" "$(fm "$OLDREC" graduated_to)"
assert_eq "the old outcome is untouched" "error" "$(fm "$OLDREC" outcome)"
assert_eq "the old record keeps its other lines" "1" "$(fm "$OLDREC" pin_count)"

begin_test "a resumed run that re-pins an old pin keeps one copy, the new one"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
hist "$LIVE" '{"seq":1,"pins":[{"n":1,"text":"a, reworded","x":1,"y":2,"selector":"div.a","nearText":"near a","ts":1,"page":"http://x/p"}],"sent_at":"2026-10-04T10:05:00Z"}'
file_rec "$ROOT" s1 nothing
assert_eq "one pin, not two" "1" "$(pins_json "$OUT" 'len(p)')"
assert_eq "it carries the new text" "a, reworded" "$(pins_json "$OUT" 'p[0]["text"]')"

begin_test "a resumed run with no new pins still files the old pins and the sheet"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "the old pin carried" "a" "$(pins_json "$OUT" 'p[0]["text"]')"
assert_eq "the status is open" "open" "$(fm "$OUT" status)"
assert_eq "the sheet carried byte for byte" "0" "$(cmp -s "$(dirname "$OUT")/session.css" "$ROOT/.craft/annotations/$OLD/session.css"; echo $?)"

begin_test "filing a resumed run never fails on a missing or unparseable resumed record"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
hist "$LIVE" "$S1"
printf -- '---\nstatus: open\noutcome: error\n---\n\n## Pin Data\n\n```json\nnot json\n```\n' > "$ROOT/.craft/annotations/$OLD/record.md"
file_rec "$ROOT" s1 nothing
assert_eq "an unparseable block files only the new pins" "1" "$(pins_json "$OUT" 'len(p)')"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
hist "$LIVE" "$S1"
rm -rf "$ROOT/.craft/annotations/$OLD"
file_rec "$ROOT" s1 nothing
assert_eq "a missing resumed record files only the new pins" "0" "$RC"

begin_test "a resumed record that is no longer open is left as it is"
resume_fixture
begin_run --subject "picked up" --resume "$OLD"
rec "$ROOT" close --record "$OLD"
file_rec "$ROOT" s1 nothing
assert_eq "file exits 0" "0" "$RC"
assert_eq "the closed record stays abandoned" "abandoned" "$(fm "$ROOT/.craft/annotations/$OLD/record.md" status)"
assert_eq "graduated_to stays empty" "" "$(fm "$ROOT/.craft/annotations/$OLD/record.md" graduated_to)"

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

begin_test "graduate --to 'story: one #two' writes a quoted value"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" s1 0 "quoted"; hist "$LIVE" "$S1"; file_rec "$ROOT" s1 nothing
NAME="$(basename "$(dirname "$OUT")")"
CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to 'story: one #two' >/dev/null 2>&1
assert_eq "the colon destination is JSON-quoted" '"story: one #two"' "$(fm "$OUT" graduated_to)"
assert_eq "status is still graduated" "graduated" "$(fm "$OUT" status)"
CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to $'two\nlines: x' >/dev/null 2>&1
assert_eq "a newline cannot add a frontmatter line" '"two lines: x"' "$(fm "$OUT" graduated_to)"

begin_test "graduate writes through a temp of its own and never touches one another writer left"
# A fixed record.md.tmp is shared by every graduate, so one's rename can find
# it gone. A file already at that name stands for another graduate's temp.
new_root; ROOT="$NEW_ROOT"
live "$ROOT" g1 0 "held temp"; hist "$LIVE" "$S1"; file_rec "$ROOT" g1 nothing
RDIR="$(dirname "$OUT")"; NAME="$(basename "$RDIR")"
NEW_MODE="$(stat -f '%Lp' "$OUT" 2>/dev/null || stat -c '%a' "$OUT")"
printf 'another writer\n' > "$RDIR/record.md.tmp"
CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to held >/dev/null 2>&1; GRC=$?
assert_eq "graduate exits 0" "0" "$GRC"
assert_eq "graduated_to set" "held" "$(fm "$OUT" graduated_to)"
assert_eq "the other writer's record.md.tmp is left as it was" "another writer" "$(rd "$RDIR/record.md.tmp")"
assert_eq "no temp of its own is left" "record.md.tmp" "$(ls "$RDIR" | grep '\.tmp$' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "record.md keeps the mode the filer gave it" "$NEW_MODE" "$(stat -f '%Lp' "$OUT" 2>/dev/null || stat -c '%a' "$OUT")"

begin_test "two graduate calls on one record at once all succeed, 20 rounds"
new_root; ROOT="$NEW_ROOT"
live "$ROOT" g2 0 "twice"; hist "$LIVE" "$S1"; file_rec "$ROOT" g2 nothing
RDIR="$(dirname "$OUT")"; NAME="$(basename "$RDIR")"
GRAD_FAILED=0
for i in $(seq 20); do
  CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to one >/dev/null 2>&1 & A=$!
  CRAFT_PROJECT_ROOT="$ROOT" bash "$REC" graduate --record "$NAME" --to two >/dev/null 2>&1 & B=$!
  wait "$A" || GRAD_FAILED=$((GRAD_FAILED + 1))
  wait "$B" || GRAD_FAILED=$((GRAD_FAILED + 1))
done
assert_eq "no graduate failed" "0 of 40" "$GRAD_FAILED of 40"
assert_eq "status is graduated" "graduated" "$(fm "$OUT" status)"
case "$(fm "$OUT" graduated_to)" in
  one|two) echo "  PASS: graduated_to is one of the two destinations"; PASS=$((PASS + 1)) ;;
  *) echo "  FAIL: graduated_to is '$(fm "$OUT" graduated_to)'"; FAIL=$((FAIL + 1)) ;;
esac
assert_eq "no temp file is left" "0" "$(ls "$RDIR" | grep -c '\.tmp$' || true)"

finish_tests "test-annotate-record"
