#!/usr/bin/env python3
"""
ipc_client.py - Machine B (Linux, Python 3.8+).
Sends a command request to Machine A through the shared folder and waits for the response.

Mount the share with attribute caching off (for CIFS, e.g. `actimeo=0`, or `actimeo=1`), or new
response files can take several seconds to show up on Linux.

Usage as a library:
    from ipc_client import run_remote
    result = run_remote("ipconfig", ["/all"], timeout_sec=30)
    print(result["status"], result["exit_code"], result["stdout"])

Usage from the shell:
    IPC_SHARE=/mnt/ipc python3 ipc_client.py ipconfig /all --timeout 30
"""
import argparse
import datetime as _dt
import json
import os
import sys
import time
import uuid

SHARE_ROOT = os.environ.get("IPC_SHARE", "/mnt/ipc")


class RemoteCommandTimeout(TimeoutError):
    """No response arrived from Machine A in time."""


def new_request_id() -> str:
    """UTC timestamp + UUID4: sortable, unique, and a safe filename on NTFS and ext4."""
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return f"{ts}-{uuid.uuid4().hex}"


def _write_json_atomic(folder: str, request_id: str, obj: dict) -> str:
    """Write <id>.tmp (ignored by A), fsync, then rename to <id>.json in the same folder.
    The rename is atomic, so A never sees a partially written request."""
    tmp = os.path.join(folder, f"{request_id}.tmp")
    final = os.path.join(folder, f"{request_id}.json")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, final)
    return final


def _remove_quietly(path: str, attempts: int = 5) -> None:
    """Delete a file, retrying briefly in case Windows still has it open."""
    for _ in range(attempts):
        try:
            os.remove(path)
            return
        except FileNotFoundError:
            return
        except OSError:
            time.sleep(0.2)


def run_remote(command: str, args=(), timeout_sec: int = 60, share_root: str = SHARE_ROOT,
               poll_interval: float = 0.25, grace_sec: float = 15.0) -> dict:
    """Ask Machine A to run an allowlisted command and return its response dict:
    {id, status ('ok'|'timeout'|'rejected'|'error'), exit_code, stdout, stderr, error, ...}.

    Raises RemoteCommandTimeout if nothing comes back within timeout_sec + grace_sec
    (the grace covers A's polling interval and SMB latency)."""
    inbound = os.path.join(share_root, "inbound")
    responses = os.path.join(share_root, "responses")
    request_id = new_request_id()

    request = {
        "id": request_id,
        "command": command,
        "args": [str(a) for a in args],
        "timeout_sec": int(timeout_sec),
        "created_utc": _dt.datetime.now(_dt.timezone.utc).isoformat(),
    }
    req_path = _write_json_atomic(inbound, request_id, request)
    resp_path = os.path.join(responses, f"{request_id}.json")
    deadline = time.monotonic() + timeout_sec + grace_sec

    try:
        while time.monotonic() < deadline:
            if os.path.exists(resp_path):
                try:
                    # utf-8-sig tolerates a BOM if A's writer ever adds one.
                    with open(resp_path, encoding="utf-8-sig") as f:
                        return json.load(f)
                except (json.JSONDecodeError, OSError):
                    pass  # still locked or mid-rename on the Windows side; try again
            time.sleep(poll_interval)

        # Timed out. If A never claimed the request, withdraw it so it can't run later.
        # This is race-safe: if A already renamed it to .processing, the remove fails.
        try:
            os.remove(req_path)
        except FileNotFoundError:
            raise RemoteCommandTimeout(
                f"{request_id}: no response within {timeout_sec + grace_sec:.0f}s (A claimed it)")
        raise RemoteCommandTimeout(f"{request_id}: Machine A never picked up the request (withdrawn)")
    finally:
        _remove_quietly(resp_path)  # clean up our response file


def sweep_stale_responses(share_root: str = SHARE_ROOT, max_age_sec: int = 3600) -> int:
    """Delete response files older than max_age_sec, which is what's left behind when a
    response arrives after the client has already given up. Returns how many were removed."""
    responses = os.path.join(share_root, "responses")
    cutoff = time.time() - max_age_sec
    removed = 0
    for name in os.listdir(responses):
        path = os.path.join(responses, name)
        try:
            if os.path.getmtime(path) < cutoff:
                os.remove(path)
                removed += 1
        except OSError:
            pass
    return removed


def main() -> int:
    ap = argparse.ArgumentParser(description="Run an allowlisted command on Machine A via the shared folder.")
    ap.add_argument("command", help="logical command name from A's allowlist, e.g. ipconfig")
    ap.add_argument("args", nargs=argparse.REMAINDER, help="arguments passed to the command")
    ap.add_argument("--timeout", type=int, default=60, help="per-request timeout in seconds")
    ap.add_argument("--share", default=SHARE_ROOT, help="mount point of the shared folder")
    opts = ap.parse_args()

    try:
        result = run_remote(opts.command, opts.args, timeout_sec=opts.timeout, share_root=opts.share)
    except RemoteCommandTimeout as e:
        print(f"timeout: {e}", file=sys.stderr)
        return 124

    if result.get("stdout"):
        sys.stdout.write(result["stdout"])
    if result.get("stderr"):
        sys.stderr.write(result["stderr"])
    if result.get("status") != "ok":
        print(f"[{result.get('status')}] {result.get('error')}", file=sys.stderr)
        return 125
    return int(result.get("exit_code") or 0)


if __name__ == "__main__":
    sys.exit(main())
