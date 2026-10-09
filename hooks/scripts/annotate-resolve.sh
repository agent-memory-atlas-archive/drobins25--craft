#!/bin/bash
# annotate-resolve.sh - Pin to source: where does the element a pin points at
# live in this project?
# Usage:
#   annotate-resolve.sh probe   [--root R] --session ID [--target TS=SELECTOR]...
#   annotate-resolve.sh resolve [--root R] --session ID [--target TS=SELECTOR]...   (the probe's result on stdin)
#   annotate-resolve.sh where   [--root R] --session ID --ts TS
#
# probe prints ONE line, a function for evaluate_script, that calls the
# overlay's own walker (window.__craftAnnotateProbe) for each project-page pin
# of the session's current.json: the rules the browser matched on the element
# and the stylesheet each came from - or prints nothing when there is nothing
# to ask the page. It writes nothing. A pin on an external page
# (annotate-run.sh kind) is never probed.
#
# resolve reads the probe's return value on stdin, maps each rule to a project
# file and each component name to a definition, caches the result in
# <session-dir>/resolutions.json, and prints {<ts>: resolution | null}.
#
# A location is recorded only when the winning rule's selector text is found
# literally in a project file. A built bundle, a minified component name, a
# missing definition and an element painted by no rule are each said as such;
# nothing is ever guessed.
#
# where prints exactly one line about a pin, from the cache. On a page outside
# the project it prints the one outside-the-project line and reads no cache.
#
# --target TS=SELECTOR aims a pin's resolution at a different element (an
# ancestor the comment was really about) instead of the pin's own selector.
#
# Exit: 0 on success; 1 on a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "annotate-resolve: $*" >&2
  exit 1
}

# Project root: --root, then CRAFT_PROJECT_ROOT, then the workshop oracle.
resolve_root() {
  local given="${1:-}" found=""
  if [ -n "$given" ]; then
    found="$given"
  elif [ -n "${CRAFT_PROJECT_ROOT:-}" ]; then
    found="$CRAFT_PROJECT_ROOT"
  else
    found="$(source "$SCRIPT_DIR/find-workshop.sh" >/dev/null 2>&1; echo "${PROJECT_ROOT:-}")" || found=""
  fi
  echo "${found%/}"
}

VERB="${1:-}"
case "$VERB" in
  probe|resolve|where) shift ;;
  *) die "usage: annotate-resolve.sh probe|resolve|where [options]" ;;
esac

ROOT_ARG=""
SESSION=""
TS=""
TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    [ $# -ge 2 ] || die "--root needs a value"; ROOT_ARG="$2"; shift 2 ;;
    --session) [ $# -ge 2 ] || die "--session needs a value"; SESSION="$2"; shift 2 ;;
    --ts)      [ $# -ge 2 ] || die "--ts needs a value"; TS="$2"; shift 2 ;;
    --target)  [ $# -ge 2 ] || die "--target needs a value"; TARGETS+=("$2"); shift 2 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

case "$SESSION" in
  ''|*[!A-Za-z0-9_-]*) die "--session <id> is required" ;;
esac
if [ "$VERB" = "where" ]; then
  case "$TS" in
    ''|*[!0-9]*) die "--ts <pin ts> is required" ;;
  esac
fi
for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
  case "$target" in
    [0-9]*=?*) ;;
    *) die "--target must look like TS=SELECTOR" ;;
  esac
done

ROOT="$(resolve_root "$ROOT_ARG")"
[ -n "$ROOT" ] || die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)"
SESSION_DIR="$ROOT/.craft/annotations/$SESSION"
[ -d "$SESSION_DIR" ] || die "no session folder for $SESSION"

read -r -d '' PY_SOURCE <<'PYEOF' || true
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile

verb, root, session_dir, run_sh, ts_arg = sys.argv[1:6]
target_args = sys.argv[6:]

