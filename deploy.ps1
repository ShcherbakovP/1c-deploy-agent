# deploy.ps1 — оркестратор конвейера доставки 1С (запускается на рабочей станции).
# Кладёт командный JSON в <корень>\<цель>\in\, ждёт ответ агента из <цель>\out\,
# пишет журнал в <корень>\log\deploy.log. На сервере в RDP-сессии должен работать
# deploy-agent.ps1, а корень папки обмена — лежать на диске, проброшенном в эту сессию.
#
# Корень папки обмена: параметр -Root, иначе переменная окружения DEPLOY_ROOT, иначе F:\deploy.
# Цель (-Target) — имя секции agent-config.json; по умолчанию test.
#
# Примеры:
#   deploy.ps1 ping
#   deploy.ps1 pull
#   deploy.ps1 test -Comment "задача 12345"          # захват + объединение release.cf на тестовой
#   deploy.ps1 commit -Comment "задача 12345"        # помещение в хранилище
#   deploy.ps1 unlock                                # откат: снять захват без версии
#   deploy.ps1 update-prod -Mode hot                 # боевая из хранилища, динамически
#   deploy.ps1 ext-install -Target acc -Extension МоёРасширение -Cfe C:\build\МоёРасширение.cfe
#   deploy.ps1 mcp-start -Target prod                # MCP-демон по COM (только чтение)
#   deploy.ps1 fetch -Path 'D:\dump\base.dt'         # файл с сервера в artifacts
# Полное описание команд — README.md.

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('ping', 'status', 'sessions', 'kill-sessions', 'com-check', 'peek', 'fetch', 'com-exec', 'windows',
        'screenshot', 'build-epf', 'mcp-start', 'mcp-stop', 'mcp-list',
        'ext-list', 'ext-dump', 'ext-install', 'dump-cf', 'dump-dt', 'load-cf',
        'pull', 'repo-bind', 'repo-unbind', 'repo-report', 'repo-dump', 'test', 'commit', 'unlock', 'update-prod', 'reload', 'stop')]
    [string]$Command,
    [string]$Target = 'test',
    [string]$Root = '',
    [int]$TimeoutSec = 0,
    [string]$Comment = '',
    [string]$Release = '',
    [string]$Objects = '',
    [string]$Settings = '',
    [ValidateSet('mergecfg', 'loadcfg', 'loadfiles')]
    [string]$Method = 'mergecfg',
    [ValidateSet('', 'hot', 'full')]
    [string]$Mode = '',
    # repo-dump: номер версии хранилища; repo-report: диапазон версий истории.
    [int]$Version = 0,
    [int]$NBegin = 0,
    [int]$NEnd = 0,
    [string]$Ib = '',
    [string]$IbUser = '',
    [string]$IbPassword = '',
    [string]$Server1c = '',
    [string]$Cf = '',
    [string]$Path = '',
    [string]$Name = '',
    [string]$ScriptFile = '',
    [int]$Tail = 0,
    [string]$Src = '',
    [string]$Out = '',
    [string]$Extension = '',
    [string]$Cfe = '',
    [string]$Dir = '',
    [string]$Epf = '',
    [string]$EpfServer = '',
    [string]$Exchange = '',
    [switch]$NoBackup,
    [switch]$Kill,
    [switch]$Force,
    # mcp-start: разрешить демону выполнение произвольного кода (execute_bsl_code).
    [switch]$AllowCode
)

if ($Root -eq '') { $Root = $env:DEPLOY_ROOT }
if ([string]::IsNullOrEmpty($Root)) { $Root = 'F:\deploy' }
if (-not (Test-Path $Root)) { Write-Host ("Нет корня папки обмена {0} (параметр -Root или переменная DEPLOY_ROOT)." -f $Root); exit 1 }

# update-prod идёт только на прод-агента.
if ($Command -eq 'update-prod') { $Target = 'prod' }

# Команды хранилища для цели без repoPath отклоняем сразу, не гоняя агента.
$configPath = Join-Path $Root 'agent-config.json'
if ($Command -in @('pull', 'repo-bind', 'repo-unbind', 'test', 'commit', 'unlock', 'update-prod') -and (Test-Path $configPath)) {
    try {
        $section = (Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).$Target
        if ($null -ne $section -and [string]::IsNullOrEmpty('' + $section.repoPath)) {
            Write-Host ("Команда '{0}' работает через хранилище конфигурации, а у цели '{1}' его нет (repoPath пуст)." -f $Command, $Target)
            Write-Host "Для расширений: ext-list / ext-dump / ext-install; для выгрузок: dump-cf / dump-dt."
            exit 1
        }
    } catch {}
}

