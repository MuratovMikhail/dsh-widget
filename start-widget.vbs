' Starts the DSH Widget without a visible console window.
' Double-click this file to show the card in the bottom-right corner.
Option Explicit

Dim fso, shell, scriptDir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\widget-ui.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "widget-ui.ps1 was not found next to this file.", 16, "DSH Widget"
    WScript.Quit 1
End If

shell.CurrentDirectory = scriptDir
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
shell.Run cmd, 0, False