SKIP_DIRS = {"node_modules", ".git", ".craft", "dist", "build", ".next", "out", "coverage"}
STYLE_EXT = (".css", ".scss", ".sass", ".less")
CODE_EXT = (".js", ".jsx", ".ts", ".tsx", ".vue", ".svelte")
OUTSIDE = "That page is outside this project, so there's no source file to point at."
MIN_NAME = 3  # a component name of 2 characters or fewer is a minifier's output


# ---- files -----------------------------------------------------------------

def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def ts_key(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value) if isinstance(value, (int, str)) and str(value) != "" else None


def run_id():
    run = read_json(os.path.join(session_dir, "run.json"), {})
    if not isinstance(run, dict):
        run = {}
    start = run.get("start_seq")
    start = start if isinstance(start, int) and not isinstance(start, bool) else 0
    return "%d@%s" % (start, run.get("started_at") or "")


def empty_cache():
    return {"run": run_id(), "targets": {}, "pins": {}}


def load_cache():
    cache = read_json(os.path.join(session_dir, "resolutions.json"), None)
    if (not isinstance(cache, dict) or cache.get("run") != run_id()
            or not isinstance(cache.get("targets"), dict) or not isinstance(cache.get("pins"), dict)):
        return empty_cache()
    return cache


def save_cache(cache):
    """Write through a temp file of this writer's own, then replace."""
    path = os.path.join(session_dir, "resolutions.json")
    fd, tmp = tempfile.mkstemp(dir=session_dir, prefix="resolutions.json.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(cache, handle)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class cache_lock:
    """An exclusive lock for a load-to-save of the cache. Take it only when no
    subprocess is left to run: the work that needs one happens before."""

    def __enter__(self):
        self.handle = open(os.path.join(session_dir, "resolutions.json.lock"), "w")
        fcntl.flock(self.handle, fcntl.LOCK_EX)

    def __exit__(self, *_):
        self.handle.close()


def current_pins():
    state = read_json(os.path.join(session_dir, "current.json"), {})
    pins = state.get("pins") if isinstance(state, dict) else None
    return [p for p in pins if isinstance(p, dict)] if isinstance(pins, list) else []


_kinds = {}


def is_project_page(page):
    if not isinstance(page, str) or not page:
        return False
    if page not in _kinds:
        result = subprocess.run(["bash", run_sh, "kind", "--page", page], capture_output=True, text=True)
        _kinds[page] = result.stdout.strip() == "project"
    return _kinds[page]


def overrides():
    found = {}
    for raw in target_args:
        key, _, selector = raw.partition("=")
        found[key] = selector
    return found


def target_of(pin, override):
    key = ts_key(pin.get("ts"))
    if key is not None and key in override:
        return override[key]
    selector = pin.get("selector")
    return selector if isinstance(selector, str) and selector else None


# ---- project scans ---------------------------------------------------------

_files = None


def project_files():
    global _files
    if _files is not None:
        return _files
    listed = None
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-co", "--exclude-standard", "-z"],
                             capture_output=True, text=True, timeout=20)
        if out.returncode == 0:
            listed = [p for p in out.stdout.split("\0") if p]
    except (OSError, subprocess.SubprocessError):
        listed = None
    if listed is None:
        listed = []
        for dir_path, dir_names, file_names in os.walk(root):
            dir_names[:] = [d for d in dir_names if d not in SKIP_DIRS]
            for name in file_names:
                listed.append(os.path.relpath(os.path.join(dir_path, name), root).replace(os.sep, "/"))
    _files = sorted(p for p in listed
                    if not (set(p.split("/")[:-1]) & SKIP_DIRS) and os.path.isfile(os.path.join(root, p)))
    return _files


def inside_root(path):
    real_root = os.path.realpath(root)
    real = os.path.realpath(path)
    return real == real_root or real.startswith(real_root + os.sep)


def rel(path):
    return os.path.relpath(os.path.realpath(path), os.path.realpath(root)).replace(os.sep, "/")


# ---- rules -----------------------------------------------------------------

def last_compound(selector):
    depth = 0
    start = 0
    quote = ""
    for i, ch in enumerate(selector):
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif depth == 0 and (ch.isspace() or ch in ">+~"):
            start = i + 1
    return selector[start:]


def is_candidate(selector):
    return bool(re.search(r"[.#\[]", last_compound(selector)))


def specificity(selector):
    text = re.sub(r":where\((?:[^()]|\([^()]*\))*\)", "", selector)
    text = re.sub(r"\[[^\]]*\]", " [a] ", text)
    text = re.sub(r"::?(?:is|not|has|matches)\(", " (", text)
    ids = len(re.findall(r"#[\w-]+", text))
    classes = len(re.findall(r"\.[\w-]+", text)) + text.count("[a]")
    classes += len(re.findall(r"(?<!:):(?!:)[\w-]+", text))
    bare = re.sub(r"::?[\w-]+|#[\w-]+|\.[\w-]+|\[a\]", " ", text)
    types = len(re.findall(r"(?:^|[\s>+~(,])([A-Za-z][\w-]*)", bare)) + len(re.findall(r"::[\w-]+", text))
    return (ids, classes, types)


def find_literal(text, needle):
    """1-indexed line of the first occurrence of needle on an identifier boundary, else None."""
    if not needle:
        return None
    ident = re.compile(r"[\w-]")
    start = 0
    while True:
        at = text.find(needle, start)
        if at < 0:
            return None
        before = text[at - 1] if at > 0 else ""
        after = text[at + len(needle)] if at + len(needle) < len(text) else ""
        if not (before and ident.match(before)) and not (after and ident.match(after)):
            return text.count("\n", 0, at) + 1
        start = at + 1


def url_path(href):
    from urllib.parse import unquote, urlparse
    parsed = urlparse(href)
    return parsed.scheme.lower(), unquote(parsed.path)


def mapped_file(rule):
    """The project file a rule's sheet came from, or None when it cannot be mapped."""
    href = rule.get("href")
    dev = rule.get("devId")
    candidates = []
    if isinstance(href, str) and href:
        scheme, path = url_path(href)
        if scheme == "file":
            candidates.append(path)
        elif scheme in ("http", "https"):
            from urllib.parse import urlparse
            if (urlparse(href).hostname or "").lower() not in ("localhost", "127.0.0.1"):
                return None
            if path.startswith("/@fs/"):
                candidates.append(path[len("/@fs"):])
            else:
                clean = path.lstrip("/")
                candidates += [os.path.join(root, clean), os.path.join(root, "public", clean)]
    elif isinstance(dev, str) and dev:
        candidates.append(dev.split("?", 1)[0])
    for candidate in candidates:
        if os.path.isfile(candidate) and inside_root(candidate):
            return candidate
    return None


def has_source_hint(rule):
    """True when the sheet came with something that could name a file (href or dev id)."""
    return bool(rule.get("href")) or bool(rule.get("devId"))


def resolve_rule(item):
    out = {"rule": None, "rule_file": None, "rule_line": None, "rule_via": None, "rule_matches": None}
    notes = []
    rules = [r for r in item.get("rules") or [] if isinstance(r, dict) and isinstance(r.get("selector"), str)]
    candidates = [r for r in rules if is_candidate(r["selector"])]
    if not candidates:
        blocked = [b for b in item.get("blocked") or []]
        notes.append("unresolved: bundle" if blocked else "no rule")
        return out, notes
    order = lambda r: r["order"] if isinstance(r.get("order"), (int, float)) else 0
    winner = max(candidates, key=lambda r: (specificity(r["selector"]), order(r)))
    selector = winner["selector"]
    out["rule"] = selector
    out["rule_matches"] = winner.get("matches") if isinstance(winner.get("matches"), int) else None
    if not has_source_hint(winner):
        return {**out, "rule": None, "rule_matches": None}, ["no rule"]
    path = mapped_file(winner)
    if path is not None:
        line = find_literal(read_text(path), selector)
        if line is None:
            return {**out, "rule": None, "rule_matches": None}, ["no rule"]
        out.update(rule_file=rel(path), rule_line=line, rule_via="stylesheet")
        return out, notes
    notes.append("unresolved: bundle")
    hits = []
    for name in project_files():
        if name.lower().endswith(STYLE_EXT):
            line = find_literal(read_text(os.path.join(root, name)), selector)
            if line is not None:
                hits.append((name, line))
    if len(hits) == 1:
        out.update(rule_file=hits[0][0], rule_line=hits[0][1], rule_via="class-search")
    return out, notes


# ---- components ------------------------------------------------------------

def map_hits(name):
    index = read_json(os.path.join(root, ".craft", "map", "index.json"), None)
    if not isinstance(index, dict) or index.get("version") != 2 or not isinstance(index.get("areas"), dict):
        return None
    found = {}
    for area in index["areas"].values():
        files = area.get("files") if isinstance(area, dict) else None
        for entry in (files or {}).values():
            for anchor in (entry.get("anchors") if isinstance(entry, dict) else None) or []:
                text = anchor.get("anchor") if isinstance(anchor, dict) else None
                if not isinstance(text, str) or "#" not in text:
                    continue
                path, _, symbol = text.partition("#")
                if symbol == name and os.path.isfile(os.path.join(root, path)):
                    line = anchor.get("startLine")
                    found.setdefault(path, line if isinstance(line, int) else 1)
    return found


def grep_hits(name):
    esc = re.escape(name)
    patterns = [re.compile(r"\bfunction\s*\*?\s+%s\b" % esc), re.compile(r"\bclass\s+%s\b" % esc),
                re.compile(r"\b(?:const|let|var)\s+%s\s*=" % esc)]
    found = {}
    for path in project_files():
        if not path.lower().endswith(CODE_EXT):
            continue
        stem, ext = os.path.splitext(os.path.basename(path))
        if ext.lower() in (".vue", ".svelte") and stem == name:
            found[path] = 1
            continue
        for number, line in enumerate(read_text(os.path.join(root, path)).splitlines(), 1):
            if any(p.search(line) for p in patterns):
                found[path] = number
                break
    return found


def resolve_component(item):
    out = {"component": None, "component_file": None, "component_line": None, "component_via": None}
    name = item.get("component")
    if not isinstance(name, str) or len(name) < MIN_NAME:
        return out, ["no component name"]
    out["component"] = name
    hits = map_hits(name)
    via = "map"
    if not hits:
        hits = grep_hits(name)
        via = "grep"
    if not hits:
        return out, ["component not found"]
    if len(hits) > 1:
        return out, ["component ambiguous"]
    path, line = next(iter(hits.items()))
    out.update(component_file=path, component_line=line, component_via=via)
    return out, []


def resolution_of(item):
    component, c_notes = resolve_component(item)
    rule, r_notes = resolve_rule(item)
    result = {}
    result.update(component)
    result.update(rule)
    result["notes"] = c_notes + r_notes
    return result


# ---- verbs -----------------------------------------------------------------

def cmd_probe():
    cache = load_cache()
    override = overrides()
    wanted = []
    seen = set()
    for pin in current_pins():
        page = pin.get("page")
        key = ts_key(pin.get("ts"))
        selector = target_of(pin, override)
        if key is None or selector is None or not is_project_page(page):
            continue
        if selector in (cache["targets"].get(page) or {}) or (page, key, selector) in seen:
            continue
        seen.add((page, key, selector))
        wanted.append({"page": page, "ts": pin.get("ts"), "selector": selector,
                       "component": pin.get("component") if isinstance(pin.get("component"), str) else None})
    if wanted:
        payload = json.dumps(wanted, ensure_ascii=True, separators=(",", ":"))
        print("() => (typeof window.__craftAnnotateProbe === 'function' ? window.__craftAnnotateProbe(%s) : [])" % payload)


