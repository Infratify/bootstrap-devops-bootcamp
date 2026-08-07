# This script is intended to be launched via script.bat,
# which handles execution policy bypass and admin elevation.

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

$ErrorActionPreference = "Stop"

# script.bat normally elevates; guard against running script.ps1 directly.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host "Double-click script.bat instead - it elevates automatically." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

# --- Log file setup ---
$logFile = Join-Path $PSScriptRoot "script.log"
Set-Content -Path $logFile -Value "Bootstrap started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] $Message"
}

# Runs a command, streams all output to the log file, and returns the exit code.
# Uses -ErrorAction Continue so stderr from native executables (e.g. wsl.exe)
# does not become a terminating error that skips retry logic.
function Invoke-LoggedCommand {
    param([string]$Command)
    Write-Log "Running: $Command"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # Reset first so a throw before the native binary launches cannot leave
        # a stale exit code from an earlier command for the caller to read.
        $global:LASTEXITCODE = 0
        $output = Invoke-Expression $Command 2>&1
        if ($output) {
            # Some native executables (e.g. wsl.exe) output UTF-16LE which leaves
            # null bytes when captured. Strip them so the log stays readable.
            $text = ($output | Out-String).Trim() -replace "`0", ""
            if ($text) {
                Add-Content -Path $logFile -Value $text
            }
        }
    } catch {
        # Invoke-Expression can throw before the native binary ever launches
        # (command not found, parse error). Report failure explicitly - the
        # reset 0 above would otherwise be returned and read as success.
        Write-Log "Command threw: $_"
        $global:LASTEXITCODE = 1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    Write-Log "Exit code: $LASTEXITCODE"
    return $LASTEXITCODE
}

# Runs a native command while showing a spinner and an elapsed-time counter,
# then streams its output to the log and returns the exit code.
#
# Long installs capture their output to the log, which means the console sits
# completely silent for minutes - beginners read that as a freeze and kill the
# window. Start-Process gives a handle to poll so the foreground can animate
# while the install runs.
function Invoke-WithSpinner {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Message
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $frames = @("|", "/", "-", "\")
    $exit = 1

    Write-Log "Running: $FilePath $($ArgumentList -join ' ')"
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
            -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Touching .Handle makes the Process object cache the OS handle. Without
        # it .ExitCode reads back empty once the process has gone, which would
        # report a successful install as a failure with a blank exit code.
        $null = $proc.Handle
        $started = Get-Date
        $i = 0
        while (-not $proc.HasExited) {
            $secs = [int]((Get-Date) - $started).TotalSeconds
            $mins = [int]($secs / 60)
            if ($mins -ge 1) {
                $clock = "{0}m {1:d2}s" -f $mins, ($secs % 60)
            } else {
                $clock = "{0}s" -f $secs
            }
            Write-Host ("`r  {0} {1} ({2}) " -f $frames[$i % 4], $Message, $clock) -NoNewline -ForegroundColor Yellow
            $i++
            Start-Sleep -Milliseconds 150
        }
        $proc.WaitForExit()
        $exit = $proc.ExitCode
        if ($null -eq $exit) {
            Write-Log "Could not read exit code from $FilePath - treating as failure."
            $exit = 1
        }
        # Wipe the spinner line so the next Write-Host starts clean.
        Write-Host ("`r" + (" " * 70) + "`r") -NoNewline
    } catch {
        Write-Host ("`r" + (" " * 70) + "`r") -NoNewline
        Write-Log "Command threw: $_"
        $exit = 1
    } finally {
        foreach ($capture in @($outFile, $errFile)) {
            if (Test-Path $capture) {
                # Same UTF-16LE null-stripping as everywhere else wsl.exe is captured.
                $text = (Get-Content $capture -Raw -ErrorAction SilentlyContinue) -replace "`0", ""
                if ($text -and $text.Trim()) { Add-Content -Path $logFile -Value $text.Trim() }
                Remove-Item $capture -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log "Exit code: $exit"
    return $exit
}

# Refresh PATH helper — picks up changes from installers without restarting the shell
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Log "PATH refreshed."
}

# Summary table tracker
$summary = [System.Collections.ArrayList]::new()

function Add-Result {
    param(
        [string]$Component,
        [string]$Status,
        [string]$Reason
    )
    $summary.Add([PSCustomObject]@{
        Component = $Component
        Status    = $Status
        Reason    = $Reason
    }) | Out-Null
    if ($Reason) {
        Write-Log "$Component : $Status ($Reason)"
    } else {
        Write-Log "$Component : $Status"
    }
}

# =====================================================================
# Windows version / edition detection
# =====================================================================
$winInfo = $null
try {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
    $build = [int]$reg.CurrentBuildNumber
    $ubr = 0
    if ($reg.PSObject.Properties['UBR']) { $ubr = [int]$reg.UBR }
    $editionId = "$($reg.EditionID)"
    $productName = "$($reg.ProductName)"
    $displayVersion = if ($reg.PSObject.Properties['DisplayVersion']) { "$($reg.DisplayVersion)" } else { "$($reg.ReleaseId)" }

    # Win 11 identifies as build >= 22000 even though ProductName may still say "Windows 10"
    $osFamily = if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }
    $isHome = $editionId -match "Core|Home"
    $isServer = $editionId -match "Server"

    $winInfo = [PSCustomObject]@{
        Family         = $osFamily
        ProductName    = $productName
        EditionID      = $editionId
        DisplayVersion = $displayVersion
        Build          = $build
        UBR            = $ubr
        IsHome         = $isHome
        IsServer       = $isServer
    }

    Write-Log "Detected: $osFamily $editionId ($displayVersion) build $build.$ubr"
} catch {
    Write-Log "Windows version detection failed: $_"
}

Write-Host "=== Bootcamp Environment Bootstrap ===" -ForegroundColor Cyan
if ($winInfo) {
    Write-Host "OS:  $($winInfo.Family) $($winInfo.EditionID) $($winInfo.DisplayVersion) (build $($winInfo.Build).$($winInfo.UBR))" -ForegroundColor DarkGray
}
Write-Host "Log: $logFile`n" -ForegroundColor DarkGray

$rebootRequired = $false

# =====================================================================
# Chocolatey
# =====================================================================
Write-Host "Checking Chocolatey..." -NoNewline
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Add-Result "Chocolatey" "Ready"
    Write-Host " done." -ForegroundColor Green
} else {
    try {
        Write-Host " installing..." -ForegroundColor Yellow
        $null = Invoke-LoggedCommand "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
        Refresh-Path

        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Add-Result "Chocolatey" "Ready"
        } else {
            Add-Result "Chocolatey" "Not Ready"
            Write-Host "Please close and reopen PowerShell as Administrator, then run this script again." -ForegroundColor Yellow
            exit 0
        }
    } catch {
        Write-Log "Chocolatey install error: $_"
        Add-Result "Chocolatey" "Not Ready"
        exit 1
    }
}

