#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание и обновление Ollama как службы Windows.

.DESCRIPTION
    Читает ollama-windows-install.ini. Позволяет выбрать версию, сделать бэкап и
    пересоздать службу. Поддерживает флаг -Upgrade для автообновления.
    Папки install, logs, Downloads, Backup, Models, .ollama и OllamaTM сохраняются
    в OllamaDir при обновлении/переустановке (не резервируются и не удаляются).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$ForceDownload,
    [switch]$Upgrade,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$forceDL = [bool]$ForceDownload

# --- 0. Инициализация путей и логов ---
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'ollama-windows-install.ini'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

$global:LogFile = Join-Path $scriptDir 'ollama-windows-install.log'
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    Write-Host $Message -ForegroundColor $Color
    if ($global:LogFile) {
        Add-Content -Path $global:LogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}
function Write-Step([string]$msg) { Write-Log "`n=== $msg ===" -Color Cyan }

Write-Log "=== Запуск ollama-windows-install.ps1 (Upgrade=$Upgrade) ===" -Color Cyan

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Запрос прав администратора (UAC)...' -Color Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`""
    if ($Force)         { $argLine += ' -Force'         }
    if ($ForceDownload) { $argLine += ' -ForceDownload' }
    if ($Upgrade)       { $argLine += ' -Upgrade'       }
    if ($NoPause)       { $argLine += ' -NoPause'       }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine
    exit
}

# --- 1. Парсер INI ---
function Read-IniFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Не найден INI: $Path" }
    $data = @{}
    $section = ''
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq ';' -or $line[0] -eq '#') { continue }
        if ($line -match '^\[(.+?)\]$') {
            $section = $matches[1].Trim()
            if (-not $data.ContainsKey($section)) { $data[$section] = @{} }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if (-not $data.ContainsKey($section)) { $data[$section] = @{} }
        $data[$section][$key] = $val
    }
    return $data
}

$cfg = Read-IniFile -Path $ConfigPath

function Get-Cfg {
    param([string]$Section, [string]$Key, [string]$Default = '')
    if ($cfg.ContainsKey($Section) -and $cfg[$Section].ContainsKey($Key)) {
        $v = $cfg[$Section][$Key]
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $Default
}
function Get-CfgBool {
    param([string]$Section, [string]$Key, [bool]$Default = $false)
    $v = Get-Cfg $Section $Key ''
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v -match '^(true|1|yes|y|on)$')
}
function Get-CfgInt {
    param([string]$Section, [string]$Key, [int]$Default = 0)
    $v = Get-Cfg $Section $Key ''
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return $Default
}

# --- 2. Конфигурация ---
$OllamaDir        = Get-Cfg     'paths'     'OllamaDir'            'D:\AI\Ollama'
$ModelsDir        = Get-Cfg     'paths'     'ModelsDir'            ''
$NssmDir          = Get-Cfg     'paths'     'NssmDir'              'C:\Program Files\NSSM'
$LogsDir          = Get-Cfg     'paths'     'LogsDir'              ''
$DownloadsDir     = Get-Cfg     'paths'     'DownloadsDir'         ''
$BackupDir        = Get-Cfg     'paths'     'BackupDir'            ''
$OllamaHome       = Get-Cfg     'ollama'    'OllamaHome'           $OllamaDir
$ServiceName      = Get-Cfg     'service'   'ServiceName'          'Ollama'
$StartType        = Get-Cfg     'service'   'StartType'            'SERVICE_DELAYED_AUTO_START'
$StartTimeoutSec  = Get-CfgInt  'service'   'StartTimeoutSeconds'  60
$AppRestartDelay  = Get-CfgInt  'service'   'AppRestartDelay'      10000
$AddToPath        = Get-CfgBool 'service'   'AddToPath'            $true
$AddNssmToPath    = Get-CfgBool 'service'   'AddNssmToPath'        $true
$LogRetentionDays = Get-CfgInt  'service'   'LogRetentionDays'     7
$HostOnly         = Get-Cfg     'network'   'Host'                 '0.0.0.0'
$Port             = Get-CfgInt  'network'   'Port'                 11434
$FirewallEnabled  = Get-CfgBool 'network'   'FirewallEnabled'      $true
$FirewallSubnet   = Get-Cfg     'network'   'FirewallSubnet'       '192.168.117.0/24'
$Origins          = Get-Cfg     'network'   'Origins'              ''
$OllamaVersion    = Get-Cfg     'downloads' 'OllamaVersion'        'ask'
$NssmUrl          = Get-Cfg     'downloads' 'NssmUrl'              'https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip'
$OllamaUrlFallback = Get-Cfg    'downloads' 'OllamaUrl'            'https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-windows-amd64.zip'
$KeepDownloads    = Get-CfgBool 'downloads' 'KeepDownloads'        $true
$DownloadModels   = Get-CfgBool 'models'    'DownloadModels'       $true
$InteractiveModels = Get-CfgBool 'models'   'Interactive'          $true
$ModelsSpec       = Get-Cfg     'models'    'Models'               ''

# Параметры производительности
$KeepAlive       = Get-Cfg     'performance' 'KeepAlive'          '10m'
$FlashAttention  = Get-CfgBool 'performance' 'FlashAttention'     $true
$KvCacheType     = Get-Cfg     'performance' 'KvCacheType'        'q8_0'
$NumParallel     = Get-CfgInt  'performance' 'NumParallel'        1
$MaxLoadedModels = Get-CfgInt  'performance' 'MaxLoadedModels'    1
$DebugMode       = Get-CfgBool 'performance' 'Debug'              $false

if ($Upgrade) {
    Write-Log "  [Upgrade] Автообновление: выбор версии отключен, будет установлена latest." -Color Magenta
    $Force = $true
    $OllamaVersion = 'latest'
    $InteractiveModels = $false
}

