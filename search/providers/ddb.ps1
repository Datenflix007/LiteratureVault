function Get-DdbValues {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string] -or $Value -is [ValueType]) { return @("$Value".Trim() | Where-Object { $_ }) }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value | ForEach-Object { Get-DdbValues $_ } | Where-Object { $_ }) }
    foreach ($property in @('value', 'label', 'name', 'title')) {
        if ($Value.PSObject.Properties[$property]) { return Get-DdbValues $Value.$property }
    }
    return @()
}

function Get-DdbFieldValues {
    param($Item, [string[]]$Names)
    foreach ($name in $Names) {
        if ($Item.PSObject.Properties[$name]) {
            $values = @(Get-DdbValues $Item.$name)
            if ($values.Count) { return $values }
        }
    }
    return @()
}

function Invoke-DdbResearchProvider {
    param($Request)
    $query = Get-ResearchQueryText $Request
    if ([string]::IsNullOrWhiteSpace($query)) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $configuration = Get-ResearchProviderConfiguration
    $apiKey = "$($configuration['DDB_API_KEY'])".Trim()
    if (-not $apiKey) { throw 'DDB-API-Schlüssel fehlt.' }
    $count = [math]::Min([int]$Request.limit, 100)
    $uri = "https://api.deutsche-digitale-bibliothek.de/search?query=$([uri]::EscapeDataString($query))&rows=$count&offset=$([int]$Request.offset)&oauth_consumer_key=$([uri]::EscapeDataString($apiKey))"
    $response = Invoke-ResearchHttpGet $uri | ConvertFrom-Json
    $total = 0
    foreach ($totalField in @('numberOfResults', 'total', 'totalResults')) {
        if ($response.PSObject.Properties[$totalField]) { [void][int]::TryParse("$($response.$totalField)", [ref]$total); if ($total) { break } }
    }
    $items = @()
    foreach ($field in @('results', 'documents', 'items')) {
        if ($response.PSObject.Properties[$field]) { $items = @($response.$field); break }
    }
    $results = @()
    foreach ($item in $items) {
        $id = "@((Get-DdbFieldValues $item @('id', 'identifier'))[0])"
        $title = "@((Get-DdbFieldValues $item @('title', 'label', 'name'))[0])"
        $year = "@((Get-DdbFieldValues $item @('year', 'date', 'time'))[0])"
        if ($year -match '(1[5-9]|20)\d{2}') { $year = $matches[0] }
        $sourceUrl = if ($id) { "https://www.deutsche-digitale-bibliothek.de/item/$id" } else { 'https://www.deutsche-digitale-bibliothek.de/' }
        $results += New-NormalizedResearchResult -Provider 'ddb' -ProviderRecordId $id -Title $title -Authors (Get-DdbFieldValues $item @('creator', 'author', 'person')) -PublicationYear $year -PublicationType "@((Get-DdbFieldValues $item @('type', 'objecttype', 'documentType'))[0])" -Abstract "@((Get-DdbFieldValues $item @('description', 'abstract', 'snippet'))[0])" -Keywords (Get-DdbFieldValues $item @('subject', 'keywords', 'topic')) -Language "@((Get-DdbFieldValues $item @('language'))[0])" -SourceUrl $sourceUrl -Publisher "@((Get-DdbFieldValues $item @('provider', 'institution', 'dataProvider'))[0])"
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
