# agent-start.ps1 — лаунчер агента (выполняется НА СЕРВЕРЕ в RDP-сессии).
# 1) пишет диагностический лог старта, который переживает закрытие окна;
# 2) прописывает себя в автозагрузку профиля (shell:startup);
# 3) запускает deploy-agent.ps1 и проверяет, что тот не упал на первой секунде.
#
# Запуск из RDP (Win+R или двойной клик по agent-start.cmd):
#   powershell -ExecutionPolicy Bypass -File "\\tsclient\F\deploy\agent-start.ps1" -Role test
#
# Лог старта: %TEMP%\agent-start-<штамп>.log и, если папка обмена видна, log\start-<хост>.log на ней.
param(
    [switch]$FromStartup,
    [string]$Role = '',
    [string]$ShareRoot = '\\tsclient\F\deploy'
)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logLocal = Join-Path $env:TEMP ('agent-start-' + $stamp + '.log')
$logShare = ''

function Say([string]$text) {
    $line = ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text)
    Write-Host $line
    try { Add-Content -Path $script:logLocal -Value $line -Encoding UTF8 } catch {}
    if ($script:logShare -ne '') { try { Add-Content -Path $script:logShare -Value $line -Encoding UTF8 } catch {} }
}

Say ("Хост {0}, пользователь {1}\{2}, PowerShell {3}" -f $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion)

$shareOk = Test-Path $ShareRoot
Say ("Папка обмена {0}: {1}" -f $ShareRoot, $(if ($shareOk) { 'доступна' } else { 'НЕ ДОСТУПНА' }))
if ($shareOk) {
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'log') | Out-Null
        $logShare = Join-Path $ShareRoot ('log\start-' + $env:COMPUTERNAME + '.log')
        Add-Content -Path $logShare -Value ("=== запуск лаунчера " + $stamp + " ===") -Encoding UTF8
    } catch { Say ('лог в папку обмена не пишется: ' + $_.Exception.Message) }
} else {
    Say 'Проброс диска в RDP-сессию выключен либо диск называется иначе.'
    Say 'Включается в клиенте RDP: Локальные ресурсы -> Подробнее -> Диски. Без него агент работать не может.'
    Say ('Лог старта: ' + $logLocal)
    exit 1
}

$agentPs1 = Join-Path $ShareRoot 'deploy-agent.ps1'
Say ("Файл агента {0}: {1}" -f $agentPs1, $(if (Test-Path $agentPs1) { 'на месте' } else { 'НЕ НАЙДЕН' }))
if (-not (Test-Path $agentPs1)) { exit 1 }

$platforms = @()
foreach ($root in @('C:\Program Files\1cv8', 'C:\Program Files (x86)\1cv8')) {
    if (-not (Test-Path $root)) { continue }
    $platforms += @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-Path (Join-Path $_.FullName 'bin\1cv8.exe')) } |
        ForEach-Object { $_.Name })
}
Say ("Платформы 1С: {0}" -f $(if ($platforms.Count -gt 0) { ($platforms | Sort-Object -Unique) -join ', ' } else { 'НЕ НАЙДЕНЫ' }))

$agentArgs = ' -ShareRoot "' + $ShareRoot + '"'
if ($Role -ne '') {
    $agentArgs += ' -Role ' + $Role
    Say ("Роль задана явно: {0}" -f $Role)
} else {
    Say ("Роль будет определена агентом по hostPattern в конфиге ({0})" -f $env:COMPUTERNAME)
}

$startup = [Environment]::GetFolderPath('Startup')
$launcher = Join-Path $startup 'deploy-agent-start.cmd'
$content = '@start "deploy-agent" powershell -ExecutionPolicy Bypass -File "' + $ShareRoot + '\agent-start.ps1" -FromStartup' + $agentArgs
try {
    Set-Content -Path $launcher -Value $content -Encoding ASCII
    Say ("Автозагрузка профиля: " + $launcher)
} catch { Say ('в автозагрузку не записался: ' + $_.Exception.Message) }

$already = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '-File\s+"?[^"]*deploy-agent\.ps1' }
if ($already) {
    Say ("Агент уже работает (PID " + (($already | ForEach-Object { $_.ProcessId }) -join ', ') + "), второй не запускаю.")
    exit 0
}

Say 'Запускаю агента...'
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-ExecutionPolicy Bypass -File "' + $agentPs1 + '"' + $agentArgs) -PassThru

# Агент, упавший на ранней проверке, закрывает своё окно мгновенно — ловим это здесь.
Start-Sleep -Seconds 12
$proc.Refresh()
if ($proc.HasExited) {
    Say ("АГЕНТ НЕ ПОДНЯЛСЯ: процесс завершился сразу (exit=" + $proc.ExitCode + ").")
    Say ("Причина — в " + (Join-Path $env:TEMP 'deploy-agent\start-fail.log') + " и в log\start-fail-" + $env:COMPUTERNAME + ".log в папке обмена.")
    exit 1
}
Say ("Агент работает, PID " + $proc.Id + ". Окно агента закрывать нельзя — в нём он и крутится.")
Say ('Лог старта: ' + $logLocal + ' и ' + $logShare)
