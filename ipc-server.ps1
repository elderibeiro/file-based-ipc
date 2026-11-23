<#
ipc-server.ps1 - Machine A (Windows, PowerShell 5.1+).
Polls <share>\inbound for request JSON written by Machine B, runs allowlisted executables,
and writes a response JSON with the same request ID into <share>\responses.

Request  (inbound\<id>.json):   {"id":"<id>","command":"ipconfig","args":["/all"],"timeout_sec":30}
Response (responses\<id>.json): {"id","status":"ok|timeout|rejected|error","exit_code","stdout","stderr",
                                 "error","started_utc","finished_utc","duration_ms"}

File states: <id>.tmp (being written, ignored) -> <id>.json (ready) -> <id>.processing (claimed by A)
             -> archive\ or deleted. Every state change is a same-folder rename, which is atomic on NTFS/SMB.
#>
[CmdletBinding()]
param(
    [string]$ShareRoot = 'D:\share\ipc',   # local path or UNC path of the shared folder
    [int]$PollIntervalMs = 500,
    [int]$DefaultTimeoutSec = 60,
    [int]$MaxTimeoutSec = 600,              # cap on whatever timeout B asks for
    [int]$MaxOutputChars = 1000000,         # cap per stream so responses stay reasonable
    [switch]$DeleteProcessed                # default is to archive processed requests
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Inbound   = Join-Path $ShareRoot 'inbound'
$Responses = Join-Path $ShareRoot 'responses'
$Archive   = Join-Path $ShareRoot 'archive'
$Work      = Join-Path $env:TEMP 'ipc-work'   # local scratch for stdout/stderr capture
foreach ($d in @($Inbound, $Responses, $Archive, $Work)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# Allowlist: the logical name B sends -> full path on A. Nothing else can run.
# Don't add shells (cmd, powershell, pwsh) unless you accept arbitrary code execution from B.
$Allowlist = @{
    'ipconfig' = 'C:\Windows\System32\ipconfig.exe'
    'hostname' = 'C:\Windows\System32\HOSTNAME.EXE'
    'whoami'   = 'C:\Windows\System32\whoami.exe'
    'ping'     = 'C:\Windows\System32\PING.EXE'
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$IdPattern = '^[A-Za-z0-9_-]{1,128}$'   # IDs become filenames, so keep them strict

function Write-Log([string]$Message) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

# Quote one argument using Windows command-line rules. Start-Process joins ArgumentList with plain
# spaces in 5.1, so args containing spaces or quotes would otherwise split or break.
function ConvertTo-WinArg([string]$Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $bsChar = [char]92
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq $bsChar) { $bs++; continue }
        if ($c -eq '"') { [void]$sb.Append($bsChar, 2 * $bs + 1); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append($bsChar, $bs); $bs = 0 }
        [void]$sb.Append($c)
    }
    [void]$sb.Append($bsChar, 2 * $bs)   # double trailing backslashes before the closing quote
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Write to <id>.tmp, then rename to <id>.json so B never reads a half-written file.
function Write-JsonAtomic([string]$Dir, [string]$Id, $Obj) {
    $tmp   = Join-Path $Dir "$Id.tmp"
    $final = Join-Path $Dir "$Id.json"
    [System.IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 5), $Utf8NoBom)
    if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Force }
    [System.IO.File]::Move($tmp, $final)
}

