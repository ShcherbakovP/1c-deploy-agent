# deploy-agent.ps1 — агент конвейера доставки 1С для контуров, где до сервера есть только RDP.
#
# Работает в RDP-сессии на сервере 1С. Опрашивает папку обмена на проброшенном в сессию диске
# рабочей станции (\\tsclient\<диск>\...), исполняет команды пакетного Конфигуратора, ras/rac и
# COM, отвечает JSON-файлами в ту же папку. Команды отправляет deploy.ps1 с рабочей станции.
#
# Запуск на сервере (из RDP-сессии):
#   powershell -ExecutionPolicy Bypass -File "\\tsclient\F\deploy\deploy-agent.ps1" -Role test
# Роль можно не указывать, если в agent-config.json у секции задан hostPattern, совпадающий
# с именем машины. Остановка: команда stop от оркестратора или Ctrl+C в окне агента.
#
# Конфиг с учётными данными: <папка обмена>\agent-config.json (см. agent-config.sample.json).
# Описание команд, протокола и накопленных граблей — README.md.

param(
    [string]$Role = '',
    # Папка обмена глазами сервера. Диск рабочей станции должен быть проброшен в RDP-сессию.
    [string]$ShareRoot = '\\tsclient\F\deploy',
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Continue'
$AgentVersion = '2.0'

# Ранний выход (роль, папка обмена, конфиг, платформа) в окне не увидеть: при запуске из
# лаунчера окно закрывается вместе с процессом. Причина ложится в файл — локально
# в %TEMP%\deploy-agent\start-fail.log и, если папка обмена доступна, в log\ на ней.
function Fail([string]$text) {
    $line = ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $text)
    Write-Host $line
    try {
        $d = Join-Path $env:TEMP 'deploy-agent'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Add-Content -Path (Join-Path $d 'start-fail.log') -Value $line -Encoding UTF8
    } catch {}
    try {
        $shareLog = Join-Path $ShareRoot 'log'
        if (Test-Path $shareLog) {
            Add-Content -Path (Join-Path $shareLog ('start-fail-' + $env:COMPUTERNAME + '.log')) -Value $line -Encoding UTF8
        }
    } catch {}
    exit 1
}

# --- Папка обмена и конфиг ------------------------------------------------------
if (-not (Test-Path $ShareRoot)) {
    Fail ("Недоступна папка обмена {0}. Проверьте, проброшен ли диск в RDP-сессию (Локальные ресурсы -> Подробнее -> Диски)." -f $ShareRoot)
}
$configPath = Join-Path $ShareRoot 'agent-config.json'
if (-not (Test-Path $configPath)) { Fail ("Нет конфига " + $configPath + " — стоп.") }
$allConfig = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Роль: явный параметр, иначе секция конфига, чей hostPattern подходит к имени машины.
if ($Role -eq '') {
    foreach ($p in $allConfig.PSObject.Properties) {
        $pattern = '' + $p.Value.hostPattern
        if ($pattern -ne '' -and $env:COMPUTERNAME -match $pattern) { $Role = $p.Name; break }
    }
    if ($Role -eq '') {
        Fail ("Роль не определена: у машины '" + $env:COMPUTERNAME + "' нет подходящего hostPattern в конфиге — запустите с -Role <имя секции>")
    }
}
$cfg = $allConfig.$Role
if ($null -eq $cfg) { Fail ("В конфиге " + $configPath + " нет секции '" + $Role + "' — стоп.") }

$inDir   = Join-Path $ShareRoot ($Role + '\in')
$outDir  = Join-Path $ShareRoot ($Role + '\out')
$doneDir = Join-Path $inDir 'done'
$artDir  = Join-Path $ShareRoot 'artifacts'
foreach ($d in @($inDir, $outDir, $doneDir, $artDir, (Join-Path $ShareRoot 'log'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Логи пишутся локально и копируются в папку обмена целиком после каждой команды:
# построчный Add-Content через \\tsclient занимает около 10 секунд на строку.
$workRoot = Join-Path $env:TEMP 'deploy-agent'
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$agentLog = Join-Path $workRoot ('agent-' + (Get-Date -Format 'yyyyMMdd') + '.log')

function Log([string]$text) {
    $line = ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text)
    Write-Host $line
    Add-Content -Path $script:agentLog -Value $line -Encoding UTF8
}

function Copy-AgentLogToShare() {
    try { Copy-Item -Path $script:agentLog -Destination (Join-Path $ShareRoot ('log\agent-' + $Role + '.log')) -Force } catch {}
}

# --- Платформа: строго версия кластера ------------------------------------------
# Старший клиент даёт «несоответствие версий клиента и сервера» на пакетных операциях.
# platformVersion = 'auto' берёт старшую установленную и годится только для первого запуска
# на незнакомой машине: ping отдаёт список найденных версий, из них выбирается точная.
$platformRoots = @('C:\Program Files\1cv8', 'C:\Program Files (x86)\1cv8')
$installedPlatforms = @()
foreach ($root in $platformRoots) {
    if (-not (Test-Path $root)) { continue }
    $installedPlatforms += @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-Path (Join-Path $_.FullName 'bin\1cv8.exe')) } |
        ForEach-Object { $_.Name })
}
$installedPlatforms = @($installedPlatforms | Sort-Object -Unique { [version]$_ })

$wantVersion = '' + $cfg.platformVersion
$designerExe = $null
if ($wantVersion -eq '' -or $wantVersion -eq 'auto') {
    if ($installedPlatforms.Count -eq 0) { Fail 'Платформа 1С не найдена: нет 1cv8.exe в C:\Program Files\1cv8\<версия>\bin — стоп.' }
    $wantVersion = $installedPlatforms[-1]
    Log ("platformVersion=auto: беру старшую установленную {0} (все: {1})" -f $wantVersion, ($installedPlatforms -join ', '))
}
foreach ($root in $platformRoots) {
    $exe = Join-Path $root ($wantVersion + '\bin\1cv8.exe')
    if (Test-Path $exe) { $designerExe = $exe; break }
}
if ($null -eq $designerExe) {
    Fail ("Не найдена платформа " + $wantVersion + " — стоп. Установлены: " + ($installedPlatforms -join ', '))
}
$platformUsed = $wantVersion
$binDir = Split-Path $designerExe
Log ("Агент v{0}, роль {1}, ИБ {2}\{3}, платформа {4}" -f $AgentVersion, $Role, $cfg.server1c, $cfg.ib, $designerExe)

# Единственность через lock-файл: при старте пишем свой PID, в цикле сверяем. Если в lock
# чужой PID, стартовал новый экземпляр (reload), и этот выходит — иначе одну команду
# обработают дважды. Старые процессы дополнительно снимаем, если хватает прав.
$lockFile = Join-Path $outDir 'agent.lock'
try {
    $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-File\s+"?[^"]*deploy-agent\.ps1' -and $_.ProcessId -ne $PID })
    Log ("Других экземпляров агента найдено: " + $others.Count)
    foreach ($o in $others) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { Log ('проверка процессов не удалась: ' + $_) }
try { [System.IO.File]::WriteAllText($lockFile, [string]$PID, (New-Object System.Text.UTF8Encoding($false))) } catch {}

# --- Вспомогательное ------------------------------------------------------------
function Get-Tail([string]$text, [int]$lines = 25) {
    if ($null -eq $text -or $text -eq '') { return '' }
    $arr = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($arr.Count -le $lines) { return ($arr -join "`n") }
    return (($arr | Select-Object -Last $lines) -join "`n")
}

function Coalesce([string]$value, [string]$fallback) {
    if ([string]::IsNullOrEmpty($value)) { return $fallback }
    return $value
}

# ИБ и учётные данные: из самой команды, иначе из секции конфига этой роли.
function Resolve-IbTarget($cmd) {
    return @{
        ib       = (Coalesce ('' + $cmd.ib) ('' + $cfg.ib))
        user     = (Coalesce ('' + $cmd.user) ('' + $cfg.ibUser))
        password = (Coalesce ('' + $cmd.password) ('' + $cfg.ibPassword))
    }
}

# --- ras/rac: сеансы ИБ ---------------------------------------------------------
function Get-RacBlocks([string]$text) {
    $blocks = New-Object System.Collections.ArrayList
    $cur = @{}
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln.Trim() -eq '') {
            if ($cur.Count -gt 0) { [void]$blocks.Add($cur); $cur = @{} }
        } elseif ($ln -match '^\s*([a-zA-Z\-]+)\s*:\s*(.*)$') {
            $cur[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }
    if ($cur.Count -gt 0) { [void]$blocks.Add($cur) }
    return $blocks
}

