#!/usr/bin/env python3
"""annotate-channel.py - per-session capture listener for page annotations.

A page (often a file:// page, so a null origin) posts the pin set it wants
Claude to read. The listener keeps current.json, and that file only ever holds
one of two things:

  - the body of an explicit POST /pins, written wholesale, or
  - the cleared tombstone written by POST /clear.

No other request writes a pin. GET /events holds a text/event-stream
connection per page and POST /announce pushes a reload event down every held
stream; the stream registry lives in memory only and never touches the file. Nothing is merged: a write never reads the
prior file's pins, and the process remembers only the last sequence number it
wrote, so restarting it cannot bring back a set the user cleared.

Beside current.json the listener keeps history.jsonl, an append-only ledger of
every state it wrote (sets and tombstones, one JSON line each, in seq order).
Only the record writer reads it; wait, mockup and dial read current.json alone.

changes.jsonl is the change log, also append-only: each write appends one line
per pin added, edited or deleted (and one per clear), decided once against what
the log already holds, so a resent set adds nothing and a restarted listener
rebuilds that memory by folding the log. A SEND body may be the plain array or
{pins, deleted, probes}; probes are merged into probes.json before any state is
written so a reader woken by the log finds them.

GET /changes holds a stream like /events, in a registry of its own: /health does
not count it and /announce never reaches it. POST /sheet pushes a sheet-changed
event down it; the page answers with POST /applied, and GET /applied long-polls
for that report. GET /session.css serves the session's sheet.

GET /overlay.js serves the overlay script. The listener holds no copy of it:
every request reads the one fence in commands/references/annotate-overlay.md,
so an edit or a plugin update is served on the next load.

Every route refuses (403, the allow-origin header kept, connection closed) a
request whose `token` query value is not the one in <session-dir>/token or
whose Host is not 127.0.0.1 or localhost; the CORS preflight is checked for
Host alone. A request with Transfer-Encoding is answered 411, and a connection
that stalls longer than --socket-timeout is closed.

Usage: annotate-channel.py --dir <session-dir> [--socket-timeout SECONDS]
       annotate-channel.py --print-overlay
       annotate-channel.py --print-clear

--print-overlay writes the same bytes /overlay.js serves to stdout and exits;
it is how the bake command reads the fence without a second parser.
--print-clear does the same for the annotate-clear fence, so review-clear
reads the canonical clear through the one fence reader.

Binds 127.0.0.1 on an OS-assigned port and prints "PORT <n>" to stdout once
it is listening. Python 3.9, standard library only, plus annotate_write.py
beside this file (the one atomic write the annotate scripts share).
"""

import argparse
import hmac
import json
import os
import queue
import re
import secrets
import select
import socket
import sys
import threading
from collections import OrderedDict
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import annotate_write  # found by this file's own directory
del sys.path[0]

MAX_BODY_BYTES = 1024 * 1024
DEFAULT_SOCKET_TIMEOUT = 10.0

ALLOW_ORIGIN = "*"
ALLOW_HEADERS = "Content-Type"
ALLOW_METHODS = "POST, OPTIONS"

# How often a held stream checks its queue and whether the page went away.
STREAM_POLL_SECONDS = 0.25
RELOAD_EVENT = b"event: reload\ndata: reload\n\n"

# Page reports held for a command that asks after them, and how long it may wait.
MAX_HELD_REPORTS = 32
DEFAULT_REPORT_WAIT = 5.0
MAX_REPORT_WAIT = 10.0

# A (page, ts) entry whose pin was withdrawn; it never produces another change.
DELETED = object()


OVERLAY_FENCE_OPEN = "```overlay-source"
CLEAR_FENCE_OPEN = "```annotate-clear"
FENCE_CLOSE = "```"


def fence_source(opener):
    """The fence in the reference that starts at the opener line, read fresh.

    The reference sits beside this script's plugin tree: hooks/scripts and
    commands/references are siblings under the plugin root. Returns the lines
    strictly between the opener and the next bare fence, each ended with a
    newline, or None when the file or either fence line is missing.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", "commands", "references", "annotate-overlay.md")
    try:
        with open(path, "r", encoding="utf-8", newline="") as fh:
            lines = fh.read().split("\n")
    except (OSError, UnicodeDecodeError):
        return None
    try:
        start = lines.index(opener) + 1
    except ValueError:
        return None
    for end in range(start, len(lines)):
        if lines[end] == FENCE_CLOSE:
            return "".join(line + "\n" for line in lines[start:end]).encode("utf-8")
    return None


def overlay_source():
    """The overlay fence, read fresh on every call."""
    return fence_source(OVERLAY_FENCE_OPEN)


def _as_seq(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def read_last_seq(path):
    """The last sequence number on disk, and nothing else from the file.

    Only the integer is taken so a restarted listener keeps seq monotonic for
    readers polling it; the pins in the file are never loaded.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return _as_seq(json.load(fh).get("seq", 0))
    except (OSError, ValueError, AttributeError):
        return 0