# Нормализация путей
if ([string]::IsNullOrWhiteSpace($ModelsDir)) {
    $ModelsDir = Join-Path $OllamaDir 'Models'
} elseif (-not [IO.Path]::IsPathRooted($ModelsDir)) {
    $ModelsDir = Join-Path $OllamaDir $ModelsDir
}
if ([string]::IsNullOrWhiteSpace($LogsDir)) {
    $LogsDir = Join-Path $OllamaDir 'logs'
} elseif (-not [IO.Path]::IsPathRooted($LogsDir)) {
    $LogsDir = Join-Path $OllamaDir $LogsDir
}
if ([string]::IsNullOrWhiteSpace($DownloadsDir)) {
    $DownloadsDir = Join-Path $OllamaDir 'Downloads'
} elseif (-not [IO.Path]::IsPathRooted($DownloadsDir)) {
    $DownloadsDir = Join-Path $OllamaDir $DownloadsDir
}
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = Join-Path $OllamaDir 'Backup'
} elseif (-not [IO.Path]::IsPathRooted($BackupDir)) {
    $BackupDir = Join-Path $OllamaDir $BackupDir
}
if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }

$ModelsDir    = [IO.Path]::GetFullPath($ModelsDir)
$LogsDir      = [IO.Path]::GetFullPath($LogsDir)
$DownloadsDir = [IO.Path]::GetFullPath($DownloadsDir)
$BackupDir    = [IO.Path]::GetFullPath($BackupDir)

$OllamaHost  = "${HostOnly}:${Port}"
$NewProfile  = Join-Path $OllamaHome '.ollama'
$OldProfile  = 'C:\Windows\System32\config\systemprofile\.ollama'
$InstallPath = [IO.Path]::GetFullPath((Join-Path $OllamaDir 'install'))
$OllamaTMDir = [IO.Path]::GetFullPath((Join-Path $OllamaDir 'OllamaTM'))