$inDir = Join-Path $Root ($Target + '\in')
$outDir = Join-Path $Root ($Target + '\out')
$logDir = Join-Path $Root 'log'
$artDir = Join-Path $Root 'artifacts'
foreach ($d in @($inDir, $outDir, $logDir, $artDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$logFile = Join-Path $logDir 'deploy.log'

if ($TimeoutSec -eq 0) {
    if ($Command -eq 'dump-dt') { $TimeoutSec = 21600 }
    elseif ($Command -in @('pull', 'update-prod', 'load-cf', 'fetch', 'dump-cf')) { $TimeoutSec = 5400 }
    elseif ($Command -in @('test', 'commit', 'ext-install')) { $TimeoutSec = 3600 }
    elseif ($Command -eq 'ext-list') { $TimeoutSec = 1800 }
    elseif ($Command -in @('repo-bind', 'repo-unbind')) { $TimeoutSec = 1800 }
    elseif ($Command -eq 'repo-dump') { $TimeoutSec = 3600 }
    elseif ($Command -eq 'repo-report') { $TimeoutSec = 900 }
    elseif ($Command -in @('ext-dump', 'unlock', 'build-epf')) { $TimeoutSec = 900 }
    elseif ($Command -eq 'mcp-start') { $TimeoutSec = 300 }
    elseif ($Command -in @('com-check', 'com-exec')) { $TimeoutSec = 180 }
    else { $TimeoutSec = 90 }
}

function Latest([string]$pattern) {
    $f = Get-ChildItem (Join-Path $artDir $pattern) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $f) { return '' }
    return $f.Name
}

function Log([string]$text) {
    $line = ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Target, $text)
    Write-Host $line
    Add-Content -Path $script:logFile -Value $line -Encoding UTF8
}

function Stop-WithUsage([string]$text) { Write-Host $text; exit 1 }

# --- status: свежесть heartbeat агента, без отправки команды --------------------
if ($Command -eq 'status') {
    $hbPath = Join-Path $outDir 'agent-status.json'
    if (Test-Path $hbPath) {
        $hb = Get-Content -Path $hbPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = [int]((Get-Date) - (Get-Item $hbPath).LastWriteTime).TotalSeconds
        Write-Host ("Агент v{0}, роль {1}, хост {2}: heartbeat {3} с назад." -f $hb.agent, $hb.role, $hb.host, $age)
        if ($age -gt 180) { Write-Host "ВНИМАНИЕ: heartbeat старше 3 минут — агент, похоже, не работает."; exit 2 }
        exit 0
    }
    Write-Host "Heartbeat не найден — агент ни разу не выходил на связь."
    exit 2
}

# --- Полезная нагрузка команды --------------------------------------------------
$payload = @{ id = ''; command = $Command; created = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }

if ($Command -in @('test', 'commit', 'unlock')) {
    if ($Objects -eq '') { $Objects = Latest 'objects-*.xml' }
    if ($Objects -eq '') { Stop-WithUsage 'Нет objects-*.xml в artifacts — положите список объектов для захвата.' }
    $payload.objects = $Objects
    if ($Command -eq 'test') {
        $payload.method = $Method
        if ($Release -eq '') { $Release = Latest 'release-*.cf' }
        if ($Release -eq '') { Stop-WithUsage 'Нет release-*.cf в artifacts — положите собранный .cf.' }
        $payload.release = $Release
        if ($Method -eq 'mergecfg') {
            if ($Settings -eq '') { $Settings = Latest 'MergeSettings-*.xml' }
            if ($Settings -eq '') { Stop-WithUsage 'Нет MergeSettings-*.xml в artifacts — нужны настройки объединения.' }
            $payload.settings = $Settings
        }
        Write-Host ("Метод {0}: release={1} settings={2}" -f $Method, $Release, $Settings)
    }
    if ($Comment -ne '') { $payload.comment = $Comment }
    Write-Host ("Артефакты: objects={0}" -f $Objects)
    Write-Host ("ВНИМАНИЕ: команда '{0}' изменяет ОБЩЕЕ хранилище конфигурации." -f $Command)
}

if ($Command -eq 'repo-bind') {
    # -Force → -forceReplaceCfg: конфигурация базы заменяется хранилищной. Нужен, когда база
    # разошлась с хранилищем (перезалита, обновлена из .cf); на боевой применять осознанно.
    $payload.force = [bool]$Force
    if ($Force) { Write-Host 'ВНИМАНИЕ: конфигурация базы будет заменена хранилищной (-Force).' }
}