# =====================================================================
# Applications
# =====================================================================
function Test-Git {
    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Test-WindowsTerminal {
    return [bool](Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction SilentlyContinue)
}

function Test-VSCode {
    return [bool](
        (Get-Command code -ErrorAction SilentlyContinue) -or
        (Test-Path "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe") -or
        (Test-Path "$env:ProgramFiles\Microsoft VS Code\Code.exe")
    )
}

function Test-DockerDesktop {
    return [bool](
        (Get-Command docker -ErrorAction SilentlyContinue) -or
        (Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe")
    )
}

# True only when the WSL platform actually responds - not merely when wsl.exe exists.
# Old inbox wsl.exe does not understand --version and exits non-zero.
# ErrorActionPreference is forced to Continue because 2>&1 on a native binary
# turns stderr into a terminating NativeCommandError under the script's
# default "Stop" preference.
function Test-WslWorking {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { return $false }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $global:LASTEXITCODE = 0
        # wsl.exe emits UTF-16LE; strip the null bytes left behind by the capture.
        $v = (wsl --version 2>&1 | Out-String) -replace "`0", ""
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return ($exit -eq 0 -and $v -match "WSL")
}

# Lists installed distros, tolerating a broken wsl.exe. Returns "" on failure.
function Get-WslDistros {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $list = (wsl -l -q 2>&1 | Out-String) -replace "`0", ""
    } catch {
        $list = ""
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $list
}

# Returns the distro's default UNIX user, or "" if it cannot be determined.
# A distro registered with --no-launch has no account yet and answers "root".
function Get-WslDefaultUser {
    param([string]$Distro)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $global:LASTEXITCODE = 0
        $who = (wsl -d $Distro -- whoami 2>&1 | Out-String) -replace "`0", ""
        if ($LASTEXITCODE -ne 0) { $who = "" }
    } catch {
        $who = ""
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $who.Trim()
}

# Creates the UNIX account inside a registered distro and makes it the default,
# prompting in this console. This is what `wsl --install -d` does on its own,
# except it hands the prompts to a separate window and blocks this script until
# that window is closed - and closing it rather than typing `exit` kills the run
# before any summary row is written. Returns $true on success.
function Initialize-WslUser {
    param([string]$Distro)

    $suggested = ($env:USERNAME -replace "[^A-Za-z0-9_-]", "").ToLower()
    if ($suggested -notmatch "^[a-z_]") { $suggested = "dev$suggested" }
    if ($suggested.Length -gt 32) { $suggested = $suggested.Substring(0, 32) }

    $unixUser = ""
    while (-not $unixUser) {
        $entered = Read-Host "UNIX username (press Enter for '$suggested')"
        if (-not $entered) { $entered = $suggested }
        $entered = $entered.Trim()
        if ($entered -cmatch "^[a-z_][a-z0-9_-]{0,31}$") {
            $unixUser = $entered
        } else {
            Write-Host "  Must start with a lowercase letter or _, then lowercase letters, digits, - or _ (max 32)." -ForegroundColor Yellow
        }
    }

    $plain = ""
    while (-not $plain) {
        $secure1 = Read-Host "Password for '$unixUser'" -AsSecureString
        $secure2 = Read-Host "Confirm password" -AsSecureString
        $bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
        $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
        try {
            $try1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
            $try2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
            if (-not $try1) {
                Write-Host "  Password cannot be empty." -ForegroundColor Yellow
            } elseif ($try1 -cne $try2) {
                Write-Host "  Passwords do not match." -ForegroundColor Yellow
            } else {
                $plain = $try1
            }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
        }
    }

    $ok = $false
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # An existing account means a previous run got partway; carry on and
        # reset its password rather than failing the whole section.
        $global:LASTEXITCODE = 0
        wsl -d $Distro -u root -- id -u $unixUser 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Creating UNIX user '$unixUser' in $Distro"
            $out = (wsl -d $Distro -u root -- useradd -m -s /bin/bash -G sudo $unixUser 2>&1 | Out-String) -replace "`0", ""
            if ($out.Trim()) { Write-Log $out.Trim() }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "useradd failed (exit code $LASTEXITCODE)"
                return $false
            }
        } else {
            Write-Log "UNIX user '$unixUser' already exists in $Distro; resetting password."
        }

        # Piped over stdin so the password never lands on a command line, in the
        # process list, or in this log.
        $global:LASTEXITCODE = 0
        "${unixUser}:${plain}" | wsl -d $Distro -u root -- chpasswd 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "chpasswd failed (exit code $LASTEXITCODE)"
            return $false
        }

        $global:LASTEXITCODE = 0
        $out = (wsl --manage $Distro --set-default-user $unixUser 2>&1 | Out-String) -replace "`0", ""
        if ($out.Trim()) { Write-Log $out.Trim() }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "--set-default-user failed (exit code $LASTEXITCODE)"
            return $false
        }
        $ok = $true
    } catch {
        Write-Log "UNIX user setup error: $_"
        $ok = $false
    } finally {
        $plain = $null
        $ErrorActionPreference = $prevEAP
    }

    if ($ok) { Write-Log "UNIX user '$unixUser' created and set as default for $Distro." }
    return $ok
}

