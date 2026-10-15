#!/bin/bash
# test-annotate-pin-follow.sh - Pin markers follow the element they were dropped on.
#
# The overlay's placement functions are cut from the one reference file that carries
# its source and run under node against stubbed element boxes and a stubbed frame
# queue: a live change that shifts an anchor moves its marker by the same amount,
# a pin whose anchor is gone docks as DETACHED, a pin found by its stored path takes
# the look-alike nearest where it was clicked, and the follow loop keeps one frame
# pending at a time and stops once nothing moves.
# Usage: bash tests/test-annotate-pin-follow.sh

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

PLACEMENT="$(top_line 'const FOLLOW_STILL = ')
$(top_line 'let followFrame = ')
$(top_line 'let stillFrames = ')
$(fn_body anchorOf)
$(fn_body placeOf)
$(fn_body place)
$(fn_body anchorAnimating)
$(fn_body follow)
$(fn_body settle)"

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: no node binary, pin placement not evaluated"
  finish_tests "test-annotate-pin-follow"
fi

# run_case <case> - evaluates the placement functions under the named scenario, prints its result
run_case() {
  node -e '
const [code, scenario] = process.argv.slice(1);
const frames = [];
const win = { scrollX: 0, scrollY: 40 };
const strip = { isConnected: true };
const entries = [];
const anchors = {};
let animations = [];
const doc = { getAnimations: () => animations, querySelectorAll: sel => anchors[sel] || [], querySelector: sel => (anchors[sel] || [])[0] || null };
const raf = fn => { frames.push(fn); return frames.length; };
const el = (left, top, width, height) => {
  const box = { left, top, width, height };
  return { box, isConnected: true, getBoundingClientRect: () => ({ left: box.left, top: box.top, right: box.left + box.width, bottom: box.top + box.height, width: box.width, height: box.height }) };
};
const pinNode = () => {
  const set = new Set();
  return { title: "", style: { left: "", top: "", right: "", bottom: "" }, classList: { toggle: (c, on) => { if (on) set.add(c); else set.delete(c); }, contains: c => set.has(c) } };
};
const api = new Function("window", "document", "requestAnimationFrame", "strip", "entries",
  code + "\nreturn { settle: typeof settle === \"function\" ? settle : null, follow: typeof follow === \"function\" ? follow : null };"
)(win, doc, raf, strip, entries);
const runFrames = max => { let n = 0; while (frames.length && n < max) { frames.shift()(); n++; } return n; };

// Avatar at viewport (100, 60) => document (100, 100); the click landed 10px in, 8px down.
// The pin carries no dropped element, as one restored from storage, so its path is looked up.
const avatar = el(100, 60, 80, 80);
anchors[".avatar"] = [avatar];
const pin = { d: { n: 1, text: "x", x: 110, y: 108, selector: ".avatar", box: { x: 100, y: 100, width: 80, height: 80 } }, sent: false, node: pinNode(), el: null };
entries.push(pin);
const at = () => pin.node.style.left + " " + pin.node.style.top;

if (scenario === "static-shift") {
  api.settle();
  const before = at();
  avatar.box.top += 120; avatar.box.left += 24;
  api.settle();
  console.log(before + " -> " + at());
} else if (scenario === "detached") {
  api.settle();
  anchors[".avatar"] = [];
  api.settle();
  console.log([pin.node.classList.contains("ca-detached"), pin.node.style.left, pin.node.style.top, pin.node.style.right, pin.node.style.bottom].join(" "));
} else if (scenario === "nearest-match") {
  // Three look-alike rows at document y 0, 2400 and 4800; the pin was clicked on the middle one.
  anchors[".row"] = [el(100, -40, 80, 80), el(100, 2360, 80, 80), el(100, 4760, 80, 80)];
  pin.d.selector = ".row"; pin.d.box = { x: 100, y: 2400, width: 80, height: 80 }; pin.d.x = 110; pin.d.y = 2408;
  api.settle();
  console.log(at());
} else if (scenario === "dropped-element") {
  // The element the pin was dropped on wins while it is in the page, even over a closer look-alike.
  const mine = el(300, 500, 80, 80);
  anchors[".avatar"] = [avatar, mine];
  pin.el = mine;
  api.settle();
  const held = at();
  mine.isConnected = false;
  api.settle();
  console.log(held + " / " + at());
} else if (scenario === "far-match") {
  // Only look-alikes screens away from the click: the pin holds its click spot, not DETACHED.
  anchors[".avatar"] = [el(100, 3060, 80, 80), el(100, 5060, 80, 80)];
  api.settle();
  console.log(pin.node.classList.contains("ca-detached") + " " + at());
} else if (scenario === "hidden-anchor") {
  api.settle();
  avatar.box.left = 0; avatar.box.top = 0; avatar.box.width = 0; avatar.box.height = 0;
  api.settle();
  console.log(at());
} else if (scenario === "follow-moves") {
  api.settle();
  runFrames(1);
  avatar.box.top += 12;
  runFrames(1);
  console.log(at());
} else if (scenario === "follow-stops") {
  api.settle();
  const ran = runFrames(1000);
  console.log(ran + " " + frames.length);
} else if (scenario === "follow-one-frame") {
  api.settle(); api.settle(); api.follow(); api.follow();
  console.log(frames.length);
} else if (scenario === "follow-animating") {
  animations = [{ playState: "running", effect: { target: { contains: n => n === avatar } } }];
  api.settle();
  const ran = runFrames(200);
  animations = [];
  const after = runFrames(1000);
  console.log(ran + " " + (after < 1000) + " " + frames.length);
} else if (scenario === "follow-strip-gone") {
  api.settle();
  strip.isConnected = false;
  const ran = runFrames(1000);
  console.log(ran + " " + frames.length);
}
' "$PLACEMENT" "$1" 2>&1 || true
}