if ($Command -eq 'load-cf') {
    if ($Ib -eq '' -or $IbUser -eq '') { Stop-WithUsage 'Укажите -Ib <имя ИБ> -IbUser <пользователь> [-IbPassword <пароль>] [-Cf <файл в artifacts>].' }
    if ($Cf -eq '') { $Cf = Latest 'snapshot-*.cf' }
    if ($Cf -eq '') { Stop-WithUsage 'Нет snapshot-*.cf в artifacts — сначала pull или укажите -Cf.' }
    $payload.ib = $Ib; $payload.user = $IbUser; $payload.password = $IbPassword; $payload.cf = $Cf
    Write-Host ("ВНИМАНИЕ: конфигурация базы {0} будет ПОЛНОСТЬЮ заменена файлом {1}." -f $Ib, $Cf)
}

if ($Command -eq 'com-exec') {
    if ($ScriptFile -eq '') { Stop-WithUsage 'Укажите -ScriptFile <локальный .vbs> — его текст уйдёт агенту.' }
    if (-not (Test-Path $ScriptFile)) { Stop-WithUsage ('Нет файла: ' + $ScriptFile) }
    $payload.script = [System.IO.File]::ReadAllText($ScriptFile, [System.Text.Encoding]::UTF8)
    $payload.timeout = [Math]::Min($TimeoutSec, 600)
}

if ($Command -eq 'fetch') {
    if ($Path -eq '') { Stop-WithUsage 'Укажите -Path <путь на сервере> [-Name <имя в artifacts>].' }
    $payload.path = $Path
    if ($Name -ne '') { $payload.name = $Name }
    Write-Host ("Забираю {0} в artifacts (копирует агент; по RDP-каналу это около 1 МБ/с)." -f $Path)
}

if ($Command -eq 'peek') {
    if ($Path -eq '') { Stop-WithUsage 'Укажите -Path <путь на сервере>.' }
    $payload.path = $Path
    if ($Tail -gt 0) { $payload.tail = $Tail }
}

if ($Command -eq 'build-epf') {
    if ($Src -eq '' -or $Out -eq '') { Stop-WithUsage 'Укажите -Src <корневой XML> -Out <файл .epf> (пути, видимые агенту).' }
    $payload.src = $Src
    $payload.out = $Out
}

if ($Command -in @('build-epf', 'ext-list', 'ext-dump', 'ext-install', 'dump-cf', 'dump-dt',
        'mcp-start', 'mcp-stop', 'mcp-list', 'kill-sessions', 'sessions', 'com-check')) {
    # ИБ и учётные данные: без параметров агент берёт базу из своего конфига.
    if ($Ib -ne '') { $payload.ib = $Ib }
    if ($IbUser -ne '') { $payload.user = $IbUser }
    if ($IbPassword -ne '') { $payload.password = $IbPassword }
    if ($Server1c -ne '') { $payload.server1c = $Server1c }
    if ($Name -ne '') { $payload.name = $Name }
}

if ($Command -in @('ext-dump', 'ext-install')) {
    if ($Extension -eq '') { Stop-WithUsage 'Укажите -Extension <имя расширения в базе>.' }
    $payload.extension = $Extension
}

if ($Command -eq 'ext-install') {
    # Доставка: локальный .cfe кладём в artifacts (агент читает папку обмена), либо берём файл,
    # который уже лежит на диске самого сервера (-Path).
    if ($Path -ne '') {
        $payload.path = $Path
    } else {
        if ($Cfe -eq '') { Stop-WithUsage 'Укажите -Cfe <путь к .cfe или имя файла в artifacts> либо -Path <файл на диске сервера>.' }
        $cfeName = Split-Path $Cfe -Leaf
        $inArtifacts = Join-Path $artDir $cfeName
        if (Test-Path $Cfe) {
            $srcFull = (Resolve-Path $Cfe).Path
            if ($srcFull -ne $inArtifacts) {
                Copy-Item -LiteralPath $srcFull -Destination $inArtifacts -Force
                Write-Host ("Доставка: {0} -> artifacts\{1}" -f $srcFull, $cfeName)
            }
        } elseif (-not (Test-Path $inArtifacts)) {
            Stop-WithUsage ('Файл расширения не найден ни как путь, ни в artifacts: ' + $Cfe)
        }
        $payload.cfe = $cfeName
    }
    if ($NoBackup) { $payload.backup = $false }
    if ($Kill) { $payload.kill = $true }
    Write-Host ("ВНИМАНИЕ: расширение {0} будет ЗАМЕНЕНО в базе {1}." -f $Extension, $(if ($Ib -ne '') { $Ib } else { 'из конфига агента (' + $Target + ')' }))
    if ($Kill) { Write-Host 'Перед установкой будут сняты ВСЕ сеансы базы.' }
}

