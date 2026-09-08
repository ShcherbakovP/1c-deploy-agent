' mcp-daemon.vbs — файловый MCP-транспорт к базе 1С без клиента 1С.
'
' Ядро MCP (разбор JSON-RPC, инструменты) живёт во внешней обработке. Демон открывает её
' во ВНЕШНЕМ СОЕДИНЕНИИ (V83.COMConnector): контекст серверный, интерфейс не нужен, окон нет.
' Запросы — файлы *.json в <папка обмена>\in, ответы — одноимённые файлы в <папка обмена>\out.
'
' Почему не /Execute в клиенте: обработчик ожидания формы в пакетно запущенном клиенте
' не тикает, а в некоторых конфигурациях ключ /Execute обработку подключает, но форму
' не открывает — автостарт из ПриОткрытии не срабатывает.
'
' Файл обработки открывает СЕРВЕР 1С (rphost под учёткой службы), а не этот скрипт, поэтому
' .epf обязан лежать там, где его видит rphost; проброшенный \\tsclient серверу не виден.
' Папку обмена читает сам скрипт — ей \\tsclient годится.
'
' Контракт обработки (см. README): экспортный метод ProcessMCPRequest(ТелоЗапроса) → строка
' ответа JSON-RPC; необязательный EnableCodeExecution(Истина) для включения выполнения кода.
' Имена только латинские: кириллические методы из VBScript не вызвать, CallByName в нём нет.
'
' Запуск: cscript //nologo mcp-daemon.vbs <ИБ> <пользователь> <пароль> <папка обмена> <сервер> <путь к .epf> [code]
' Остановка: файл stop.flag в папке обмена либо снятие процесса (mcp-stop).
' Разрыв сеанса (kill-sessions): одно переподключение и повтор запроса; не вышло — ответ
' с error в out и выход (код 6), чтобы не жить зомби и не терять запросы.
' Кодировка файла на диске сервера — ANSI (cp1251): агент конвертирует из UTF-8 при запуске.

Option Explicit

Dim fso, args, ibName, ibUser, ibPwd, exchangeDir, inDir, outDir, logPath, srv
Set fso = CreateObject("Scripting.FileSystemObject")
Set args = WScript.Arguments

If args.Count < 6 Then
  WScript.Echo "нужны параметры: <ИБ> <пользователь> <пароль> <папка обмена> <сервер> <путь к .epf> [code]"
  WScript.Quit 2
End If

ibName = args(0)
ibUser = args(1)
ibPwd = args(2)
exchangeDir = args(3)
srv = args(4)

Dim agentPath, allowCode
agentPath = args(5)
' Выполнение произвольного кода (execute_bsl_code) выключено, пока седьмым аргументом
' явно не передан "code".
allowCode = False
If args.Count > 6 Then allowCode = (LCase(args(6)) = "code")

inDir = JoinPath(exchangeDir, "in")
outDir = JoinPath(exchangeDir, "out")
logPath = JoinPath(exchangeDir, "daemon.log")

If Not fso.FolderExists(exchangeDir) Then fso.CreateFolder exchangeDir
If Not fso.FolderExists(inDir) Then fso.CreateFolder inDir
If Not fso.FolderExists(outDir) Then fso.CreateFolder outDir

Dim stopFlag
stopFlag = JoinPath(exchangeDir, "stop.flag")
If fso.FileExists(stopFlag) Then fso.DeleteFile stopFlag   ' остаток прошлой остановки

WriteLog "старт демона, ИБ " & ibName & ", папка " & exchangeDir

Dim connector, conn, agent, connStr
On Error Resume Next
Set connector = CreateObject("V83.COMConnector")
If Err.Number <> 0 Then
  WriteLog "не создан COMConnector: " & Err.Description
  WScript.Quit 3
