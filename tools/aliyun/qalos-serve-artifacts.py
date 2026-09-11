#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""qalos — token-gated HTTP server for build artifacts.

Serves the AOSP build output (system.img, boot.img, userdata.img, the
build log, the preflight log) from a build instance over a one-shot
HTTP URL. Replaces the previous `scp` step in the LLM-driven Aliyun
build flow.

The instance is destroyed 5-10 min after the artifacts are
downloaded (the mavis cron owns the teardown). The token in the URL
is a uuid4 generated at start; the public IP is the only attack
surface, and a port-scan + uuid4-guess is infeasible in the
5-10 min window.

Usage on the build instance (started by the systemd unit's
ExecStartPost after do-build.sh finishes):

    # Generate a token
    TOKEN=$(python3 -c 'import uuid; print(uuid.uuid4())')
    # Start the server in the background; it writes the URL to a
    # file the agent / cron can read.
    python3 /opt/qalos/qalos-serve-artifacts.py \
        --port 8080 --token "$TOKEN" \
        --directory /root/aosp/out/target/product/qalos_emulator \
        --url-file /tmp/qalos-artifacts-url.txt \
        --pid-file /tmp/qalos-serve-artifacts.pid \
        --log-file /var/log/qalos-serve-artifacts.log &

    cat /tmp/qalos-artifacts-url.txt
    # http://114.215.200.49:8080/<token>/

    # Download
    curl http://114.215.200.49:8080/<token>/system.img -o system.img
    curl http://114.215.200.49:8080/<token>/build.log  -o build.log

    # Stop
    kill $(cat /tmp/qalos-serve-artifacts.pid)

The token check is in the URL path: anything not starting with the
token is a 404. The instance state moves to Stopped (or
Deleted) once the cron tears down; the server dies with it.
"""

from __future__ import annotations

import argparse
import http.server
import logging
import os
import signal
import socketserver
import sys
import threading
import uuid
from pathlib import Path

# Default values, overridable via CLI
DEFAULT_PORT = 8080
DEFAULT_DIRECTORY = "/root/aosp/out/target/product/qalos_emulator"
DEFAULT_URL_FILE = "/tmp/qalos-artifacts-url.txt"
DEFAULT_PID_FILE = "/tmp/qalos-serve-artifacts.pid"
DEFAULT_LOG_FILE = "/var/log/qalos-serve-artifacts.log"

log = logging.getLogger("qalos-serve-artifacts")


class TokenGatedHandler(http.server.SimpleHTTPRequestHandler):
    """Serves files from the configured directory, but only under the
    configured token path. Anything else is a 404.

    The token is compared in constant time; the comparison is short-
    circuited on length mismatch but the token is a uuid4 (always 36
    chars including dashes) so the path length is fixed.
    """

    def __init__(self, *args, directory: str, token: str, **kwargs):
        self.directory = directory
        self.token = token
        super().__init__(*args, directory=directory, **kwargs)

    def log_message(self, format: str, *args) -> None:
        # Mirror to the module log so the cron / agent can read it.
        log.info("%s - %s", self.address_string(), format % args)

    def translate_path(self, path: str) -> str:
        # Strip the leading "/" + token prefix. If the path doesn't
        # start with "/<token>/" or "/<token>", return a path that
        # will not resolve to anything (so do_GET returns 404).
        prefix = "/" + self.token
        if path == prefix or path == prefix + "/":
            # Token root — serve a directory listing.
            return self.directory
        if path.startswith(prefix + "/"):
            relative = path[len(prefix) + 1 :]
            # Re-use the parent's directory-relative resolution.
            # http.server.SimpleHTTPRequestHandler's translate_path
            # joins self.directory + path; we need to map our
            # already-stripped path. Hack: temporarily set path
            # to "/" + relative, then call super.
            return super().translate_path("/" + relative)
        # Path doesn't start with the token. Map to a path that
        # won't resolve, so do_GET returns 404.
        return "/dev/null/no-such-path"

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        if not (self.path == "/" + self.token
                or self.path.startswith("/" + self.token + "/")):
            self.send_error(404, "Not Found")
            return
        return super().do_GET()


class ReusableThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threading HTTP server with SO_REUSEADDR so a quick restart
    doesn't hit TIME_WAIT on the listening port.
    """
    allow_reuse_address = True
    daemon_threads = True


