# rdp-open.ps1 — авто-RDP оркестратора (запускается на рабочей станции).
# Находит или поднимает RDP-сессию к серверу цели и через Win+R в сессии запускает лаунчер агента.
# Требования (разово):
#   - файл <корень>\rdp\<цель>.rdp с настройками подключения (проброс диска, keyboardhook:i:1);
#   - учётные данные в диспетчере учётных данных: cmdkey /generic:TERMSRV/<хост> и, если есть
#     шлюз удалённых рабочих столов, cmdkey /generic:<шлюз>.
# Во время клавиатурной фазы (~5 с) не трогать клавиатуру и мышь.
param(
    [string]$Target = 'test',
    [string]$Root = '',
    [string]$ShareRoot = '\\tsclient\F\deploy',
    [switch]$ConnectOnly,
    [int]$ConnectTimeoutSec = 90,
    [int]$HeartbeatTimeoutSec = 150
)

if ($Root -eq '') { $Root = $env:DEPLOY_ROOT }
if ([string]::IsNullOrEmpty($Root)) { $Root = 'F:\deploy' }
$rdpFile = Join-Path $Root ('rdp\' + $Target + '.rdp')
if (-not (Test-Path $rdpFile)) { Write-Host ("Нет файла {0} — стоп." -f $rdpFile); exit 1 }
$hostLine = (Get-Content $rdpFile) | Where-Object { $_ -match '^full address:s:(.+)$' } | Select-Object -First 1
if ($hostLine -match '^full address:s:(.+)$') { $rdpHost = $Matches[1].Trim() } else { Write-Host 'В .rdp нет full address — стоп.'; exit 1 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RdpNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
'@

function Find-RdpWindow() {
    $procs = @(Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match [regex]::Escape($rdpHost) })
    if ($procs.Count -gt 0) { return $procs[0] }
    return $null
}

# --- 1. Сессия: найти или поднять ---------------------------------------------
$win = Find-RdpWindow
if ($null -eq $win) {
    Write-Host ("Открываю RDP-сессию: {0}" -f $rdpFile)
    Start-Process -FilePath 'mstsc.exe' -ArgumentList ('"' + $rdpFile + '"')
    $deadline = (Get-Date).AddSeconds($ConnectTimeoutSec)
    while ((Get-Date) -lt $deadline -and $null -eq $win) { Start-Sleep -Seconds 3; $win = Find-RdpWindow }
    if ($null -eq $win) { Write-Host ("Окно RDP к {0} не появилось за {1} с — стоп." -f $rdpHost, $ConnectTimeoutSec); exit 1 }
    Write-Host 'Окно появилось, жду установления сеанса (15 с)...'
    Start-Sleep -Seconds 15
} else {
    Write-Host ("Использую существующее окно RDP (PID {0}): {1}" -f $win.Id, $win.MainWindowTitle)
}
if ($ConnectOnly) { Write-Host 'Готово (только подключение).'; exit 0 }

# --- 2. Запуск агента: Win+R в сессии -----------------------------------------
$agentCmd = 'powershell -ExecutionPolicy Bypass -File ' + $ShareRoot + '\agent-start.ps1 -Role ' + $Target + ' -ShareRoot ' + $ShareRoot
$hbPath = Join-Path $Root ($Target + '\out\agent-status.json')
$startedAt = Get-Date

Write-Host 'Клавиатурная фаза: НЕ трогайте клавиатуру и мышь ~5 секунд.'
Start-Sleep -Seconds 2
[void][RdpNative]::SetForegroundWindow($win.MainWindowHandle)
Start-Sleep -Milliseconds 800
# Win+R уходит в сессию, если в .rdp задано keyboardhook:i:1
[RdpNative]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
[RdpNative]::keybd_event(0x52, 0, 0, [UIntPtr]::Zero)
[RdpNative]::keybd_event(0x52, 0, 2, [UIntPtr]::Zero)
[RdpNative]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1500
[System.Windows.Forms.SendKeys]::SendWait($agentCmd)
Start-Sleep -Milliseconds 500
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Write-Host 'Команда запуска агента отправлена в сессию.'

# --- 3. Ожидание heartbeat агента ---------------------------------------------
Write-Host ("Жду heartbeat агента ({0}) до {1} с..." -f $hbPath, $HeartbeatTimeoutSec)
$deadline = (Get-Date).AddSeconds($HeartbeatTimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $hbPath) -and ((Get-Item $hbPath).LastWriteTime -gt $startedAt)) {
        $hb = Get-Content $hbPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ("АГЕНТ РАБОТАЕТ: v{0}, роль {1}, хост {2}." -f $hb.agent, $hb.role, $hb.host)
        exit 0
    }
    Start-Sleep -Seconds 5
}
Write-Host 'Heartbeat не появился — агент не стартовал. Проверьте окно сессии (диалог Win+R, сертификат, вход).'
exit 2
