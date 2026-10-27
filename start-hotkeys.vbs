' Launches the DDC hotkey daemon hidden (no console window).
' Double-click to start now; also used by install-startup.ps1 for logon autostart.
Dim fso, sh, scriptDir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = scriptDir
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\ddc-hotkeys.ps1""", 0, False
