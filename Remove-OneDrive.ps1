<#
.SYNOPSIS
    Completely removes OneDrive from a Windows 10/11 PC and points the user
    folders (Desktop, Documents, Pictures, Music, Videos, Screenshots) back to
    their normal local locations under C:\Users\<you>.

.DESCRIPTION
    Fresh Windows installs ship with OneDrive pre-installed and, if you sign in
    with a Microsoft account, it quietly moves Desktop/Documents/Pictures into
    C:\Users\<you>\OneDrive\... ("Known Folder Backup"). Uninstalling OneDrive
    through Settings does NOT undo that redirection, which is why Explorer then
    throws "Location is not available" errors and Pictures opens an empty
    OneDrive folder.

    This script does the full job, in this order:

      1. Stops every OneDrive process.
      2. Uninstalls OneDrive (per-user and machine-wide installs, plus the
         Store/Appx package if present).
      3. Repoints the known folders to the local paths and makes sure those
         folders exist.
      4. Rescues any files still inside the OneDrive folder into the matching
         local folder (never overwrites a file that already exists locally).
      5. Removes the "OneDrive - Personal" sidebar entry, the startup entry,
         the scheduled update tasks, and the OneDrive environment variables.
      6. Stops Windows from re-installing OneDrive for this and future user
         accounts (Default-user hive + group policy key).
      7. Deletes the leftover OneDrive folders and program files.
      8. Restarts Explorer and prints a verification report.

    Nothing in your OneDrive cloud account is touched. Only the local copy is
    removed, and anything found in it is moved to the local user folders first.

.PARAMETER CheckOnly
    Report the current state without changing anything.

.PARAMETER KeepFiles
    Do not delete the C:\Users\<you>\OneDrive folder after rescuing files.
    Use this if you want to look through what was in it yourself.

.PARAMETER SkipUninstall
    Only fix the folder locations and Explorer; leave the OneDrive program
    installed. Useful if you only want to undo Known Folder Backup.

.EXAMPLE
    .\Remove-OneDrive.ps1 -CheckOnly
    Show what would be changed.

.EXAMPLE
    .\Remove-OneDrive.ps1
    Do everything. Prompts for admin rights (UAC) if needed.