$packages = @(
    @{ Name = "git";                        Display = "Git";              Check = { Test-Git } }
    @{ Name = "microsoft-windows-terminal"; Display = "Windows Terminal"; Check = { Test-WindowsTerminal } }
    @{ Name = "vscode";                     Display = "VS Code";         Check = { Test-VSCode } }
    @{ Name = "docker-desktop";             Display = "Docker Desktop";  Check = { Test-DockerDesktop } }
)

foreach ($pkg in $packages) {
    Write-Host "Checking $($pkg.Display)..." -NoNewline
    if (& $pkg.Check) {
        Add-Result $pkg.Display "Ready"
        Write-Host " done." -ForegroundColor Green
    } else {
        try {
            Write-Host " installing..." -ForegroundColor Yellow
            $exit = Invoke-LoggedCommand "choco install $($pkg.Name) -y"
            Refresh-Path

            if ($exit -eq 3010) {
                # 3010 = success, reboot required (common for docker-desktop)
                $rebootRequired = $true
                Add-Result $pkg.Display "Ready" "installed; reboot required"
            } elseif ($exit -eq 0) {
                Add-Result $pkg.Display "Ready"
            } else {
                Add-Result $pkg.Display "Not Ready" "choco exit code $exit - see script.log"
            }
        } catch {
            Write-Log "Install error ($($pkg.Name)): $_"
            Add-Result $pkg.Display "Not Ready" "$_"
        }
    }
}

