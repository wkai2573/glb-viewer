' Launch GlbViewer.ps1 with no console window
If WScript.Arguments.Count = 0 Then WScript.Quit 1
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "GlbViewer.ps1"" """ & WScript.Arguments(0) & """"
sh.Run cmd, 0, False