function Read-Capped([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    # Note: console tools write in the OEM code page; non-ASCII output may need re-decoding.
    $t = [System.IO.File]::ReadAllText($Path)
    if ($t.Length -gt $MaxOutputChars) { $t = $t.Substring(0, $MaxOutputChars) + "`n[truncated]" }
    return $t
}

# Archive (default) or delete the claimed request file.
function Complete-Request([string]$ProcessingPath, [string]$Id) {
    try {
        if ($DeleteProcessed) { Remove-Item -LiteralPath $ProcessingPath -Force }
        else {
            $dest = Join-Path $Archive ("{0}.{1}.json" -f $Id, (Get-Date -Format 'yyyyMMddHHmmssfff'))
            Move-Item -LiteralPath $ProcessingPath -Destination $dest -Force
        }
    } catch { Write-Log "WARN could not archive ${ProcessingPath}: $($_.Exception.Message)" }
}

function Invoke-Request($Req, [string]$Id) {
    $started = [DateTime]::UtcNow
    $outFile = Join-Path $Work "$Id.out"
    $errFile = Join-Path $Work "$Id.err"
    $resp = [ordered]@{
        id = $Id; status = 'error'; exit_code = $null; stdout = ''; stderr = ''; error = $null
        started_utc = $started.ToString('o'); finished_utc = $null; duration_ms = $null
    }
    try {
        $cmd = [string]$Req.command
        if (-not $Allowlist.ContainsKey($cmd)) {
            $resp.status = 'rejected'; $resp.error = "command '$cmd' is not allowlisted"
            return $resp
        }
        $exe = $Allowlist[$cmd]

        $argList = @()
        if ($Req.PSObject.Properties['args'] -and $null -ne $Req.args) {
            $argList = @($Req.args | ForEach-Object { [string]$_ })
        }

        $timeout = $DefaultTimeoutSec
        if ($Req.PSObject.Properties['timeout_sec'] -and $Req.timeout_sec) { $timeout = [int]$Req.timeout_sec }
        $timeout = [Math]::Max(1, [Math]::Min($timeout, $MaxTimeoutSec))

        $sp = @{
            FilePath = $exe; NoNewWindow = $true; PassThru = $true
            RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        }
        if ($argList.Count -gt 0) { $sp.ArgumentList = ($argList | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ' }

        $p = Start-Process @sp
        $null = $p.Handle   # cache the handle, or ExitCode can come back empty after exit

        if ($p.WaitForExit($timeout * 1000)) {
            $p.WaitForExit()   # let redirected output finish flushing
            $resp.status = 'ok'
            $resp.exit_code = $p.ExitCode
        } else {
            # Kill the whole process tree, not just the top process.
            & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null
            [void]$p.WaitForExit(5000)
            $resp.status = 'timeout'
            $resp.error = "killed after $timeout s"
        }
        $resp.stdout = Read-Capped $outFile
        $resp.stderr = Read-Capped $errFile
    } catch {
        $resp.status = 'error'
        $resp.error = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        $finished = [DateTime]::UtcNow
        $resp.finished_utc = $finished.ToString('o')
        $resp.duration_ms = [int]($finished - $started).TotalMilliseconds
    }
    return $resp
}

# Crash recovery: a leftover .processing file was mid-run when A stopped.
# Report it as an error instead of re-running it (the command may not be safe to repeat).
Get-ChildItem -LiteralPath $Inbound -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.processing' } | ForEach-Object {
        $id = $_.BaseName
        if ($id -match $IdPattern) {
            Write-JsonAtomic $Responses $id ([ordered]@{ id = $id; status = 'error'; error = 'server restarted while request was processing' })
        }
        Complete-Request $_.FullName $id
    }

Write-Log "Watching $Inbound (allowlist: $($Allowlist.Keys -join ', '))"
while ($true) {
    # Exact extension match, so <id>.tmp files that B is still writing are never picked up.
    $files = @(Get-ChildItem -LiteralPath $Inbound -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.json' } | Sort-Object LastWriteTimeUtc)

    foreach ($f in $files) {
        $id = $f.BaseName
        $processing = Join-Path $Inbound "$id.processing"

        # Atomic claim: fails if the file vanished, is still locked, or another worker took it.
        try { [System.IO.File]::Move($f.FullName, $processing) } catch { continue }

        if ($id -notmatch $IdPattern) {
            Write-Log "Rejecting request with invalid id '$id'"
            Complete-Request $processing 'invalid-id'
            continue
        }

        try {
            $req = [System.IO.File]::ReadAllText($processing) | ConvertFrom-Json
            if ($req.PSObject.Properties['id'] -and [string]$req.id -ne $id) { throw 'id in body does not match filename' }
            Write-Log "Run  $id : $($req.command)"
            $resp = Invoke-Request $req $id
        } catch {
            $resp = [ordered]@{ id = $id; status = 'error'; error = "bad request: $($_.Exception.Message)" }
        }

        try { Write-JsonAtomic $Responses $id $resp } catch { Write-Log "ERROR writing response ${id}: $($_.Exception.Message)" }
        Complete-Request $processing $id
        Write-Log "Done $id -> $($resp.status)"
    }
    Start-Sleep -Milliseconds $PollIntervalMs
}