# Поднимает локальный ras к кластеру из конфига, находит кластер и ИБ. Вызывающий обязан
# снять $ctx.rasProc в finally. Кластер может быть удалённым (clusterAddr — другая машина).
function Connect-Rac([string]$IbName) {
    $ctx = @{ ok = $false; detail = ''; rasProc = $null; rac = ''; rasAddr = ''; clusterId = ''; ibId = $null; infobases = @() }
    $rasExe = Join-Path $binDir 'ras.exe'
    $racExe = Join-Path $binDir 'rac.exe'
    if (-not ((Test-Path $rasExe) -and (Test-Path $racExe))) { $ctx.detail = 'ras/rac не найдены в ' + $binDir; return $ctx }
    $ctx.rac = $racExe
    $ctx.rasAddr = 'localhost:' + $cfg.rasPort
    $ctx.rasProc = Start-Process -FilePath $rasExe -ArgumentList ('cluster --port=' + $cfg.rasPort + ' ' + $cfg.clusterAddr) -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $clustersOut = (& $racExe cluster list $ctx.rasAddr 2>&1 | Out-String)
    if ($clustersOut -notmatch 'cluster\s*:\s*([0-9a-f\-]{36})') {
        $ctx.detail = 'кластер не найден: ' + (Get-Tail $clustersOut 5)
        return $ctx
    }
    $ctx.clusterId = $Matches[1]
    $ibOut = (& $racExe infobase summary list ('--cluster=' + $ctx.clusterId) $ctx.rasAddr 2>&1 | Out-String)
    $names = @()
    foreach ($b in (Get-RacBlocks $ibOut)) {
        if ($b['name']) { $names += $b['name'] }
        if ($b['name'] -eq $IbName) { $ctx.ibId = $b['infobase'] }
    }
    $ctx.infobases = $names
    if ($null -eq $ctx.ibId) { $ctx.detail = ('инфобаза {0} не найдена в кластере' -f $IbName); return $ctx }
    $ctx.ok = $true
    return $ctx
}

function Get-RacSessions($ctx) {
    $sessOut = (& $ctx.rac session list ('--cluster=' + $ctx.clusterId) $ctx.rasAddr 2>&1 | Out-String)
    return @(Get-RacBlocks $sessOut | Where-Object { $_['infobase'] -eq $ctx.ibId })
}

# Список сеансов без снятия: проверка, что ras/rac достают до кластера, и трезвый взгляд
# на базу перед операциями, требующими монопольного доступа.
function Get-IbSessions([string]$IbName = '') {
    $IbName = Coalesce $IbName ('' + $cfg.ib)
    $result = @{ ok = $false; ib = $IbName; cluster = ''; count = 0; sessions = @(); infobases = @(); detail = '' }
    $ctx = Connect-Rac $IbName
    try {
        $result.cluster = $ctx.clusterId
        $result.infobases = $ctx.infobases
        if (-not $ctx.ok) { $result.detail = $ctx.detail; return $result }
        $list = New-Object System.Collections.ArrayList
        foreach ($b in (Get-RacSessions $ctx)) {
            [void]$list.Add(@{ user = ('' + $b['user-name']); app = ('' + $b['app-id']);
                host = ('' + $b['host']); started = ('' + $b['started-at']) })
        }
        $result.sessions = @($list)
        $result.count = $list.Count
        $result.ok = $true
        return $result
    } finally {
        if ($ctx.rasProc) { try { $ctx.rasProc.Kill() } catch {} }
    }
}

# Снятие всех сеансов ИБ. Закрытое окно Конфигуратора не равно завершённому сеансу,
# поэтому перед каждой пакетной операцией сеансы снимаются принудительно.
function Stop-IbSessions([string]$IbName = '') {
    $IbName = Coalesce $IbName ('' + $cfg.ib)
    $result = @{ ok = $false; killed = 0; left = -1; detail = '' }
    $ctx = Connect-Rac $IbName
    try {
        if (-not $ctx.ok) { $result.detail = $ctx.detail; return $result }
        $killed = 0; $errors = 0
        foreach ($b in (Get-RacSessions $ctx)) {
            Log ("  снимаю сеанс {0}: {1} / {2}" -f $b['session-id'], $b['user-name'], $b['app-id'])
            $termOut = (& $ctx.rac session terminate ('--cluster=' + $ctx.clusterId) ('--session=' + $b['session']) $ctx.rasAddr 2>&1 | Out-String)
            if ($termOut.Trim() -eq '') { $killed++ } else { $errors++; $result.detail += ('terminate: ' + $termOut.Trim() + '; ') }
        }
        Start-Sleep -Seconds 2
        $left = @(Get-RacSessions $ctx).Count
        $result.killed = $killed
        $result.left = $left
        if ($left -gt 0) { $result.detail += ('осталось сеансов: ' + $left) }
        $result.ok = ($errors -eq 0 -and $left -eq 0)
        return $result
    } finally {
        if ($ctx.rasProc) { try { $ctx.rasProc.Kill() } catch {} }
    }
}

# Шаг «снять сеансы» в составе многошаговой команды: пишет шаг в $steps, при неудаче
# возвращает готовый ответ с ошибкой, при успехе — $null.
function Invoke-KillStep($steps, [string]$IbName = '') {
    $k = Stop-IbSessions $IbName
    [void]$steps.Add(@{ step = 'kill-sessions'; ok = $k.ok; killed = $k.killed; left = $k.left; detail = $k.detail })
    if ($k.ok) { return $null }
    return @{ status = 'error'; error = ('не удалось освободить базу: ' + $k.detail); steps = $steps }
}

# --- Пакетный Конфигуратор ------------------------------------------------------
# Один запуск 1cv8 DESIGNER с ожиданием и таймаутом. $connection — строка подключения:
# серверная ИБ '/S сервер\ИБ /N пользователь /P "пароль"' или файловая '/F "путь"'.
function Invoke-Designer1cv8([string]$step, [string]$connection, [string]$commandPart, [int]$timeoutSec) {
    $outFile = Join-Path $workRoot ($step + '-' + (Get-Date -Format 'HHmmss') + '.out.txt')
    $argLine = 'DESIGNER ' + $connection + ' ' + $commandPart + ' /Out "' + $outFile + '" /DisableStartupDialogs /DisableStartupMessages'
    Log ("{0}: 1cv8 {1}" -f $step, $commandPart)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $designerExe -ArgumentList $argLine -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        Log ("{0}: ТАЙМАУТ {1} с, процесс снят." -f $step, $timeoutSec)
        return [pscustomobject]@{ Step = $step; ExitCode = -1; Seconds = [int]$sw.Elapsed.TotalSeconds; Output = ('(таймаут ' + $timeoutSec + ' с)') }
    }
    $text = ''
    if (Test-Path $outFile) {
        $text = (Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue)
        if ($null -eq $text) { $text = '' }
    }
    Log ("{0}: exit={1} за {2} с" -f $step, $p.ExitCode, [int]$sw.Elapsed.TotalSeconds)
    foreach ($ln in ((Get-Tail $text 10) -split "`n")) { if ($ln.Trim() -ne '') { Log ("    | " + $ln) } }
    return [pscustomobject]@{ Step = $step; ExitCode = $p.ExitCode; Seconds = [int]$sw.Elapsed.TotalSeconds; Output = $text }
}

# Пароль в кавычках с удвоением внутренней кавычки (правила CommandLineToArgvW): пароль
# с символом " иначе разрывает аргументы 1cv8.
function Quote-Password([string]$password) {
    return '"' + (('' + $password) -replace '"', '""') + '"'
}

# ИБ из конфига роли, при $withRepo — с параметрами хранилища конфигурации.
function Invoke-Designer([string]$step, [string]$commandPart, [int]$timeoutSec, [bool]$withRepo) {
    $conn = '/S ' + $cfg.server1c + '\' + $cfg.ib + ' /N ' + $cfg.ibUser + ' /P ' + (Quote-Password $cfg.ibPassword)
    if ($withRepo) {
        $conn += ' /ConfigurationRepositoryF "' + $cfg.repoPath + '"' +
            ' /ConfigurationRepositoryN "' + $cfg.repoUser + '" /ConfigurationRepositoryP ' + (Quote-Password $cfg.repoPassword)
    }
    return Invoke-Designer1cv8 $step $conn $commandPart $timeoutSec
}

# Произвольная серверная ИБ этого кластера (без хранилища) — для баз, которых нет в конфиге.
function Invoke-DesignerIb([string]$step, [string]$ib, [string]$user, [string]$password, [string]$commandPart, [int]$timeoutSec) {
    $conn = '/S ' + $cfg.server1c + '\' + $ib + ' /N ' + $user + ' /P ' + (Quote-Password $password)
    return Invoke-Designer1cv8 ($step + '[' + $ib + ']') $conn $commandPart $timeoutSec
}

# Файловая база (временная), без хранилища и пользователей.
function Invoke-DesignerF([string]$step, [string]$ibPath, [string]$commandPart, [int]$timeoutSec) {
    return Invoke-Designer1cv8 $step ('/F "' + $ibPath + '"') $commandPart $timeoutSec
}

