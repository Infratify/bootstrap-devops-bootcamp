# This script is intended to be launched via script.bat,
# which handles execution policy bypass and admin elevation.

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

$ErrorActionPreference = "Stop"

# --- Log file setup ---
$logFile = Join-Path $PSScriptRoot "script.log"
Set-Content -Path $logFile -Value "Bootstrap started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] $Message"
}

# Runs a command and streams all output to the log file.
# Uses -ErrorAction Continue so stderr from native executables (e.g. wsl.exe)
# does not become a terminating error that skips retry logic.
function Invoke-LoggedCommand {
    param([string]$Command)
    Write-Log "Running: $Command"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = Invoke-Expression $Command 2>&1
        if ($output) {
            # Some native executables (e.g. wsl.exe) output UTF-16LE which leaves
            # null bytes when captured. Strip them so the log stays readable.
            $text = ($output | Out-String).Trim() -replace "`0", ""
            if ($text) {
                Add-Content -Path $logFile -Value $text
            }
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
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
        Invoke-LoggedCommand "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
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
    if ($wslFeature -and $wslFeature.State -eq "Enabled") {
        $prevEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        # Check if the WSL platform package is already installed and working
        $wslPkg = Get-AppxPackage -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $wslVersion = (wsl --version 2>&1 | Out-String) -replace "`0", ""
        $ErrorActionPreference = $prevEAP
        $wslWorking = $wslPkg -and ($wslVersion -match "WSL")

        if ($wslWorking) {
            Add-Result "WSL Platform" "Ready"
            Write-Host " done." -ForegroundColor Green
        } else {
            Write-Host " installing..." -ForegroundColor Yellow
            Invoke-LoggedCommand "wsl --install --no-distribution"

            if ($LASTEXITCODE -ne 0) {
                Write-Log "wsl --install failed (exit code $LASTEXITCODE), checking for corrupted WSL package..."
                if ($wslPkg) {
                    Write-Log "Removing corrupted WSL package: $($wslPkg.PackageFullName)"
                    Remove-AppxPackage -Package $wslPkg.PackageFullName -ErrorAction SilentlyContinue
                    Write-Log "Corrupted package removed, retrying WSL install..."
                }
                Invoke-LoggedCommand "wsl --install --no-distribution"
            }

            if ($LASTEXITCODE -ne 0) {
                Add-Result "WSL Platform" "Not Ready"
            } else {
                Add-Result "WSL Platform" "Ready"
            }
        }

        [Console]::OutputEncoding = $prevEncoding
    } else {
        Add-Result "WSL Platform" "Not Ready"
    }
} catch {
    Write-Log "WSL install/update error: $_"
    Add-Result "WSL Platform" "Not Ready"
}

# =====================================================================
# Ubuntu 24.04 LTS
# =====================================================================
$wslReady = (Get-Command wsl -ErrorAction SilentlyContinue) -and ((wsl --status 2>&1) -notmatch "not installed|REGDB")
if ($wslReady) {
    $distros = (wsl -l -q 2>&1 | Out-String) -replace "`0", ""
    if ($distros -match "Ubuntu-24\.04") {
        Add-Result "Ubuntu 24.04 LTS" "Ready"
    } else {
        Write-Host ""
        $answer = Read-Host "Would you like to install Ubuntu 24.04 LTS on WSL? (Y/n)"
        if ($answer -eq "" -or $answer -match "^[Yy]") {
            Write-Host "Installing Ubuntu 24.04 LTS (you will be asked to create a UNIX user)..." -ForegroundColor Yellow
            Write-Log "Running: wsl --install -d Ubuntu-24.04"
            wsl --install -d Ubuntu-24.04
            if ($LASTEXITCODE -eq 0) {
                Add-Result "Ubuntu 24.04 LTS" "Ready"
            } else {
                Add-Result "Ubuntu 24.04 LTS" "Not Ready"
            }
        } else {
            Add-Result "Ubuntu 24.04 LTS" "Not Ready"
        }
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
            Invoke-LoggedCommand "choco install $($pkg.Name) -y"
            Refresh-Path

            if ($LASTEXITCODE -ne 0) {
                Add-Result $pkg.Display "Not Ready"
            } else {
                Add-Result $pkg.Display "Ready"
            }
        } catch {
            Write-Log "Install error ($($pkg.Name)): $_"
            Add-Result $pkg.Display "Not Ready"
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
