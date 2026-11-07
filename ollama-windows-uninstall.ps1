#Requires -Version 5.1
<#
.SYNOPSIS
    Удаление службы Ollama.

.DESCRIPTION
    Читает ollama-windows-install.ini. Останавливает и удаляет службу,
    чистит брандмауэр и переменные окружения. Каталоги (модели, профиль,
    логи, бэкапы, архивы) удаляются только по явным флагам.
    При -PurgeOllama папки install, OllamaTM, logs, Downloads, Backup, Models, .ollama
    сохраняются.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$PurgeProfile,
    [switch]$PurgeModels,
    [switch]$PurgeOllama,
    [switch]$PurgeLogs,
    [switch]$PurgeDownloads,
    [switch]$PurgeBackup,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'ollama-windows-install.ini'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запрос прав администратора (UAC)...' -ForegroundColor Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`""
    if ($PurgeProfile)   { $argLine += ' -PurgeProfile'   }
    if ($PurgeModels)    { $argLine += ' -PurgeModels'    }
    if ($PurgeOllama)    { $argLine += ' -PurgeOllama'    }
    if ($PurgeLogs)      { $argLine += ' -PurgeLogs'      }
    if ($PurgeDownloads) { $argLine += ' -PurgeDownloads' }
    if ($PurgeBackup)    { $argLine += ' -PurgeBackup'    }
    if ($Force)          { $argLine += ' -Force'          }
    if ($NoPause)        { $argLine += ' -NoPause'        }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine
    exit
}

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

$OllamaDir    = Get-Cfg     'paths'   'OllamaDir'        'D:\AI\Ollama'
$ModelsDir    = Get-Cfg     'paths'   'ModelsDir'        ''
$NssmDir      = Get-Cfg     'paths'   'NssmDir'          'C:\Program Files\NSSM'
$LogsDir      = Get-Cfg     'paths'   'LogsDir'          ''
$DownloadsDir = Get-Cfg     'paths'   'DownloadsDir'     ''
$BackupDir    = Get-Cfg     'paths'   'BackupDir'        ''
$OllamaHome   = Get-Cfg     'ollama'  'OllamaHome'       $OllamaDir
$ServiceName  = Get-Cfg     'service' 'ServiceName'      'Ollama'
$AddToPath    = Get-CfgBool 'service' 'AddToPath'        $true
$AddNssmToPath = Get-CfgBool 'service' 'AddNssmToPath'   $true
$Port         = [int](Get-Cfg 'network' 'Port'           '11434')

# Нормализация путей
if ([string]::IsNullOrWhiteSpace($ModelsDir)) { $ModelsDir = Join-Path $OllamaDir 'Models' } elseif (-not [IO.Path]::IsPathRooted($ModelsDir)) { $ModelsDir = Join-Path $OllamaDir $ModelsDir }
if ([string]::IsNullOrWhiteSpace($LogsDir)) { $LogsDir = Join-Path $OllamaDir 'logs' } elseif (-not [IO.Path]::IsPathRooted($LogsDir)) { $LogsDir = Join-Path $OllamaDir $LogsDir }
if ([string]::IsNullOrWhiteSpace($DownloadsDir)) { $DownloadsDir = Join-Path $OllamaDir 'Downloads' } elseif (-not [IO.Path]::IsPathRooted($DownloadsDir)) { $DownloadsDir = Join-Path $OllamaDir $DownloadsDir }
if ([string]::IsNullOrWhiteSpace($BackupDir)) { $BackupDir = Join-Path $OllamaDir 'Backup' } elseif (-not [IO.Path]::IsPathRooted($BackupDir)) { $BackupDir = Join-Path $OllamaDir $BackupDir }
if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }

$ModelsDir    = [IO.Path]::GetFullPath($ModelsDir)
$LogsDir      = [IO.Path]::GetFullPath($LogsDir)
$DownloadsDir = [IO.Path]::GetFullPath($DownloadsDir)
$BackupDir    = [IO.Path]::GetFullPath($BackupDir)
$NewProfile   = Join-Path $OllamaHome '.ollama'
$InstallPath  = [IO.Path]::GetFullPath((Join-Path $OllamaDir 'install'))
$OllamaTMDir  = [IO.Path]::GetFullPath((Join-Path $OllamaDir 'OllamaTM'))

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Confirm-Action([string]$Prompt) {
    if ($Force) { Write-Host "  (Force) $Prompt -> да"; return $true }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -eq 'y')
}

function Find-Nssm {
    param([string]$Dir)
    $exe = Get-ChildItem -Path $Dir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $exe) { $exe = Get-ChildItem -Path $Dir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    return $exe
}