function Add-DesignerStep($steps, $r) {
    [void]$steps.Add(@{ step = $r.Step; exitCode = $r.ExitCode; seconds = $r.Seconds; log = (Get-Tail $r.Output) })
}

# --- Служебные команды ----------------------------------------------------------
function Do-Ping() {
    return @{
        status = 'ok'; agent = $AgentVersion; role = $Role; host = $env:COMPUTERNAME; pid = $PID
        user = ($env:USERDOMAIN + '\' + $env:USERNAME); platform = $platformUsed
        platformConfigured = ('' + $cfg.platformVersion); platformsInstalled = $installedPlatforms
        server1c = ('' + $cfg.server1c); ib = ('' + $cfg.ib); share = $ShareRoot
    }
}

function Do-Sessions($cmd) {
    $r = Get-IbSessions ('' + $cmd.ib)
    $status = 'ok'
    if (-not $r.ok) { $status = 'error' }
    return @{ status = $status; ib = $r.ib; cluster = $r.cluster; clusterAddr = ('' + $cfg.clusterAddr);
        count = $r.count; sessions = $r.sessions; infobases = $r.infobases; error = $r.detail }
}

function Do-KillSessions($cmd) {
    $ib = Coalesce ('' + $cmd.ib) ('' + $cfg.ib)
    $k = Stop-IbSessions $ib
    $status = 'error'
    if ($k.ok) { $status = 'ok' }
    return @{ status = $status; ib = $ib; killed = $k.killed; left = $k.left; detail = $k.detail }
}

function Do-ComCheck($cmd) {
    # Достижимость чужой ИБ с ЭТОЙ машины по COM: TCP до портов кластера, версия зарегистрированного
    # comcntr, CLSID/AppID (по ним администратор ищет объект в dcomcnfg), учётка службы сервера 1С,
    # и, если задана ИБ, одно реальное внешнее соединение. Всё, кроме соединения, read-only.
    $result = @{ status = 'error'; host = $env:COMPUTERNAME; target = ('' + $cmd.server1c) }
    if (-not $cmd.server1c) { $result.error = 'нет параметра server1c'; return $result }

    # 1540 ragent, 1541 rmngr, 1560 — первый порт rphost.
    $tcp = @{}
    foreach ($port in @(1540, 1541, 1560)) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect($cmd.server1c, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(5000) -and $client.Connected) { $tcp[[string]$port] = 'open' }
            else { $tcp[[string]$port] = 'closed/timeout' }
        } catch { $tcp[[string]$port] = ('error: ' + $_.Exception.Message) } finally { $client.Close() }
    }
    $result.tcp = $tcp

    $result.comcntr = @{}
    $clsid = $null
    try { $clsid = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\V83.COMConnector\CLSID' -ErrorAction Stop).'(default)' } catch {}
    $result.clsid = ('' + $clsid)
    foreach ($hive in @(@{ name = 'x64'; path = 'Registry::HKEY_CLASSES_ROOT\CLSID' },
                        @{ name = 'x86'; path = 'Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID' })) {
        try {
            $dll = (Get-ItemProperty ($hive.path + '\' + $clsid + '\InprocServer32') -ErrorAction Stop).'(default)'
            $ver = (Get-Item $dll -ErrorAction Stop).VersionInfo.FileVersion
            $result.comcntr[$hive.name] = ("{0} ({1})" -f $ver, $dll)
        } catch { $result.comcntr[$hive.name] = 'нет' }
    }
    if ($clsid) {
        foreach ($p in @("Registry::HKEY_CLASSES_ROOT\CLSID\$clsid", "Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\$clsid")) {
            try {
                $appid = (Get-ItemProperty $p -ErrorAction Stop).AppID
                if ($appid) {
                    $result.appid = ('' + $appid)
                    try { $result.appidName = ('' + (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\AppID\$appid" -ErrorAction Stop).'(default)') } catch {}
                    break
                }
            } catch {}
        }
    }
    try {
        $svc = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.PathName -match 'ragent\.exe' })
        $result.service1c = @($svc | ForEach-Object { ("{0} = {1} (state {2})" -f $_.Name, $_.StartName, $_.State) })
    } catch { $result.service1c = ('не прочитана: ' + $_.Exception.Message) }
    $result.platforms = ($installedPlatforms -join ', ')

    if (-not $cmd.ib) { $result.status = 'ok'; $result.connect = 'пропущено (ib не задан)'; return $result }

    # Одна попытка: неудачные входы блокируют пользователя ИБ.
    $connector = $null; $conn = $null
    try {
        $connector = New-Object -ComObject 'V83.COMConnector'
        $pwd = ('' + $cmd.password) -replace '"', '""'
        $connStr = ('Srvr="{0}";Ref="{1}";Usr="{2}";Pwd="{3}";' -f $cmd.server1c, $cmd.ib, $cmd.user, $pwd)
        $t0 = Get-Date
        $conn = $connector.Connect($connStr)
        $result.connectSeconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        try { $result.config = ('' + $conn.Metadata.Name + ' ' + $conn.Metadata.Version) } catch {}
        $result.connect = 'ok'
        $result.status = 'ok'
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg += ' | ' + $_.Exception.InnerException.Message }
        $result.connect = ('ошибка: ' + $msg)
    } finally {
        foreach ($o in @($conn, $connector)) {
            if ($null -ne $o) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch {} }
        }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
    return $result
}

function Do-Peek($cmd) {
    # Файловая система сервера: каталог — список файлов, файл — хвост текста. Нужна, когда
    # код на сервере пишет логи туда, куда с рабочей станции не видно.
    $path = '' + $cmd.path
    if ([string]::IsNullOrEmpty($path)) { return @{ status = 'error'; error = 'не задан path' } }
    if (-not (Test-Path $path)) { return @{ status = 'ok'; exists = $false; path = $path } }

    $item = Get-Item -LiteralPath $path
    if ($item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue |
            Select-Object -First 50 | ForEach-Object {
                @{ name = $_.Name; size = $(if ($_.PSIsContainer) { -1 } else { $_.Length });
                   modified = ('' + $_.LastWriteTime) } })
        return @{ status = 'ok'; exists = $true; kind = 'dir'; path = $path; items = $files }
    }
    $tail = 30
    if ($cmd.tail) { $tail = [int]$cmd.tail }
    $text = ''
    try { $text = ((Get-Content -LiteralPath $path -Tail $tail -Encoding UTF8 -ErrorAction Stop) -join "`n") } catch { $text = ('не прочитан: ' + $_.Exception.Message) }
    return @{ status = 'ok'; exists = $true; kind = 'file'; path = $path; size = $item.Length;
        modified = ('' + $item.LastWriteTime); text = $text }
}

function Do-Fetch($cmd) {
    # Файл с диска СЕРВЕРА в artifacts папки обмена, то есть на рабочую станцию. Копирует сам
    # агент: процесс, запущенный через com-exec, видит другую проекцию \\tsclient и пишет мимо.
    $src = '' + $cmd.path
    if ([string]::IsNullOrEmpty($src)) { return @{ status = 'error'; error = 'не задан path' } }
    if (-not (Test-Path -LiteralPath $src)) { return @{ status = 'error'; error = ('нет файла: ' + $src) } }
    $name = Coalesce ('' + $cmd.name) (Split-Path $src -Leaf)
    $dst = Join-Path $artDir $name
    $srcSize = (Get-Item -LiteralPath $src).Length
    Log ("FETCH: {0} ({1} МБ) -> {2}" -f $src, [math]::Round($srcSize/1MB, 1), $dst)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop }
    catch { return @{ status = 'error'; error = ('копирование не удалось: ' + $_.Exception.Message) } }
    $sw.Stop()
    $dstSize = 0
    try { $dstSize = (Get-Item -LiteralPath $dst).Length } catch {}
    if ($dstSize -ne $srcSize) {
        return @{ status = 'error'; error = ('размер не совпал: источник {0}, копия {1}' -f $srcSize, $dstSize) }
    }
    return @{ status = 'ok'; artifact = ('artifacts/' + $name); sizeMB = [math]::Round($dstSize/1MB, 1);
              seconds = [int]$sw.Elapsed.TotalSeconds }
}

