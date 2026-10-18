$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Ensure-StorageRoot { return $env:TEMP }
. (Join-Path $repoRoot 'search\search-service.ps1')

foreach ($command in @('Invoke-JstorResearchProvider', 'Invoke-BaseResearchProvider', 'Invoke-DdbResearchProvider', 'Invoke-EuropeanaResearchProvider')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Adapter $command wurde nicht geladen." }
}

function Get-ResearchProviderConfiguration {
    return @{ DDB_API_KEY = 'ddb-test'; EUROPEANA_API_KEY = 'europeana-test'; JSTOR_SRU_URL = 'https://gateway.example.test/sru'; BASE_OAI_ENABLED = 'true' }
}

$configuredIds = @((Get-ResearchProviderCatalog | Where-Object { $_.enabled } | ForEach-Object id))
foreach ($id in @('jstor', 'base', 'ddb', 'europeana')) {
    if ($configuredIds -notcontains $id) { throw "Konfigurierter Provider $id wurde nicht aktiviert." }
}

$request = [PSCustomObject]@{ query = 'Stadtgeschichte'; title = ''; author = ''; keywords = ''; doi = ''; isbn = ''; issn = ''; subject = ''; fromYear = 0; toYear = 0; language = ''; publicationType = ''; openAccess = ''; providers = @(); limit = 25; offset = 0; sort = 'relevance' }

function Invoke-ResearchHttpGet {
    param([string]$Uri)
    if ($Uri -match 'europeana') {
        return '{"totalResults":1,"items":[{"id":"/2021/example","title":["Europeana Titel"],"dcCreator":["Ada Beispiel"],"dcDescription":["Kurzbeschreibung"],"dcSubject":["Geschichte"],"year":["1920"],"type":["TEXT"],"language":["de"],"edmIsShownAt":["https://example.test/europeana"]}]}'
    }
    if ($Uri -match 'deutsche-digitale-bibliothek') {
        return '{"numberOfResults":1,"results":[{"id":"ABCDEFGHIJKLMNOPQRSTUVWX23456789","title":"DDB Titel","creator":"Max Muster","description":"Beschreibung","subject":"Archiv","year":"1919","type":"Text","language":"de"}]}'
    }
    if ($Uri -match 'gateway.example.test') {
        return '<searchRetrieveResponse xmlns="http://www.loc.gov/zing/srw/"><numberOfRecords>1</numberOfRecords><records><record><recordData><dc xmlns="http://purl.org/dc/elements/1.1/"><title>JSTOR Titel</title><creator>J. Beispiel</creator><date>1918</date><identifier>https://www.jstor.org/stable/example</identifier></dc></recordData></record></records></searchRetrieveResponse>'
    }
    if ($Uri -match 'oai.base-search.net') {
        return '<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><ListRecords><record><header><identifier>oai:base.example:1</identifier></header><metadata><dc xmlns="http://purl.org/dc/elements/1.1/"><title>BASE Titel</title><creator>B. Beispiel</creator><date>1917</date><identifier>https://example.test/base</identifier><subject>Open Access</subject></dc><oa xmlns="http://oai.base-search.net/base_dc/">1</oa></metadata></record><resumptionToken completeListSize="1">next</resumptionToken></ListRecords></OAI-PMH>'
    }
    throw "Unbekannte Test-URL: $Uri"
}

foreach ($case in @(
    @{ command = 'Invoke-DdbResearchProvider'; expected = 'DDB Titel' },
    @{ command = 'Invoke-EuropeanaResearchProvider'; expected = 'Europeana Titel' },
    @{ command = 'Invoke-JstorResearchProvider'; expected = 'JSTOR Titel' },
    @{ command = 'Invoke-BaseResearchProvider'; expected = 'BASE Titel' }
)) {
    $response = & $case.command $request
    if (@($response.results).Count -ne 1) { throw "$($case.command) lieferte keinen normalisierten Treffer." }
    if ($response.results[0].title -ne $case.expected) { throw "$($case.command) normalisierte den Titel nicht korrekt: $($response.results[0].title)" }
}

Write-Host '[OK] DDB, Europeana, JSTOR und BASE normalisieren ihre Adapterantworten.'
