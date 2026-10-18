param(
    [switch]$SkipDockerInstall,
    [switch]$SkipZoteroInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir
$script:FirstRun = $false
$WebDavStartupTimeoutMinutes = 8
$WebDavComposeMaxAttempts = 3
$WebDavComposeRetryDelaySeconds = 5

# ----------- Helpers -------------------------------------------------

function Write-Step($Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
}
function Write-Ok($Text)   { Write-Host "[OK]   $Text" -ForegroundColor Green  }
function Write-Info($Text) { Write-Host "[INFO] $Text" -ForegroundColor Gray   }
function Write-Warn($Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }

# ----------- Env file ------------------------------------------------

function Import-EnvFile {
    $values = [ordered]@{}
    if (-not (Test-Path ".env")) { return $values }
    Get-Content ".env" -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $value = $line.Split("=", 2)
            $values[$key.Trim()] = $value.Trim()
            [Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim(), "Process")
        }
    }
    return $values
}

function Get-DefaultStoragePath {
    $oneDriveFolders = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter "OneDrive*" -ErrorAction SilentlyContinue)
    $oneDrive = @($oneDriveFolders | Where-Object { $_.Name -like "OneDrive - *" } | Select-Object -First 1).FullName
    if ([string]::IsNullOrWhiteSpace($oneDrive)) { $oneDrive = [Environment]::GetEnvironmentVariable("OneDrive") }
    if ([string]::IsNullOrWhiteSpace($oneDrive)) { $oneDrive = Join-Path $env:USERPROFILE "OneDrive" }
    return (Join-Path $oneDrive "MyLiteratureVault")
}

function Get-StoragePath {
    $storagePath = "$env:ZOTERO_STORAGE_PATH".Trim()
    if ([string]::IsNullOrWhiteSpace($storagePath)) { $storagePath = Get-DefaultStoragePath }
    if (-not [IO.Path]::IsPathRooted($storagePath)) { $storagePath = Join-Path $ScriptDir $storagePath }
    return [IO.Path]::GetFullPath($storagePath)
}

function Ensure-EnvFile {
    Write-Step "[1/7] Projekt einrichten"

    if (Test-Path ".env") {
        Write-Ok ".env ist vorhanden"
        Import-EnvFile | Out-Null
        return
    }

    $script:FirstRun = $true
    Write-Host "Erster Start - GitHub speichert nur den Code, niemals Zotero-Anhaenge."
    $githubUser  = Read-Host "GitHub Benutzername"
    $githubEmail = Read-Host "GitHub E-Mail"
    $githubToken = Read-Host "GitHub Personal Access Token (leer = Git bereits angemeldet)"
    $providerInput = (Read-Host "Cloud-Anbieter (onedrive, nextcloud, dropbox oder local; Standard: onedrive)").Trim()
    $provider = $providerInput.ToLowerInvariant()
    $shareUrl = ""
    if ($provider -match "^https?://") {
        $shareUrl = $providerInput
        $provider = "onedrive"
        Write-Info "Der eingefuegte Link wird als OneDrive-Freigabelink gespeichert."
    }
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = "onedrive" }
    if ($provider -notin @("onedrive", "nextcloud", "dropbox", "local")) {
        Write-Warn "Unbekannter Anbieter '$provider'; verwende onedrive."
        $provider = "onedrive"
    }
    $defaultStoragePath = Get-DefaultStoragePath
    $storagePath = Read-Host "Lokal synchronisierter Cloud-Ordner (Standard: $defaultStoragePath)"
    if ([string]::IsNullOrWhiteSpace($storagePath)) { $storagePath = $defaultStoragePath }
    $shareUrlInput = Read-Host "Optionaler Freigabelink zu diesem Ordner"
    if (-not [string]::IsNullOrWhiteSpace($shareUrlInput)) { $shareUrl = $shareUrlInput }

    $lines = @(
        "# GitHub Configuration",
        "GITHUB_USERNAME=$githubUser",
        "GITHUB_EMAIL=$githubEmail",
        "GITHUB_TOKEN=$githubToken",
        "",
        "# WebDAV Server",
        "WEBDAV_URL=http://localhost:8080",
        "WEBDAV_USERNAME=zotero",
        "WEBDAV_PASSWORD=changeme123",
        "",
        "# External attachment storage - synced by the provider desktop app, never Git/LFS",
        "STORAGE_PROVIDER=$provider",
        "ZOTERO_STORAGE_PATH=$storagePath",
        "STORAGE_SHARE_URL=$shareUrl"
    )
    $lines | Out-File -FilePath '.env' -Encoding UTF8 -Force

    [Environment]::SetEnvironmentVariable("GITHUB_USERNAME", $githubUser,  "Process")
    [Environment]::SetEnvironmentVariable("GITHUB_EMAIL",    $githubEmail, "Process")
    [Environment]::SetEnvironmentVariable("GITHUB_TOKEN",    $githubToken, "Process")
    [Environment]::SetEnvironmentVariable("STORAGE_PROVIDER", $provider, "Process")
    [Environment]::SetEnvironmentVariable("ZOTERO_STORAGE_PATH", $storagePath, "Process")
    [Environment]::SetEnvironmentVariable("STORAGE_SHARE_URL", $shareUrl, "Process")
    if ($githubUser)  { git config user.name  $githubUser  | Out-Null }
    if ($githubEmail) { git config user.email $githubEmail | Out-Null }
    Write-Ok ".env erstellt und Git-Benutzer gesetzt"
}