def read_history_last_seq(path):
    """The highest seq among the parsable lines of the history; a torn or
    unparsable line is skipped, so a crash mid-append never blocks a restart."""
    last = 0
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    last = max(last, _as_seq(json.loads(line).get("seq", 0)))
                except (ValueError, AttributeError):
                    continue
    except OSError:
        return 0
    return last


def terminate_torn_line(path):
    """A crash can leave the last history line without its newline; end it so
    the next append starts on a line of its own instead of fusing with it."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            if fh.tell() == 0:
                return
            fh.seek(-1, os.SEEK_END)
            torn = fh.read(1) != b"\n"
    except OSError:
        return
    if torn:
        with open(path, "ab") as fh:
            fh.write(b"\n")


def replace_json(path, data):
    """Writes data as JSON through the shared atomic write, synced: a temp file
    of this writer's own in the same folder, then os.replace, so a reader never
    sees it half written and a second process writing the same file never
    shares the temp."""
    annotate_write.write_atomic(path, json.dumps(data), sync=True)


def ts_key(value):
    """A pin's ts as the string every reader keys it by: an integral float
    becomes an int first, so 5, 5.0 and "5" meet. None when unusable."""
    if isinstance(value, bool):
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value) if isinstance(value, (int, str)) and str(value) != "" else None


def compute_changes(latest, seq, pins, deleted):
    """The changes one write makes against what was already logged.

    latest maps (page, ts_key) to the last logged text, or DELETED, and is
    updated in place. A pin not seen before is added, a different text is
    edited, an equal text is nothing; a deleted ts that names a live entry on
    any page is deleted once. The label n renumbers when a pin is deleted, so
    only the text decides an edit.
    """
    changes = []
    for pin in pins:
        if not isinstance(pin, dict) or not isinstance(pin.get("page"), str):
            continue
        key = ts_key(pin.get("ts"))
        if key is None:
            continue
        entry = (pin["page"], key)
        text = pin.get("text")
        if entry not in latest:
            kind = "added"
        elif latest[entry] is DELETED or latest[entry] == text:
            continue
        else:
            kind = "edited"
        latest[entry] = text
        changes.append({"seq": seq, "kind": kind, "page": pin["page"], "ts": key, "pin": pin})
    for raw in deleted:
        key = ts_key(raw)
        if key is None:
            continue
        for entry in [e for e in latest if e[1] == key and latest[e] is not DELETED]:
            latest[entry] = DELETED
            changes.append({"seq": seq, "kind": "deleted", "page": entry[0], "ts": key})
    return changes


def fold_changes(path):
    """Rebuilds the latest-text map from the change log, in order; a line that
    does not parse is skipped."""
    latest = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    change = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(change, dict) or not isinstance(change.get("page"), str):
                    continue
                entry = (change["page"], change.get("ts"))
                if change.get("kind") in ("added", "edited") and isinstance(change.get("pin"), dict):
                    latest[entry] = change["pin"].get("text")
                elif change.get("kind") == "deleted":
                    latest[entry] = DELETED
    except OSError:
        pass
    return latest


class Registry:
    """The held streams of one kind: a set of queues, one per page connection."""

    def __init__(self):
        self.members = set()
        self.lock = threading.Lock()

    def add(self):
        events = queue.Queue()
        with self.lock:
            self.members.add(events)
        return events

    def remove(self, events):
        with self.lock:
            self.members.discard(events)

    def count(self):
        with self.lock:
            return len(self.members)

    def broadcast(self, event):
        """Queues the event for every member; returns how many got it."""
        with self.lock:
            targets = list(self.members)
        for events in targets:
            events.put(event)
        return len(targets)


class Channel(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, session_dir, token, socket_timeout=DEFAULT_SOCKET_TIMEOUT):
        super().__init__(("127.0.0.1", 0), Handler)
        self.session_dir = session_dir
        self.token = token
        self.socket_timeout = socket_timeout
        self.current_path = os.path.join(session_dir, "current.json")
        self.history_path = os.path.join(session_dir, "history.jsonl")
        self.changes_path = os.path.join(session_dir, "changes.jsonl")
        self.probes_path = os.path.join(session_dir, "probes.json")
        terminate_torn_line(self.history_path)
        terminate_torn_line(self.changes_path)
        self.seq = max(read_last_seq(self.current_path), read_history_last_seq(self.history_path))
        self.write_lock = threading.Lock()
        self.latest = fold_changes(self.changes_path)
        self.events = Registry()
        self.change_streams = Registry()
        self.probes_lock = threading.Lock()
        self.reports = OrderedDict()
        self.reports_ready = threading.Condition()

    def client_count(self):
        return self.events.count()

    def broadcast(self, event):
        """Queues the event for every held /events stream; returns how many got it."""
        return self.events.broadcast(event)

    def merge_probes(self, items):
        """Merges probe items into probes.json keyed by ts; an incoming item
        replaces what that ts held. Written whole through a temp file."""
        with self.probes_lock:
            try:
                with open(self.probes_path, "r", encoding="utf-8") as fh:
                    held = json.load(fh)
            except (OSError, ValueError):
                held = {}
            if not isinstance(held, dict):
                held = {}
            for item in items:
                key = ts_key(item.get("ts")) if isinstance(item, dict) else None
                if key is not None:
                    held[key] = item
            replace_json(self.probes_path, held)

    def hold_report(self, report):
        """Keeps a page report by id; the first for an id wins and only the
        newest MAX_HELD_REPORTS are kept."""
        with self.reports_ready:
            if report["id"] not in self.reports:
                self.reports[report["id"]] = report
                while len(self.reports) > MAX_HELD_REPORTS:
                    self.reports.popitem(last=False)
            self.reports_ready.notify_all()

    def wait_report(self, report_id, seconds):
        """The held report for the id, waiting up to seconds for it to arrive."""
        with self.reports_ready:
            self.reports_ready.wait_for(lambda: report_id in self.reports, timeout=seconds)
            return self.reports.get(report_id)

    def replace_state(self, cleared, pins, sent_at=None, deleted=None):
        """The only write path: append to the history, then temp file in the same
        directory and os.replace for current.json, then append the changes this
        write makes to the change log. The history and the change log are only
        ever opened for append, so no restart or write can shorten them."""
        with self.write_lock:
            self.seq += 1
            state = {"seq": self.seq, "cleared": cleared, "pins": pins}
            if sent_at is not None:
                state["sent_at"] = sent_at
            if deleted:
                state["deleted"] = deleted
            with open(self.history_path, "a", encoding="utf-8") as ledger:
                ledger.write(json.dumps(state) + "\n")
                ledger.flush()
                os.fsync(ledger.fileno())
            replace_json(self.current_path, state)
            if cleared:
                changes = [{"seq": self.seq, "kind": "cleared"}]
            else:
                changes = compute_changes(self.latest, self.seq, pins, deleted or [])
            if changes:
                with open(self.changes_path, "a", encoding="utf-8") as log:
                    log.write("".join(json.dumps(c) + "\n" for c in changes))
                    log.flush()
                    os.fsync(log.fileno())
            return self.seq


LOCAL_HOSTS = ("127.0.0.1", "localhost")
HOST_PORT_SUFFIX = re.compile(r":[0-9]+$")


def host_is_local(header):
    """True when the Host header names this machine: 127.0.0.1 or localhost,
    any case, with an optional :port. A browser sends the page's own host, so a
    rebound name (evil.example resolving to 127.0.0.1) never matches."""
    if not header:
        return False
    return HOST_PORT_SUFFIX.sub("", header.strip().lower()) in LOCAL_HOSTS


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        # A stalled client frees its thread: reads and writes on the accepted
        # connection give up after the server's socket timeout.
        self.timeout = self.server.socket_timeout
        super().setup()

    def log_message(self, format, *args):  # noqa: A002 - signature fixed by the base class
        pass

    def _send(self, status, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _refuse(self, status, error):
        """Answers a refused request and closes the connection. The allow-origin
        header stays on the refusal: without it the page's fetch rejects and the
        strip would say BLOCKED BY PAGE instead of NOT ARMED. Bytes the client
        already sent are discarded unread by the handler (never parsed), so
        closing does not reset the connection under the answer."""
        self.close_connection = True
        body = json.dumps({"ok": False, "error": error}).encode("utf-8")
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self._discard_declared_body()

    def _discard_declared_body(self):
        """Drops the body a refused request declared (capped), after the answer
        went out, so the close is a clean FIN rather than a reset."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
            self.connection.shutdown(socket.SHUT_WR)
            remaining = min(max(length, 0), MAX_BODY_BYTES)
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
        except (OSError, ValueError):
            pass

    def _admitted(self, route):
        """True when the request may be served; otherwise it has been answered.
        Checks in order, all before any body is read or any state changes: the
        Host names this machine (defeats DNS rebinding), no Transfer-Encoding
        (the listener frames bodies by Content-Length only), and the token
        query value equals the session's."""
        if not host_is_local(self.headers.get("Host")):
            self._refuse(403, "forbidden")
            return False
        if self.headers.get("Transfer-Encoding") is not None:
            self._refuse(411, "length required")
            return False
        supplied = (parse_qs(route.query).get("token") or [""])[0]
        if not hmac.compare_digest(supplied.encode("utf-8"), self.server.token.encode("utf-8")):
            self._refuse(403, "forbidden")
            return False
        return True

    def _read_body(self):
        """Body bytes, or None after answering 400/413 itself."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, {"ok": False, "error": "bad Content-Length"})
            return None
        if length < 0 or length > MAX_BODY_BYTES:
            self.close_connection = True
            self._send(413, {"ok": False, "error": "body too large"})
            return None
        return self.rfile.read(length) if length else b""

    def do_OPTIONS(self):
        # The preflight URL carries the page's query, but the browser sends no
        # token on a preflight, so only the Host is checked.
        if not host_is_local(self.headers.get("Host")):
            self._refuse(403, "forbidden")
            return
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Access-Control-Allow-Headers", ALLOW_HEADERS)
        self.send_header("Access-Control-Allow-Methods", ALLOW_METHODS)
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _peer_closed(self):
        """True once the page has hung up (EOF or reset on the held socket)."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""
        except (OSError, ValueError):
            return True

    def _write_chunk(self, data):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    def _serve_stream(self, registry):
        """Holds the connection open, writing each event queued on a member of
        the registry and flushing it."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.close_connection = True
        events = registry.add()
        try:
            self._write_chunk(b": connected\n\n")
            while True:
                try:
                    event = events.get(timeout=STREAM_POLL_SECONDS)
                except queue.Empty:
                    if self._peer_closed():
                        return
                    continue
                self._write_chunk(event)
        except (OSError, ValueError):
            return
        finally:
            registry.remove(events)

    def _serve_overlay(self):
        """The overlay fence as a script. Reads the reference per request and
        never touches current.json or history.jsonl."""
        body = overlay_source()
        if body is None:
            self._send(404, {"ok": False, "error": "overlay source not found"})
            return
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Content-Type", "text/javascript; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_session_css(self):
        """The session's sheet, read per request; an absent sheet is empty."""
        try:
            with open(os.path.join(self.server.session_dir, "session.css"), "rb") as fh:
                body = fh.read()
        except OSError:
            body = b""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Content-Type", "text/css; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _serve_applied(self, query):
        """Long-polls for the page report of one sheet job."""
        params = parse_qs(query)
        report_id = (params.get("id") or [""])[0]
        try:
            seconds = float((params.get("wait") or [DEFAULT_REPORT_WAIT])[0])
        except ValueError:
            seconds = DEFAULT_REPORT_WAIT
        seconds = min(max(seconds, 0.0), MAX_REPORT_WAIT)
        report = self.server.wait_report(report_id, seconds)
        if report is None:
            self._send(404, {"ok": False, "error": "no report"})
        else:
            self._send(200, report)

    def do_GET(self):
        route = urlsplit(self.path)
        if not self._admitted(route):
            return
        if route.path == "/applied":
            self._serve_applied(route.query)
        elif route.path == "/overlay.js":
            self._serve_overlay()
        elif route.path == "/health":
            self._send(200, {
                "ok": True,
                "port": self.server.server_address[1],
                "clients": self.server.client_count(),
            })
        elif route.path == "/session.css":
            self._serve_session_css()
        elif route.path == "/events":
            self._serve_stream(self.server.events)
        elif route.path == "/changes":
            self._serve_stream(self.server.change_streams)
        else:
            self._send(404, {"ok": False, "error": "not found"})

    def _json_object_with_id(self, body):
        """The body as a dict with a string id, or None after answering 400."""
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send(400, {"ok": False, "error": "body is not JSON"})
            return None
        if not isinstance(parsed, dict) or not isinstance(parsed.get("id"), str):
            self._send(400, {"ok": False, "error": "body must be an object with a string id"})
            return None
        return parsed

    def do_POST(self):
        route = urlsplit(self.path)
        if not self._admitted(route):
            return
        body = self._read_body()
        if body is None:
            return
        if route.path == "/pins":
            try:
                pins = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._send(400, {"ok": False, "error": "body is not JSON"})
                return
            deleted, probes = [], []
            if isinstance(pins, dict) and isinstance(pins.get("pins"), list):
                body = pins
                pins = body["pins"]
                deleted = body["deleted"] if isinstance(body.get("deleted"), list) else []
                probes = body["probes"] if isinstance(body.get("probes"), list) else []
            elif not isinstance(pins, list):
                self._send(400, {"ok": False, "error": "body must be a JSON array of pins or an object with a pins array"})
                return
            if probes:
                self.server.merge_probes(probes)
            sent_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            seq = self.server.replace_state(False, pins, sent_at, deleted)
            self._send(200, {"ok": True, "seq": seq, "count": len(pins)})
        elif route.path == "/sheet":
            job = self._json_object_with_id(body)
            if job is not None:
                delivered = self.server.change_streams.broadcast(
                    b"event: sheet\ndata: " + json.dumps(job).encode("utf-8") + b"\n\n")
                self._send(200, {"ok": True, "delivered": delivered})
        elif route.path == "/applied":
            report = self._json_object_with_id(body)
            if report is not None:
                self.server.hold_report(report)
                self._send(200, {"ok": True})
        elif route.path == "/clear":
            seq = self.server.replace_state(True, [])
            self._send(200, {"ok": True, "seq": seq, "cleared": True})
        elif route.path == "/announce":
            delivered = self.server.broadcast(RELOAD_EVENT)
            self._send(200, {"ok": True, "delivered": delivered})
        else:
            self._send(404, {"ok": False, "error": "not found"})


