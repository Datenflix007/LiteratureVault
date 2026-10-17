#!/usr/bin/env powershell
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$PluginDir = Join-Path $ScriptDir "zotero-plugin"
$DistDir = Join-Path $ScriptDir "dist"
$ZipPath = Join-Path $DistDir "myliteraturevault-zotero.zip"
$XpiPath = Join-Path $DistDir "myliteraturevault-zotero.xpi"

if (-not (Test-Path $PluginDir)) {
    throw "zotero-plugin Ordner nicht gefunden."
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Remove-Item $ZipPath, $XpiPath -Force -ErrorAction SilentlyContinue

$stagingDir = Join-Path $DistDir "zotero-plugin-staging"
Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

@("manifest.json", "bootstrap.js", "vault.xhtml") | ForEach-Object {
    Copy-Item -LiteralPath (Join-Path $PluginDir $_) -Destination $stagingDir -Force
}
# vault.xhtml always opens the running local UI at http://localhost:8765.
# Packaging a second, unreachable UI copy or the repository README would only
# make the XPI larger and could let its contents become stale.

Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $ZipPath -Force
Move-Item $ZipPath $XpiPath -Force
Remove-Item $stagingDir -Recurse -Force

Write-Host "Zotero Plugin gebaut: $XpiPath" -ForegroundColor Green
Write-Host "In Zotero: Tools -> Add-ons -> Zahnrad -> Install Add-on From File..." -ForegroundColor Cyan