# ----------- Git pull ------------------------------------------------

function Invoke-GitRemotePull {
    Write-Step "[2/7] GitHub-Stand pruefen"

    $token = $env:GITHUB_TOKEN
    $auth = if ($token) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
        @("-c", "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64")
    } else { @() }

    $null = & git @auth fetch --prune 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Fetch fehlgeschlagen - arbeite lokal weiter."
        return
    }

    $dirty = git status --porcelain 2>$null
    if (-not [string]::IsNullOrWhiteSpace($dirty)) {
        Write-Info "Pull uebersprungen (lokale Aenderungen vorhanden)."
        return
    }

    $null = & git @auth pull --ff-only 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "Repository ist aktuell" }
    else { Write-Warn "Fast-forward Pull nicht moeglich - bitte git status pruefen." }
}

# ----------- Zotero --------------------------------------------------

function Find-ZoteroExe {
    $candidates = @(
        "$env:ProgramFiles\Zotero\zotero.exe",
        "${env:ProgramFiles(x86)}\Zotero\zotero.exe",
        "$env:LOCALAPPDATA\Zotero\zotero.exe",
        "$env:LOCALAPPDATA\Programs\Zotero\zotero.exe"
    )
    foreach ($rp in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe",
                      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe")) {
        $entry = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        if ($entry -and $entry.'(default)') { $candidates += $entry.'(default)' }
    }
    return ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Ensure-ZoteroInstalled {
    Write-Step "[3/7] Zotero pruefen"

    if (Find-ZoteroExe) {
        Write-Ok "Zotero ist installiert"
        return
    }

    if ($SkipZoteroInstall) {
        Write-Warn "Zotero nicht installiert. Bitte manuell installieren: https://www.zotero.org/download/"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget nicht gefunden. Bitte Zotero manuell installieren: https://www.zotero.org/download/"
        return
    }

    $wl = winget list --id Zotero.Zotero --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -and "$wl" -match "Zotero") {
        Write-Ok "Zotero ist bereits installiert (winget)"
        return
    }

    Write-Info "Installiere Zotero via winget..."
    winget install --exact --id Zotero.Zotero --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Zotero-Installation fehlgeschlagen. Manuell: https://www.zotero.org/download/"
        return
    }
    Write-Ok "Zotero installiert"
}

function Start-Zotero {
    $running = Get-Process -Name "zotero" -ErrorAction SilentlyContinue
    if ($running) { Write-Ok "Zotero laeuft bereits"; return }

    $exe = Find-ZoteroExe
    if ($exe) {
        Write-Info "Starte Zotero..."
        Start-Process -FilePath $exe -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Zotero nicht gefunden - bitte manuell starten."
    }
}

# ----------- Docker install ------------------------------------------

function Ensure-DockerInstalled {
    Write-Step "[4/7] Docker pruefen"

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Ok "Docker CLI ist vorhanden"
        return
    }

    if ($SkipDockerInstall) {
        throw "Docker nicht installiert. Bitte Docker Desktop installieren: https://www.docker.com/products/docker-desktop/"
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Docker nicht installiert und winget nicht gefunden. Bitte Docker Desktop manuell installieren."
    }

    Write-Info "Installiere Docker Desktop via winget (kann einige Minuten dauern)..."
    winget install --exact --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Docker-Installation fehlgeschlagen. Bitte Docker Desktop manuell installieren: https://www.docker.com/products/docker-desktop/"
    }

    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker installiert, aber noch nicht im PATH. Bitte Windows neu starten und quickstart.bat erneut ausfuehren."
    }
    Write-Ok "Docker Desktop installiert"
}

# ----------- Docker start --------------------------------------------

