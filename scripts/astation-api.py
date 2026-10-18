#!/usr/bin/env python3
"""Call Astation's opt-in local API without putting its bearer key in argv."""

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", default=os.environ.get("ASTATION_LOCAL_API_TOKEN_FILE"))
    parser.add_argument("--port", type=int, default=8080)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "sessions", "approvals", "approval-rules", "approval-activity"):
        sub.add_parser(name)
    post = sub.add_parser("post")
    post.add_argument("operation", choices=("sessions/acquire", "sessions/renew", "sessions/release", "sessions/submit",
                                            "chat/read", "chat/history", "chat/page",
                                            "approvals/answer", "approval-rules/revoke", "receipts/query"))
    post.add_argument("--file", required=True, help="JSON request file, or - to read stdin")
    args = parser.parse_args()
    if not args.token_file or not 1 <= args.port <= 65535:
        parser.error("set --token-file (or ASTATION_LOCAL_API_TOKEN_FILE) and a valid local port")
    descriptor = os.open(args.token_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise ValueError("token file must be a same-user regular file with mode 0600")
        key = os.read(descriptor, 66).removesuffix(b"\n").decode("ascii")
        if len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
            raise ValueError("token file must contain 32 random bytes as lowercase hexadecimal")
    finally:
        os.close(descriptor)
    path = args.operation if args.command == "post" else args.command
    body = None
    if args.command == "post":
        body = sys.stdin.buffer.read(65537) if args.file == "-" else Path(args.file).read_bytes()
        if len(body) > 65536:
            raise ValueError("request body exceeds 64 KiB")
    request = urllib.request.Request(f"http://127.0.0.1:{args.port}/api/v1/{path}", data=body,
                                     headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    # Do not use proxy settings or follow redirects carrying the local key.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=10) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        print(f"Astation API refused the request (HTTP {error.code}).", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError):
        print("Astation local API is unavailable. Check the running app and API opt-in.", file=sys.stderr)
        return 1
    print(json.dumps(value, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, UnicodeError):
        print("Could not read the protected token or valid JSON request/response.", file=sys.stderr)
        sys.exit(1)
