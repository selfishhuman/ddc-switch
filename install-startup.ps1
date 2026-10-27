<#
    install-startup.ps1  -  Autostart the coordinated hotkey daemon at logon,
    and open the coordination port in Windows Firewall.

    Run:    powershell -ExecutionPolicy Bypass -File install-startup.ps1
    Remove: powershell -ExecutionPolicy Bypass -File install-startup.ps1 -Remove

    The firewall rule needs admin; if not elevated it is skipped with a warning
    (you'll instead get a one-time Windows Firewall prompt the first time the
    daemon listens -- just click Allow).
#>
param([switch]$Remove)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vbs       = Join-Path $ScriptDir 'start-hotkeys.vbs'
$Startup   = [Environment]::GetFolderPath('Startup')
$Lnk       = Join-Path $Startup 'DDC Switch Hotkeys.lnk'
$RuleName  = 'DDC Switch coordination'

# Read the port from config.psd1 (default 58762).
$Port = 58762
$cfgPath = Join-Path $ScriptDir 'config.psd1'
if (Test-Path $cfgPath) {
    try { $c = Import-PowerShellDataFile $cfgPath; if ($c.Network.Port) { $Port = [int]$c.Network.Port } } catch { Write-Warning "Could not read Network.Port from config.psd1; using $Port." }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if ($Remove) {
    if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Write-Host "Removed autostart: $Lnk" } else { Write-Host "No autostart shortcut found." }
    if (Test-Admin) {
        Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Write-Host "Removed firewall rule '$RuleName'."
    } else { Write-Host "(Not admin: leaving firewall rule in place.)" }
    # Stop any running daemon.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*-File*ddc-hotkeys.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Stopped daemon PID $($_.ProcessId)" }
    return
}

if (-not (Test-Path $cfgPath)) {
    Write-Warning "config.psd1 not found. Copy config.example.psd1 to config.psd1 (and"
    Write-Warning "machine.local.example.psd1 to machine.local.psd1) and edit them first."
    return
}

# 1) Autostart shortcut
$sh = New-Object -ComObject WScript.Shell
$s  = $sh.CreateShortcut($Lnk)
$s.TargetPath       = "$env:SystemRoot\System32\wscript.exe"
$s.Arguments        = "`"$Vbs`""
$s.WorkingDirectory = $ScriptDir
$s.Description       = 'DDC monitor input switch hotkeys'
$s.Save()
Write-Host "Installed autostart shortcut: $Lnk"

# 2) Firewall rule (inbound TCP on the coordination port)
if (Test-Admin) {
    Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -Profile Private,Domain | Out-Null
    Write-Host "Opened inbound TCP port $Port (Private/Domain) in Windows Firewall."
} else {
    Write-Warning "Not running as admin - skipped firewall rule. You'll get a one-time Windows"
    Write-Warning "Firewall prompt the first time the daemon listens; click Allow (Private networks)."
}

# 3) Start now
Write-Host "Starting the daemon now..."
Start-Process wscript.exe -ArgumentList "`"$Vbs`""
Write-Host "Done. Hotkeys are live (see ddc-hotkeys.log)."