function Find-DockerDesktopExe {
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($rp in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Docker Desktop.exe",
                      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Docker Desktop.exe")) {
        $entry = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        if ($entry -and $entry.'(default)') { $candidates += $entry.'(default)' }
    }
    return ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Test-DockerReady {
    # A stopped Docker Desktop daemon is expected during startup. Do not let its
    # stderr abort the quickstart before we get the chance to launch it.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        $null = & docker info 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Start-DockerDesktop {
    Write-Step "[5/7] Docker starten"

    if (Test-DockerReady) {
        Write-Ok "Docker Engine laeuft bereits"
        return
    }

    $ddExe = Find-DockerDesktopExe
    if ($ddExe) {
        Write-Info "Starte Docker Desktop: $ddExe"
        Start-Process -FilePath $ddExe -WindowStyle Hidden -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Docker Desktop Exe nicht gefunden - versuche trotzdem..."
        Start-Process "Docker Desktop" -ErrorAction SilentlyContinue
    }

    Write-Host "Warte auf Docker Engine" -NoNewline
    $deadline = (Get-Date).AddMinutes(4)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        Write-Host "." -NoNewline
        if (Test-DockerReady) {
            Write-Host " bereit"
            Write-Ok "Docker Engine ist bereit"
            return
        }
    }

    Write-Host ""
    throw "Docker Engine war nach 4 Minuten nicht bereit. Docker Desktop manuell oeffnen, dann quickstart.bat erneut starten."
}

# ----------- WebDAV --------------------------------------------------

function Test-WebDavReady {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        return ($r.StatusCode -in @(200, 401, 207))
    } catch {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            return ($code -in @(200, 401, 207))
        }
        return $false
    }
}