# Защищённые пути: не бэкапятся и не удаляются при обновлении
$protectedPaths = @(
    $InstallPath
    $OllamaTMDir
    [IO.Path]::GetFullPath($LogsDir)
    [IO.Path]::GetFullPath($DownloadsDir)
    [IO.Path]::GetFullPath($BackupDir)
    [IO.Path]::GetFullPath($ModelsDir)
    [IO.Path]::GetFullPath($NewProfile)
    [IO.Path]::GetFullPath($NssmDir)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

$preselectedModels = @()
if (-not [string]::IsNullOrWhiteSpace($ModelsSpec)) {
    $preselectedModels = $ModelsSpec -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

$faValue = if ($FlashAttention) { '1' } else { '0' }
if ($KvCacheType -ne 'f16' -and -not $FlashAttention) {
    Write-Log "KvCacheType=$KvCacheType требует FlashAttention=1. Принудительно включаем Flash Attention." -Color Yellow
    $faValue = '1'
}

$envPairs = @(
    "USERPROFILE=$OllamaHome",
    "HOME=$OllamaHome",
    "OLLAMA_HOST=$OllamaHost",
    "OLLAMA_MODELS=$ModelsDir",
    "OLLAMA_KEEP_ALIVE=$KeepAlive",
    "OLLAMA_FLASH_ATTENTION=$faValue",
    "OLLAMA_KV_CACHE_TYPE=$KvCacheType",
    "OLLAMA_NUM_PARALLEL=$NumParallel",
    "OLLAMA_MAX_LOADED_MODELS=$MaxLoadedModels"
)
if (-not [string]::IsNullOrWhiteSpace($Origins)) { $envPairs += "OLLAMA_ORIGINS=$Origins" }
if ($DebugMode) { $envPairs += "OLLAMA_DEBUG=1" }

$testEnv = @{
    'USERPROFILE'              = $OllamaHome
    'HOME'                     = $OllamaHome
    'OLLAMA_HOST'              = $OllamaHost
    'OLLAMA_MODELS'            = $ModelsDir
    'OLLAMA_KEEP_ALIVE'        = $KeepAlive
    'OLLAMA_FLASH_ATTENTION'   = $faValue
    'OLLAMA_KV_CACHE_TYPE'     = $KvCacheType
    'OLLAMA_NUM_PARALLEL'      = "$NumParallel"
    'OLLAMA_MAX_LOADED_MODELS' = "$MaxLoadedModels"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Stop-OllamaProcesses {
    Write-Log "  -> Завершение процессов Ollama..."
    foreach ($procName in @("OllamaTM", "ollama app", "ollama", "ollama_llama_server")) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "    Убит процесс: $($_.Name) (PID: $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Set-OllamaAcl {
    param([string]$OllamaDir, [string]$OllamaHome, [string]$ModelsDir, [string]$NewProfile)
    foreach ($dir in @($OllamaDir, $OllamaHome)) {
        if ((Test-Path $dir) -and $dir) {
            icacls $dir /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
            icacls $dir /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
        }
    }
    if ($ModelsDir -and (Test-Path $ModelsDir)) {
        icacls $ModelsDir /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
        icacls $ModelsDir /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
    }
    if ($NewProfile -and (Test-Path $NewProfile)) {
        icacls $NewProfile /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
        icacls $NewProfile /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
    }
}

function Get-FileNameFromUrl {
    param([string]$Url, [string]$Fallback = 'download.bin')
    try {
        $uri  = [Uri]$Url
        $name = [IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch { }
    return $Fallback
}

# --- Кастомная функция скачивания с прогрессом в МБ ---
function Start-Download {
    param([string]$Url, [string]$Dest)
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.UserAgent = "PowerShell-Ollama-Deploy-Script"
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $stream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Create($Dest)
        
        $buffer = New-Object byte[] 1048576 # Буфер 1 МБ
        $bytesRead = 0
        $totalRead = 0
        $lastPercent = -1
        $fileName = [System.IO.Path]::GetFileName($Dest)
        
        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead
            
            if ($totalBytes -gt 0) {
                $percent = [math]::Min(100, [math]::Floor(($totalRead / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    $readMb = [math]::Round($totalRead / 1MB, 1)
                    $totalMb = [math]::Round($totalBytes / 1MB, 1)
                    Write-Progress -Activity "Скачивание $fileName" -Status "$readMb MB / $totalMb MB" -PercentComplete $percent
                    $lastPercent = $percent
                }
            } else {
                $readMb = [math]::Round($totalRead / 1MB, 1)
                Write-Progress -Activity "Скачивание $fileName" -Status "$readMb MB скачано" -PercentComplete 0
            }
        }
        
        $fileStream.Close()
        $stream.Close()
        $response.Close()
        Write-Progress -Activity "Скачивание $fileName" -Completed
    } catch {
        throw "Ошибка скачивания файла: $_"
    }
}

function Get-CachedFile {
    param([string]$Url, [string]$FileName, [string]$SubDir = '', [switch]$ForceRedownload)
    $targetDir = if ([string]::IsNullOrWhiteSpace($SubDir)) { $DownloadsDir } else { Join-Path $DownloadsDir $SubDir }
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $cachePath = Join-Path $targetDir $FileName
    $urlStamp  = "$cachePath.url"

    if ($KeepDownloads -and -not $ForceRedownload) {
        if ((Test-Path -LiteralPath $cachePath) -and (Test-Path -LiteralPath $urlStamp)) {
            $cachedUrl = ''
            try { $cachedUrl = (Get-Content -LiteralPath $urlStamp -Raw -ErrorAction Stop).Trim() } catch { }
            if ($cachedUrl -eq $Url) {
                $sizeMb = [math]::Round((Get-Item -LiteralPath $cachePath).Length / 1MB, 1)
                Write-Log "  [OK] Кэш: $cachePath ($sizeMb MB)" -Color Green
                return $cachePath
            }
        }
    }

    if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath -Force }
    if (Test-Path -LiteralPath $urlStamp)  { Remove-Item -LiteralPath $urlStamp  -Force }
    
    Write-Log "  -> Скачивание: $Url"
    Start-Download -Url $Url -Dest $cachePath
    
    if ($KeepDownloads) { Set-Content -LiteralPath $urlStamp -Value $Url -NoNewline }
    return $cachePath
}

function Add-ToMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current) { $current = '' }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    $normalized = $parts | ForEach-Object { $_.TrimEnd('\') }
    if ($normalized -contains $Dir.TrimEnd('\')) {
        Write-Log "  [INFO] Уже в PATH: $Dir (пропускаем)" -Color DarkGray
        return
    }
    $new = if ($current.TrimEnd(';') -eq '') { $Dir } else { $current.TrimEnd(';') + ';' + $Dir }
    [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    Write-Log "  [OK] Добавлено в PATH: $Dir" -Color Green
    Write-Log "  [INFO] Изменения вступят в силу в новых консолях" -Color DarkGray
}

function Get-OllamaReleases {
    param([switch]$ForceRefresh)
    $cacheFile = Join-Path $DownloadsDir '.ollama_releases_cache.json'
    $cacheTtl  = 12 * 60 * 60

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cacheFile)) {
        $age = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $cacheTtl) {
            try { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
    }

    $headers = @{ 'User-Agent' = 'PowerShell-Ollama-Deploy-Script'; 'Accept' = 'application/vnd.github+json' }
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ollama/ollama/releases?per_page=30' -Headers $headers -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $DownloadsDir)) {
            New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
        }
        $releases | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        return $releases
    } catch {
        Write-Log "  [ERR] Не удалось получить список релизов: $($_.Exception.Message)" -Color Yellow
        if (Test-Path -LiteralPath $cacheFile) { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) }
        return $null
    }
}

function Test-IsPrerelease {
    param($Release)
    return ($Release.prerelease -or $Release.tag_name -match '-(rc|beta|alpha)')
}

function Select-OllamaVersionInteractive {
    param($Releases, [string]$CurrentVersion)
    if (-not $Releases) { return $null }

    $stable = @($Releases | Where-Object { -not (Test-IsPrerelease $_) })
    if ($stable.Count -eq 0) {
        Write-Log '  Нет доступных версий для установки.' -Color Yellow
        return $null
    }

    $list = $stable[0..([math]::Min(14, $stable.Count-1))]
    Write-Log ''
    Write-Log 'Доступные версии Ollama:' -Color Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $date = ([datetime]$list[$i].published_at).ToString('yyyy-MM-dd')
        $mark = if ($CurrentVersion -and $list[$i].tag_name -eq $CurrentVersion) { ' <-- текущая (переустановка)' } else { '' }
        $color = if ($mark) { 'Yellow' } else { 'White' }
        Write-Log ('  [{0}] {1,-16} {2}  {3}' -f ($i+1), $list[$i].tag_name, $date, $mark) -Color $color
    }
    Write-Log ''

    while ($true) {
        Write-Host 'Введите номер версии (Enter — последняя, s — отмена):' -ForegroundColor Cyan
        $ans = (Read-Host 'Выбор').Trim()

        if ([string]::IsNullOrWhiteSpace($ans)) { return $list[0] }
        if ($ans -match '^[scысSCЫС]$') { return 'CANCEL' }

        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            return $list[$n-1]
        }
        Write-Log "  Некорректный ввод: '$ans'. Введите число от 1 до $($list.Count), 's' для отмены или Enter." -Color Yellow
    }
}

