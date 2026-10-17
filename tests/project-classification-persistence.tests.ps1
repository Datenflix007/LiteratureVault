$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$vaultPath = Join-Path $repoRoot 'vault-ui.ps1'
$source = Get-Content -LiteralPath $vaultPath -Raw -Encoding UTF8
$marker = '$script:listener = New-Object Net.HttpListener'
$cut = $source.IndexOf($marker)
if ($cut -lt 0) { throw 'Der testbare Teil von vault-ui.ps1 wurde nicht gefunden.' }

# Load the production functions without opening an HTTP listener. The store is
# replaced below, so no user project data or external storage is touched.
$source = $source.Substring(0, $cut)
$escapedRoot = $repoRoot.Replace("'", "''")
$source = $source -replace '\$ScriptDir = Split-Path -Parent -Path \$MyInvocation\.MyCommand\.Definition', ('$ScriptDir = ''' + $escapedRoot + '''')
Invoke-Expression $source

$resultId = '1111111111111111111111111111111111111111'
$projectId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:testStore = [PSCustomObject]@{
    version = 2
    projects = @([PSCustomObject]@{
        id = $projectId; name = 'Test'; createdAt = (Get-Date).ToString('o')
        # Older references did not yet persist resultId. A completed queue entry
        # supplies the Zotero key so their collection can still be moved.
        references = @([PSCustomObject]@{ id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; zoteroKey = 'ABCDEFGH'; kind = 'literature'; resultId = ''; title = 'Bereits importiert' })
        zoteroImportQueue = @(
            [PSCustomObject]@{ id = 'cccccccccccccccccccccccccccccccc'; kind = 'literature'; status = 'pending'; result = [PSCustomObject]@{ resultId = $resultId } },
            [PSCustomObject]@{ id = 'dddddddddddddddddddddddddddddddd'; kind = 'literature'; status = 'completed'; zoteroKey = 'ABCDEFGH'; result = [PSCustomObject]@{ resultId = $resultId } }
        )
    })
}
function Get-ProjectStore { return $script:testStore }
function Save-ProjectStore { param($Store) $script:testStore = $Store }

$response = Set-ProjectResearchClassification $projectId $resultId ([PSCustomObject]@{ category = 'source' })
$project = $script:testStore.projects[0]
if ($project.references[0].kind -ne 'source') { throw 'Die bestehende Projektreferenz wurde nicht zur Quelle verschoben.' }
if ($project.references[0].resultId -ne $resultId) { throw 'Die ältere Projektreferenz wurde nicht mit der Recherche-ID nachgerüstet.' }
if ($project.zoteroImportQueue[0].kind -ne 'source') { throw 'Der ausstehende Zotero-Import wurde nicht zur Quelle umgeleitet.' }
if ($project.researchClassifications[0].category -ne 'source') { throw 'Die manuelle Entscheidung wurde nicht projektbezogen gespeichert.' }
if ($response.zotero.status -ne 'pending') { throw 'Nach der Verschiebung wurde kein Zotero-Abgleich angefordert.' }

Write-Host '[OK] Manuelle Korrektur: Persistenz, bestehende Referenz, Importwarteschlange und Zotero-Abgleich.' -ForegroundColor Green