function Do-ComExec($cmd) {
    # VBScript на сервере, обычно — работа с ИБ через V83.COMConnector. PowerShell с объектами 1С
    # по позднему связыванию не работает (свойства приходят $null), поэтому только cscript.
    $script = '' + $cmd.script
    if ([string]::IsNullOrEmpty($script)) { return @{ status = 'error'; error = 'не задан script' } }

    $vbsPath = Join-Path $workRoot ('comexec-' + (Get-Date -Format 'HHmmss') + '.vbs')
    # cscript ждёт ANSI-кодировку исходника, иначе кириллица в скрипте бьётся.
    [System.IO.File]::WriteAllText($vbsPath, $script, [System.Text.Encoding]::GetEncoding(1251))

    $outFile = $vbsPath + '.out'
    $errFile = $vbsPath + '.err'
    $proc = Start-Process -FilePath 'cscript.exe' -ArgumentList ('//nologo "' + $vbsPath + '"') `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $timeout = 120
    if ($cmd.timeout) { $timeout = [int]$cmd.timeout }
    if (-not $proc.WaitForExit($timeout * 1000)) {
        try { $proc.Kill() } catch {}
        return @{ status = 'error'; error = ('таймаут ' + $timeout + ' с') }
    }

    # cscript пишет в консольной кодировке (866).
    $oem = [System.Text.Encoding]::GetEncoding(866)
    $out = ''; $err = ''
    try { $out = $oem.GetString([System.IO.File]::ReadAllBytes($outFile)) } catch {}
    try { $err = $oem.GetString([System.IO.File]::ReadAllBytes($errFile)) } catch {}
    try { Remove-Item $vbsPath, $outFile, $errFile -Force -ErrorAction SilentlyContinue } catch {}

    # ExitCode у Start-Process -PassThru после WaitForExit(int) бывает пустым — перечитываем.
    $code = 0
    try { $proc.Refresh(); if ($null -ne $proc.ExitCode) { $code = $proc.ExitCode } } catch {}
    $status = 'ok'
    if ($code -ne 0 -or ('' + $err).Trim() -ne '') { $status = 'error' }
    return @{ status = $status; exitCode = $code; output = ('' + $out); errors = ('' + $err) }
}

function Do-Windows($cmd) {
    # Все окна процессов 1С, включая дочерние и модальные. MainWindowTitle показывает только
    # главное окно, а пакетные ключи не выполняются как раз тогда, когда поверх висит диалог.
    $src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinList {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWnd, EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  public static List<string> All() {
    var res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
      var t = sb.ToString();
      if (t.Length > 0) res.Add(pid + "|" + (IsWindowVisible(h) ? "vis" : "hid") + "|" + t);
      // Текст диалога живёт в дочерних контролах: без них видно только «1С:Предприятие».
      EnumChildWindows(h, delegate(IntPtr ch, IntPtr l2) {
        var sb2 = new StringBuilder(512); GetWindowText(ch, sb2, 512);
        var t2 = sb2.ToString();
        if (t2.Length > 0) res.Add(pid + "|child|" + t2);
        return true;
      }, IntPtr.Zero);
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
'@
    try { Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue } catch {}

    $pids = @{}
    foreach ($pr in @(Get-Process -Name '1cv8','1cv8c' -ErrorAction SilentlyContinue)) { $pids[[string]$pr.Id] = $true }
    $rows = @()
    try {
        foreach ($row in [WinList]::All()) {
            $parts = $row -split '\|', 3
            if ($pids.ContainsKey($parts[0])) { $rows += @{ pid = $parts[0]; visible = $parts[1]; title = $parts[2] } }
        }
    } catch { return @{ status = 'error'; error = ('перечисление окон не удалось: ' + $_.Exception.Message) } }
    return @{ status = 'ok'; count = $rows.Count; windows = $rows }
}

function Do-Screenshot($cmd) {
    # Снимок экрана RDP-сессии: свои диалоги 1С рисует сама, через GetWindowText их текст
    # не прочитать. В отключённой сессии картинка может быть чёрной — это тоже ответ.
    try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop }
    catch { return @{ status = 'error'; error = ('нет сборок GDI: ' + $_.Exception.Message) } }

    $file = Coalesce ('' + $cmd.file) (Join-Path $ShareRoot 'log\screen.png')
    try { New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null } catch {}
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
        $g.Dispose()
        $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        $size = (Get-Item $file).Length
        $bmp.Dispose()
        return @{ status = 'ok'; file = $file; size = $size; width = $bounds.Width; height = $bounds.Height }
    } catch { return @{ status = 'error'; error = ('снимок не сделан: ' + $_.Exception.Message) } }
}

function Do-BuildEpf($cmd) {
    # Сборка внешней обработки из XML платформой СЕРВЕРА: .epf, собранный старшей платформой
    # рабочей станции, клиент кластера молча не открывает («Неизвестная версия формата»).
    $src = '' + $cmd.src
    $out = '' + $cmd.out
    if ([string]::IsNullOrEmpty($src) -or [string]::IsNullOrEmpty($out)) {
        return @{ status = 'error'; error = 'нужны параметры src (корневой XML) и out (файл .epf)' }
    }
    if (-not (Test-Path $src)) { return @{ status = 'error'; error = ('нет исходника: ' + $src) } }
    $t = Resolve-IbTarget $cmd
    $r = Invoke-DesignerIb 'BuildEpf' $t.ib $t.user $t.password `
        ('/LoadExternalDataProcessorOrReportFromFiles "' + $src + '" "' + $out + '"') 900
    if ($r.ExitCode -ne 0) {
        return @{ status = 'error'; error = ('LoadExternalDataProcessorOrReportFromFiles: exit=' + $r.ExitCode); log = (Get-Tail $r.Output) }
    }
    if (-not (Test-Path $out)) { return @{ status = 'error'; error = 'сборка прошла, но файла нет: ' + $out; log = (Get-Tail $r.Output) } }
    return @{ status = 'ok'; out = $out; size = (Get-Item $out).Length; platform = $platformUsed; log = (Get-Tail $r.Output) }
}

# --- MCP-транспорт: демон по COM ------------------------------------------------
# Внешняя обработка с ядром MCP открывается во внешнем соединении (V83.COMConnector) и обслуживает
# запросы из папки обмена — клиент 1С не нужен, лишних окон нет. Контракт обработки — в README.

function Get-McpClients([string]$ib) {
    $all = @()
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.Name -eq 'cscript.exe' -and $_.CommandLine -like '*mcp-daemon*.vbs*' })
    } catch { return @() }
    if ([string]::IsNullOrEmpty($ib)) { return $all }
    # Имя ИБ в командной строке демона стоит в кавычках.
    return @($all | Where-Object { $_.CommandLine -match ('"' + [regex]::Escape($ib) + '"') })
}

function Do-McpList($cmd) {
    $list = @(Get-McpClients ('' + $cmd.ib) | ForEach-Object {
        @{ pid = $_.ProcessId; started = ('' + $_.CreationDate); cmd = ('' + $_.CommandLine) }
    })
    # Заодно все окна 1С этой сессии: заголовок показывает, во что упёрся процесс.
    $all = @(Get-Process -Name '1cv8','1cv8c' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ pid = $_.Id; window = ('' + $_.MainWindowTitle) } })
    return @{ status = 'ok'; count = $list.Count; clients = $list; all1cv8 = $all }
}

