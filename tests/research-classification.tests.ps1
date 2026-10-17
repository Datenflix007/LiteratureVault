$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ("$Actual" -ne "$Expected") { throw "$Message (erwartet: $Expected, erhalten: $Actual)" }
}

# The search service only needs this helper when its cache is used. Defining it
# keeps this test isolated from the user's external research-data directory.
function Ensure-StorageRoot { return $env:TEMP }
. (Join-Path $repoRoot 'search\search-service.ps1')

$project = [PSCustomObject]@{
    id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; name = 'Testprojekt'; researchQuestion = 'Stadtgeschichte und Erinnerung'; hypothesis = ''; paperGoal = ''; subject = 'Geschichte'; tags = @('Stadtgeschichte')
    researchConcept = [PSCustomObject]@{ topic = ''; question = ''; terms = ''; method = ''; }; outline = ''
    researchSettings = [PSCustomObject]@{ weights = [PSCustomObject]@{ title = 30; abstract = 40; keywords = 20; subject = 10 }; importantTerms = @('Erinnerung'); classification = [PSCustomObject]@{ cutoffYear = 1945 } }
    researchClassifications = @()
}
$request = [PSCustomObject]@{ query = 'Stadtgeschichte Erinnerung'; title = ''; author = ''; keywords = ''; doi = ''; isbn = ''; issn = ''; subject = ''; fromYear = 0; toYear = 0; language = ''; publicationType = ''; openAccess = ''; providers = @('openalex'); limit = 50; offset = 0; sort = 'relevance' }

# A modern edition can remain a source because the explicit source year, not its
# reprint date, is authoritative.
$edition = New-NormalizedResearchResult -Provider 'test' -ProviderRecordId 'edition' -Title 'Quellenedition: Briefe aus der Stadt' -PublicationYear '2008' -PublicationType 'book' -SourceYear '1939'
Add-ResearchClassification $edition $project | Out-Null
Assert-Equal $edition.classification.category 'source' 'Historische Edition muss als Quelle erkennbar bleiben'
Assert-Equal $edition.classification.confidence 'high' 'Explizites Entstehungsjahr plus Quellensignal muss hoch gewichtet werden'

$literature = New-NormalizedResearchResult -Provider 'test' -ProviderRecordId 'study' -Title 'Eine Studie zur Stadtgeschichte' -PublicationYear '2018' -PublicationType 'journal-article' -Abstract 'Analyse der Erinnerungskultur.'
Add-ResearchClassification $literature $project | Out-Null
Assert-Equal $literature.classification.category 'literature' 'Moderne Studie muss als Forschungsliteratur eingeordnet werden'

$unknown = New-NormalizedResearchResult -Provider 'test' -ProviderRecordId 'unknown' -Title 'Ohne nähere Angaben'
Add-ResearchClassification $unknown $project | Out-Null
Assert-Equal $unknown.classification.category 'unclear' 'Fehlende Metadaten dürfen keine erfundene Klassifikation erzeugen'
Assert-Equal $unknown.classification.confidence 'low' 'Fehlende Metadaten müssen als unsicher markiert sein'

$project.researchClassifications = @([PSCustomObject]@{ resultId = $literature.resultId; category = 'source'; origin = 'manual'; updatedAt = (Get-Date).ToString('o') })
Add-ResearchClassification $literature $project | Out-Null
Assert-Equal $literature.classification.category 'source' 'Manuelle Entscheidung muss Vorrang haben'
Assert-Equal $literature.classification.origin 'manual' 'Manuelle Entscheidung muss transparent gekennzeichnet sein'

$relevance = New-NormalizedResearchResult -Provider 'test' -ProviderRecordId 'relevance' -Title 'Stadtgeschichte' -PublicationYear '2020' -PublicationType 'journal-article' -Abstract 'Erinnerung im Stadtraum' -Keywords @('Erinnerung')
Add-ResearchRelevance $relevance $project $request | Out-Null
if ($relevance.relevance.score -lt 1 -or @($relevance.relevance.fields).Count -ne 4) { throw 'Relevanz muss Feldbegründungen für Titel, Abstract, Schlagwörter und Projektkontext liefern.' }
if (@($relevance.relevance.fields | Where-Object { $_.field -eq 'subject' }).Count -ne 1) { throw 'Projektkontext muss als separates, erklärbares Feld erscheinen.' }

Write-Host '[OK] Klassifikation: Grenzjahr, historische Edition, fehlende Metadaten, manuelle Überschreibung und Relevanzbegründung.' -ForegroundColor Green
