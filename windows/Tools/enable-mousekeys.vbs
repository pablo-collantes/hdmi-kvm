' Launches enable-mousekeys.ps1 hidden (Run window-style 0, don't wait).
' Used by the LanMouseMouseKeys logon task to re-enable Mouse Keys on every login,
' which keeps the injected cursor visible when no physical mouse is connected.
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\Tools\enable-mousekeys.ps1""", 0, False