function Do-McpStart($cmd) {
    $steps = New-Object System.Collections.ArrayList
    $t = Resolve-IbTarget $cmd

    $daemonSrc = Coalesce ('' + $cmd.daemon) (Join-Path $ShareRoot 'mcp-daemon.vbs')
    if (-not (Test-Path $daemonSrc)) { return @{ status = 'error'; error = ('нет демона: ' + $daemonSrc) } }

    $exchange = Coalesce ('' + $cmd.exchange) ('' + $cfg.mcpExchange)
    if ([string]::IsNullOrEmpty($exchange)) {
        return @{ status = 'error'; error = 'не задана папка обмена MCP: параметр exchange или mcpExchange в конфиге роли' }
    }
    $epfName = Coalesce ('' + $cmd.epf) ('' + $cfg.mcpEpf)
    if ([string]::IsNullOrEmpty($epfName)) { return @{ status = 'error'; error = 'не задано имя обработки: параметр epf или mcpEpf в конфиге роли' } }

    # .epf открывает СЕРВЕР 1С (rphost), а не этот скрипт: проброшенный \\tsclient серверу не виден.
    # Кластер локальный — держим копию на диске этой машины (mcpLocalDir) и обновляем из папки обмена по дате.
    # Кластер на другой машине — путь задаётся явно (epfServer / mcpEpfServer) и должен быть виден
    # именно rphost; проверить его отсюда нельзя, обновление файла — на человеке.
    $serverEpf = Coalesce ('' + $cmd.epfServer) ('' + $cfg.mcpEpfServer)
    if ([string]::IsNullOrEmpty($serverEpf)) {
        $shareEpf = Join-Path $ShareRoot $epfName
        if (-not (Test-Path $shareEpf)) { return @{ status = 'error'; error = ('нет обработки: ' + $shareEpf) } }
        $localDir = Coalesce ('' + $cfg.mcpLocalDir) 'C:\ProgramData\deploy-agent\mcp'
        $serverEpf = Join-Path $localDir $epfName
        try {
            New-Item -ItemType Directory -Force -Path $localDir | Out-Null
            $needCopy = $true
            if (Test-Path $serverEpf) {
                $needCopy = ((Get-Item $shareEpf).LastWriteTimeUtc -gt (Get-Item $serverEpf).LastWriteTimeUtc)
            }
            if ($needCopy) {
                Copy-Item -LiteralPath $shareEpf -Destination $serverEpf -Force
                [void]$steps.Add(@{ step = 'copy-epf-local'; to = $serverEpf })
            }
        } catch { return @{ status = 'error'; error = ('не удалось разложить .epf локально: ' + $_.Exception.Message) } }
    } else {
        [void]$steps.Add(@{ step = 'epf-server-path'; path = $serverEpf; note = 'путь для rphost, агентом не проверяется' })
    }

    $already = @(Get-McpClients $t.ib)
    if ($already.Count -gt 0 -and $cmd.force -ne $true) {
        return @{ status = 'ok'; note = 'MCP-транспорт этой ИБ уже работает, новый не поднимаю (force=true — поднять ещё)';
            ib = $t.ib; pids = @($already | ForEach-Object { $_.ProcessId }) }
    }

    # Сеансы снимаем только по явной просьбе: команда бьёт и по живым пользователям базы.
    if ($cmd.kill -eq $true) { $fail = Invoke-KillStep $steps $t.ib; if ($fail) { return $fail } }

    # Демон хранится в UTF-8, а cscript ждёт ANSI — конвертируем в рабочий каталог перед запуском.
    $daemon = Join-Path $workRoot 'mcp-daemon.vbs'
    try {
        $text = [System.IO.File]::ReadAllText($daemonSrc, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($daemon, $text, [System.Text.Encoding]::GetEncoding(1251))
    } catch { return @{ status = 'error'; error = ('не удалось подготовить демон: ' + $_.Exception.Message) } }

    # Выполнение произвольного кода демон включает только по явному allowCode.
    $daemonAllowCode = ''
    if ($cmd.allowCode -eq $true) { $daemonAllowCode = 'code' }
    $argLine = '//nologo "' + $daemon + '" "' + $t.ib + '" "' + $t.user + '" "' + $t.password + '" "' + $exchange + '" "' +
        $cfg.server1c + '" "' + $serverEpf + '" "' + $daemonAllowCode + '"'
    Log ("mcp-start: cscript демон [{0}] -> {1} (код {2})" -f $t.ib, $exchange,
        $(if ($daemonAllowCode -eq 'code') { 'разрешён' } else { 'запрещён' }))

    $proc = $null
    try { $proc = Start-Process -FilePath 'cscript.exe' -ArgumentList $argLine -PassThru -WindowStyle Hidden }
    catch { return @{ status = 'error'; error = ('не удалось запустить демон: ' + $_.Exception.Message); steps = $steps } }

    # Демон должен ОСТАТЬСЯ жить: ранний выход = не поднялось COM-соединение или не открылась обработка.
    Start-Sleep -Seconds 15
    $proc.Refresh()
    $daemonLog = ''
    try {
        $lp = Join-Path $exchange 'daemon.log'
        if (Test-Path $lp) { $daemonLog = ((Get-Content -LiteralPath $lp -Tail 5 -ErrorAction SilentlyContinue) -join "`n") }
    } catch {}
    if ($proc.HasExited) {
        return @{ status = 'error'; ib = $t.ib; exitCode = $proc.ExitCode; steps = $steps; daemonLog = $daemonLog;
            error = ('демон завершился сразу (exit=' + $proc.ExitCode + ')') }
    }
    [void]$steps.Add(@{ step = 'start-daemon'; pid = $proc.Id })
    return @{ status = 'ok'; ib = $t.ib; pid = $proc.Id; exchange = $exchange; steps = $steps; daemonLog = $daemonLog;
        epf = $serverEpf; note = ('MCP-транспорт поднят для ' + $t.ib + ' через COM-соединение, клиент 1С не задействован.') }
}

function Do-McpStop($cmd) {
    $clients = @(Get-McpClients ('' + $cmd.ib))
    if ($clients.Count -eq 0) { return @{ status = 'ok'; note = 'MCP-демонов не найдено'; stopped = 0 } }
    $stopped = 0; $errors = ''
    foreach ($c in $clients) {
        try { Stop-Process -Id $c.ProcessId -Force -ErrorAction Stop; $stopped++ }
        catch { $errors += ('pid ' + $c.ProcessId + ': ' + $_.Exception.Message + '; ') }
    }
    $status = 'ok'
    if ($errors -ne '') { $status = 'error' }
    return @{ status = $status; stopped = $stopped; detail = $errors }
}

# --- Расширения и выгрузки (база без хранилища) ---------------------------------
function Do-ExtList($cmd) {
    # Штатного ключа «перечислить расширения» у Конфигуратора нет: выгружаем все расширения
    # в файлы и читаем имена каталогов — заодно видно объём.
    $t = Resolve-IbTarget $cmd
    $dir = Join-Path $workRoot ('ext-list-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $r = Invoke-DesignerIb 'ExtList' $t.ib $t.user $t.password ('/DumpConfigToFiles "' + $dir + '" -AllExtensions') 1800
    if ($r.ExitCode -ne 0) {
        try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        return @{ status = 'error'; ib = $t.ib; error = ('DumpConfigToFiles -AllExtensions: exit=' + $r.ExitCode); log = (Get-Tail $r.Output) }
    }
    $list = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $files = @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $bytes = 0
        foreach ($f in $files) { $bytes += $f.Length }
        @{ name = $_.Name; files = $files.Count; sizeKB = [math]::Round($bytes / 1KB, 1) }
    })
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    return @{ status = 'ok'; ib = $t.ib; count = $list.Count; extensions = $list; seconds = $r.Seconds }
}

function Do-ExtDump($cmd) {
    # Действующее расширение в .cfe — бэкап перед установкой новой версии.
    $t = Resolve-IbTarget $cmd
    $ext = '' + $cmd.extension
    if ([string]::IsNullOrEmpty($ext)) { return @{ status = 'error'; error = 'не задано extension (имя расширения в базе)' } }
    $name = Coalesce ('' + $cmd.name) ($ext + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.cfe')
    $local = Join-Path $workRoot $name
    $r = Invoke-DesignerIb 'ExtDump' $t.ib $t.user $t.password ('/DumpCfg "' + $local + '" -Extension "' + $ext + '"') 900
    if ($r.ExitCode -ne 0 -or -not (Test-Path $local)) {
        return @{ status = 'error'; ib = $t.ib; extension = $ext;
            error = ('DumpCfg -Extension: exit=' + $r.ExitCode + ', файл есть=' + (Test-Path $local)); log = (Get-Tail $r.Output) }
    }
    $dst = Join-Path $artDir $name
    Copy-Item -LiteralPath $local -Destination $dst -Force
    $sizeKB = [math]::Round((Get-Item -LiteralPath $dst).Length / 1KB, 1)
    Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
    return @{ status = 'ok'; ib = $t.ib; extension = $ext; artifact = ('artifacts/' + $name); sizeKB = $sizeKB; seconds = $r.Seconds }
}

function Do-ExtInstall($cmd) {
    # .cfe из artifacts (или с диска сервера) → локальная копия → /LoadCfg -Extension →
    # отдельным запуском /UpdateDBCfg -Extension. Перед установкой снимается бэкап прежней версии.
    $steps = New-Object System.Collections.ArrayList
    $t = Resolve-IbTarget $cmd
    $ext = '' + $cmd.extension
    if ([string]::IsNullOrEmpty($ext)) { return @{ status = 'error'; error = 'не задано extension (имя расширения в базе)' } }

    $src = '' + $cmd.path
    if ([string]::IsNullOrEmpty($src)) {
        $cfe = '' + $cmd.cfe
        if ([string]::IsNullOrEmpty($cfe)) { return @{ status = 'error'; error = 'не задан cfe (файл в artifacts) или path (файл на диске сервера)' } }
        $src = Join-Path $artDir $cfe
    }
    if (-not (Test-Path -LiteralPath $src)) { return @{ status = 'error'; error = ('нет файла расширения: ' + $src) } }

    if ($cmd.backup -ne $false) {
        $b = Do-ExtDump @{ ib = $t.ib; user = $t.user; password = $t.password; extension = $ext;
            name = ($ext + '-before-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.cfe') }
        if ($b.status -eq 'ok') { [void]$steps.Add(@{ step = 'backup'; artifact = $b.artifact; sizeKB = $b.sizeKB }) }
        else { [void]$steps.Add(@{ step = 'backup'; skipped = $true; detail = ('' + $b.error) }) }
    }

    # Через RDP-канал платформа читает файл мучительно долго — копия на локальный диск.
    $localCfe = Join-Path $workRoot ('install-' + (Get-Date -Format 'HHmmss') + '.cfe')
    try { Copy-Item -LiteralPath $src -Destination $localCfe -Force -ErrorAction Stop }
    catch { return @{ status = 'error'; error = ('не скопировал .cfe локально: ' + $_.Exception.Message); steps = $steps } }
    [void]$steps.Add(@{ step = 'copy-local'; from = $src; to = $localCfe; sizeKB = [math]::Round((Get-Item $localCfe).Length / 1KB, 1) })

    if ($cmd.kill -eq $true) { $fail = Invoke-KillStep $steps $t.ib; if ($fail) { return $fail } }

    $r = Invoke-DesignerIb 'LoadCfgExt' $t.ib $t.user $t.password ('/LoadCfg "' + $localCfe + '" -Extension "' + $ext + '"') 1800
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) {
        Remove-Item -LiteralPath $localCfe -Force -ErrorAction SilentlyContinue
        return @{ status = 'error'; error = ('LoadCfg -Extension: exit=' + $r.ExitCode); steps = $steps }
    }

    # LoadCfg и UpdateDBCfg в одном запуске платформа не принимает («Ошибка в параметрах командной строки»).
    $r = Invoke-DesignerIb 'UpdateDBCfgExt' $t.ib $t.user $t.password ('/UpdateDBCfg -Extension "' + $ext + '"') 1800
    Add-DesignerStep $steps $r
    Remove-Item -LiteralPath $localCfe -Force -ErrorAction SilentlyContinue
    if ($r.ExitCode -ne 0) {
        return @{ status = 'error'; error = ('UpdateDBCfg -Extension: exit=' + $r.ExitCode +
            '. База в промежуточном состоянии (LoadCfg прошёл): проверьте сообщение платформы, при необходимости верните бэкап из artifacts.'); steps = $steps }
    }
    return @{ status = 'ok'; ib = $t.ib; extension = $ext; source = $src; steps = $steps }
}

