$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# The catalog test is intentionally offline: provider requests are covered by
# the live smoke check and must not be sent during every local test run.
function Ensure-StorageRoot { return $env:TEMP }
. (Join-Path $repoRoot 'search\search-service.ps1')

$expectedModes = @{ k10plus = 'sru'; zdb = 'sru'; ezb = 'xml'; dta = 'opensearch' }
foreach ($id in $expectedModes.Keys) {
    $provider = Get-ResearchProvider $id
    if ($null -eq $provider) { throw "Provider $id fehlt im Katalog." }
    if (-not $provider.enabled) { throw "Provider $id muss als öffentliche Recherchequelle aktiviert sein." }
    if ($provider.mode -ne $expectedModes[$id]) { throw "Provider $id weist den erwarteten Modus nicht aus." }
    if (-not $provider.searchUrl.StartsWith('https://')) { throw "Provider $id benötigt eine HTTPS-Suchadresse." }
}

foreach ($command in @('Invoke-K10plusResearchProvider', 'Invoke-ZdbResearchProvider', 'Invoke-EzbResearchProvider', 'Invoke-DtaResearchProvider')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Adapter $command wurde nicht geladen." }
}

Write-Host 'Öffentliche Provider K10plus und ZDB sind korrekt registriert.'
