# One-line launcher for the DevOps Bootcamp bootstrap.
#
#   irm https://raw.githubusercontent.com/Infratify/bootstrap-devops-bootcamp/main/install.ps1 | iex
#
# It downloads script.ps1 and relaunches it with Administrator rights - the
# Windows equivalent of the sudo re-exec in script-linux.sh.
#
# This is deliberately a separate file from script.ps1, because anything run
# through `iex` has no $PSScriptRoot to resolve paths against, and a bare
# `exit` inside `iex` terminates the user's whole PowerShell session. Keeping
# the launcher tiny and side-effect-free avoids both traps; script.ps1 stays a
# normal script that is always invoked with -File.
#
# The body runs inside & { } so the variables and preferences below stay in a
# child scope instead of leaking into the session that piped this to iex.

& {
    # TLS 1.2 for stock PowerShell 5.1 on older Windows builds, which would
    # otherwise fail to reach raw.githubusercontent.com.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    $repo   = "Infratify/bootstrap-devops-bootcamp"
    $branch = if ($env:BOOTSTRAP_BRANCH) { $env:BOOTSTRAP_BRANCH } else { "main" }
    $url    = "https://raw.githubusercontent.com/$repo/$branch/script.ps1"

    # GetFolderPath, not "$env:USERPROFILE\Desktop" - OneDrive redirects the
    # Desktop on many student machines and the literal path will not exist.
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE "Desktop" }

    $dir  = Join-Path $desktop "bootcamp"
    $dest = Join-Path $dir "script.ps1"

    Write-Host "=== Bootcamp Environment Bootstrap ===" -ForegroundColor Cyan
    Write-Host "Downloading the bootstrap script..." -NoNewline

    try {
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host " failed." -ForegroundColor Red
        Write-Host "Could not download $url" -ForegroundColor Red
        Write-Host "$_" -ForegroundColor DarkGray
        Write-Host "Check your internet connection and try again." -ForegroundColor Yellow
        # return, not exit - exit inside iex would close the user's session.
        return
    }

    Write-Host " done." -ForegroundColor Green
    Write-Host "Saved to $dest" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Click YES on the Administrator prompt to continue." -ForegroundColor Yellow
    Write-Host "The bootstrap runs in a new window - watch that one from here on." -ForegroundColor DarkGray

    try {
        # -NoExit keeps the elevated window open so the summary table stays
        # readable after the run finishes (script.bat used `pause` for this).
        Start-Process powershell -Verb RunAs -ErrorAction Stop -ArgumentList `
            "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$dest`""
    } catch {
        Write-Host ""
        Write-Host "Could not start the elevated window: $_" -ForegroundColor Red
        Write-Host "You can run it yourself - right-click PowerShell, Run as Administrator, then:" -ForegroundColor Yellow
        Write-Host "  & `"$dest`"" -ForegroundColor White
    }
}