function Do-DumpCf($cmd) {
    $t = Resolve-IbTarget $cmd
    $name = Coalesce ('' + $cmd.name) ($t.ib + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.cf')
    $local = Join-Path $workRoot $name
    $r = Invoke-DesignerIb 'DumpCfg' $t.ib $t.user $t.password ('/DumpCfg "' + $local + '"') 3600
    if ($r.ExitCode -ne 0 -or -not (Test-Path $local)) {
        return @{ status = 'error'; ib = $t.ib; error = ('DumpCfg: exit=' + $r.ExitCode + ', файл есть=' + (Test-Path $local)); log = (Get-Tail $r.Output) }
    }
    $hash = (Get-FileHash -Path $local -Algorithm SHA256).Hash
    $sizeMB = [math]::Round((Get-Item $local).Length / 1MB, 1)
    Log ("Копирую конфигурацию в папку обмена ({0} МБ)..." -f $sizeMB)
    Publish-Artifact $local $name
    return @{ status = 'ok'; ib = $t.ib; artifact = ('artifacts/' + $name); sha256 = $hash; sizeMB = $sizeMB; seconds = $r.Seconds }
}

# Файл в artifacts атомарно: сначала .tmp, потом переименование, чтобы оркестратор не забрал
# недокопированный файл. Локальный оригинал удаляется.
function Publish-Artifact([string]$localPath, [string]$name) {
    $tmp = Join-Path $artDir ($name + '.tmp')
    Copy-Item -Path $localPath -Destination $tmp -Force
    Rename-Item -Path $tmp -NewName $name
    Remove-Item -Path $localPath -Force -ErrorAction SilentlyContinue
}

function Do-DumpDt($cmd) {
    # Выгрузка ИБ целиком: монопольный режим и десятки ГБ. Файл остаётся НА СЕРВЕРЕ,
    # на рабочую станцию его тянут отдельной командой fetch (по RDP-каналу это часы).
    $t = Resolve-IbTarget $cmd
    if ($cmd.kill -ne $true) {
        return @{ status = 'error'; error = 'DumpIB требует монопольного доступа: повторите с kill=true (все сеансы базы будут сняты)' }
    }
    $dir = Coalesce ('' + $cmd.dir) ('' + $cfg.dumpDir)
    if ([string]::IsNullOrEmpty($dir)) { return @{ status = 'error'; error = 'не задан dir (каталог на диске сервера под .dt) и нет dumpDir в конфиге' } }
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { return @{ status = 'error'; error = ('нет каталога ' + $dir + ': ' + $_.Exception.Message) } }
    }
    $freeGB = -1
    try {
        $drive = (Get-Item -LiteralPath $dir).PSDrive
        if ($drive) { $freeGB = [math]::Round($drive.Free / 1GB, 1) }
    } catch {}

    $steps = New-Object System.Collections.ArrayList
    $fail = Invoke-KillStep $steps $t.ib; if ($fail) { return $fail }

    $name = Coalesce ('' + $cmd.name) ($t.ib + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.dt')
    $file = Join-Path $dir $name
    $timeout = 21600
    if ($cmd.timeout) { $timeout = [int]$cmd.timeout }
    $r = Invoke-DesignerIb 'DumpIB' $t.ib $t.user $t.password ('/DumpIB "' + $file + '"') $timeout
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0 -or -not (Test-Path $file)) {
        return @{ status = 'error'; ib = $t.ib; freeGBbefore = $freeGB;
            error = ('DumpIB: exit=' + $r.ExitCode + ', файл есть=' + (Test-Path $file)); steps = $steps }
    }
    $sizeGB = [math]::Round((Get-Item -LiteralPath $file).Length / 1GB, 2)
    return @{ status = 'ok'; ib = $t.ib; path = $file; sizeGB = $sizeGB; seconds = $r.Seconds; steps = $steps;
        note = 'файл остался на сервере; забрать на рабочую станцию — командой fetch' }
}

function Do-LoadCf($cmd) {
    # Полная замена конфигурации произвольной ИБ кластера файлом .cf из artifacts — для случаев,
    # когда две базы должны стать идентичными. Точечная доставка по объектам — test + commit.
    $steps = New-Object System.Collections.ArrayList
    foreach ($p in @('ib', 'user', 'password', 'cf')) {
        if ([string]::IsNullOrEmpty(('' + $cmd.$p))) { return @{ status = 'error'; error = ('не задан параметр ' + $p) } }
    }
    $src = Join-Path $artDir $cmd.cf
    if (-not (Test-Path $src)) { return @{ status = 'error'; error = ('нет файла cf: ' + $src) } }

    $fail = Invoke-KillStep $steps $cmd.ib; if ($fail) { return $fail }

    $localCf = Join-Path $workRoot ('load-' + (Get-Date -Format 'HHmmss') + '.cf')
    $swCopy = [System.Diagnostics.Stopwatch]::StartNew()
    Copy-Item $src $localCf -Force
    $swCopy.Stop()
    [void]$steps.Add(@{ step = 'copy-cf-local'; seconds = [int]$swCopy.Elapsed.TotalSeconds })

    $r = Invoke-DesignerIb 'LoadCfg' $cmd.ib $cmd.user $cmd.password ('/LoadCfg "' + $localCf + '"') 3600
    Add-DesignerStep $steps $r
    try { Remove-Item $localCf -Force -ErrorAction SilentlyContinue } catch {}
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('LoadCfg: exit=' + $r.ExitCode + '. Конфигурация БД не менялась.'); alarm = $true; steps = $steps } }

    $r = Invoke-DesignerIb 'UpdateDBCfg' $cmd.ib $cmd.user $cmd.password '/UpdateDBCfg' 5400
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('UpdateDBCfg: exit=' + $r.ExitCode + '. Конфигурация загружена, но не применена к БД.'); alarm = $true; steps = $steps } }

    return @{ status = 'ok'; note = ('Конфигурация ' + $cmd.cf + ' загружена в ' + $cmd.ib + ' и применена к БД.'); steps = $steps }
}

# --- Хранилище конфигурации -----------------------------------------------------
function Test-RepoConfigured() {
    return -not [string]::IsNullOrEmpty('' + $cfg.repoPath)
}

function Do-RepoUnbind($cmd) {
    # Нужна, когда база перезалита или подключена к хранилищу под другим пользователем:
    # RepoUpdateCfg тогда падает с «Пользователь существующей связи отличается от текущего»,
    # а сменить пользователя связи пакетно нельзя — только снять связь и установить заново (pull).
    $steps = New-Object System.Collections.ArrayList
    $fail = Invoke-KillStep $steps; if ($fail) { return $fail }
    $r = Invoke-Designer 'RepoUnbind' '/ConfigurationRepositoryUnbindCfg -force' 900 $false
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('ConfigurationRepositoryUnbindCfg: exit=' + $r.ExitCode); steps = $steps } }
    return @{ status = 'ok'; note = 'база отвязана от хранилища; следующий pull привяжет её под пользователем из конфига'; steps = $steps }
}

