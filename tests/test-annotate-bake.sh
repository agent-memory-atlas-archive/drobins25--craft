#!/bin/bash
# test-annotate-bake.sh - The mockup delivery of the annotation overlay:
# annotate-run.sh bake splices the stamps and the overlay fence into a page
# file, strip removes them, and the served, printed and baked copies of the
# overlay are the same bytes as the fence in the reference.
# Usage: bash tests/test-annotate-bake.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REPO="$PLUGIN_ROOT"
RUN="$SCRIPTS_DIR/annotate-run.sh"
CHANNEL="$SCRIPTS_DIR/annotate-channel.py"
REF="$REPO/commands/references/annotate-overlay.md"

TMP_ROOTS=()
cleanup() {
  local r f p
  for r in "${TMP_ROOTS[@]:-}"; do
    [ -n "$r" ] || continue
    for f in "$r"/.craft/annotations/*/listener.pid; do
      [ -f "$f" ] || continue
      p="$(cat "$f" 2>/dev/null || true)"
      case "$p" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null || true ;; esac
    done
    rm -rf "$r"
  done
  return 0
}
trap cleanup EXIT

new_root() {
  NEW_ROOT="$(mktemp -d)"
  TMP_ROOTS+=("$NEW_ROOT")
  mkdir -p "$NEW_ROOT/.craft"
}

arm_session() {
  local root="$1"; shift
  local out
  out="$(CRAFT_PROJECT_ROOT="$root" bash "$RUN" arm --owner-pid "$$" "$@" 2>/dev/null)" || true
  SID="$(echo "$out" | awk '/^SESSION /{print $2; exit}')"
  PORT="$(echo "$out" | awk '/^SESSION /{print $4; exit}')"
}

run_in() {
  local root="$1"; shift
  CRAFT_PROJECT_ROOT="$root" bash "$RUN" "$@" 2>/dev/null || true
}

is_running() { kill -0 "$1" 2>/dev/null; }
wait_dead() {
  local i=0
  while is_running "$1" && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
  ! is_running "$1"
}

# fence_of_ref - the overlay-source fence body, by an independent awk
fence_of_ref() {
  awk '
    $0 == "```overlay-source" {inside=1; next}
    inside && $0 == "```" {exit}
    inside {print}
  ' "$REF"
}

begin_test "the overlay source carries no closing script tag"
FENCE="$(fence_of_ref)"
assert_not_eq "the fence is not empty" "" "$FENCE"
assert_eq "no </script sequence in the fence" "0" "$(printf '%s\n' "$FENCE" | grep -ci '</script' || true)"

PAGE_HTML='<html><body><p>x</p></body></html>'
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session bk1
PAGE="$ROOT/page.html"

begin_test "bake inserts one element before </body> with stamps then fence"
printf '%s' "$PAGE_HTML" > "$PAGE"
OUT="$(run_in "$ROOT" bake --session bk1 --file "$PAGE")"
assert_eq "prints BAKED with the path and port" "BAKED $PAGE PORT $PORT" "$OUT"
assert_eq "one overlay element" "1" "$(grep -c '<script id="ca-overlay">' "$PAGE")"
assert_eq "one closing script tag" "1" "$(grep -c '</script>' "$PAGE")"
assert_eq "the element opens right after the body content" '<html><body><p>x</p><script id="ca-overlay">' "$(sed -n 1p "$PAGE")"
assert_eq "stamp 1 is the port" "window.__craftAnnotatePort = $PORT;" "$(sed -n 2p "$PAGE")"
assert_eq "stamp 2 is the baked flag" "window.__craftAnnotateBaked = true;" "$(sed -n 3p "$PAGE")"
BTOKEN="$(tr -d '\n' < "$ROOT/.craft/annotations/bk1/token")"
assert_eq "stamp 3 is the token" "window.__craftAnnotateToken = \"$BTOKEN\";" "$(sed -n 4p "$PAGE")"
assert_eq "the fence follows the stamps" "$(printf '%s\n' "$FENCE" | sed -n 1p)" "$(sed -n 5p "$PAGE")"
assert_eq "the page ends with the closing tags" "</script>" "$(tail -2 "$PAGE" | head -1)"
assert_eq "the body closes right after the element" "</body></html>" "$(tail -1 "$PAGE")"
assert_eq "no context stamp" "0" "$(grep -c '^window.__craftAnnotateContext = ' "$PAGE" || true)"
assert_eq "no src attribute on the element" "0" "$(grep -c '<script[^>]* src=' "$PAGE" || true)"

begin_test "served, printed and baked bytes equal the reference fence"
A="$(mktemp)"; B="$(mktemp)"; C="$(mktemp)"; D="$(mktemp)"
fence_of_ref > "$A"
curl -s --max-time 5 -o "$B" "http://127.0.0.1:$PORT/overlay.js?token=$BTOKEN" 2>/dev/null || true
python3 "$CHANNEL" --print-overlay > "$C" 2>/dev/null || true
LINES="$(wc -l < "$PAGE" | tr -d ' ')"
sed -n "5,$((LINES - 1))p" "$PAGE" > "$D"
for pair in "B:served" "C:printed" "D:baked"; do
  var="${pair%%:*}"; label="${pair##*:}"
  rc=0; cmp -s "$A" "${!var}" || rc=$?
  assert_eq "$label bytes equal the reference fence" "0" "$rc"
done
rm -f "$A" "$B" "$C" "$D"

begin_test "re-bake replaces, never stacks"
LP="$(cat "$ROOT/.craft/annotations/bk1/listener.pid")"
kill "$LP" 2>/dev/null || true
wait_dead "$LP" || true
arm_session "$ROOT" --session bk1
OUT="$(run_in "$ROOT" bake --session bk1 --file "$PAGE")"
assert_eq "bake reports the new port" "BAKED $PAGE PORT $PORT" "$OUT"
assert_eq "still one element" "1" "$(grep -c '<script id="ca-overlay">' "$PAGE")"
assert_eq "the stamp carries the new port" "window.__craftAnnotatePort = $PORT;" "$(sed -n 2p "$PAGE")"
assert_eq "one port stamp in the page" "1" "$(grep -c '^window.__craftAnnotatePort = ' "$PAGE")"

begin_test "bake writes the token on line 4; a re-bake leaves exactly one token line"
BTOKEN="$(tr -d '\n' < "$ROOT/.craft/annotations/bk1/token")"
assert_eq "line 4 is the token stamp" "window.__craftAnnotateToken = \"$BTOKEN\";" "$(sed -n 4p "$PAGE")"
assert_eq "exactly one token line after the re-bake" "1" "$(grep -c '^window.__craftAnnotateToken = ' "$PAGE")"
run_in "$ROOT" bake --session bk1 --file "$PAGE" >/dev/null
assert_eq "still one token line after another bake" "1" "$(grep -c '^window.__craftAnnotateToken = ' "$PAGE")"

begin_test "bake then strip restores the original bytes"
printf '%s\n' '<html>' '<body>' '<p>x</p>' '</body>' '</html>' > "$PAGE"
cp "$PAGE" "$ROOT/orig.html"
run_in "$ROOT" bake --session bk1 --file "$PAGE" >/dev/null
rc=0; cmp -s "$PAGE" "$ROOT/orig.html" || rc=$?
assert_not_eq "the bake changed the file" "0" "$rc"
OUT="$(run_in "$ROOT" strip --file "$PAGE")"
assert_eq "strip reports one element" "STRIPPED 1" "$OUT"
rc=0; cmp -s "$PAGE" "$ROOT/orig.html" || rc=$?
assert_eq "bytes restored exactly" "0" "$rc"
printf '%s' "$PAGE_HTML" > "$PAGE"
cp "$PAGE" "$ROOT/orig.html"
run_in "$ROOT" bake --session bk1 --file "$PAGE" >/dev/null
run_in "$ROOT" strip --file "$PAGE" >/dev/null
rc=0; cmp -s "$PAGE" "$ROOT/orig.html" || rc=$?
assert_eq "bytes restored exactly with no newline before </body>" "0" "$rc"

begin_test "strip with nothing to strip prints STRIPPED 0"
printf '%s' "$PAGE_HTML" > "$PAGE"
assert_eq "prints STRIPPED 0" "STRIPPED 0" "$(run_in "$ROOT" strip --file "$PAGE")"
assert_eq "the page is unchanged" "$PAGE_HTML" "$(cat "$PAGE")"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" strip --file "$ROOT/missing.html" >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "a missing file exits 1" "1" "$RC"

begin_test "strip removes any ca-overlay element whatever its contents"
printf '%s\n' '<body><p>x</p><script id="ca-overlay">' 'old paste' '</script>' '<script id="ca-overlay">' 'again' '</script>' '</body>' > "$PAGE"
assert_eq "two elements stripped" "STRIPPED 2" "$(run_in "$ROOT" strip --file "$PAGE")"
assert_eq "none left" "0" "$(grep -c 'ca-overlay' "$PAGE" || true)"

begin_test "bake refuses a file with no </body> and leaves it untouched"
printf '%s' '<html><p>no body close</p></html>' > "$PAGE"
cp "$PAGE" "$ROOT/orig.html"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" bake --session bk1 --file "$PAGE" >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "exits 1" "1" "$RC"
rc=0; cmp -s "$PAGE" "$ROOT/orig.html" || rc=$?
assert_eq "file untouched" "0" "$rc"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" bake --session bk1 --file "$ROOT/missing.html" >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "a missing file exits 1" "1" "$RC"

begin_test "bake refuses a session whose port is not a number and leaves the file untouched"
printf '%s' "$PAGE_HTML" > "$PAGE"
echo "nope" > "$ROOT/.craft/annotations/bk1/port"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" bake --session bk1 --file "$PAGE" >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "exits 1" "1" "$RC"
assert_eq "file untouched" "$PAGE_HTML" "$(cat "$PAGE")"

begin_test "bake works with the listener down"
new_root; ROOT2="$NEW_ROOT"
arm_session "$ROOT2" --session bk2
LP="$(cat "$ROOT2/.craft/annotations/bk2/listener.pid")"
kill "$LP" 2>/dev/null || true
wait_dead "$LP" || true
printf '%s' "$PAGE_HTML" > "$ROOT2/page.html"
OUT="$(run_in "$ROOT2" bake --session bk2 --file "$ROOT2/page.html")"
assert_eq "bake still succeeds" "BAKED $ROOT2/page.html PORT $PORT" "$OUT"
assert_eq "the element is in the page" "1" "$(grep -c '<script id="ca-overlay">' "$ROOT2/page.html")"

begin_test "bake exits 1 and leaves the file when the overlay source cannot be read"
ISO="$(mktemp -d)"; TMP_ROOTS+=("$ISO")
mkdir -p "$ISO/hooks/scripts" "$ISO/root/.craft/annotations/bk3"
cp "$RUN" "$ISO/hooks/scripts/annotate-run.sh"
cp "$CHANNEL" "$ISO/hooks/scripts/annotate-channel.py"
echo 4242 > "$ISO/root/.craft/annotations/bk3/port"
printf '%s' "$PAGE_HTML" > "$ISO/page.html"
set +e
CRAFT_PROJECT_ROOT="$ISO/root" bash "$ISO/hooks/scripts/annotate-run.sh" bake --session bk3 --file "$ISO/page.html" >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "exits 1" "1" "$RC"
assert_eq "file untouched" "$PAGE_HTML" "$(cat "$ISO/page.html")"

begin_test "bake and strip never touch a temp file another writer left beside the page"
# A temp name shared by every writer lets one bake rename or delete another's
# temp mid-flight. Each writer must use a name of its own, so a file already
# sitting at any fixed name beside the page is left exactly as it was.
new_root; ROOT4="$NEW_ROOT"
arm_session "$ROOT4" --session bk4
P4="$ROOT4/page.html"
printf '%s' "$PAGE_HTML" > "$P4"
for NAME in page.html.bake-tmp page.html.strip-tmp page.html.tmp; do printf 'another writer\n' > "$ROOT4/$NAME"; done
OUT="$(run_in "$ROOT4" bake --session bk4 --file "$P4")"
assert_eq "bake succeeds" "BAKED $P4 PORT $PORT" "$OUT"
OUT="$(run_in "$ROOT4" strip --file "$P4")"
assert_eq "strip succeeds" "STRIPPED 1" "$OUT"
assert_eq "the page is back to its original bytes" "$PAGE_HTML" "$(cat "$P4")"
for NAME in page.html.bake-tmp page.html.strip-tmp page.html.tmp; do
  assert_eq "$NAME is left as it was" "another writer" "$(cat "$ROOT4/$NAME" 2>/dev/null || echo MISSING)"
done
assert_eq "no other file was left beside the page" "page.html page.html.bake-tmp page.html.strip-tmp page.html.tmp" "$(cd "$ROOT4" && ls | tr '\n' ' ' | sed 's/ $//')"

begin_test "bake and strip leave a page with the mode a new file gets, as they always did"
# mode_of <file> - the permission bits in octal (BSD stat, then GNU stat)
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
P6="$ROOT4/fresh.html"
printf '%s' "$PAGE_HTML" > "$P6"
NEW_MODE="$(mode_of "$P6")"
run_in "$ROOT4" bake --session bk4 --file "$P6" >/dev/null
assert_eq "bake leaves the mode a new file gets" "$NEW_MODE" "$(mode_of "$P6")"
run_in "$ROOT4" strip --file "$P6" >/dev/null
assert_eq "strip leaves the mode a new file gets" "$NEW_MODE" "$(mode_of "$P6")"
rm -f "$P6"

begin_test "two bakes, then two strips, of the same page at once all succeed, 20 rounds each"
new_root; ROOT5="$NEW_ROOT"
arm_session "$ROOT5" --session bk5
P5="$ROOT5/page.html"
printf '%s' "$PAGE_HTML" > "$P5"
BAKE_FAILED=0
for i in $(seq 20); do
  CRAFT_PROJECT_ROOT="$ROOT5" bash "$RUN" bake --session bk5 --file "$P5" >/dev/null 2>&1 & A=$!
  CRAFT_PROJECT_ROOT="$ROOT5" bash "$RUN" bake --session bk5 --file "$P5" >/dev/null 2>&1 & B=$!
  wait "$A" || BAKE_FAILED=$((BAKE_FAILED + 1))
  wait "$B" || BAKE_FAILED=$((BAKE_FAILED + 1))
done
assert_eq "no bake failed" "0 of 40" "$BAKE_FAILED of 40"
assert_eq "the page holds exactly one overlay" "1" "$(grep -c '<script id="ca-overlay">' "$P5" || true)"
assert_eq "no temp file is left beside the page" "page.html" "$(cd "$ROOT5" && ls | tr '\n' ' ' | sed 's/ $//')"
STRIP_FAILED=0
for i in $(seq 20); do
  run_in "$ROOT5" bake --session bk5 --file "$P5" >/dev/null
  CRAFT_PROJECT_ROOT="$ROOT5" bash "$RUN" strip --file "$P5" >/dev/null 2>&1 & A=$!
  CRAFT_PROJECT_ROOT="$ROOT5" bash "$RUN" strip --file "$P5" >/dev/null 2>&1 & B=$!
  wait "$A" || STRIP_FAILED=$((STRIP_FAILED + 1))
  wait "$B" || STRIP_FAILED=$((STRIP_FAILED + 1))
done
assert_eq "no strip failed" "0 of 40" "$STRIP_FAILED of 40"
assert_eq "the page holds no overlay" "$PAGE_HTML" "$(cat "$P5")"
assert_eq "no temp file is left beside the page after the strips" "page.html" "$(cd "$ROOT5" && ls | tr '\n' ' ' | sed 's/ $//')"

finish_tests "test-annotate-bake"