.NOTES
    Run from a normal PowerShell window; the script relaunches itself elevated.
    Tested on Windows 11 Home 24H2 / 25H2. Should work on Windows 10 too.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$KeepFiles,
    [switch]$SkipUninstall
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step($msg)  { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "   [ok]   $msg" -ForegroundColor Green }
function Write-Skip($msg)  { Write-Host "   [skip] $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg) { Write-Host "   [warn] $msg" -ForegroundColor Yellow }
function Write-Bad($msg)   { Write-Host "   [bad]  $msg" -ForegroundColor Red }

# Read one registry value, or $null if the key or value doesn't exist.
function Get-RegValue($path, $name) {
    $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $prop = $item.PSObject.Properties[$name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch elevated if needed. Elevation is only required for the uninstall
# and the machine-wide "don't reinstall" settings, but doing everything in one
# elevated run keeps the script simple.
if (-not $CheckOnly -and -not (Test-Admin)) {
    Write-Host "Requesting administrator rights..." -ForegroundColor Yellow
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($KeepFiles)     { $args += '-KeepFiles' }
    if ($SkipUninstall) { $args += '-SkipUninstall' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args -Wait
    exit
}

# When elevated via UAC the profile is the same user, so $env:USERPROFILE is
# still correct. Guard anyway in case someone runs it from an admin account on
# behalf of another user -- that is not supported.
$User     = $env:USERPROFILE
$OneDrive = Join-Path $User 'OneDrive'
$USF      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$SF       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$NsClsid  = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'   # "OneDrive - Personal" sidebar node

# Known folders Windows/OneDrive may redirect.
#   Key   = value name in "User Shell Folders"
#   Local = where it should live
#   SF    = also write the old-style "Shell Folders" value (Windows keeps both)
$KnownFolders = @(
    @{ Key = 'Desktop';                                Local = "$User\Desktop";                SF = $true  }
    @{ Key = 'Personal';                               Local = "$User\Documents";              SF = $true  }
    @{ Key = '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'; Local = "$User\Documents";              SF = $false }  # Local Documents
    @{ Key = 'My Pictures';                            Local = "$User\Pictures";               SF = $true  }
    @{ Key = '{0DDD015D-B06C-45D5-8C4C-F59713854639}'; Local = "$User\Pictures";               SF = $false }  # Local Pictures
    @{ Key = 'My Music';                               Local = "$User\Music";                  SF = $true  }
    @{ Key = '{A0C69A99-21C8-4671-8703-7934162FCF1D}'; Local = "$User\Music";                  SF = $false }  # Local Music
    @{ Key = 'My Video';                               Local = "$User\Videos";                 SF = $true  }
    @{ Key = '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'; Local = "$User\Videos";                 SF = $false }  # Local Videos
    @{ Key = '{B7BEDE81-DF94-4682-A7D8-57A52620B86F}'; Local = "$User\Pictures\Screenshots";   SF = $false }  # Screenshots
    @{ Key = '{AB5FB87B-7CE2-4F83-915D-550846C9537B}'; Local = "$User\Pictures\Camera Roll";   SF = $false }  # Camera Roll
)

# ---------------------------------------------------------------------------
# Check-only report
# ---------------------------------------------------------------------------
function Show-State {
    Write-Step "Current state"

    $procs = Get-Process -Name 'OneDrive*', 'FileCoAuth' -ErrorAction SilentlyContinue
    if ($procs) { Write-Bad "OneDrive is running ($($procs.Count) process(es))" } else { Write-Ok "OneDrive is not running" }

    $exes = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
              "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
              "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") | Where-Object { Test-Path $_ }
    if ($exes) { $exes | ForEach-Object { Write-Bad "Installed: $_" } } else { Write-Ok "OneDrive program not installed" }

    if (Get-AppxPackage -Name '*OneDrive*' -ErrorAction SilentlyContinue) { Write-Bad "OneDrive Store package present" } else { Write-Ok "No OneDrive Store package" }

    foreach ($kf in $KnownFolders) {
        $cur = Get-RegValue $USF $kf.Key
        if ($null -eq $cur) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($cur)
        if ($expanded -like '*OneDrive*') { Write-Bad "$($kf.Key) -> $expanded" } else { Write-Ok "$($kf.Key) -> $expanded" }
    }

    if (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$NsClsid") { Write-Bad "Sidebar entry 'OneDrive - Personal' present" } else { Write-Ok "No sidebar entry" }
    if (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'OneDrive') { Write-Bad "Startup entry present" } else { Write-Ok "No startup entry" }
    # Read the stored value, not $env:OneDrive -- an open shell keeps the old
    # value in its own environment until it is restarted.
    $envOd = [Environment]::GetEnvironmentVariable('OneDrive', 'User')
    if ($envOd) { Write-Bad "OneDrive environment variable set ($envOd)" } else { Write-Ok "No OneDrive environment variable" }

    if (Test-Path $OneDrive) {
        $n = (Get-ChildItem $OneDrive -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini' | Measure-Object).Count
        Write-Bad "$OneDrive exists ($n file(s) inside)"
    } else { Write-Ok "No local OneDrive folder" }

    if ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC') -eq 1) { Write-Ok "Policy blocks OneDrive from coming back" } else { Write-Warn2 "No policy blocking reinstall (Windows updates can bring OneDrive back)" }
}

if ($CheckOnly) { Show-State; exit 0 }

# ---------------------------------------------------------------------------
# 1. Stop OneDrive
# ---------------------------------------------------------------------------
Write-Step "Stopping OneDrive"
Get-Process -Name 'OneDrive*', 'FileCoAuth', 'FileSyncHelper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2
Write-Ok "Done"

# ---------------------------------------------------------------------------
# 2. Uninstall
# ---------------------------------------------------------------------------
if ($SkipUninstall) {
    Write-Step "Uninstall skipped (-SkipUninstall)"
} else {
    Write-Step "Uninstalling OneDrive"

    # Every place Microsoft has put OneDriveSetup.exe over the years.
    $setups = @(
        Get-ChildItem "$env:ProgramFiles\Microsoft OneDrive" -Recurse -Filter OneDriveSetup.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft OneDrive" -Recurse -Filter OneDriveSetup.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe"
        Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Filter OneDriveSetup.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        "$env:SystemRoot\System32\OneDriveSetup.exe"
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    if (-not $setups) {
        Write-Skip "No OneDriveSetup.exe found; program already gone"
    } else {
        foreach ($setup in $setups) {
            foreach ($argset in @('/uninstall /allusers', '/uninstall')) {
                $p = Start-Process $setup -ArgumentList $argset -PassThru -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
                if ($p) { Write-Ok "$setup $argset (exit $($p.ExitCode))" }
            }
        }
    }

    Get-AppxPackage -Name '*OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
        Write-Ok "Removed Store package $($_.Name)"
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -like '*OneDrive*' | ForEach-Object {
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "Removed provisioned package $($_.DisplayName)"
    }
}

# ---------------------------------------------------------------------------
# 3. Repoint known folders
# ---------------------------------------------------------------------------
Write-Step "Pointing user folders back to $User"
foreach ($kf in $KnownFolders) {
    $cur = Get-RegValue $USF $kf.Key
    # Only touch values that exist and currently point into OneDrive, or that
    # are the core six (Windows expects those to always be present).
    $core = $kf.Key -in 'Desktop', 'Personal', 'My Pictures', 'My Music', 'My Video'
    if ($null -eq $cur -and -not $core) { continue }
    $expanded = if ($cur) { [Environment]::ExpandEnvironmentVariables($cur) } else { '' }
    # Leave any value alone that already points somewhere outside OneDrive --
    # the user may have moved a folder on purpose (e.g. Pictures on D:).
    if ($cur -and $expanded -notlike '*OneDrive*') { Write-Skip "$($kf.Key) already local ($expanded)"; continue }

    New-Item -ItemType Directory -Force $kf.Local | Out-Null
    # Store with %USERPROFILE% so the profile stays portable, like Windows does.
    $stored = $kf.Local.Replace($User, '%USERPROFILE%')
    Set-ItemProperty $USF -Name $kf.Key -Value $stored -Type ExpandString
    if ($kf.SF) { Set-ItemProperty $SF -Name $kf.Key -Value $kf.Local -Type String }
    Write-Ok "$($kf.Key) -> $($kf.Local)"
}

# ---------------------------------------------------------------------------
# 4. Rescue files from the OneDrive folder
# ---------------------------------------------------------------------------
Write-Step "Rescuing files from $OneDrive"
if (-not (Test-Path $OneDrive)) {
    Write-Skip "Folder does not exist"
} else {
    $rescued = 0; $kept = 0
    Get-ChildItem $OneDrive -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'desktop.ini' } |
        ForEach-Object {
            # OneDrive\Pictures\x.png -> <profile>\Pictures\x.png, etc.
            $rel  = $_.FullName.Substring($OneDrive.Length + 1)
            $dest = Join-Path $User $rel
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            if (Test-Path $dest) {
                # Same name already exists locally: keep both, rename the OneDrive one.
                $dest = Join-Path (Split-Path $dest) ("$($_.BaseName) (from OneDrive)$($_.Extension)")
                $kept++
            }
            Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            $rescued++
        }
    Write-Ok "$rescued file(s) moved into $User ($kept renamed because a local copy already existed)"
}

# ---------------------------------------------------------------------------
# 5. Explorer sidebar, startup, scheduled tasks, env vars
# ---------------------------------------------------------------------------
Write-Step "Removing Explorer / startup leftovers"
foreach ($key in @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$NsClsid",
    "HKCU:\Software\Classes\CLSID\$NsClsid",
    "HKCU:\Software\Classes\Wow6432Node\CLSID\$NsClsid",
    "HKLM:\SOFTWARE\Classes\CLSID\$NsClsid",
    "HKLM:\SOFTWARE\Classes\Wow6432Node\CLSID\$NsClsid",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$NsClsid"
)) {
    if (Test-Path $key) { Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue; Write-Ok "Removed $key" }
}

Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
Write-Ok "Startup entries removed"

Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object TaskName -like '*OneDrive*' | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok "Removed scheduled task $($_.TaskName)"
}

foreach ($v in 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') {
    [Environment]::SetEnvironmentVariable($v, $null, 'User')
    [Environment]::SetEnvironmentVariable($v, $null, 'Process')
}
Write-Ok "Environment variables cleared"

# ---------------------------------------------------------------------------
# 6. Stop it coming back
# ---------------------------------------------------------------------------
Write-Step "Blocking reinstall"

# Group-policy switch Windows honours even on Home edition.
$polKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
New-Item -Path $polKey -Force | Out-Null
Set-ItemProperty $polKey -Name 'DisableFileSyncNGSC' -Value 1 -Type DWord
Set-ItemProperty $polKey -Name 'DisableFileSync'     -Value 1 -Type DWord
Write-Ok "Policy set: DisableFileSyncNGSC = 1"

# Windows installs OneDrive for every NEW user account via a Run entry in the
# Default user's registry hive. Load that hive, remove the entry, unload it.
$defaultHive = "$env:SystemDrive\Users\Default\NTUSER.DAT"
if (Test-Path $defaultHive) {
    & reg.exe load 'HKU\DefaultUserTemp' $defaultHive | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & reg.exe delete 'HKU\DefaultUserTemp\Software\Microsoft\Windows\CurrentVersion\Run' /v 'OneDriveSetup' /f 2>$null | Out-Null
        [GC]::Collect(); Start-Sleep 1
        & reg.exe unload 'HKU\DefaultUserTemp' | Out-Null
        Write-Ok "Removed OneDriveSetup from the Default user profile (new accounts won't get it)"
    } else {
        Write-Warn2 "Could not load the Default user hive; new user accounts may still get OneDrive"
    }
}

# ---------------------------------------------------------------------------
# 7. Delete leftovers
# ---------------------------------------------------------------------------
Write-Step "Deleting leftover folders"
$leftovers = @(
    "$env:LOCALAPPDATA\Microsoft\OneDrive",
    "$env:ProgramData\Microsoft OneDrive",
    "$env:SystemDrive\OneDriveTemp",
    "$env:ProgramFiles\Microsoft OneDrive",
    "${env:ProgramFiles(x86)}\Microsoft OneDrive"
)
if (-not $KeepFiles) { $leftovers += $OneDrive }

# Explorer must be stopped first or it holds the Desktop/Pictures folders open.
Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

foreach ($dir in $leftovers) {
    if (-not (Test-Path $dir)) { continue }
    try {
        Get-ChildItem $dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item $dir -Recurse -Force -ErrorAction Stop
        Write-Ok "Deleted $dir"
    } catch {
        Write-Warn2 "Could not delete $dir ($($_.Exception.Message)); delete it after a reboot"
    }
}
if ($KeepFiles -and (Test-Path $OneDrive)) { Write-Skip "Kept $OneDrive (-KeepFiles)" }

# ---------------------------------------------------------------------------
# 8. Restart Explorer and verify
# ---------------------------------------------------------------------------
Write-Step "Restarting Explorer"
Start-Process "$env:SystemRoot\explorer.exe"
Start-Sleep 5
Write-Ok "Done"

Show-State

Write-Host "`nFinished. Sign out and back in (or reboot) so every app picks up the new folder locations." -ForegroundColor Cyan
