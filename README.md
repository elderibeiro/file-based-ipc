# file-based-ipc

A minimal, file-based remote procedure call (RPC) system that lets a **Linux machine (Machine B)** run **allowlisted Windows commands (Machine A)** through a shared folder (SMB/CIFS mount or similar). No daemons, no ports, no firewall holes — just JSON files exchanged in a shared directory.

Two small scripts, one message protocol:

| File | Runs on | Role |
|---|---|---|
| `ipc-server.ps1` | Windows (PowerShell 5.1+) | Watches the share, runs allowlisted executables, writes responses |
| `ipc_client.py` | Linux (Python 3.8+) | Submits command requests and waits for the JSON response |

## How it works

Communication happens through three folders on the shared mount:

```
share/
├── inbound/      B writes <id>.json requests here
├── responses/    A writes <id>.json responses here
└── archive/      A archives processed requests here (default) unless -DeleteProcessed
```

A request is a small JSON file, e.g.:

```json
{
  "id": "20240521T101530123456Z-4f9c2ab1e3d84a7f",
  "command": "ipconfig",
  "args": ["/all"],
  "timeout_sec": 30
}
```

A response carries the same `id` plus the outcome:

```json
{
  "id": "20240521T101530123456Z-4f9c2ab1e3d84a7f",
  "status": "ok",
  "exit_code": 0,
  "stdout": "...",
  "stderr": "",
  "started_utc": "...",
  "finished_utc": "...",
  "duration_ms": 123
}
```

`status` is one of `ok`, `timeout` (killed after the timeout), `rejected` (command not allowlisted), or `error`.

### Why atomic file renames matter

Every file moves through states via **same-folder atomic renames**, so neither side ever reads a half-written file:

```
<id>.tmp  ->  <id>.json  ->  <id>.processing  ->  archive/ (or deleted)
  (writer)     (ready)        (claimed by A)       (done)
```

- **B** writes to `<id>.tmp`, fsyncs, then renames to `<id>.json`. The server ignores `.tmp` files entirely (exact-extension match).
- **A** claims a request by renaming it to `<id>.processing` — if the move fails, the request was withdrawn or raced, and A skips it.
- If B times out before A picks a request up, B deletes the request file so it can't run later; this is race-safe because A's rename of a claimed file would have made the delete fail.
- If A restarts and finds a leftover `.processing` file, it reports it as an `error` response instead of re-running the command (which might not be safe to repeat).

On the Linux side, mount the CIFS share with attribute caching disabled or near-zero (e.g. `actimeo=0` or `actimeo=1`) or newly written response files may take seconds to become visible.

## Setup

### Machine A (Windows)

1. Point the server at the shared folder (local path or UNC path):

   ```powershell
   .\ipc-server.ps1 -ShareRoot 'D:\share\ipc'
   ```

2. Optionally tune the loop:

   ```powershell
   .\ipc-server.ps1 -ShareRoot '\\fileserver\share\ipc' -PollIntervalMs 250 -MaxTimeoutSec 300
   ```

The allowlist lives in the script. By default only these run:

| Logical name | Executable |
|---|---|
| `ipconfig` | `C:\Windows\System32\ipconfig.exe` |
| `hostname` | `C:\Windows\System32\HOSTNAME.EXE` |
| `whoami` | `C:\Windows\System32\whoami.exe` |
| `ping` | `C:\Windows\System32\PING.EXE` |

Edit `$Allowlist` to add more, mapping a logical name to a full executable path. **Don't add shells (`cmd`, `powershell`, `pwsh`)** unless you're comfortable with Machine B executing arbitrary code on A.

Other defaults: requests B asks for are capped at `-MaxTimeoutSec` (600 s) and stdout/stderr are capped at `-MaxOutputChars` (1 MB per stream).

### Machine B (Linux)

Mount the share, e.g. in `/etc/fstab`:

```
//machine-a/share  /mnt/ipc  cifs  credentials=/etc/smb-creds,uid=1000,actimeo=0  0  0
```

Then either export `IPC_SHARE=/mnt/ipc` or pass `--share /mnt/ipc`.

## Usage examples

### From the shell

```bash
# Simple: run ipconfig /all on Machine A (exit code and streams are forwarded locally)
python3 ipc_client.py ipconfig /all

# With a 30-second timeout and explicit share path
python3 ipc_client.py ping -n 5 8.8.8.8 --timeout 30 --share /mnt/ipc

# Environment variable form
IPC_SHARE=/mnt/ipc python3 ipc_client.py whoami

# Handle timeout (exit code 124) and rejection/error (exit code 125)
python3 ipc_client.py ipconfig || echo "remote call failed"
```

The CLI forwards the remote `stdout`/`stderr` to your local streams and exits with the remote command's exit code, `124` on timeout, or `125` on rejection/error.

### As a Python library

```python
from ipc_client import run_remote, RemoteCommandTimeout, sweep_stale_responses

try:
    result = run_remote("ipconfig", ["/all"], timeout_sec=30)
    print(result["status"], result["exit_code"])
    print(result["stdout"])
except RemoteCommandTimeout as e:
    print(f"no response in time: {e}")

# Housekeeping: remove response files left over from calls that already gave up
print(f"cleaned {sweep_stale_responses()} stale responses")
```

The `run_remote()` return value is the full response dict shown above.

### Client/server behavior at a glance

| Situation | Behavior |
|---|---|---|
| Command not in A's allowlist | `status: rejected`, B exits 125 |
| Command exceeds its timeout | A kills the whole process tree (`taskkill /T /F`), `status: timeout` |
| A never picks up the request | B withdraws it and raises/exits 124 |
| A restarts mid-command | Leftover request reported as `error` (not re-run) |
| Slow stale responses pile up | `sweep_stale_responses()` cleans them (default age > 1 h) |

## Security notes

- Only allowlisted executables run, and only by full path — the `command` field is a lookup key, never a path or shell string.
- Arguments are escaped for Windows command-line rules before being passed to `Start-Process`.
- Anyone with write access to the share can submit requests, so restrict share permissions accordingly; the allowlist is the main defense, but treat the whole channel as trusted-network, not authenticated-by-design.
- Set `Set-StrictMode` and output caps are in place so malformed or huge responses can't wedge the loop.