# =====================================================================
# Windows Features
# =====================================================================
# MinBuild / RequiresPro gate skipped features with an explicit reason instead of silent "skipped".
# WSL2 + VM Platform need 19041 (Win10 2004). Hyper-V + Containers require Pro/Enterprise/Education.
$features = @(
    @{ Name = "Microsoft-Windows-Subsystem-Linux"; Display = "WSL Feature";              MinBuild = 19041; RequiresPro = $false }
    @{ Name = "VirtualMachinePlatform";            Display = "Virtual Machine Platform"; MinBuild = 19041; RequiresPro = $false }
    @{ Name = "Microsoft-Hyper-V-All";             Display = "Hyper-V";                  MinBuild = 0;     RequiresPro = $true  }
    @{ Name = "Containers";                        Display = "Containers";               MinBuild = 0;     RequiresPro = $true  }
)

function Test-FeatureSupported {
    param($Feature, $WinInfo)
    if (-not $WinInfo) { return @{ Supported = $true; Reason = "" } }
    if ($Feature.RequiresPro -and $WinInfo.IsHome) {
        return @{ Supported = $false; Reason = "requires Pro/Enterprise/Education (detected $($WinInfo.EditionID))" }
    }
    if ($Feature.MinBuild -gt 0 -and $WinInfo.Build -lt $Feature.MinBuild) {
        return @{ Supported = $false; Reason = "requires build $($Feature.MinBuild)+ (detected $($WinInfo.Build))" }
    }
    return @{ Supported = $true; Reason = "" }
}

foreach ($feature in $features) {
    Write-Host "Checking $($feature.Display)..." -NoNewline

    $support = Test-FeatureSupported -Feature $feature -WinInfo $winInfo
    if (-not $support.Supported) {
        Add-Result $feature.Display "Not Supported" $support.Reason
        Write-Host " not supported ($($support.Reason))." -ForegroundColor DarkYellow
        continue
    }

    try {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature.Name -ErrorAction SilentlyContinue
        if (-not $state) {
            $reason = "feature not present in DISM catalog for this edition"
            Add-Result $feature.Display "Not Ready" $reason
            Write-Host " unavailable ($reason)." -ForegroundColor DarkYellow
        } elseif ($state.State -eq "Enabled") {
            Add-Result $feature.Display "Ready"
            Write-Host " done." -ForegroundColor Green
        } else {
            Write-Host " enabling..." -ForegroundColor Yellow
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature.Name -NoRestart -All -ErrorAction Stop -WarningAction SilentlyContinue
            if ($result.RestartNeeded) { $rebootRequired = $true }
            Add-Result $feature.Display "Ready"
        }
    } catch {
        Write-Log "Feature enable error ($($feature.Name)): $_"
        Add-Result $feature.Display "Not Ready" "$_"
        Write-Host " failed." -ForegroundColor Red
    }
}

# =====================================================================
# WSL Platform (the appx/MSI package, separate from the Windows feature)
# =====================================================================
Write-Host "Checking WSL Platform..." -NoNewline
try {
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
    if (-not ($wslFeature -and $wslFeature.State -eq "Enabled")) {
        if ($rebootRequired) {
            Add-Result "WSL Platform" "Pending Reboot" "reboot to finish enabling Windows features, then run this script again"
            Write-Host " pending reboot." -ForegroundColor DarkYellow
        } else {
            Add-Result "WSL Platform" "Not Ready" "WSL Windows feature is not enabled (see WSL Feature row)"
            Write-Host " skipped." -ForegroundColor DarkYellow
        }
    } elseif (Test-WslWorking) {
        Add-Result "WSL Platform" "Ready"
        Write-Host " done." -ForegroundColor Green
    } else {
        Write-Host " installing..." -ForegroundColor Yellow
        $wslPkg = Get-AppxPackage -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue
        $exit = Invoke-LoggedCommand "wsl --install --no-distribution"

        if ($exit -ne 0) {
            Write-Log "wsl --install failed (exit code $exit), cleaning up and retrying with --web-download..."
            if ($wslPkg) {
                Write-Log "Removing possibly corrupted WSL package: $($wslPkg.PackageFullName)"
                Remove-AppxPackage -Package $wslPkg.PackageFullName -ErrorAction SilentlyContinue
            }
            # --web-download bypasses the Microsoft Store, which is blocked on
            # many school/corporate machines.
            $exit = Invoke-LoggedCommand "wsl --install --no-distribution --web-download"
        }

        if ($exit -ne 0) {
            Add-Result "WSL Platform" "Not Ready" "wsl --install failed (exit code $exit) - see script.log"
        } elseif (Test-WslWorking) {
            Add-Result "WSL Platform" "Ready"
        } else {
            # Installed but not responding yet - normal on first install.
            $rebootRequired = $true
            Add-Result "WSL Platform" "Pending Reboot" "installed; reboot, then run this script again"
        }
    }
} catch {
    Write-Log "WSL install/update error: $_"
    Add-Result "WSL Platform" "Not Ready" "$_"
}

