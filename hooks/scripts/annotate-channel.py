#!/usr/bin/env python3
"""annotate-channel.py - per-session capture listener for page annotations.

A page (often a file:// page, so a null origin) posts the pin set it wants
Claude to read. The listener keeps one file, current.json, and that file only
ever holds one of two things:

  - the body of an explicit POST /pins, written wholesale, or
  - the cleared tombstone written by POST /clear.

No other request writes a pin. GET /events holds a text/event-stream
connection per page and POST /announce pushes a reload event down every held
stream; the stream registry lives in memory only and never touches the file. Nothing is merged: a write never reads the
prior file's pins, and the process remembers only the last sequence number it
wrote, so restarting it cannot bring back a set the user cleared.

Usage: annotate-channel.py --dir <session-dir>

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


def read_last_seq(path):
    """The last sequence number on disk, and nothing else from the file.

    Only the integer is taken so a restarted listener keeps seq monotonic for
    readers polling it; the pins in the file are never loaded.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            seq = json.load(fh).get("seq", 0)
    except (OSError, ValueError, AttributeError):
        return 0
    return seq if isinstance(seq, int) and not isinstance(seq, bool) else 0


class Channel(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, session_dir):
        super().__init__(("127.0.0.1", 0), Handler)
        self.session_dir = session_dir
        self.current_path = os.path.join(session_dir, "current.json")
        self.seq = read_last_seq(self.current_path)
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
        """The only write path: temp file in the same directory, then os.replace."""
        with self.write_lock:
            self.seq += 1
            state = {"seq": self.seq, "cleared": cleared, "pins": pins}
            if sent_at is not None:
                state["sent_at"] = sent_at
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

    def do_GET(self):
        if self.path == "/health":
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
    parser.add_argument("--dir", required=True, help="the session directory holding current.json")
    args = parser.parse_args()

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
