#!/usr/bin/env python3
"""Local KOReader sync server for development and end-to-end checks.

Mirrors the routes, validation, status codes and error bodies of the official
koreader-sync-server controller (github.com/koreader/koreader-sync-server,
app/controllers/1/syncs_controller.lua and config/errors.lua at 46ef6b84a393)
with an in-memory store instead of Redis. It is a test double, not the
official server: use it when the public server is down or for repeatable runs.

    python3 scripts/kosync_dev_server.py [--port 8765] [--no-registration]

Debug builds of Pocket Daily accept http://127.0.0.1:<port> as a server.
"""
import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ERRORS = {
    2001: (401, "Unauthorized"),
    2002: (402, "Username is already registered."),
    2003: (403, "Invalid request"),
    2004: (403, "Field 'document' not provided."),
    2005: (402, "User registration is disabled."),
    2007: (403, "Field 'document' contains characters the read route cannot serve."),
}
SERVABLE = re.compile(r"^[A-Za-z0-9_]+$")


def valid(field):
    return isinstance(field, str) and len(field) > 0


def valid_key(field):
    return valid(field) and ":" not in field


class Store:
    def __init__(self):
        self.lock = threading.Lock()
        self.users = {}
        self.documents = {}


class Handler(BaseHTTPRequestHandler):
    store = Store()
    registration = True
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("kosync:", fmt % args, flush=True)

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, code):
        status, message = ERRORS[code]
        self.reply(status, {"code": code, "message": message})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            parsed = json.loads(self.rfile.read(length) or b"{}")
            return parsed if isinstance(parsed, dict) else {}
        except ValueError:
            return {}

    def authorize(self):
        user, key = self.headers.get("x-auth-user"), self.headers.get("x-auth-key")
        if valid(key) and valid_key(user) and self.store.users.get(user) == key:
            return user
        return None

    def do_GET(self):
        if self.path == "/healthcheck":
            return self.reply(200, {"state": "OK"})
        if self.path == "/users/auth":
            return self.reply(200, {"authorized": "OK"}) if self.authorize() else self.fail(2001)
        match = re.fullmatch(r"/syncs/progress/([A-Za-z0-9_]+)", self.path)
        if match:
            user = self.authorize()
            if not user:
                return self.fail(2001)
            document = match.group(1)
            record = dict(self.store.documents.get((user, document), {}))
            if record:
                record["document"] = document
            return self.reply(200, record)
        self.reply(404, {"message": "Not found"})

    def do_POST(self):
        if self.path != "/users/create":
            return self.reply(404, {"message": "Not found"})
        if not self.registration:
            return self.fail(2005)
        body = self.body()
        username, password = body.get("username"), body.get("password")
        if not valid_key(username) or not valid(password):
            return self.fail(2003)
        with self.store.lock:
            if username in self.store.users:
                return self.fail(2002)
            self.store.users[username] = password
        self.reply(201, {"username": username})

    def do_PUT(self):
        if self.path != "/syncs/progress":
            return self.reply(404, {"message": "Not found"})
        user = self.authorize()
        if not user:
            return self.fail(2001)
        body = self.body()
        document = body.get("document")
        if not valid_key(document):
            return self.fail(2004)
        if not SERVABLE.match(document):
            return self.fail(2007)
        try:
            percentage = float(body.get("percentage"))
        except (TypeError, ValueError):
            percentage = None
        progress, device = body.get("progress"), body.get("device")
        if percentage is None or progress is None or device is None:
            return self.fail(2003)
        timestamp = int(time.time())
        record = {"percentage": percentage, "progress": progress, "device": device, "timestamp": timestamp}
        if body.get("device_id") is not None:
            record["device_id"] = body["device_id"]
        with self.store.lock:
            self.store.documents.setdefault((user, document), {}).update(record)
        self.reply(200, {"document": document, "timestamp": timestamp})


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-registration", action="store_true")
    args = parser.parse_args()
    Handler.registration = not args.no_registration
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"kosync dev server on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
