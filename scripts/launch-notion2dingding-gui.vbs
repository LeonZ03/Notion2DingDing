Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, guiScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
guiScript = fileSystem.BuildPath(scriptDirectory, "notion2dingding-gui.ps1")
shell.CurrentDirectory = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Notion2DingDing"
command = Chr(34) & powershellPath & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & guiScript & Chr(34)

shell.Run command, 1, False
