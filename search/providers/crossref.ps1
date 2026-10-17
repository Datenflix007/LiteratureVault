function Get-CrossrefYear {
    param($Item)
    foreach ($field in @('published-print', 'published-online', 'published', 'issued', 'created')) {
        $value = $Item.PSObject.Properties[$field].Value
        if ($value -and $value.'date-parts' -and @($value.'date-parts')[0][0]) { return "$(@($value.'date-parts')[0][0])" }
    }
    return ""
}

function Invoke-CrossrefResearchProvider {
    param($Request)
    $query = Get-ResearchQueryText $Request
    if ([string]::IsNullOrWhiteSpace($query)) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $count = [math]::Min([int]$Request.limit, 100)
    $offset = [int]$Request.offset
    $uri = $(if ($Request.doi) { "https://api.crossref.org/works/$([uri]::EscapeDataString($Request.doi))" } else { "https://api.crossref.org/works?query.bibliographic=$([uri]::EscapeDataString($query))&rows=$count&offset=$offset" })
    $message = (Invoke-ResearchHttpGet $uri | ConvertFrom-Json).message
    $items = if ($Request.doi) { @($message) } else { @($message.items) }
    $total = if ($Request.doi) { 1 } else { 0 }
    if (-not $Request.doi) { [void][int]::TryParse("$($message.'total-results')", [ref]$total) }
    $results = @()
    foreach ($item in $items) {
        $authors = @($item.author | ForEach-Object { @($_.given, $_.family) -join " " } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $links = @($item.link)
        $fulltext = @($links | Where-Object { "$($_.'content-type')" -like "*pdf*" } | Select-Object -First 1 | ForEach-Object { $_.URL })[0]
        $sourceUrl = $(if ($item.URL) { "$($item.URL)" } elseif ($item.DOI) { "https://doi.org/$($item.DOI)" } else { "" })
        $openAccess = if ($fulltext) { 'open' } else { 'unknown' }
        $results += New-NormalizedResearchResult -Provider "crossref" -ProviderRecordId "$($item.DOI)" -Title "$(@($item.title)[0])" -Authors $authors -PublicationYear (Get-CrossrefYear $item) -PublicationType "$($item.type)" -Abstract "$($item.abstract)" -Keywords @($item.subject) -Language "$($item.language)" -Doi "$($item.DOI)" -Isbn @($item.ISBN) -Issn @($item.ISSN) -SourceUrl $sourceUrl -FulltextUrl "$fulltext" -OpenAccessStatus $openAccess -Publisher "$($item.publisher)"
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
