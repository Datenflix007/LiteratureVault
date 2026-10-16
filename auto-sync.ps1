#!/usr/bin/env powershell
param(
    [string]$WatchPath = "",
    [int]$IntervalSeconds = 5
)

# This is intentionally only an activity monitor. The OneDrive/Nextcloud/Dropbox
# desktop client performs the actual cloud sync; Zotero files are never added to Git.
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$script:LogFile = Join-Path $ScriptDir ".sync-log.json"

function Write-Log($Text, $Level = "info") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Text"
    try {
        $entries = @()
        if (Test-Path $script:LogFile) { $entries = @(Get-Content $script:LogFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        $entries += [PSCustomObject]@{ ts = (Get-Date).ToString("o"); level = $Level; text = $Text }
        if ($entries.Count -gt 300) { $entries = $entries[($entries.Count - 300)..($entries.Count - 1)] }
        $entries | ConvertTo-Json -Depth 4 | Set-Content $script:LogFile -Encoding UTF8
    } catch { }
}

function Get-ConfiguredStoragePath {
    if (Test-Path (Join-Path $ScriptDir ".env.local")) {
        Get-Content (Join-Path $ScriptDir ".env.local") -Encoding UTF8 | ForEach-Object {
            if ($_.Trim() -match '^ZOTERO_STORAGE_PATH=(.*)$') { $script:configuredPath = $matches[1].Trim() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:configuredPath)) { return (Join-Path $ScriptDir "data") }
    if ([IO.Path]::IsPathRooted($script:configuredPath)) { return $script:configuredPath }
    return (Join-Path $ScriptDir $script:configuredPath)
}

if ([string]::IsNullOrWhiteSpace($WatchPath)) { $WatchPath = Get-ConfiguredStoragePath }
if (-not (Test-Path -LiteralPath $WatchPath)) { New-Item -ItemType Directory -Path $WatchPath -Force | Out-Null }
$WatchPath = (Resolve-Path -LiteralPath $WatchPath).Path

Write-Log "Speicher-Monitor gestartet. Cloud-Synchronisierung ueber den Desktop-Client; keine Git-Commits fuer Anhaenge." "ok"
Write-Log "Ueberwache: $WatchPath" "info"
$lastStamp = (Get-ChildItem -LiteralPath $WatchPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object LastWriteTimeUtc -Maximum).Maximum

try {
    while ($true) {
        Start-Sleep -Seconds $IntervalSeconds
        $currentStamp = (Get-ChildItem -LiteralPath $WatchPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object LastWriteTimeUtc -Maximum).Maximum
        if ($currentStamp -and $currentStamp -ne $lastStamp) {
            $lastStamp = $currentStamp
            Write-Log "Dateien im externen Speicher wurden aktualisiert. Der Cloud-Client synchronisiert sie ausserhalb von Git." "info"
        }
    }
}
finally { Write-Log "Speicher-Monitor beendet." "warn" }