def map_pin(cache, page, key, selector, override):
    """A mapping, once made, stays unless a --target override names that pin."""
    mapped = cache["pins"].setdefault(page, {})
    if key not in mapped or key in override:
        mapped[key] = selector


def cmd_resolve():
    raw = sys.stdin.read().strip()
    try:
        items = json.loads(raw) if raw else []
    except ValueError:
        items = []
    items = [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []
    override = overrides()
    # Everything that may start a subprocess (the page-kind check, the file
    # search) runs before the lock; the locked part only merges and saves.
    found_items = []
    missed = set()
    for item in items:
        page, selector, key = item.get("page"), item.get("selector"), ts_key(item.get("ts"))
        if not isinstance(page, str) or not isinstance(selector, str) or key is None or not is_project_page(page):
            continue
        if item.get("found") is not True:
            missed.add((page, selector))
            continue
        found_items.append((page, selector, key, resolution_of(item)))
    pins = []
    for pin in current_pins():
        page = pin.get("page")
        key = ts_key(pin.get("ts"))
        selector = target_of(pin, override)
        if key is None or selector is None or not is_project_page(page):
            continue
        pins.append((page, key, selector))
    with cache_lock():
        cache = load_cache()
        for page, selector, key, resolution in found_items:
            cache["targets"].setdefault(page, {})[selector] = resolution
            # The item names its own pin, so a pin no longer in current.json
            # still maps. An override that points the pin at another element
            # wins only when this item is that element.
            if key not in override or override[key] == selector:
                map_pin(cache, page, key, selector, override)
        printed = {}
        for page, key, selector in pins:
            cached = (cache["targets"].get(page) or {}).get(selector)
            if cached is not None:
                map_pin(cache, page, key, selector, override)
                printed[key] = cached
            elif (page, selector) in missed:
                printed[key] = None
        save_cache(cache)
    print(json.dumps(printed))


def component_part(res):
    name = res.get("component")
    notes = res.get("notes") or []
    if not name:
        return "no component name"
    if res.get("component_file"):
        return "%s in %s:%s" % (name, res["component_file"], res.get("component_line"))
    if "component ambiguous" in notes:
        return "%s (defined in more than one file)" % name
    return "%s (not found in this project)" % name


def rule_part(res):
    notes = res.get("notes") or []
    rule = res.get("rule")
    if res.get("rule_via") == "stylesheet":
        return "rule %s in %s:%s" % (rule, res["rule_file"], res.get("rule_line"))
    if res.get("rule_via") == "class-search":
        return ("rule %s in %s:%s (found by class name - the browser reported a built bundle)"
                % (rule, res["rule_file"], res.get("rule_line")))
    if "unresolved: bundle" in notes:
        subject = "rule %s" % rule if rule else "the matching rules"
        return "%s %s from a built bundle - no source file found" % (subject, "comes" if rule else "come")
    return "no stylesheet rule - the change belongs in the component"


def cmd_where():
    pin = next((p for p in current_pins() if ts_key(p.get("ts")) == ts_arg), None)
    cache = None
    page = pin.get("page") if pin else None
    if pin is not None:
        if not is_project_page(page):
            print(OUTSIDE)
            return
    else:
        cache = load_cache()
        page = next((pg for pg, by_ts in cache["pins"].items() if ts_arg in by_ts), None)
    cache = cache or load_cache()
    selector = (cache["pins"].get(page) or {}).get(ts_arg) if page else None
    res = (cache["targets"].get(page) or {}).get(selector) if selector else None
    if res is None:
        print("not resolved - the element was not on the page when it was sent")
        return
    print("%s; %s" % (component_part(res), rule_part(res)))


{"probe": cmd_probe, "resolve": cmd_resolve, "where": cmd_where}[verb]()
PYEOF

exec python3 -c "$PY_SOURCE" "$VERB" "$ROOT" "$SESSION_DIR" "$SCRIPT_DIR/annotate-run.sh" "$TS" ${TARGETS[@]+"${TARGETS[@]}"}