# =====================================================================
# Ubuntu 26.04 LTS
# =====================================================================
Write-Host "Checking Ubuntu 26.04 LTS..." -NoNewline
if (-not (Test-WslWorking)) {
    if ($rebootRequired) {
        Add-Result "Ubuntu 26.04 LTS" "Pending Reboot" "reboot, then run this script again"
        Write-Host " pending reboot." -ForegroundColor DarkYellow
    } else {
        Add-Result "Ubuntu 26.04 LTS" "Not Ready" "WSL is not working (see WSL Platform row)"
        Write-Host " skipped." -ForegroundColor DarkYellow
    }
} else {
    $distros = Get-WslDistros
    $installed = ($distros -match "Ubuntu-26\.04")
    $continue = $true

    if (-not $installed) {
        Write-Host ""
        $answer = Read-Host "Would you like to install Ubuntu 26.04 LTS on WSL? (Y/n)"
        if ($answer -eq "" -or $answer -match "^[Yy]") {
            Write-Host "Installing Ubuntu 26.04 LTS. This usually takes 2-5 minutes." -ForegroundColor Yellow
            # --no-launch keeps account setup in this window. Without it wsl.exe
            # opens a separate console for the first-run prompts and blocks here
            # until that console is closed - and closing it rather than typing
            # `exit` ends the run before any summary row is written.
            $exit = Invoke-WithSpinner "wsl" @("--install", "-d", "Ubuntu-26.04", "--no-launch") "Downloading and installing Ubuntu 26.04 LTS"
            # Verify by listing distros again - the exit code alone is not
            # reliable across wsl.exe versions.
            $distros = Get-WslDistros
            $installed = ($distros -match "Ubuntu-26\.04")
            if (-not $installed) {
                Add-Result "Ubuntu 26.04 LTS" "Not Ready" "install did not complete (exit code $exit) - see script.log, or run 'wsl --install -d Ubuntu-26.04' manually"
                Write-Host " failed." -ForegroundColor Red
                $continue = $false
            }
        } else {
            Add-Result "Ubuntu 26.04 LTS" "Skipped" "declined by user"
            Write-Host " skipped." -ForegroundColor DarkYellow
            $continue = $false
        }
    }

    if ($continue) {
        # Registered but still starting as root means account setup never ran:
        # either the --no-launch install just above, or an earlier run that was
        # interrupted partway. Both are finished off here.
        $defaultUser = Get-WslDefaultUser "Ubuntu-26.04"
        if ($defaultUser -and $defaultUser -ne "root") {
            Add-Result "Ubuntu 26.04 LTS" "Ready"
            Write-Host " done." -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "Setting up your Ubuntu account - answer here, no separate window opens." -ForegroundColor Yellow
            if (Initialize-WslUser "Ubuntu-26.04") {
                $defaultUser = Get-WslDefaultUser "Ubuntu-26.04"
                if ($defaultUser -and $defaultUser -ne "root") {
                    Add-Result "Ubuntu 26.04 LTS" "Ready"
                    Write-Host "Ubuntu 26.04 LTS is ready as '$defaultUser'." -ForegroundColor Green
                } else {
                    Add-Result "Ubuntu 26.04 LTS" "Not Ready" "account created but Ubuntu still starts as root - see script.log"
                    Write-Host "Ubuntu 26.04 LTS still starts as root." -ForegroundColor Red
                }
            } else {
                Add-Result "Ubuntu 26.04 LTS" "Not Ready" "installed, but UNIX account setup failed - see script.log, or run 'wsl -d Ubuntu-26.04' to finish it manually"
                Write-Host "Ubuntu account setup failed." -ForegroundColor Red
            }
        }
    }
}