TOKEN_FILE = "token"
TOKEN_PATTERN = re.compile(r"^[0-9a-f]{32}$")


def load_or_create_token(session_dir):
    """Return the session's token, creating the file when it does not exist.

    The file is 32 lowercase hex characters, mode 0600, and lives as long as
    the session folder, so a re-armed listener keeps the token that pages and
    baked mockups already carry. A malformed file is replaced atomically.

    A new token is written to a temp file first and only then put at the
    path, so the path never exists half-written: a reader racing a creator
    sees no file or the whole token, never an empty file it would replace."""
    path = os.path.join(session_dir, TOKEN_FILE)
    for _ in range(3):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                existing = handle.read().strip()
            if TOKEN_PATTERN.match(existing):
                return existing
            replace = True
        except FileNotFoundError:
            replace = False
        except OSError:
            replace = True
        token = secrets.token_hex(16)
        # A malformed file is replaced; a missing one gets the exclusive create,
        # which returns False when another caller put its token there first,
        # and the loop then reads that one.
        if not annotate_write.write_atomic(path, token + "\n", exclusive=not replace):
            continue
        return token
    raise OSError("could not settle the session token file")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", help="the session directory holding current.json")
    parser.add_argument("--socket-timeout", type=float, default=DEFAULT_SOCKET_TIMEOUT, metavar="SECONDS",
                        help="seconds a connection may stall before it is closed (default %(default)s)")
    parser.add_argument("--print-overlay", action="store_true", help="print the overlay script and exit")
    parser.add_argument("--print-clear", action="store_true", help="print the canonical annotate clear and exit")
    args = parser.parse_args()

    if args.print_overlay:
        body = overlay_source()
        if body is None:
            sys.stderr.write("annotate-channel: overlay source not found in annotate-overlay.md\n")
            return 1
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
        return 0
    if args.print_clear:
        body = fence_source(CLEAR_FENCE_OPEN)
        if body is None:
            sys.stderr.write("annotate-channel: annotate-clear fence not found in annotate-overlay.md\n")
            return 1
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
        return 0
    if not args.dir:
        parser.error("--dir is required unless --print-overlay or --print-clear is given")

    os.makedirs(args.dir, exist_ok=True)
    # The token file exists before the port is announced, so the arm that reads
    # the port can stamp the token at once. Callers read it from the file.
    token = load_or_create_token(args.dir)
    server = Channel(args.dir, token, args.socket_timeout)
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
