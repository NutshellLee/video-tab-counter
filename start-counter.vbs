' video-tab-counter launcher - starts the counter with no console window.
' Derives its own folder, so it works from any location and leaks no local path.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\counter.ps1""", 0, False