# =====================================================================
# Summary Table
# =====================================================================
function Write-Table {
    param([System.Collections.ArrayList]$Data)

    # Box-drawing characters (PS 5.1 compatible — no `u{} escapes)
    $TL = [char]0x250C; $TR = [char]0x2510  # top-left, top-right
    $BL = [char]0x2514; $BR = [char]0x2518  # bottom-left, bottom-right
    $H  = [string][char]0x2500; $V  = [string][char]0x2502  # horizontal, vertical
    $TJ = [char]0x252C; $BJ = [char]0x2534  # top-junction, bottom-junction
    $LJ = [char]0x251C; $RJ = [char]0x2524  # left-junction, right-junction
    $CJ = [char]0x253C                       # cross-junction

    [int]$w1 = ($Data | ForEach-Object { $_.Component.Length }        | Measure-Object -Maximum).Maximum
    [int]$w2 = ($Data | ForEach-Object { $_.Status.Length }           | Measure-Object -Maximum).Maximum
    [int]$w3 = ($Data | ForEach-Object { ("$($_.Reason)").Length }    | Measure-Object -Maximum).Maximum
    if ($w1 -lt 9)  { $w1 = 9 }
    if ($w2 -lt 13) { $w2 = 13 }
    if ($w3 -lt 6)  { $w3 = 6 }

    $top    = "$TL$($H * ($w1 + 2))$TJ$($H * ($w2 + 2))$TJ$($H * ($w3 + 2))$TR"
    $mid    = "$LJ$($H * ($w1 + 2))$CJ$($H * ($w2 + 2))$CJ$($H * ($w3 + 2))$RJ"
    $bottom = "$BL$($H * ($w1 + 2))$BJ$($H * ($w2 + 2))$BJ$($H * ($w3 + 2))$BR"

    Write-Host $top -ForegroundColor DarkGray
    Write-Host "$V " -NoNewline -ForegroundColor DarkGray
    Write-Host "Component".PadRight($w1) -NoNewline -ForegroundColor White
    Write-Host " $V " -NoNewline -ForegroundColor DarkGray
    Write-Host "Status".PadRight($w2) -NoNewline -ForegroundColor White
    Write-Host " $V " -NoNewline -ForegroundColor DarkGray
    Write-Host "Reason".PadRight($w3) -NoNewline -ForegroundColor White
    Write-Host " $V" -ForegroundColor DarkGray
    Write-Host $mid -ForegroundColor DarkGray

    foreach ($row in $Data) {
        $color = switch ($row.Status) {
            "Ready"         { "Green" }
            "Not Ready"     { "Red" }
            "Not Supported" { "DarkYellow" }
            default         { "Yellow" }
        }
        $reasonText = "$($row.Reason)"
        Write-Host "$V " -NoNewline -ForegroundColor DarkGray
        Write-Host $row.Component.PadRight($w1) -NoNewline
        Write-Host " $V " -NoNewline -ForegroundColor DarkGray
        Write-Host $row.Status.PadRight($w2) -NoNewline -ForegroundColor $color
        Write-Host " $V " -NoNewline -ForegroundColor DarkGray
        Write-Host $reasonText.PadRight($w3) -NoNewline -ForegroundColor DarkGray
        Write-Host " $V" -ForegroundColor DarkGray
    }

    Write-Host $bottom -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ""
Write-Table $summary
Write-Host ""

$unsupported = $summary | Where-Object { $_.Status -eq "Not Supported" }
if ($unsupported) {
    Write-Host "Note: " -NoNewline -ForegroundColor Cyan
    Write-Host "$(($unsupported | ForEach-Object { $_.Component }) -join ', ') unavailable on this Windows edition." -ForegroundColor White
    Write-Host "      WSL + Docker Desktop alone are sufficient for the bootcamp." -ForegroundColor DarkGray
    Write-Host ""
}

if ($rebootRequired) {
    Write-Host "** A REBOOT IS REQUIRED to finish enabling Windows features. **" -ForegroundColor Red
    Write-Host "Please restart your machine, then run this script again." -ForegroundColor Yellow
} else {
    Write-Host "Restart your terminal for all changes to take effect." -ForegroundColor White
}

Write-Host "Log: $logFile`n" -ForegroundColor DarkGray
Write-Log "Bootstrap finished."