End If
connStr = "Srvr=""" & srv & """;Ref=""" & ibName & """;Usr=""" & ibUser & """;Pwd=""" & Replace(ibPwd, """", """""") & """;"
Set conn = connector.Connect(connStr)
If Err.Number <> 0 Then
  WriteLog "не установлено соединение с " & ibName & ": " & Err.Description
  WScript.Quit 4
End If
Set agent = conn.ExternalDataProcessors.Create(agentPath, False)
If Err.Number <> 0 Then
  WriteLog "не открыта обработка " & agentPath & ": " & Err.Description
  WScript.Quit 5
End If
Call ApplyAllowCode()
On Error Goto 0

WriteLog "соединение установлено, обработка открыта: " & agentPath

Dim handled
handled = 0

Do While True
  Dim f, files, body, answer, tmpName, dstName, errText, fatal
  fatal = False
  On Error Resume Next
  Set files = fso.GetFolder(inDir).Files
  If Err.Number <> 0 Then
    WriteLog "папка входящих недоступна: " & Err.Description
    Err.Clear
  Else
    For Each f In files
      If LCase(fso.GetExtensionName(f.Name)) = "json" Then
        body = ReadUtf8(f.Path)
        If Err.Number <> 0 Then
          WriteLog "не прочитан " & f.Name & ": " & Err.Description
          Err.Clear
        Else
          answer = CallAgent(body)
          If Err.Number <> 0 Then
            ' Ошибка самого COM-вызова (ошибки инструментов обработка возвращает в JSON): почти
            ' всегда это сеанс, снятый kill-sessions. Переподключаемся и повторяем один раз.
            errText = Err.Description
            Err.Clear
            WriteLog "ошибка обработки " & f.Name & ": " & errText & " - пробую переподключиться"
            If Reconnect() Then
              answer = CallAgent(body)
              If Err.Number <> 0 Then
                ' Повтор упал при живой связи — ошибка кода или данных, не транспорта:
                ' отвечаем ошибкой, демон продолжает работать.
                errText = Err.Description
                Err.Clear
                answer = ErrorAnswer(errText)
                WriteLog "повтор не удался (ошибка кода/данных), демон продолжает: " & errText
              End If
            Else
              answer = ErrorAnswer(errText)
              fatal = True
            End If
          End If
          If Len(answer) > 0 Then
            tmpName = JoinPath(outDir, f.Name & ".tmp")
            dstName = JoinPath(outDir, f.Name)
            WriteUtf8 tmpName, answer
            If fso.FileExists(dstName) Then fso.DeleteFile dstName
            fso.MoveFile tmpName, dstName
          End If
          fso.DeleteFile f.Path
          handled = handled + 1
          If fatal Then
            WriteLog "соединение с " & ibName & " потеряно и не восстановлено, демон завершается (обработано " & handled & ")"
            WScript.Quit 6
          End If
        End If
      End If
    Next
  End If
  On Error Goto 0

  If fso.FileExists(stopFlag) Then
    fso.DeleteFile stopFlag
    WriteLog "остановка по stop.flag, обработано запросов: " & handled
    Exit Do
  End If

  WScript.Sleep 1500
Loop

WScript.Quit 0

Sub ApplyAllowCode()
  If Not allowCode Then Exit Sub
  On Error Resume Next
  agent.EnableCodeExecution True
  If Err.Number <> 0 Then
    WriteLog "выполнение кода не включено (" & Err.Description & ")"
    Err.Clear
  Else
    WriteLog "выполнение кода включено параметром запуска"
  End If
End Sub

Function CallAgent(body)
  Dim res, num, desc, src
  On Error Resume Next
  res = agent.ProcessMCPRequest(body)
  If Err.Number <> 0 Then
    num = Err.Number : desc = Err.Description : src = Err.Source
    Err.Clear
    On Error Goto 0
    Err.Raise num, src, desc
  End If
  On Error Goto 0
  CallAgent = res
End Function

Function Reconnect()
  Reconnect = False
  On Error Resume Next
  Set agent = Nothing
  Set conn = Nothing
  Set conn = connector.Connect(connStr)
  If Err.Number <> 0 Then
    WriteLog "переподключение к " & ibName & " не удалось: " & Err.Description
    Err.Clear
    Exit Function
  End If
  Set agent = conn.ExternalDataProcessors.Create(agentPath, False)
  If Err.Number <> 0 Then
    WriteLog "после переподключения не открыта обработка " & agentPath & ": " & Err.Description
    Err.Clear
    Exit Function
  End If
  Call ApplyAllowCode()
  WriteLog "соединение с " & ibName & " восстановлено"
  Reconnect = True
End Function

Function ErrorAnswer(text)
  ErrorAnswer = "{""jsonrpc"":""2.0"",""id"":null,""error"":{""code"":-32000,""message"":""mcp-daemon: " & JsonEscape(text) & """}}"
End Function

Function JsonEscape(s)
  s = Replace(s, "\", "\\")
  s = Replace(s, """", "\""")
  s = Replace(s, vbCrLf, "\n")
  s = Replace(s, vbCr, "\n")
  s = Replace(s, vbLf, "\n")
  s = Replace(s, vbTab, "\t")
  JsonEscape = s
End Function

Function JoinPath(base, tail)
  If Right(base, 1) = "\" Then
    JoinPath = base & tail
  Else
    JoinPath = base & "\" & tail
  End If
End Function

Function ReadUtf8(path)
  Dim st
  Set st = CreateObject("ADODB.Stream")
  st.Type = 2
  st.Charset = "utf-8"
  st.Open
  st.LoadFromFile path
  ReadUtf8 = st.ReadText()
  st.Close
End Function

Sub WriteUtf8(path, text)
  ' ADODB пишет UTF-8 с BOM, а клиенты ждут чистый JSON — BOM срезаем.
  Dim st, bin, out
  Set st = CreateObject("ADODB.Stream")
  st.Type = 2
  st.Charset = "utf-8"
  st.Open
  st.WriteText text
  st.Position = 0
  st.Type = 1
  st.Position = 3
  bin = st.Read()
  st.Close

  Set out = CreateObject("ADODB.Stream")
  out.Type = 1
  out.Open
  out.Write bin
  out.SaveToFile path, 2
  out.Close
End Sub

Sub WriteLog(text)
  Dim ts, line, f
  ts = Year(Now) & "-" & Pad(Month(Now)) & "-" & Pad(Day(Now)) & " " & Pad(Hour(Now)) & ":" & Pad(Minute(Now)) & ":" & Pad(Second(Now))
  line = ts & "  " & text
  On Error Resume Next
  Set f = fso.OpenTextFile(logPath, 8, True)
  f.WriteLine line
  f.Close
  On Error Goto 0
  WScript.Echo line
End Sub

Function Pad(n)
  If n < 10 Then
    Pad = "0" & n
  Else
    Pad = CStr(n)
  End If
End Function