begin_test "a live change that shifts the anchor moves its marker by the same amount"
assert_eq "marker keeps its offset inside the anchor" "110px 108px -> 134px 228px" "$(run_case static-shift)"

begin_test "a pin whose anchor is gone docks as DETACHED"
assert_eq "detached dock above the strip" "true auto auto 60px 64px" "$(run_case detached)"

begin_test "a pin found by a path that matches many elements takes the one nearest where it was clicked"
assert_eq "marker sits on the middle row, not the first" "110px 2408px" "$(run_case nearest-match)"

begin_test "a pin keeps the element it was dropped on until that element leaves the page"
assert_eq "dropped element first, then the path lookup" "310px 548px / 110px 108px" "$(run_case dropped-element)"

begin_test "a pin whose only look-alikes are screens away holds its click spot"
assert_eq "not detached, drawn at the stored click" "false 110px 108px" "$(run_case far-match)"

begin_test "an anchor that renders no box leaves the marker where it was"
assert_eq "marker holds its last place" "110px 108px" "$(run_case hidden-anchor)"

begin_test "the follow loop re-places a marker when the anchor moves between frames"
assert_eq "marker followed a 12px move" "110px 120px" "$(run_case follow-moves)"

begin_test "the follow loop stops once nothing moves"
assert_eq "ten still frames, then no frame pending" "10 0" "$(run_case follow-stops)"

begin_test "the follow loop keeps one frame pending at a time"
assert_eq "one frame queued after repeated wakes" "1" "$(run_case follow-one-frame)"

begin_test "the follow loop keeps running while an anchor is animating, then stops"
assert_eq "ran the whole sample, stopped after the animation ended" "200 true 0" "$(run_case follow-animating)"

begin_test "the follow loop stops once the overlay is removed"
assert_eq "one frame, nothing rescheduled" "1 0" "$(run_case follow-strip-gone)"

begin_test "animations, transitions and resizes wake the follow loop"
for type in animationstart animationiteration animationend transitionrun transitionstart transitionend; do
  assert_contains_literal "$type wakes the loop" "'$type'" "$SRC"
done
assert_contains_literal "event types are registered through the self-removing handler" "forEach(type => on(document, type, follow, true));" "$SRC"
assert_contains_literal "a resize wakes the loop" "on(window, 'resize', follow, false);" "$SRC"
assert_contains_literal "head changes (the session sheet, dev-server style swaps) re-settle" "watcher.observe(document.head, { childList: true, subtree: true, characterData: true });" "$SRC"

begin_test "the overlay rule states that pins follow their element"
assert_not_contains "no comment says pins sit at page coordinates" "sit at their page coordinates" "$SRC"
assert_not_contains "no paragraph says pins hold page coordinates" "Pins hold their page coordinates" "$(cat "$REF")"
assert_contains_literal "the paragraph states the new rule" "Pins keep the click's offset inside their element's box" "$(cat "$REF")"
assert_contains_literal "the paragraph states the nearest-match rule" "takes the match nearest where it was clicked" "$(cat "$REF")"

finish_tests "test-annotate-pin-follow"
