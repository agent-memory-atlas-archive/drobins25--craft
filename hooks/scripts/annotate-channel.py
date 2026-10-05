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

GET /overlay.js serves the overlay script. The listener holds no copy of it:
every request reads the one fence in commands/references/annotate-overlay.md,
so an edit or a plugin update is served on the next load.

Usage: annotate-channel.py --dir <session-dir>
       annotate-channel.py --print-overlay

--print-overlay writes the same bytes /overlay.js serves to stdout and exits;
it is how the bake command reads the fence without a second parser.

Binds 127.0.0.1 on an OS-assigned port and prints "PORT <n>" to stdout once
it is listening. Python 3.9, standard library only.
"""

import argparse
import json
import os
import queue
import select
import socket
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY_BYTES = 1024 * 1024

ALLOW_ORIGIN = "*"
ALLOW_HEADERS = "Content-Type"
ALLOW_METHODS = "POST, OPTIONS"

# How often a held stream checks its queue and whether the page went away.
STREAM_POLL_SECONDS = 0.25
RELOAD_EVENT = b"event: reload\ndata: reload\n\n"


OVERLAY_FENCE_OPEN = "```overlay-source"
OVERLAY_FENCE_CLOSE = "```"


def overlay_source():
    """The overlay fence from the reference, read fresh on every call.

    The reference sits beside this script's plugin tree: hooks/scripts and
    commands/references are siblings under the plugin root. Returns the lines
    strictly between the opening fence and the next bare fence, each ended with
    a newline, or None when the file or either fence line is missing.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", "commands", "references", "annotate-overlay.md")
    try:
        with open(path, "r", encoding="utf-8", newline="") as fh:
            lines = fh.read().split("\n")
    except (OSError, UnicodeDecodeError):
        return None
    try:
        start = lines.index(OVERLAY_FENCE_OPEN) + 1
    except ValueError:
        return None
    for end in range(start, len(lines)):
        if lines[end] == OVERLAY_FENCE_CLOSE:
            return "".join(line + "\n" for line in lines[start:end]).encode("utf-8")
    return None


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


class Channel(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, session_dir):
        super().__init__(("127.0.0.1", 0), Handler)
        self.session_dir = session_dir
        self.current_path = os.path.join(session_dir, "current.json")
        self.history_path = os.path.join(session_dir, "history.jsonl")
        terminate_torn_line(self.history_path)
        self.seq = max(read_last_seq(self.current_path), read_history_last_seq(self.history_path))
        self.write_lock = threading.Lock()
        self.clients = set()
        self.clients_lock = threading.Lock()

    def register_client(self):
        """Adds one held stream; returns the queue its handler thread drains."""
        events = queue.Queue()
        with self.clients_lock:
            self.clients.add(events)
        return events

    def unregister_client(self, events):
        with self.clients_lock:
            self.clients.discard(events)

    def client_count(self):
        with self.clients_lock:
            return len(self.clients)

    def broadcast(self, event):
        """Queues the event for every held stream; returns how many got it."""
        with self.clients_lock:
            targets = list(self.clients)
        for events in targets:
            events.put(event)
        return len(targets)

    def replace_state(self, cleared, pins, sent_at=None):
        """The only write path: append to the history, then temp file in the same
        directory and os.replace for current.json. The history is only ever
        opened for append, so no restart or write can shorten it."""
        with self.write_lock:
            self.seq += 1
            state = {"seq": self.seq, "cleared": cleared, "pins": pins}
            if sent_at is not None:
                state["sent_at"] = sent_at
            with open(self.history_path, "a", encoding="utf-8") as ledger:
                ledger.write(json.dumps(state) + "\n")
                ledger.flush()
                os.fsync(ledger.fileno())
            tmp_path = self.current_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(state, fh)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp_path, self.current_path)
            return self.seq


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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

    def _serve_stream(self):
        """Holds the connection open, writing each queued event and flushing it."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.close_connection = True
        events = self.server.register_client()
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
            self.server.unregister_client(events)

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

    def do_GET(self):
        if self.path == "/overlay.js":
            self._serve_overlay()
        elif self.path == "/health":
            self._send(200, {
                "ok": True,
                "port": self.server.server_address[1],
                "clients": self.server.client_count(),
            })
        elif self.path == "/events":
            self._serve_stream()
        else:
            self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        body = self._read_body()
        if body is None:
            return
        if self.path == "/pins":
            try:
                pins = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._send(400, {"ok": False, "error": "body is not JSON"})
                return
            if not isinstance(pins, list):
                self._send(400, {"ok": False, "error": "body must be a JSON array of pins"})
                return
            sent_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            seq = self.server.replace_state(False, pins, sent_at)
            self._send(200, {"ok": True, "seq": seq, "count": len(pins)})
        elif self.path == "/clear":
            seq = self.server.replace_state(True, [])
            self._send(200, {"ok": True, "seq": seq, "cleared": True})
        elif self.path == "/announce":
            delivered = self.server.broadcast(RELOAD_EVENT)
            self._send(200, {"ok": True, "delivered": delivered})
        else:
            self._send(404, {"ok": False, "error": "not found"})


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", help="the session directory holding current.json")
    parser.add_argument("--print-overlay", action="store_true", help="print the overlay script and exit")
    args = parser.parse_args()

    if args.print_overlay:
        body = overlay_source()
        if body is None:
            sys.stderr.write("annotate-channel: overlay source not found in annotate-overlay.md\n")
            return 1
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
        return 0
    if not args.dir:
        parser.error("--dir is required unless --print-overlay is given")

    os.makedirs(args.dir, exist_ok=True)
    server = Channel(args.dir)
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