function Get-WebDavContainerState {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        $stateOutput = & docker inspect --format "{{.State.Status}}" zotero-webdav 2>$null | Select-Object -First 1
        $state = ([string]$stateOutput).Trim()
        if ($LASTEXITCODE -eq 0) { return $state }
        return "nicht vorhanden"
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Test-WebDavContainerStarting {
    param(
        [object[]]$ComposeOutput,
        [string]$ContainerState
    )

    if ($ContainerState -in @("created", "running", "restarting")) { return $true }

    # `docker compose up -d` can return while Docker Desktop still creates the
    # container. In that short gap, docker inspect may not find it yet even
    # though Compose already reports "Container zotero-webdav Creating".
    $outputText = ($ComposeOutput | Out-String)
    return $outputText -match "(?im)^\\s*Container\\s+zotero-webdav\\s+(Creating|Created|Starting)\\s*$"
}

function Invoke-WebDavComposeUp {
    # Docker Compose can emit progress on stderr while Docker Desktop is still
    # settling. Capture that output with a non-terminating preference so the
    # quickstart can retry instead of entering the outer catch block.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& docker compose --env-file .env up -d 2>&1)
        $exitCode = $LASTEXITCODE
        return [PSCustomObject]@{
            Output = $output
            ExitCode = $exitCode
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Write-WebDavComposeLogs {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker compose --env-file .env logs --tail 20 2>&1 |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Start-WebDav {
    Write-Step "[6/7] WebDAV Container starten"

    $storagePath = Get-StoragePath
    $env:ZOTERO_STORAGE_PATH = $storagePath
    if (-not (Test-Path -LiteralPath $storagePath)) { New-Item -ItemType Directory -Path $storagePath -Force | Out-Null }
    # Zotero appends /zotero/ to the configured WebDAV endpoint. Apache DAV
    # does not create this collection on a PUT request, so prepare it here.
    $zoteroWebDavPath = Join-Path $storagePath "zotero"
    if (-not (Test-Path -LiteralPath $zoteroWebDavPath)) { New-Item -ItemType Directory -Path $zoteroWebDavPath -Force | Out-Null }
    $projectsPath = Join-Path $storagePath "Projekte"
    if (-not (Test-Path -LiteralPath $projectsPath)) { New-Item -ItemType Directory -Path $projectsPath -Force | Out-Null }
    Write-Info "Externer Speicher: $storagePath"

    $null = docker compose version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose nicht verfuegbar. Bitte Docker Desktop aktualisieren."
    }

    if (Test-WebDavReady) {
        Write-Ok "WebDAV antwortet bereits auf http://localhost:8080"
        return
    }

    Write-Info "Starte WebDAV Container..."
    # .env is intentionally ignored by Git and contains the local credentials.
    $upOut = @()
    $containerState = "nicht vorhanden"
    for ($attempt = 1; $attempt -le $WebDavComposeMaxAttempts; $attempt++) {
        # Docker Desktop restarts containers with `restart: unless-stopped` in
        # parallel to this script. After the short retry pause, prefer the
        # already restored service over another competing `compose up` call.
        if ($attempt -gt 1 -and (Test-WebDavReady)) {
            Write-Ok "WebDAV wurde waehrend des Docker-Starts bereit"
            return
        }

        $composeResult = Invoke-WebDavComposeUp
        $upOut = @($composeResult.Output)
        if ($composeResult.ExitCode -eq 0) {
            break
        }

        $containerState = Get-WebDavContainerState
        $containerIsStarting = Test-WebDavContainerStarting -ComposeOutput $upOut -ContainerState $containerState
        if ($attempt -lt $WebDavComposeMaxAttempts) {
            $status = if ($containerState -eq "nicht vorhanden") { "wird noch angelegt" } else { $containerState }
            Write-Warn "Docker Compose ist beim Versuch $attempt/$WebDavComposeMaxAttempts noch nicht bereit (Status: $status). Neuer Versuch in $WebDavComposeRetryDelaySeconds Sekunden..."
            Start-Sleep -Seconds $WebDavComposeRetryDelaySeconds
            continue
        }

        if (-not $containerIsStarting) {
            $upOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            Write-WebDavComposeLogs
            throw "WebDAV Container konnte nach $WebDavComposeMaxAttempts Versuchen nicht gestartet werden."
        }

        $status = if ($containerState -eq "nicht vorhanden") { "wird noch angelegt" } else { $containerState }
        Write-Warn "Docker erstellt den Container nach $WebDavComposeMaxAttempts Versuchen noch (Status: $status). Warte weiter auf WebDAV..."
    }

    Write-Host "Warte auf WebDAV (bis zu $WebDavStartupTimeoutMinutes Minuten)" -NoNewline
    $deadline = (Get-Date).AddMinutes($WebDavStartupTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-WebDavReady) {
            Write-Host " OK"
            Write-Ok "WebDAV laeuft auf http://localhost:8080"
            return
        }
        Start-Sleep -Seconds 2
        Write-Host "." -NoNewline
    }
    Write-Host ""

    $containerState = Get-WebDavContainerState
    $fmt = "  {{.Names}} | {{.Status}} | {{.Ports}}"
    docker ps --filter "name=zotero-webdav" --format $fmt 2>&1 |
        Where-Object { $_ } | ForEach-Object { Write-Info $_ }
    Write-WebDavComposeLogs
    throw "WebDAV war nach $WebDavStartupTimeoutMinutes Minuten nicht bereit (Container-Status: $containerState)."
}

# ----------- Auto-Sync -----------------------------------------------

function Start-AutoSync {
    Write-Step "[7/7] Auto-Sync und UI starten"

    $syncScript = Join-Path $ScriptDir "auto-sync.ps1"
    if (-not (Test-Path $syncScript)) {
        Write-Warn "auto-sync.ps1 nicht gefunden."
        return
    }

    $existing = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe' or name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -like "*auto-sync.ps1*" -and $_.CommandLine -like "*$ScriptDir*" }

    if ($existing) {
        Write-Ok "Auto-Sync laeuft bereits (PID $($existing.ProcessId))"
        return
    }

    Start-Process powershell -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$syncScript`"",
        "-WatchPath", "`"$(Get-StoragePath)`""
    ) -WindowStyle Hidden

    Write-Ok "Auto-Sync gestartet (Hintergrundprozess)"
}

# ----------- SQLite for the local project graph ---------------------

function Ensure-SqliteDriver {
    $toolsRoot = Join-Path $ScriptDir '.tools\sqlite'
    $driver = Join-Path $toolsRoot 'sqlite3.exe'
    if (-not (Test-Path -LiteralPath $driver)) {
        Write-Step "Projektgraph-Speicher vorbereiten"
        $architecture = if ([Environment]::Is64BitOperatingSystem -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq 'Arm64') { 'arm64' } else { 'x64' }
        $version = '3540100'
        $download = "https://www.sqlite.org/2026/sqlite-tools-win-$architecture-$version.zip"
        $archive = Join-Path ([IO.Path]::GetTempPath()) ("myliteraturevault-sqlite-$version.zip")
        try {
            New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
            Write-Info "SQLite-Treiber wird einmalig aus der offiziellen SQLite-Ausgabe geladen."
            Invoke-WebRequest -Uri $download -OutFile $archive -UseBasicParsing
            Expand-Archive -LiteralPath $archive -DestinationPath $toolsRoot -Force
        } finally {
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not (Test-Path -LiteralPath $driver)) { throw "SQLite-Treiber konnte nicht eingerichtet werden. Bitte Internetverbindung prüfen und quickstart.bat erneut starten." }
    # Den Exitcode direkt nach dem nativen Aufruf sichern: nachgelagerte
    # PowerShell-Pipeline-Kommandos können $LASTEXITCODE sonst überschreiben.
    $versionOutput = & $driver ':memory:' 'SELECT sqlite_version();' 2>&1
    $sqliteExitCode = $LASTEXITCODE
    $versionText = ($versionOutput | Select-Object -First 1).ToString().Trim()
    if ($sqliteExitCode -ne 0 -or -not $versionText) { throw "SQLite-Treiber ist nicht ausführbar: $driver" }
    [Environment]::SetEnvironmentVariable('MYLITERATUREVAULT_SQLITE3', $driver, 'Process')
    Write-Ok "SQLite-Projektgraph bereit (v$versionText)"
}

# ----------- Vault UI ------------------------------------------------

function Test-VaultUiReady {
    try {
        $response = Invoke-WebRequest -Uri 'http://localhost:8765/api/status' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Start-VaultUi {
    $uiScript = Join-Path $ScriptDir "vault-ui.ps1"
    if (-not (Test-Path $uiScript)) {
        Write-Warn "vault-ui.ps1 nicht gefunden."
        return
    }

    if (Test-VaultUiReady) {
        Write-Ok "UI laeuft bereits auf http://localhost:8765"
        Start-Process "http://localhost:8765"
        return
    }

    $logDirectory = Join-Path $ScriptDir '.logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $stdoutLog = Join-Path $logDirectory 'vault-ui.stdout.log'
    $stderrLog = Join-Path $logDirectory 'vault-ui.stderr.log'
    $process = Start-Process powershell -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$uiScript`"",
        "-OpenBrowser"
    ) -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (Test-VaultUiReady) {
            Write-Ok "UI gestartet: http://localhost:8765"
            return
        }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    $details = if (Test-Path -LiteralPath $stderrLog) { (Get-Content -LiteralPath $stderrLog -Tail 8 -ErrorAction SilentlyContinue) -join ' ' } else { '' }
    throw "Die UI konnte nicht auf http://localhost:8765 gestartet werden.$(if ($details) { " Details: $details" })"
}

# ----------- Main ----------------------------------------------------

Clear-Host
Write-Host "==========================================" -ForegroundColor Blue
Write-Host " MyLiteratureVault Quickstart             " -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Blue

try {
    Ensure-EnvFile
    Invoke-GitRemotePull
    Ensure-ZoteroInstalled
    Ensure-DockerInstalled
    Start-DockerDesktop
    Start-WebDav
    Start-AutoSync
    Ensure-SqliteDriver
    Start-VaultUi
    Start-Zotero
}
catch {
    Write-Host ""
    Write-Host "[FEHLER] $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Druecke Enter zum Schliessen..." -ForegroundColor DarkGray
    Read-Host | Out-Null
    exit 1
}

Write-Host ""
Write-Host "Fertig! Alle Dienste laufen." -ForegroundColor Green
Write-Host ""
Write-Host "  WebDAV:  http://localhost:8080   Benutzer: zotero   Passwort: siehe .env"
Write-Host "  Speicher: $(Get-StoragePath) (wird nicht in Git/Git LFS gespeichert)"
Write-Host "  UI:      http://localhost:8765"
Write-Host ""

if ($script:FirstRun) {
    Write-Host "ZOTERO EINRICHTEN (Erster Start):" -ForegroundColor Yellow
    Write-Host "  1. Zotero wurde gestartet - melde dich an oder registriere dich:"
    Write-Host "     https://www.zotero.org/user/login"
    Write-Host ""
    Write-Host "  2. In Zotero: Bearbeiten -> Einstellungen -> Sync -> Datei-Sync"
    Write-Host "     Methode:   WebDAV"
    Write-Host "     URL:       http://localhost:8080"
    Write-Host "     Benutzer:  zotero"
    Write-Host "     Passwort:  changeme123"
    Write-Host "     Dann: 'Server pruefen' klicken"
    Write-Host ""
    Write-Host "Druecke Enter, wenn Zotero eingerichtet ist..." -ForegroundColor DarkGray
    Read-Host | Out-Null
} else {
    Write-Host "In Zotero: Einstellungen -> Sync -> Datei-Sync -> WebDAV -> Server pruefen."
    Write-Host ""
    Write-Host "Dieses Fenster schliesst sich automatisch..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

exit 0