function Remove-FromMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current -or $current.Trim() -eq '') { Write-Host '  [INFO] PATH не задан'; return }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    $target = $Dir.TrimEnd('\')
    $kept = $parts | Where-Object { $_.TrimEnd('\') -ne $target }
    if ($kept.Count -eq $parts.Count) { Write-Host "  [INFO] $Dir в PATH не найден"; return }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine')
    Write-Host "  [OK] $Dir удалён из PATH"
    Write-Host '  [INFO] Изменения вступят в силу в новых консолях.'
}

try {
    Write-Step "Служба $ServiceName"
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $nssmExe = Find-Nssm -Dir $NssmDir
        if ($nssmExe) { & $nssmExe stop $ServiceName 2>&1 | Out-Null } else { & sc.exe stop $ServiceName | Out-Null }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 500 }
        if ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        if ($nssmExe) { & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null }
        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { & sc.exe delete $ServiceName | Out-Null; Start-Sleep -Seconds 1 }
        Write-Host '  [OK] Служба удалена'
    } else {
        Write-Host '  [INFO] Службы нет'
    }

    Write-Step 'Правило брандмауэра'
    $rules = Get-NetFirewallRule -DisplayName "Ollama API*" -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Host "  [OK] Удалено правил: $($rules.Count)"
    } else {
        Write-Host '  [INFO] Правил не найдено'
    }

    Write-Step 'Переменная PATH (Machine)'
    if ($AddToPath) {
        Remove-FromMachinePath -Dir $OllamaDir
    }
    if ($AddNssmToPath) {
        foreach ($nssmSub in @('win32','win64')) {
            Remove-FromMachinePath -Dir (Join-Path $NssmDir $nssmSub)
        }
    }

    Write-Step 'Переменные окружения (Machine)'
    foreach ($name in @('OLLAMA_HOST','OLLAMA_MODELS')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Machine')
        Write-Host "  [OK] Удалена $name"
    }

    Write-Step "Профиль: $NewProfile"
    if (Test-Path $NewProfile) {
        if ($PurgeProfile) {
            if (Confirm-Action "Удалить $NewProfile?") {
                Remove-Item -LiteralPath $NewProfile -Recurse -Force
                Write-Host '  [OK] Удалён'
            }
        } else {
            Write-Host '  [INFO] Сохранён (используйте -PurgeProfile)'
        }
    }

    Write-Step "Модели: $ModelsDir"
    if (Test-Path $ModelsDir) {
        if ($PurgeModels) {
            if (Confirm-Action "Удалить $ModelsDir?") {
                Remove-Item -LiteralPath $ModelsDir -Recurse -Force
                Write-Host '  [OK] Удалён'
            }
        } else {
            Write-Host '  [INFO] Сохранён (используйте -PurgeModels)'
        }
    }

    Write-Step "Бинарники: $OllamaDir"
    if (Test-Path $OllamaDir) {
        if ($PurgeOllama) {
            Write-Host '  [WARN] Папки install, OllamaTM, logs, Downloads, Backup, Models, .ollama сохраняются'
            if (Confirm-Action "Удалить бинарники в $OllamaDir (кроме защищённых папок)?") {
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

                $itemsToRemove = Get-ChildItem -Path $OllamaDir | Where-Object {
                    $fp = [IO.Path]::GetFullPath($_.FullName)
                    $protectedPaths -notcontains $fp
                }
                foreach ($item in $itemsToRemove) {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-Host '  [OK] Бинарники удалены (защищённые папки сохранены)'
            }
        } else {
            Write-Host '  [INFO] Сохранён (используйте -PurgeOllama)'
        }
    }

    Write-Step "Логи: $LogsDir"
    if (Test-Path $LogsDir) {
        if ($PurgeLogs) {
            if (Confirm-Action "Удалить $LogsDir?") {
                Remove-Item -LiteralPath $LogsDir -Recurse -Force
                Write-Host '  [OK] Удалён'
            }
        } else {
            Write-Host '  [INFO] Сохранён (используйте -PurgeLogs)'
        }
    }

    Write-Step "Архивы: $DownloadsDir"
    if (Test-Path $DownloadsDir) {
        if ($PurgeDownloads) {
            if (Confirm-Action "Удалить $DownloadsDir (включая подпапки версий)?") {
                Remove-Item -LiteralPath $DownloadsDir -Recurse -Force
                Write-Host '  [OK] Удалён'
            }
        } else {
            Write-Host '  [INFO] Сохранён (используйте -PurgeDownloads)'
        }
    }

    Write-Step "Бэкапы: $BackupDir"
    if (Test-Path $BackupDir) {
        if ($PurgeBackup) {
            if (Confirm-Action "Удалить $BackupDir?") {
                Remove-Item -LiteralPath $BackupDir -Recurse -Force
                Write-Host '  [OK] Удалён'
            }
        } else {
            Write-Host '  [INFO] Сохранён (используйте -PurgeBackup)'
        }
    }

    Write-Host "`n Удаление завершено." -ForegroundColor Green
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}
if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }