#!/bin/bash
# test-annotate-measure-settle.sh - A live change is measured after the page's fades finish.
#
# The overlay's sheet handler and its settle wait are cut from the one reference file
# that carries its source and run under node with a stubbed sheet fetch, report and
# animation list: the report waits for a running transition to finish, does not wait
# on endless animations or the overlay's own, and gives up at the cap.
# Usage: bash tests/test-annotate-measure-settle.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REF="$PLUGIN_ROOT/commands/references/annotate-overlay.md"

# fenced_block <info-string> <file> - body of the first fence with that info string
fenced_block() {
  awk -v info="$1" '
    $0 == "```" info {inside=1; next}
    inside && $0 == "```" {exit}
    inside {print}
  ' "$2"
}

SRC="$(fenced_block overlay-source "$REF")"

# fn_body <name> - the top-level `  const <name> = ...` block of $SRC, through its closing `  };`
fn_body() {
  printf '%s\n' "$SRC" | awk -v s="  const $1 = " 'index($0, s) == 1 {on=1} on {print} on && $0 == "  };" {exit}'
}

# top_line <prefix> - the first top-level source line starting with the prefix
top_line() { printf '%s\n' "$SRC" | grep -m1 -F -- "  $1" || true; }

HANDLER="$(top_line 'const SETTLE_CAP_MS = ')
$(fn_body fadesDone)
$(fn_body onSheet)"

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: no node binary, measure timing not evaluated"
  finish_tests "test-annotate-measure-settle"
fi

# run_case <case> - runs one sheet event under the named scenario, prints when the report ran
run_case() {
  node -e '
const [code, scenario] = process.argv.slice(1);
const OWN = "#ca-strip";
const start = Date.now();
let reported = null;
let animations = [];
const doc = { getAnimations: () => animations };
const fetchSheet = () => Promise.resolve("/* annotate-key k */\n.card{box-shadow:none}\n");
const report = (job, text, error) => { reported = { ms: Date.now() - start, id: job.id, hasText: text.length > 0, error }; };
const target = own => ({ closest: sel => (own && sel === OWN ? {} : null) });
const anim = (endTime, finishAfter, own) => {
  const a = { playState: "running", effect: { target: target(own), getComputedTiming: () => ({ endTime }) } };
  a.finished = finishAfter == null ? new Promise(() => {}) : new Promise(res => setTimeout(() => res(a), finishAfter));
  return a;
};
const api = new Function("document", "fetchSheet", "report", "OWN",
  code + "\nreturn { onSheet };")(doc, fetchSheet, report, OWN);

if (scenario === "fade") animations = [anim(150, 150)];
if (scenario === "none") animations = [];
if (scenario === "endless") animations = [anim(Infinity, null)];
if (scenario === "own") animations = [anim(150, null, true)];
if (scenario === "cap") animations = [anim(5000, null)];
if (scenario === "finished") animations = [Object.assign(anim(150, 150), { playState: "finished" })];

api.onSheet({ data: JSON.stringify({ id: "job-1", measure: ["k"] }) });
setTimeout(() => {
  if (!reported) { console.log("no report"); return; }
  const ms = reported.ms;
  const bucket = ms < 60 ? "immediate" : ms < 400 ? "after-fade" : ms < 1400 ? "at-cap" : "late";
  console.log(bucket + " " + reported.id + " " + reported.hasText + " " + (reported.error || "ok"));
}, 1600);
' "$HANDLER" "$1" 2>&1 || true
}

begin_test "a change under a running transition is measured once the fade has finished"
assert_eq "report waits for the 150ms fade" "after-fade job-1 true ok" "$(run_case fade)"

begin_test "with nothing animating the change is measured right away"
assert_eq "report runs immediately" "immediate job-1 true ok" "$(run_case none)"

begin_test "an endless animation is not waited on"
assert_eq "report runs immediately" "immediate job-1 true ok" "$(run_case endless)"

begin_test "the overlay's own animations are not waited on"
assert_eq "report runs immediately" "immediate job-1 true ok" "$(run_case own)"

begin_test "an animation already finished is not waited on"
assert_eq "report runs immediately" "immediate job-1 true ok" "$(run_case finished)"

begin_test "a fade longer than the cap is measured at the cap"
assert_eq "report runs at about one second" "at-cap job-1 true ok" "$(run_case cap)"

begin_test "the cap fits inside the listener's report wait"
assert_contains_literal "the cap is one second" "const SETTLE_CAP_MS = 1000;" "$SRC"
assert_contains_literal "the listener holds a report for five seconds" "DEFAULT_REPORT_WAIT = 5.0" "$(cat "$PLUGIN_ROOT/hooks/scripts/annotate-channel.py")"

begin_test "the measure rule states the wait"
assert_contains_literal "rule text names the wait" "once the page's own fades and other finite animations have finished" "$(cat "$REF")"

finish_tests "test-annotate-measure-settle"