function Do-Pull() {
    # Обновление базы из хранилища и снимок конфигурации в artifacts. Версию хранилища
    # фиксирует SHA256 снимка: ключ /ConfigurationRepositoryReport на большом хранилище виснет.
    $steps = New-Object System.Collections.ArrayList
    $fail = Invoke-KillStep $steps; if ($fail) { return $fail }

    $r = Invoke-Designer 'RepoUpdateCfg' '/ConfigurationRepositoryUpdateCfg -force' 3600 $true
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('ConfigurationRepositoryUpdateCfg: exit=' + $r.ExitCode); steps = $steps } }

    $r = Invoke-Designer 'UpdateDBCfg' '/UpdateDBCfg' 1800 $false
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('UpdateDBCfg: exit=' + $r.ExitCode); steps = $steps } }

    $cfName = 'snapshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.cf'
    $localCf = Join-Path $workRoot $cfName
    $r = Invoke-Designer 'DumpCfg' ('/DumpCfg "' + $localCf + '"') 1800 $false
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0 -or -not (Test-Path $localCf)) {
        return @{ status = 'error'; error = ('DumpCfg: exit=' + $r.ExitCode + ', файл есть=' + (Test-Path $localCf)); steps = $steps }
    }
    $hash = (Get-FileHash -Path $localCf -Algorithm SHA256).Hash
    $sizeMB = [math]::Round((Get-Item $localCf).Length / 1MB, 1)
    Log ("Копирую снимок в папку обмена ({0} МБ)..." -f $sizeMB)
    Publish-Artifact $localCf $cfName
    return @{ status = 'ok'; artifact = ('artifacts/' + $cfName); sha256 = $hash; sizeMB = $sizeMB; steps = $steps }
}

function Do-Test($cmd) {
    # Захват объектов в хранилище → наложение release.cf → UpdateDBCfg. После успеха объекты
    # остаются захваченными до commit (помещение) или unlock (откат).
    $steps = New-Object System.Collections.ArrayList
    $objects  = Join-Path $artDir $cmd.objects
    $release  = Join-Path $artDir $cmd.release
    $settings = Join-Path $artDir $cmd.settings
    if (-not (Test-Path $objects)) { return @{ status = 'error'; error = ('нет файла objects: ' + $objects) } }

    $fail = Invoke-KillStep $steps; if ($fail) { return $fail }

    $r = Invoke-Designer 'Lock' ('/ConfigurationRepositoryLock -objects "' + $objects + '"') 900 $true
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = 'ЗАХВАТ НЕ УДАЛСЯ — объект занят или база не на последней версии. Тестовая не тронута.'; alarm = $true; steps = $steps } }

    # Три способа наложить release.cf:
    #   mergecfg  — /MergeCfg с настройками объединения (по умолчанию; проверен на живом хранилище);
    #   loadcfg   — /LoadCfg целиком (быстро, но база на поддержке хранилища его отвергает:
    #               «изменение конфигурации запрещено»);
    #   loadfiles — release.cf → временная файловая база → DumpConfigToFiles -Objects →
    #               LoadConfigFromFiles (нужно, когда XML рабочей станции новее платформы сервера).
    $method = Coalesce ('' + $cmd.method) 'mergecfg'
    if ($method -eq 'loadfiles') {
        if (-not (Test-Path $release)) { return @{ status = 'error'; error = ('нет файла release: ' + $release); steps = $steps } }
        $stampF = Get-Date -Format 'yyyyMMdd-HHmmss'
        $mib  = Join-Path $workRoot ('lf-ib-' + $stampF)
        $msrc = Join-Path $workRoot ('lf-src-' + $stampF)
        New-Item -ItemType Directory -Force -Path $mib | Out-Null
        New-Item -ItemType Directory -Force -Path $msrc | Out-Null

        $c = Start-Process -FilePath $designerExe -ArgumentList ('CREATEINFOBASE File="' + $mib + '" /DisableStartupDialogs /DisableStartupMessages') -PassThru -Wait -WindowStyle Hidden
        if ($c.ExitCode -ne 0) { return @{ status = 'error'; error = 'CREATEINFOBASE временной базы не удалась'; steps = $steps } }

        $r = Invoke-DesignerF 'lf-LoadCfg' $mib ('/LoadCfg "' + $release + '"') 1800
        Add-DesignerStep $steps $r
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('LoadCfg release во временную базу: exit=' + $r.ExitCode); alarm = $true; steps = $steps } }

        $r = Invoke-DesignerF 'lf-Dump' $mib ('/DumpConfigToFiles "' + $msrc + '" -Objects "' + $objects + '"')  1800
        Add-DesignerStep $steps $r
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('DumpConfigToFiles -Objects: exit=' + $r.ExitCode); alarm = $true; steps = $steps } }

        $r = Invoke-Designer 'LoadConfigFromFiles' ('/LoadConfigFromFiles "' + $msrc + '"') 900 $false
        Add-DesignerStep $steps $r
        try { Remove-Item $mib -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item $msrc -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('LoadConfigFromFiles: exit=' + $r.ExitCode + '. Объекты остались захвачены — разобрать вручную.'); alarm = $true; steps = $steps } }
    } elseif ($method -eq 'loadcfg') {
        $r = Invoke-Designer 'LoadCfg' ('/LoadCfg "' + $release + '"') 1800 $false
        Add-DesignerStep $steps $r
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('LoadCfg: exit=' + $r.ExitCode + '. На базе с хранилищем LoadCfg обычно запрещён — используйте mergecfg или loadfiles.'); alarm = $true; steps = $steps } }
    } else {
        if (-not (Test-Path $release))  { return @{ status = 'error'; error = ('нет файла release: ' + $release); steps = $steps } }
        if (-not (Test-Path $settings)) { return @{ status = 'error'; error = ('нет файла settings: ' + $settings); steps = $steps } }
        # MergeCfg читает .cf многократно, а через RDP-канал это превращает 20-секундное
        # объединение в полчаса. Локальная копия — и объединение снова идёт за секунды.
        $localRel = Join-Path $workRoot ('merge-' + (Get-Date -Format 'HHmmss') + '.cf')
        $swCopy = [System.Diagnostics.Stopwatch]::StartNew()
        Copy-Item $release $localRel -Force
        $swCopy.Stop()
        [void]$steps.Add(@{ step = 'copy-release-local'; seconds = [int]$swCopy.Elapsed.TotalSeconds })
        $r = Invoke-Designer 'MergeCfg' ('/MergeCfg "' + $localRel + '" -Settings "' + $settings + '" -Objects "' + $objects + '"') 3600 $false
        Add-DesignerStep $steps $r
        try { Remove-Item $localRel -Force -ErrorAction SilentlyContinue } catch {}
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('MergeCfg: exit=' + $r.ExitCode + '. Объекты остались захвачены — разобрать вручную.'); alarm = $true; steps = $steps } }
    }

    $r = Invoke-Designer 'UpdateDBCfg' '/UpdateDBCfg' 1800 $false
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('UpdateDBCfg: exit=' + $r.ExitCode); alarm = $true; steps = $steps } }

    return @{ status = 'ok'; note = 'Объединено и применено. Объекты захвачены: проверьте тестовую базу, затем commit или unlock.'; steps = $steps }
}

function Do-Commit($cmd) {
    $steps = New-Object System.Collections.ArrayList
    $objects = Join-Path $artDir $cmd.objects
    if (-not (Test-Path $objects)) { return @{ status = 'error'; error = ('нет файла objects: ' + $objects) } }
    $comment = Coalesce ('' + $cmd.comment) 'deploy commit'

    $r = Invoke-Designer 'Commit' ('/ConfigurationRepositoryCommit -objects "' + $objects + '" -comment "' + $comment + '"') 1800 $true
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('Commit: exit=' + $r.ExitCode + '. Объекты остались захвачены.'); alarm = $true; steps = $steps } }

    # Остаточные захваты: объекты из списка, которые по факту не изменились, Commit не отпускает.
    $r = Invoke-Designer 'Unlock' ('/ConfigurationRepositoryUnlock -objects "' + $objects + '" -force') 900 $true
    Add-DesignerStep $steps $r
    return @{ status = 'ok'; note = 'Помещено в хранилище, остаточные захваты сняты.'; steps = $steps }
}

function Do-Unlock($cmd) {
    $steps = New-Object System.Collections.ArrayList
    $objects = Join-Path $artDir $cmd.objects
    if (-not (Test-Path $objects)) { return @{ status = 'error'; error = ('нет файла objects: ' + $objects) } }
    $r = Invoke-Designer 'Unlock' ('/ConfigurationRepositoryUnlock -objects "' + $objects + '" -force') 900 $true
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('Unlock: exit=' + $r.ExitCode + '. Захват НЕ снят — проверьте вручную в Конфигураторе.'); alarm = $true; steps = $steps } }
    return @{ status = 'ok'; note = 'Захват снят, версия в хранилище НЕ создана (откат).'; steps = $steps }
}

# Признаки исхода динамического обновления в выводе платформы. Тексты зависят от языка
# интерфейса платформы; здесь — русский. Для другой локали поправьте шаблоны.
$DynamicOkPattern   = 'Обновление конфигурации успешно завершено'
$DynamicNeedMonoPattern = 'монопол|реструктуриз|невозможно|завершить работу'