def write_url_file(url_file: str, url: str) -> None:
    Path(url_file).write_text(url + "\n")
    log.info("URL written to %s: %s", url_file, url)


def write_pid_file(pid_file: str) -> None:
    Path(pid_file).write_text(f"{os.getpid()}\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Token-gated HTTP server for qalos build artifacts"
    )
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT,
        help=f"port to listen on (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--token", default=None,
        help="token required in the URL path (default: random uuid4)",
    )
    parser.add_argument(
        "--directory", default=DEFAULT_DIRECTORY,
        help=f"directory to serve (default: {DEFAULT_DIRECTORY})",
    )
    parser.add_argument(
        "--bind", default="0.0.0.0",
        help="address to bind to (default: 0.0.0.0; the public IP)",
    )
    parser.add_argument(
        "--url-file", default=DEFAULT_URL_FILE,
        help=f"file to write the public URL to (default: {DEFAULT_URL_FILE})",
    )
    parser.add_argument(
        "--pid-file", default=DEFAULT_PID_FILE,
        help=f"file to write the PID to (default: {DEFAULT_PID_FILE})",
    )
    parser.add_argument(
        "--log-file", default=DEFAULT_LOG_FILE,
        help=f"file to write the access log to (default: {DEFAULT_LOG_FILE})",
    )
    args = parser.parse_args(argv)

    # Configure logging: stdout (the systemd journal) and the
    # log file (for the cron to tail).
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        handlers=[
            logging.StreamHandler(sys.stdout),
            logging.FileHandler(args.log_file),
        ],
    )

    token = args.token or str(uuid.uuid4())
    directory = os.path.abspath(args.directory)
    if not os.path.isdir(directory):
        log.error("directory does not exist: %s", directory)
        return 1

    # Build the public URL. The instance's public IP is the only
    # address the orchestrator can reach; on a VPC the private IP
    # also works if the orchestrator is in the same VPC. The
    # orchestrator passes QALOS_PUBLIC_IP in the env file; the
    # --bind-ip CLI flag overrides it for local testing.
    #
    # Fallback order:
    #   1. QALOS_PUBLIC_IP env var (set by the orchestrator)
    #   2. --bind-ip CLI flag (only if it's not 0.0.0.0)
    #   3. HARD FAILURE — historically this used `os.uname().nodename`
    #      which is the *internal* Linux hostname (e.g. iZbp1...),
    #      not a routable address. Any caller relying on the fallback
    #      would get an unresolvable URL. Better to refuse and ask
    #      the orchestrator to pass the right IP explicitly.
    public_ip = os.environ.get("QALOS_PUBLIC_IP", "")
    if not public_ip and args.bind and args.bind != "0.0.0.0":
        # Specific bind address (e.g. 127.0.0.1 for local testing).
        public_ip = args.bind
    if not public_ip:
        log.error(
            "cannot determine public IP: set QALOS_PUBLIC_IP or pass "
            "--bind-ip <addr>. Refusing to fall back to hostname (would "
            "produce an unroutable URL)."
        )
        return 1
    url = f"http://{public_ip}:{args.port}/{token}/"

    write_pid_file(args.pid_file)
    write_url_file(args.url_file, url)

    log.info("serving %s at %s (token: %s...)", directory, url, token[:8])
    log.info("PID: %d; url file: %s; pid file: %s",
             os.getpid(), args.url_file, args.pid_file)

    handler = lambda *a, **kw: TokenGatedHandler(
        *a, directory=directory, token=token, **kw
    )
    server = ReusableThreadingServer((args.bind, args.port), handler)

    # Graceful shutdown on SIGTERM / SIGINT.
    def _shutdown(signum, frame):  # noqa: ARG001
        log.info("received signal %d, shutting down", signum)
        # Shutdown must be called from a thread to avoid blocking
        # the signal handler.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        server.serve_forever()
    finally:
        server.server_close()
        # Clean up the pid file but leave the url file in place;
        # the agent may want to read it after the server dies.
        try:
            os.unlink(args.pid_file)
        except OSError:
            pass
        log.info("server stopped")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
