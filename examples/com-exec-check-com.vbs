' Пример для deploy.ps1 com-exec -ScriptFile examples\com-exec-check-com.vbs
' Диагностика COM-компоненты 1С на сервере: регистрация V83.COMConnector, файлы comcntr.dll,
' DCOM AppID. Пригодится для заявки сисадминам, когда внешнее соединение не поднимается.
' Скрипт выполняется агентом на сервере через cscript, вывод (WScript.Echo) возвращается в ответе.
Option Explicit
Dim sh
Set sh = CreateObject("WScript.Shell")

Function RunCmd(c)
    Dim ex, s
    Set ex = sh.Exec("cmd /c " & c & " 2>&1")
    s = ""
    Do While Not ex.StdOut.AtEndOfStream
        s = s & ex.StdOut.ReadLine & vbCrLf
    Loop
    RunCmd = s
End Function

WScript.Echo "=== V83.COMConnector registration ==="
WScript.Echo RunCmd("reg query HKCR\V83.COMConnector\CLSID")
WScript.Echo "=== comcntr.dll files ==="
WScript.Echo RunCmd("dir ""C:\Program Files\1cv8\*comcntr.dll"" /s /b")
WScript.Echo RunCmd("dir ""C:\Program Files (x86)\1cv8\*comcntr.dll"" /s /b")
WScript.Echo "=== DCOM AppID with 1C in description ==="
WScript.Echo RunCmd("reg query HKCR\AppID /f 1C /d")
