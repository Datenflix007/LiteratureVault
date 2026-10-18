function Get-EuropeanaValues {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value.Trim() | Where-Object { $_ }) }
    return @($Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Get-EuropeanaYear {
    param($Item)
    foreach ($value in @(Get-EuropeanaValues $Item.year) + @(Get-EuropeanaValues $Item.timestamp_created)) {
        if ($value -match '(1[5-9]|20)\d{2}') { return $matches[0] }
    }
    return ''
}

function Invoke-EuropeanaResearchProvider {
    param($Request)
    $query = Get-ResearchQueryText $Request
    if ([string]::IsNullOrWhiteSpace($query)) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $configuration = Get-ResearchProviderConfiguration
    $apiKey = "$($configuration['EUROPEANA_API_KEY'])".Trim()
    if (-not $apiKey) { throw 'Europeana-API-Schlüssel fehlt.' }
    $count = [math]::Min([int]$Request.limit, 100)
    $page = [math]::Floor([int]$Request.offset / $count) + 1
    $uri = "https://api.europeana.eu/record/v2/search.json?wskey=$([uri]::EscapeDataString($apiKey))&query=$([uri]::EscapeDataString($query))&rows=$count&start=$page&profile=rich"
    $response = Invoke-ResearchHttpGet $uri | ConvertFrom-Json
    $total = 0; [void][int]::TryParse("$($response.totalResults)", [ref]$total)
    $results = @()
    foreach ($item in @($response.items)) {
        $identifiers = @(Get-EuropeanaValues $item.dcIdentifier)
        $shownAt = @(Get-EuropeanaValues $item.edmIsShownAt | Select-Object -First 1)[0]
        $shownBy = @(Get-EuropeanaValues $item.edmIsShownBy | Select-Object -First 1)[0]
        $sourceUrl = if ($shownAt) { $shownAt } elseif ($item.guid) { "$($item.guid)" } elseif ($item.id) { "https://www.europeana.eu/item/$($item.id)" } else { 'https://www.europeana.eu/' }
        $rights = @(Get-EuropeanaValues $item.rights) -join ' '
        $openAccess = if ($rights -match '(?i)(publicdomain|creativecommons|cc0|rightsstatements.org/vocab/noC)') { 'open' } else { 'unknown' }
        $results += New-NormalizedResearchResult -Provider 'europeana' -ProviderRecordId "$($item.id)" -Title "@((Get-EuropeanaValues $item.title)[0])" -Authors (Get-EuropeanaValues $item.dcCreator) -PublicationYear (Get-EuropeanaYear $item) -PublicationType "@((Get-EuropeanaValues $item.type)[0])" -Abstract "@((Get-EuropeanaValues $item.dcDescription)[0])" -Keywords ((Get-EuropeanaValues $item.dcSubject) + (Get-EuropeanaValues $item.europeanaCollectionName)) -Language "@((Get-EuropeanaValues $item.language)[0])" -Doi "@($identifiers | Where-Object { $_ -match '(?i)(doi\.org/|^10\.)' } | Select-Object -First 1)" -SourceUrl $sourceUrl -FulltextUrl "$shownBy" -OpenAccessStatus $openAccess -Publisher "@((Get-EuropeanaValues $item.dataProvider)[0])"
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