if ($Command -eq 'dump-dt') {
    if (-not $Kill) { Stop-WithUsage 'DumpIB требует монопольного доступа: добавьте -Kill (все сеансы базы будут сняты).' }
    $payload.kill = $true
    if ($Dir -ne '') { $payload.dir = $Dir }
    Write-Host 'ВНИМАНИЕ: выгрузка ИБ целиком. Все сеансы будут сняты, база встанет на время выгрузки,'
    Write-Host 'файл останется НА СЕРВЕРЕ — забирать отдельной командой fetch.'
}

if ($Command -in @('mcp-start', 'mcp-stop', 'mcp-list')) {
    if ($Epf -ne '') { $payload.epf = $Epf }
    if ($EpfServer -ne '') { $payload.epfServer = $EpfServer }
    if ($Exchange -ne '') { $payload.exchange = $Exchange }
    if ($Kill) { $payload.kill = $true }
    if ($Force) { $payload.force = $true }
    if ($AllowCode) { $payload.allowCode = $true }
    if ($Command -eq 'mcp-start' -and $Kill) { Write-Host 'ВНИМАНИЕ: перед запуском будут сняты ВСЕ сеансы базы.' }
}

if ($Command -eq 'repo-dump') {
    if ($Version -le 0) { Stop-WithUsage 'Укажите номер версии хранилища: -Version <N>.' }
    $payload.version = $Version
}
if ($Command -eq 'repo-report') {
    if ($NBegin -gt 0) { $payload.nbegin = $NBegin }
    if ($NEnd -gt 0) { $payload.nend = $NEnd }
}

if ($Command -eq 'update-prod') {
    if ($Mode -eq '') { Stop-WithUsage 'Укажите режим: -Mode hot (динамически, без завершения сеансов) | full (с завершением сеансов).' }
    $payload.mode = $Mode
    if ($Comment -ne '') { $payload.comment = $Comment }
    Write-Host ("ВНИМАНИЕ: update-prod (режим {0}) обновляет БОЕВУЮ базу из хранилища." -f $Mode)
}

# --- Отправка команды и ожидание ответа ------------------------------------------
$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Command
$payload.id = $id
$json = $payload | ConvertTo-Json -Compress
$tmpPath = Join-Path $inDir ($id + '.json.tmp')
[System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($true)))
Rename-Item -Path $tmpPath -NewName ($id + '.json')
Log ("Команда {0} отправлена, жду ответ до {1} с." -f $id, $TimeoutSec)

$replyPath = Join-Path $outDir ($id + '.json')
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline -and -not (Test-Path $replyPath)) { Start-Sleep -Seconds 2 }

if (-not (Test-Path $replyPath)) {
    Log ("ТАЙМАУТ: ответа на {0} нет за {1} с. Состояние НЕИЗВЕСТНО — не повторять команду, сначала проверить агента (deploy.ps1 status) и лог log\agent-{2}.log." -f $id, $TimeoutSec, $Target)
    exit 2
}

$reply = Get-Content -Path $replyPath -Raw -Encoding UTF8 | ConvertFrom-Json
Log ("Ответ на {0}: status={1}" -f $id, $reply.status)
$reply | ConvertTo-Json -Depth 6 | Write-Host

if ($reply.status -eq 'ok') {
    if ($Command -eq 'pull') { Log ("Снимок: {0} (SHA256 {1}, {2} МБ)" -f $reply.artifact, $reply.sha256, $reply.sizeMB) }
    if ($Command -eq 'dump-cf') { Log ("Конфигурация: {0} ({1} МБ)." -f $reply.artifact, $reply.sizeMB) }
    if ($Command -eq 'repo-dump') { Log ("Версия {0} хранилища: {1} (SHA256 {2}, {3} МБ)" -f $reply.version, $reply.artifact, $reply.sha256, $reply.sizeMB) }
    if ($Command -eq 'repo-report') { Log ("Отчёт истории: {0}" -f $reply.artifact) }
    if ($Command -eq 'dump-dt') { Log ("Выгрузка ИБ: {0} ({1} ГБ) — файл на сервере. Забрать: deploy.ps1 fetch -Target {2} -Path '{0}'" -f $reply.path, $reply.sizeGB, $Target) }
    exit 0
}
Log ("ОШИБКА: " + $reply.error)
exit 1
