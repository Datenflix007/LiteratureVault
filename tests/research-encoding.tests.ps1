$ErrorActionPreference = 'Stop'
$searchPath = Join-Path $PSScriptRoot '..\search\search-service.ps1'

function Get-BodyValue {
    param($Body, [string]$Name, $Default = '')
    if ($null -eq $Body -or $null -eq $Body.PSObject.Properties[$Name]) { return $Default }
    return $Body.PSObject.Properties[$Name].Value
}

. $searchPath

$mojibake = '"FlachdÃ¤cher fÃ¼r FlachkÃ¶pfe"?'
$repaired = Repair-ResearchTextEncoding $mojibake
if ($repaired -ne '"Flachdächer für Flachköpfe"?') { throw "Mojibake wurde nicht repariert: $repaired" }

$alreadyCorrect = 'VrÅ¡anský'
if ((Repair-ResearchTextEncoding $alreadyCorrect) -ne $alreadyCorrect) { throw 'Korrekte Unicode-Zeichen wurden unzulässig verändert.' }

$result = [PSCustomObject]@{ title = $mojibake; authors = @('MÃ¼ller'); keywords = @(); abstract = ''; publicationType = ''; language = ''; doi = ''; isbn = @(); issn = @(); sourceUrl = ''; fulltextUrl = ''; publisher = ''; availability = ''; sourceYear = ''; sourceDate = '' }
if (-not (Repair-NormalizedResearchResultEncoding $result)) { throw 'Der gespeicherte Treffer wurde nicht als reparaturbedürftig erkannt.' }
if ($result.title -ne '"Flachdächer für Flachköpfe"?' -or $result.authors[0] -ne 'Müller') { throw 'Trefferfelder wurden nicht korrekt repariert.' }

Write-Output '[OK] UTF-8-Providerantworten und vorhandene Merkliste-Titel werden korrekt behandelt.'