# Обновление БОЕВОЙ базы из хранилища: hot (динамически, без завершения сеансов; стоп, если
# динамически не применилось) или full (завершить сеансы, применить монопольно).
# Оба режима начинаются с бэкапа конфигурации в artifacts.
function Do-UpdateProd($cmd) {
    if ($Role -ne 'prod') { return @{ status = 'error'; error = 'update-prod допустим только на агенте с ролью prod' } }
    $mode = '' + $cmd.mode
    if ($mode -ne 'hot' -and $mode -ne 'full') { return @{ status = 'error'; error = "режим не указан или неверен (ожидается hot|full): '$mode'" } }
    $steps = New-Object System.Collections.ArrayList

    $backupName = 'prod-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.cf'
    $backupLocal = Join-Path $workRoot $backupName
    $r = Invoke-Designer 'BackupDumpCfg' ('/DumpCfg "' + $backupLocal + '"') 1800 $false
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('бэкап НЕ создан (exit=' + $r.ExitCode + ') — обновление НЕ начато'); alarm = $true; steps = $steps } }
    try { Copy-Item $backupLocal (Join-Path $artDir $backupName) -Force } catch {}

    if ($mode -eq 'full') {
        $fail = Invoke-KillStep $steps
        if ($fail) { $fail.error += ' — обновление НЕ начато'; $fail.alarm = $true; $fail.backup = $backupName; return $fail }

        $r = Invoke-Designer 'RepoUpdateCfg' '/ConfigurationRepositoryUpdateCfg -force' 3600 $true
        Add-DesignerStep $steps $r
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('ConfigurationRepositoryUpdateCfg: exit=' + $r.ExitCode); alarm = $true; backup = $backupName; steps = $steps } }

        $r = Invoke-Designer 'UpdateDBCfg' '/UpdateDBCfg' 1800 $false
        Add-DesignerStep $steps $r
        if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('UpdateDBCfg (full): exit=' + $r.ExitCode + '. Сеансы завершены, БД в промежуточном состоянии — откат руками из ' + $backupName + ', решение человека.'); alarm = $true; backup = $backupName; steps = $steps } }
        return @{ status = 'ok'; mode = 'full'; note = ('База обновлена в режиме full (сеансы завершены). Бэкап: ' + $backupName); backup = $backupName; steps = $steps }
    }

    $r = Invoke-Designer 'RepoUpdateCfg' '/ConfigurationRepositoryUpdateCfg -force' 3600 $true
    Add-DesignerStep $steps $r
    if ($r.ExitCode -ne 0) { return @{ status = 'error'; error = ('ConfigurationRepositoryUpdateCfg (hot): exit=' + $r.ExitCode + '. Конфигурация не подтянута, БД не тронута.'); alarm = $true; backup = $backupName; steps = $steps } }

    $r = Invoke-Designer 'UpdateDBCfgDynamic' '/UpdateDBCfg -Dynamic+' 1800 $false
    Add-DesignerStep $steps $r
    # Динамика удалась только если exit=0, платформа отчиталась об успехе и нет признаков
    # требования монопольного режима.
    $applied  = ($r.ExitCode -eq 0) -and ($r.Output -match $DynamicOkPattern)
    $needMono = ($r.Output -match $DynamicNeedMonoPattern)
    if ((-not $applied) -or $needMono) {
        return @{ status = 'error'; hotDynamicFailed = $true;
            error = ('Динамическое обновление не применилось (нужен монопольный режим или реструктуризация). Конфигурация подтянута из хранилища, к БД НЕ применена, сеансы НЕ завершались. СТОП — решение за человеком: full доприменит монопольно, либо откат из ' + $backupName + '.');
            backup = $backupName; steps = $steps }
    }
    return @{ status = 'ok'; mode = 'hot'; note = ('База обновлена динамически, без завершения сеансов. Бэкап: ' + $backupName); backup = $backupName; steps = $steps }
}

# --- Основной цикл --------------------------------------------------------------
$repoCommands = @('pull', 'repo-unbind', 'test', 'commit', 'unlock', 'update-prod')

function Invoke-Command1($cmd) {
    if (($repoCommands -contains $cmd.command) -and -not (Test-RepoConfigured)) {
        return @{ status = 'error'; error = ("у роли '" + $Role + "' нет хранилища конфигурации (repoPath) — команда " + $cmd.command + " неприменима") }
    }
    switch ($cmd.command) {
        'ping'          { return Do-Ping }
        'sessions'      { return Do-Sessions $cmd }
        'kill-sessions' { return Do-KillSessions $cmd }
        'com-check'     { return Do-ComCheck $cmd }
        'peek'          { return Do-Peek $cmd }
        'fetch'         { return Do-Fetch $cmd }
        'com-exec'      { return Do-ComExec $cmd }
        'windows'       { return Do-Windows $cmd }
        'screenshot'    { return Do-Screenshot $cmd }
        'build-epf'     { return Do-BuildEpf $cmd }
        'mcp-start'     { return Do-McpStart $cmd }
        'mcp-stop'      { return Do-McpStop $cmd }
        'mcp-list'      { return Do-McpList $cmd }
        'ext-list'      { return Do-ExtList $cmd }
        'ext-dump'      { return Do-ExtDump $cmd }
        'ext-install'   { return Do-ExtInstall $cmd }
        'dump-cf'       { return Do-DumpCf $cmd }
        'dump-dt'       { return Do-DumpDt $cmd }
        'load-cf'       { return Do-LoadCf $cmd }
        'repo-unbind'   { return Do-RepoUnbind $cmd }
        'pull'          { return Do-Pull }
        'test'          { return Do-Test $cmd }
        'commit'        { return Do-Commit $cmd }
        'unlock'        { return Do-Unlock $cmd }
        'update-prod'   { return Do-UpdateProd $cmd }
        'reload'        {
            # Новая копия агента из папки обмена, эта завершается. Роль передаётся явно:
            # при автоопределении по hostPattern новая копия иначе могла бы не стартовать.
            Log 'RELOAD: запускаю новую копию агента из папки обмена и завершаюсь.'
            $args = '-ExecutionPolicy Bypass -File "' + (Join-Path $ShareRoot 'deploy-agent.ps1') + '" -Role ' + $Role + ' -ShareRoot "' + $ShareRoot + '"'
            try { Start-Process -FilePath 'powershell.exe' -ArgumentList $args } catch { Log ('reload не удался: ' + $_) }
            $script:running = $false
            return @{ status = 'ok'; note = 'агент перезапускается на новую версию (reload)' }
        }
        'stop'          { $script:running = $false; return @{ status = 'ok'; note = 'агент остановлен' } }
        default         { return @{ status = 'error'; error = ('неизвестная команда: ' + $cmd.command) } }
    }
}

Log ("Опрашиваю {0} каждые {1} с. Остановка: команда stop или Ctrl+C." -f $inDir, $PollSeconds)
Copy-AgentLogToShare
$running = $true
$lastHeartbeat = [datetime]::MinValue

while ($running) {
    # Вытеснение: lock захватил другой (более новый) экземпляр — выходим.
    try {
        if (Test-Path $lockFile) {
            $owner = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($owner -ne '' -and $owner -ne [string]$PID) { Log ("Вытеснен новым экземпляром (lock=" + $owner + "), выхожу."); break }
        }
    } catch {}

    if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 60) {
        $hb = @{ agent = $AgentVersion; role = $Role; host = $env:COMPUTERNAME; time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json -Compress
        try { [System.IO.File]::WriteAllText((Join-Path $outDir 'agent-status.json'), $hb, (New-Object System.Text.UTF8Encoding($true))) } catch {}
        $lastHeartbeat = Get-Date
    }

    $files = @(Get-ChildItem -Path (Join-Path $inDir '*.json') -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $cmd = $null
        try { $cmd = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Log ("Битый JSON: " + $f.Name) }
        if ($null -eq $cmd) {
            $reply = @{ status = 'error'; error = 'битый JSON в команде' }
        } else {
            Log ("Команда {0}: {1}" -f $id, $cmd.command)
            try { $reply = Invoke-Command1 $cmd }
            catch { $reply = @{ status = 'error'; error = ('исключение в агенте: ' + $_.Exception.Message) } }
        }
        $reply.id = $id
        $reply.finished = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

        # Ответ тоже атомарно: локальный файл → .tmp в папке обмена → переименование.
        $localReply = Join-Path $workRoot ($id + '.reply.json')
        [System.IO.File]::WriteAllText($localReply, ($reply | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
        Copy-Item -Path $localReply -Destination (Join-Path $outDir ($id + '.json.tmp')) -Force
        Rename-Item -Path (Join-Path $outDir ($id + '.json.tmp')) -NewName ($id + '.json')
        Move-Item -Path $f.FullName -Destination (Join-Path $doneDir $f.Name) -Force
        Log ("Команда {0} завершена: {1}" -f $id, $reply.status)
        Copy-AgentLogToShare
        if (-not $running) { break }
    }

    if ($running) { Start-Sleep -Seconds $PollSeconds }
}

Log "Агент остановлен."
Copy-AgentLogToShare
