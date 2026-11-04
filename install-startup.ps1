<#
    install-startup.ps1  -  Autostart the coordinated hotkey daemon, and open the coordination
    port in Windows Firewall.

    Run:    powershell -ExecutionPolicy Bypass -File install-startup.ps1
    Remove: powershell -ExecutionPolicy Bypass -File install-startup.ps1 -Remove

    Autostart is a scheduled task ('DDC Switch Hotkeys', runs as you, not elevated) that fires at
    sign-in, on unlock and on resume from sleep. A machine that only sleeps and unlocks for days
    therefore still gets its daemon back if it ever stops; when one is already running, the new
    copy exits immediately (single-instance mutex in ddc-hotkeys.ps1).

    Nothing runs at the lock / sign-in screen: the hotkeys and the wheel need your desktop session.

    The firewall rule needs admin; if not elevated it is skipped with a warning
    (you'll instead get a one-time Windows Firewall prompt the first time the
    daemon listens -- just click Allow).
#>
param([switch]$Remove)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vbs       = Join-Path $ScriptDir 'start-hotkeys.vbs'
$Startup   = [Environment]::GetFolderPath('Startup')
$Lnk       = Join-Path $Startup 'DDC Switch Hotkeys.lnk'   # older versions autostarted from here
$TaskName  = 'DDC Switch Hotkeys'
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
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    } else { Write-Host "No scheduled task found." }
    if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Write-Host "Removed old autostart shortcut: $Lnk" }
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

# 1) Autostart: scheduled task with sign-in, unlock and resume-from-sleep triggers.
if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Write-Host "Removed old autostart shortcut: $Lnk" }
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$ns   = 'Root/Microsoft/Windows/TaskScheduler'

$logon = New-ScheduledTaskTrigger -AtLogOn -User $user

$unlock = New-CimInstance -CimClass (Get-CimClass -Namespace $ns -ClassName MSFT_TaskSessionStateChangeTrigger) -ClientOnly
$unlock.StateChange = 8   # TASK_SESSION_UNLOCK
$unlock.UserId      = $user
$unlock.Enabled     = $true

$resume = New-CimInstance -CimClass (Get-CimClass -Namespace $ns -ClassName MSFT_TaskEventTrigger) -ClientOnly
$resume.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
$resume.Enabled      = $true

$action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "`"$Vbs`"" -WorkingDirectory $ScriptDir
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
Register-ScheduledTask -TaskName $TaskName -Description 'DDC monitor switch hotkeys (ddc-switch)' -Force `
    -Trigger @($logon, $unlock, $resume) -Action $action -Principal $principal -Settings $settings | Out-Null
Write-Host "Installed scheduled task '$TaskName' (sign-in, unlock, resume from sleep)."

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
Start-ScheduledTask -TaskName $TaskName
Write-Host "Done. Hotkeys are live (see ddc-hotkeys.log)."