function Resolve-OllamaVersion {
    param([string]$RequestedVersion, [string]$CurrentVersion, [switch]$ForceRefresh)
    
    if ($RequestedVersion -match '^v?\d+\.\d+\.\d+$') {
        if (-not $RequestedVersion.StartsWith('v')) { return "v$RequestedVersion" }
        return $RequestedVersion
    }
    
    $releases = Get-OllamaReleases -ForceRefresh:$ForceRefresh
    if (-not $releases) { return $null }

    if ($RequestedVersion -eq 'ask' -and -not $Force) {
        $sel = Select-OllamaVersionInteractive -Releases $releases -CurrentVersion $CurrentVersion
        if ($sel -is [string] -and $sel -eq 'CANCEL') { return 'CANCEL' }
        if ($null -eq $sel) { return $null }
        if ($sel.tag_name) { return $sel.tag_name }
        return $null
    }

    $latest = @($releases | Where-Object { -not (Test-IsPrerelease $_) }) | Select-Object -First 1
    if ($latest) { return $latest.tag_name }
    return $null
}

function Test-ModelInstalled {
    param([string]$Exe, [string]$Model)
    try {
        $list = & $Exe list 2>&1 | Out-String
        $pattern = '(?m)^' + [regex]::Escape($Model) + '\s'
        return ($list -match $pattern)
    } catch { return $false }
}

function Invoke-PullModel {
    param([string]$Exe, [string]$Model, [string]$ApiHost)
    if (Test-ModelInstalled -Exe $Exe -Model $Model) {
        Write-Log "  [OK] $Model уже установлена — пропускаем" -Color Green
        return $true
    }
    
    Write-Log "  -> Загрузка $Model через API..." -Color Cyan
    $useCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
    $hasError = $false
    
    if ($useCurl) {
        $jsonBody = "{`"name`": `"$Model`"}"
        $curlArgs = @("-N", "-s", "-X", "POST", "http://$ApiHost/api/pull", "-H", "Content-Type: application/json", "-d", $jsonBody)
        $lastStatus = ""
        
        & curl.exe @curlArgs 2>&1 | ForEach-Object {
            $line = $_.Trim()
            if ($line -eq '') { return }
            try {
                $obj = $line | ConvertFrom-Json
                if ($null -ne $obj.error) {
                    Write-Log "`n    Ошибка API: $($obj.error)" -Color Yellow
                    $hasError = $true
                    return
                }
                $status = $obj.status
                if ($status -eq 'downloading' -or $status -eq 'pulling') {
                    $completed = if ($null -ne $obj.completed) { [long]$obj.completed } else { 0 }
                    $total = if ($null -ne $obj.total) { [long]$obj.total } else { 0 }
                    if ($total -gt 0) {
                        $percent = [math]::Round(($completed / $total) * 100, 1)
                        $cMB = [math]::Round($completed / 1MB, 1)
                        $tMB = [math]::Round($total / 1MB, 1)
                        Write-Progress -Activity "Загрузка $Model" -Status "$status ($cMB MB / $tMB MB)" -PercentComplete $percent
                    }
                } elseif ($status -ne $lastStatus) {
                    Write-Progress -Activity "Загрузка $Model" -Completed
                    if ($status -eq 'success') { Write-Log "  [OK] $Model успешно загружена" -Color Green }
                    else { Write-Log "    $status" }
                    $lastStatus = $status
                }
            } catch { Write-Log "    $line" }
        }
        Write-Log "" 
        if ($hasError) { return $false }
    } else {
        $prevHost = $env:OLLAMA_HOST
        $prevModels = $env:OLLAMA_MODELS
        try {
            $env:OLLAMA_HOST   = $ApiHost
            $env:OLLAMA_MODELS = $ModelsDir
            & $Exe pull $Model 2>&1 | ForEach-Object {
                $line = $_ -replace "`r", ""
                $line = $line -replace '\x1B\[[0-9;?]*[a-zA-Z]', ''
                if ($line.Trim() -ne '') { Write-Log "    $line" }
            }
        } finally {
            $env:OLLAMA_HOST   = $prevHost
            $env:OLLAMA_MODELS = $prevModels
        }
    }
    return (Test-ModelInstalled -Exe $Exe -Model $Model)
}

function Select-ModelsInteractive {
    param([string[]]$Preselected)
    $menu = @(
        [pscustomobject]@{ Name='llama3.1:8b';      Desc='Общий чат - Q4_K_M ~4.9 GB' }
        [pscustomobject]@{ Name='qwen2.5:7b';       Desc='Баланс качества - Q4_K_M ~4.7 GB' }
        [pscustomobject]@{ Name='qwen2.5-coder:7b'; Desc='Кодинг - Q4_K_M ~4.7 GB' }
        [pscustomobject]@{ Name='deepseek-r1:8b';   Desc='Reasoning - Q4_K_M ~4.9 GB' }
        [pscustomobject]@{ Name='gemma2:2b';        Desc='Лёгкая - ~1.6 GB' }
        [pscustomobject]@{ Name='qwen2.5:3b';       Desc='Быстрая - ~2 GB' }
    )

    Write-Log ''
    Write-Log 'Рекомендованные модели для RTX 4060 8 GB:' -Color Cyan
    for ($i = 0; $i -lt $menu.Count; $i++) {
        $mark = if ($Preselected -contains $menu[$i].Name) { '*' } else { ' ' }
        Write-Log ('  [{0}] {1} {2,-22} - {3}' -f ($i+1), $mark, $menu[$i].Name, $menu[$i].Desc)
    }
    Write-Log ''
    Write-Log "  * - предвыбрано из INI ([models] Models)." -Color DarkGray
    Write-Log 'Введите номера через запятую (например, "1,3"),' -Color Cyan
    Write-Log "  'a' - все, 'n' - пропустить, Enter - оставить предвыбранные:" -Color Cyan

    $ans = Read-Host 'Выбор'
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Preselected }
    if ($ans -eq 'n') { return @() }
    if ($ans -eq 'a') { return $menu | ForEach-Object { $_.Name } }

    $selected = @()
    foreach ($part in ($ans -split ',')) {
        $p = $part.Trim()
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $menu.Count) {
            $name = $menu[$n-1].Name
            if ($selected -notcontains $name) { $selected += $name }
        } else {
            Write-Log "  Пропущено: '$p' (не число или вне диапазона 1..$($menu.Count))" -Color Yellow
        }
    }
    return $selected
}

function Test-OllamaServeDirect {
    param([string]$OllamaExe, [hashtable]$EnvVars)
    Write-Log "  -> Диагностика: пробуем запустить ollama.exe serve напрямую (5 сек)..."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $OllamaExe
    $psi.Arguments = "serve"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Start-Sleep -Seconds 5
        $exited = $proc.HasExited
        if (-not $exited) {
            Write-Log "    [OK] Процесс РАБОТАЕТ (значит ollama.exe рабочий, проблема в конфиге NSSM)" -Color Green
            try { $proc.Kill() } catch {}
            $proc.WaitForExit(3000) | Out-Null
        } else {
            Write-Log "    [ERR] Процесс УПАЛ с кодом $($proc.ExitCode)" -Color Red
        }
        $stderr = ''; $stdout = ''
        try { $stderr = $proc.StandardError.ReadToEnd() } catch {}
        try { $stdout = $proc.StandardOutput.ReadToEnd() } catch {}
        if ($stderr -and $stderr.Trim()) {
            Write-Log "    STDERR:" -Color Yellow
            $stderr -split "`n" | Select-Object -First 25 | ForEach-Object { Write-Log "      $_" -Color DarkGray }
        }
        if ($stdout -and $stdout.Trim()) {
            Write-Log "    STDOUT (первые 15 строк):" -Color Yellow
            $stdout -split "`n" | Select-Object -First 15 | ForEach-Object { Write-Log "      $_" -Color DarkGray }
        }
        return ($exited -eq $false)
    } catch {
        Write-Log "    Не удалось запустить тест: $_" -Color Red
        return $false
    }
}

function Start-OllamaService {
    param([string]$NssmExe, [string]$ServiceName, [int]$TimeoutSec, [int]$MaxAttempts = 3)
    $started = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "  -> Попытка запуска $attempt из $MaxAttempts..."
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { throw "Служба $ServiceName не найдена после установки" }
        if ($svc.Status -eq 'Running') { $started = $true; break }
        & $NssmExe start $ServiceName 2>&1 | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastStatus = ''
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $svc.Refresh()
            $status = $svc.Status
            if ($status -ne $lastStatus) {
                Write-Log "    Статус: $status"
                $lastStatus = $status
            }
            if ($status -eq 'Running') { $started = $true; break }
            if ($status -eq 'Stopped' -and $sw.Elapsed.TotalSeconds -gt 3) {
                Write-Log "  [WARN] Служба упала через $([int]$sw.Elapsed.TotalSeconds) сек после запуска" -Color Yellow
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if ($started) { break }
        if ($attempt -lt $MaxAttempts) {
            Write-Log "  -> Пауза 5 сек перед повтором..."
            Start-Sleep -Seconds 5
        }
    }
    if ($started) {
        Write-Log "  [OK] Статус: Running" -Color Green
        return $true
    }

    Write-Log ""
    Write-Log "Служба не запустилась за $MaxAttempts x $TimeoutSec сек." -Color Yellow
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) { Write-Log "  Текущий статус : $($svc.Status)" -Color Yellow }
    try {
        $svcInfo = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($svcInfo -and $null -ne $svcInfo.ExitCode) {
            Write-Log "  ExitCode       : $($svcInfo.ExitCode)" -Color Yellow
        }
    } catch {}
    foreach ($logFile in @(
        (Join-Path $LogsDir 'ollama.err.log'),
        (Join-Path $LogsDir 'ollama.out.log')
    ) | Select-Object -Unique) {
        if (Test-Path $logFile) {
            $lines = @(Get-Content $logFile -Tail 15 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 0) {
                Write-Log "`n  Файл $logFile (последние строки):" -Color Yellow
                $lines | ForEach-Object { Write-Log "    $_" -Color DarkGray }
            }
        }
    }
    Write-Log "`n  nssm dump $ServiceName :" -Color Yellow
    try {
        $oemCodePage = 866
        try {
            $oemCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
            if ($oemCp -gt 0) { $oemCodePage = [int]$oemCp }
        } catch { }
        $origOutputEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding($oemCodePage)
            & $NssmExe dump $ServiceName 2>&1 | ForEach-Object { Write-Log "    $_" -Color DarkGray }
        } finally {
            [Console]::OutputEncoding = $origOutputEncoding
        }
    } catch {}
    return $false
}

try {
    $ollamaExe = Join-Path $OllamaDir 'ollama.exe'
    $currentVersion = $null

    if (Test-Path $ollamaExe) {
        $verOut = (& $ollamaExe --version 2>&1) -join ' '
        if ($verOut -match '(\d+\.\d+\.\d+)') {
            $currentVersion = "v$($matches[1])"
            Write-Log "`n  [INFO] Обнаружена установленная версия: $currentVersion" -Color Green
        }
    } else {
        Write-Log "`n  [INFO] Ollama не установлена — будет выполнена первичная установка." -Color Cyan
    }

    Write-Step "Выбор версии Ollama"
    $targetVersion = $null
    if ($currentVersion -and -not $forceDL -and -not $Upgrade) {
        Write-Log "  Текущая версия: $currentVersion" -Color Cyan
        $resolvedVersion = Resolve-OllamaVersion -RequestedVersion $OllamaVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($resolvedVersion -is [string] -and $resolvedVersion -eq 'CANCEL') {
            Write-Log "`n  Установка отменена пользователем. Служба не тронута." -Color Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
        if (-not $resolvedVersion) {
            if ($Force) { throw "Не удалось определить версию." }
            $resolvedVersion = $currentVersion
        }
        $targetVersion = $resolvedVersion
    } else {
        $targetVersion = Resolve-OllamaVersion -RequestedVersion $OllamaVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($targetVersion -is [string] -and $targetVersion -eq 'CANCEL') {
            Write-Log "`n  Установка отменена пользователем. Служба не тронута." -Color Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
        if (-not $targetVersion) {
            Write-Log '  [WARN] Не удалось определить версию. Используем резервный URL из INI.' -Color Yellow
            $targetVersion = ($OllamaUrlFallback -split '/')[-3]
        }
    }

    $isReinstall = $false
    $isUpgrade   = $false
    if ($currentVersion -and $targetVersion) {
        if ($currentVersion -eq $targetVersion) {
            $isReinstall = $true
            Write-Log "`n  [INFO] Та же версия: $targetVersion (переустановка)" -Color Yellow
            if (-not $Force) {
                $ans = Read-Host "Переустановить текущую версию $currentVersion? [Y/n]"
                if ($ans -eq 'n' -or $ans -eq 'N') {
                    Write-Log "`n  Установка отменена пользователем. Служба не тронута." -Color Yellow
                    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
                    exit 0
                }
            }
        } else {
            $isUpgrade = $true
            Write-Log "`n  -> Обновление/даунгрейд: $currentVersion -> $targetVersion" -Color Cyan
        }
    } elseif ($targetVersion) {
        Write-Log "`n  -> Первичная установка: $targetVersion" -Color Cyan
    }

    $needsBackup = ($currentVersion -and (Test-Path $OllamaDir))
    Write-Log ""
    Write-Log "  План действий:" -Color Cyan
    Write-Log "    - Текущая версия : $(if($currentVersion){$currentVersion} else {'-'})"
    Write-Log "    - Целевая версия : $targetVersion"
    Write-Log "    - Режим          : $(if($isReinstall){'переустановка'} elseif($isUpgrade){'обновление/даунгрейд'} else {'первичная установка'})"
    Write-Log "    - Бэкап          : $(if($needsBackup){'будет создан'} else {'не требуется'})"

    if (-not $Force -and $needsBackup) {
        Write-Host ""
        if ((Read-Host 'Продолжить? [Y/n]') -eq 'n') {
            Write-Log "  Отменено. Служба не тронута." -Color Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
    }

    $downloadUrl = "https://github.com/ollama/ollama/releases/download/$targetVersion/ollama-windows-amd64.zip"

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Step "Остановка существующей службы $ServiceName"
        & sc.exe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    Stop-OllamaProcesses

    Write-Step "Проверка порта $Port"
    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        $pids = ($busy.OwningProcess | Sort-Object -Unique) -join ', '
        Write-Log "Порт $Port уже занят PID: $pids" -Color Yellow
        if (-not $Force) {
            $ans = Read-Host 'Продолжить? [y/N]'
            if ($ans -ne 'y') { throw 'Отменено пользователем' }
        }
    } else {
        Write-Log '  [OK] Свободен' -Color Green
    }

    Write-Step 'Создание каталогов'
    foreach ($d in @($OllamaDir, $ModelsDir, $LogsDir, $NssmDir, $OllamaHome, $NewProfile, $DownloadsDir, $BackupDir) | Select-Object -Unique) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Log "  [OK] $d"
    }

    Write-Step 'Права доступа'
    Set-OllamaAcl -OllamaDir $OllamaDir -OllamaHome $OllamaHome -ModelsDir $ModelsDir -NewProfile $NewProfile
    Write-Log "  [OK] Права Full Control выданы (SYSTEM + Administrators)" -Color Green

    Write-Step "Установка NSSM в $NssmDir"
    $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\win64\\' } |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $nssmExe -or $forceDL) {
        $nssmZipName = Get-FileNameFromUrl -Url $NssmUrl -Fallback 'NSSM.zip'
        $nssmVer = if ($NssmUrl -match '/download/([^/]+)/') { $matches[1] -replace '^v', '' } else { 'unknown' }
        $nssmSubDir = "nssm_$nssmVer"
        $nssmZip     = Get-CachedFile -Url $NssmUrl -FileName $nssmZipName -SubDir $nssmSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $nssmZip -DestinationPath $NssmDir -Force
        if (-not $KeepDownloads) { Remove-Item -LiteralPath $nssmZip -Force -ErrorAction SilentlyContinue }
        $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
        if (-not $nssmExe) { $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Select-Object -First 1 -ExpandProperty FullName }
        if (-not $nssmExe) { throw "nssm.exe не найден после распаковки в $NssmDir" }
    }
    Write-Log "  [OK] $nssmExe"

    if ($AddNssmToPath) {
        Write-Step "Переменная PATH - NSSM (Machine)"
        foreach ($nssmSub in @('win32','win64')) {
            $nssmPath = Join-Path $NssmDir $nssmSub
            if (Test-Path $nssmPath) {
                Add-ToMachinePath -Dir $nssmPath
            } else {
                Write-Log "  [INFO] Пропущено (нет папки): $nssmPath" -Color DarkGray
            }
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # Бэкап: копируем только бинарники, защищённые папки не трогаем
    # ══════════════════════════════════════════════════════════════════════
    $backupPath = $null
    if ($needsBackup) {
        Write-Step "Создание резервной копии (только бинарники)"
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupName = "Ollama_$timestamp"
        $backupPath = Join-Path $BackupDir $backupName
        try {
            New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            $itemsToBackup = Get-ChildItem -Path $OllamaDir | Where-Object {
                $fp = [IO.Path]::GetFullPath($_.FullName)
                $protectedPaths -notcontains $fp
            }
            foreach ($item in $itemsToBackup) {
                Copy-Item -Path $item.FullName -Destination $backupPath -Recurse -Force
            }
            Write-Log "  [OK] Резервная копия создана: $backupPath" -Color Green
            Write-Log "  [INFO] Папки install, OllamaTM, logs, Downloads, Backup, Models, .ollama не копировались" -Color DarkGray
        } catch {
            throw "Не удалось создать резервную копию (файлы заняты?). Ошибка: $_"
        }
    }

    Write-Step "Очистка старых бинарников (защищённые папки сохраняются)"
    if ($needsBackup) {
        $itemsToRemove = Get-ChildItem -Path $OllamaDir | Where-Object {
            $fp = [IO.Path]::GetFullPath($_.FullName)
            $protectedPaths -notcontains $fp
        }
        foreach ($item in $itemsToRemove) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "  [OK] Старые бинарники удалены" -Color Green
    }

    if ($LogRetentionDays -gt 0 -and (Test-Path $LogsDir)) {
        Write-Log "  -> Ротация логов: удаление файлов старше $LogRetentionDays дней из $LogsDir" -Color DarkGray
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -Path $LogsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Set-OllamaAcl -OllamaDir $OllamaDir -OllamaHome $OllamaHome -ModelsDir $ModelsDir -NewProfile $NewProfile
    Write-Log "  [OK] Права Full Control повторно применены" -Color Green

    Write-Step "Установка Ollama в $OllamaDir"
    if ($needsBackup -or -not (Test-Path $ollamaExe) -or $forceDL) {
        Write-Log "  -> Целевая версия: $targetVersion" -Color Green
        $ollamaSubDir = 'ollama_' + ($targetVersion -replace '^v', '')
        $ollamaZip     = Get-CachedFile -Url $downloadUrl -FileName 'ollama-windows-amd64.zip' -SubDir $ollamaSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $ollamaZip -DestinationPath $OllamaDir -Force
        if (-not $KeepDownloads) { Remove-Item -LiteralPath $ollamaZip -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Log "  [INFO] Установка не требуется (используется текущая)"
    }

    $verRaw = (& $ollamaExe --version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) { throw "ollama.exe --version завершился с кодом $LASTEXITCODE." }
    $verDisplay = $verRaw
    if ($verRaw -match 'client version is ([\d\.]+)') { $verDisplay = "v$($matches[1])" }
    elseif ($verRaw -match 'version is ([\d\.]+)') { $verDisplay = "v$($matches[1])" }
    Write-Log "  [OK] $verDisplay" -Color Green

    Write-Step 'Переменные окружения (Machine)'
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST',   $OllamaHost, 'Machine')
    [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $ModelsDir,  'Machine')
    Write-Log "  [OK] OLLAMA_HOST=$OllamaHost"
    Write-Log "  [OK] OLLAMA_MODELS=$ModelsDir"

    if ($AddToPath) {
        Write-Step "Переменная PATH (Ollama)"
        Add-ToMachinePath -Dir $OllamaDir
    } else {
        Write-Log "`n  [INFO] AddToPath=false - PATH для Ollama не изменяем" -Color DarkGray
    }

    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        Write-Step "Правило брандмауэра ($FirewallSubnet)"
        $ruleName = "Ollama API ($FirewallSubnet)"
        Get-NetFirewallRule -DisplayName "Ollama API*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $FirewallSubnet -Action Allow -Profile Any | Out-Null
        Write-Log "  [OK] $ruleName" -Color Green
    }

    if ((Test-Path $OldProfile) -and -not (Test-Path (Join-Path $NewProfile 'id_ed25519'))) {
        Write-Step "Миграция профиля из $OldProfile"
        Copy-Item -Path "$OldProfile\*" -Destination $NewProfile -Recurse -Force -ErrorAction SilentlyContinue
        Set-OllamaAcl -OllamaDir $OllamaDir -OllamaHome $OllamaHome -ModelsDir $ModelsDir -NewProfile $NewProfile
        Write-Log "  [OK] Скопировано в $NewProfile" -Color Green
    }

    Write-Step "Регистрация службы $ServiceName"
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        $svc = Get-Service -Name $ServiceName
        if ($svc.Status -ne 'Stopped') {
            Write-Log '  -> Остановка старой службы'
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & $nssmExe stop $ServiceName 2>&1 | Out-Null
            $ErrorActionPreference = $prevEAP
            
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt 15) {
                Start-Sleep -Milliseconds 500
            }
        } else {
            Write-Log '  [INFO] Старая служба уже остановлена'
        }
        
        Write-Log '  -> Удаление старой службы'
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 500
        }
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            Write-Log "  NSSM не удалил службу, принудительно через sc.exe" -Color Yellow
            & sc.exe delete $ServiceName 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            throw "Не удалось удалить старую службу $ServiceName"
        }
    }

    & $nssmExe install $ServiceName $ollamaExe serve 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Ошибка NSSM при установке службы (код $LASTEXITCODE)." }
    & $nssmExe set $ServiceName AppDirectory $OllamaDir 2>&1 | Out-Null
    & $nssmExe set $ServiceName Start $StartType 2>&1 | Out-Null
    & $nssmExe set $ServiceName Description "Ollama is the most popular way to build with open models. Access the latest open models with complete privacy locally or in the cloud. Your prompts are never stored or trained on." 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppEnvironmentExtra @envPairs 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStdout (Join-Path $LogsDir 'ollama.out.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $LogsDir 'ollama.err.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes 10485760 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppExit Default Restart 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay $AppRestartDelay 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle 1500 2>&1 | Out-Null
    Write-Log '  [OK] Служба сконфигурирована' -Color Green

    Write-Step 'Запуск службы'
    $ok = Start-OllamaService -NssmExe $nssmExe -ServiceName $ServiceName -TimeoutSec $StartTimeoutSec -MaxAttempts 3
    if (-not $ok) {
        Write-Log "`n=== ДОПОЛНИТЕЛЬНАЯ ДИАГНОСТИКА ===" -Color Yellow
        Test-OllamaServeDirect -OllamaExe $ollamaExe -EnvVars $testEnv | Out-Null
        throw "Служба $ServiceName не запустилась. Смотрите диагностику выше."
    }

    Write-Step 'Проверка API (локально)'
    $maxAttempts = 15
    $apiOk = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 2
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tags" -TimeoutSec 5 | Out-Null
            $apiOk = $true
            Write-Log "  [OK] Попытка ${i}: API отвечает" -Color Green
            break
        } catch {
            Write-Log "  ... Попытка ${i}/${maxAttempts}: $($_.Exception.Message)"
        }
    }
    if (-not $apiOk) { Write-Log "API не ответил за $($maxAttempts * 2) секунд." -Color Yellow }

    $pulledModels = @()
    if ($DownloadModels) {
        Write-Step 'Скачивание моделей'
        if (-not $apiOk) {
            Write-Log '  API не отвечает — скачивание моделей пропущено.' -Color Yellow
        } else {
            $toPull = @()
            if ($InteractiveModels -and -not $Force) {
                $toPull = Select-ModelsInteractive -Preselected $preselectedModels
            } else {
                $toPull = $preselectedModels
                if ($toPull.Count -eq 0) { Write-Log '  [INFO] Модели не заданы - пропускаем.' }
                else { Write-Log "  -> Неинтерактивный режим: $($toPull -join ', ')" }
            }
            if ($toPull.Count -gt 0) {
                Write-Log ''
                foreach ($m in $toPull) {
                    if (Invoke-PullModel -Exe $ollamaExe -Model $m -ApiHost "127.0.0.1:$Port") {
                        $pulledModels += $m
                    }
                }
            }
        }
    }

    $actionLabel = if ($isReinstall) { 'переустановка' } elseif ($isUpgrade) { 'обновление/даунгрейд' } else { 'первичная установка' }
    Write-Log "`n=============================" -Color Green
    Write-Log " Развёртывание завершено ($actionLabel)" -Color Green
    Write-Log '=============================' -Color Green
    Write-Log " Служба      : $ServiceName"
    Write-Log " Версия      : $(if($currentVersion){$currentVersion} else {'не была установлена'}) -> $(if($targetVersion){$targetVersion} else {'N/A'})"
    Write-Log " Бинарник    : $ollamaExe"
    Write-Log " Модели      : $ModelsDir"
    Write-Log " Профиль     : $NewProfile"
    Write-Log " Логи        : $LogsDir"
    Write-Log " Архивы      : $DownloadsDir\ollama_$($targetVersion -replace '^v','')"
    if ($backupPath) { Write-Log " Бэкап       : $backupPath" } else { Write-Log " Бэкапы      : $BackupDir (не требуется)" }
    Write-Log " API локально: http://127.0.0.1:$Port"
    Write-Log " Performance : KeepAlive=$KeepAlive, FA=$faValue, KvCache=$KvCacheType"

    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        $localIps = @()
        try {
            $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and $_.PrefixOrigin -ne 'WellKnown' }
            foreach ($ip in $ips) {
                $networkIp = $FirewallSubnet -replace '/.*$'
                $prefixLen = [int]($FirewallSubnet -replace '^.*/', '')
                $ipBytes = ([System.Net.IPAddress]::Parse($ip.IPAddress)).GetAddressBytes()
                $netBytes = ([System.Net.IPAddress]::Parse($networkIp)).GetAddressBytes()
                $ipNum = [uint32]$ipBytes[0] -shl 24 -bor [uint32]$ipBytes[1] -shl 16 -bor [uint32]$ipBytes[2] -shl 8 -bor [uint32]$ipBytes[3]
                $netNum = [uint32]$netBytes[0] -shl 24 -bor [uint32]$netBytes[1] -shl 16 -bor [uint32]$netBytes[2] -shl 8 -bor [uint32]$netBytes[3]
                $mask = if ($prefixLen -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefixLen)) }
                if (($ipNum -band $mask) -eq ($netNum -band $mask)) { $localIps += $ip.IPAddress }
            }
        } catch {}
        if ($localIps.Count -gt 0) {
            foreach ($ip in $localIps) { Write-Log " API по сети : http://${ip}:$Port ($FirewallSubnet)" }
        } else {
            Write-Log " API по сети : http://<IP-сервера>:$Port ($FirewallSubnet)"
        }
    }

    if ($AddToPath) { Write-Log " PATH (Ollama): $OllamaDir добавлен (нужна новая консоль)" }
    if ($AddNssmToPath) { Write-Log " PATH (NSSM)  : $NssmDir\win32 и \win64 добавлены" }
    if ($pulledModels.Count -gt 0) { Write-Log " Загружено   : $($pulledModels -join ', ')" }
    Write-Log " Проверка    : ollama list"
}
catch {
    Write-Log "`nERROR: $_" -Color Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }