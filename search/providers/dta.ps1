function ConvertFrom-DtaAuthor {
    param([string]$Value)
    return ("$Value" -replace '\s*\(#[^)]+\)\s*$', '').Trim()
}

function Get-DtaSnippet {
    param($Hit)
    $tokens = @($Hit.ctx_[1] | ForEach-Object { "$(if ($_.u) { $_.u } else { $_.w })".Trim() } | Where-Object { $_ })
    if (-not $tokens.Count) { return '' }
    $snippet = ($tokens -join ' ') -replace '\s+([,.;:!?])', '$1'
    return $snippet.Substring(0, [math]::Min($snippet.Length, 500))
}

function Invoke-DtaResearchProvider {
    param($Request)

    $query = (Get-ResearchQueryText $Request).Trim()
    if (-not $query) { return [PSCustomObject]@{ results = @(); total = 0 } }

    # The DTA OpenSearch endpoint returns passage hits. Retrieve a small
    # overfetch and collapse these into bibliographic works for the vault.
    $count = [math]::Min([math]::Max([int]$Request.limit * 4, 10), 100)
    $start = [math]::Max([int]$Request.offset + 1, 1)
    $uri = "https://kaskade.dwds.de/dstar/dta/dstar.perl?q=$([uri]::EscapeDataString($query))&fmt=json&start=$start&limit=$count"
    $response = (Invoke-ResearchHttpGet $uri | ConvertFrom-Json)
    $total = 0
    [void][int]::TryParse("$($response.nhits_)", [ref]$total)

    $results = @()
    $seen = @{}
    foreach ($hit in @($response.hits_)) {
        $metadata = $hit.meta_
        $recordId = "$($metadata.dtaid)".Trim()
        if (-not $recordId) { $recordId = "$($metadata.basename)".Trim() }
        if (-not $recordId -or $seen.ContainsKey($recordId)) { continue }
        $seen[$recordId] = $true
        $title = "$($metadata.title)".Trim()
        if (-not $title) { continue }
        $year = @("$($metadata.firstDate)", "$($metadata.date_)") | Where-Object { $_ -match '^(1[5-9]|20)\d{2}$' } | Select-Object -First 1
        $basename = "$($metadata.basename)".Trim()
        $sourceUrl = if ($basename) { "https://www.deutschestextarchiv.de/$([uri]::EscapeDataString($basename))" } else { 'https://www.deutschestextarchiv.de/' }
        $classification = "$($metadata.textClass)".Trim()
        $type = if ($classification) { "Historischer Volltext ($classification)" } else { 'Historischer Volltext' }
        $results += New-NormalizedResearchResult -Provider 'dta' -ProviderRecordId $recordId -Title $title -Authors @(ConvertFrom-DtaAuthor "$($metadata.author)") -PublicationYear "$year" -PublicationType $type -Abstract (Get-DtaSnippet $hit) -Keywords @($metadata.textClass, $metadata.textClassDTA | Where-Object { "$_".Trim() }) -SourceUrl $sourceUrl -FulltextUrl $sourceUrl -OpenAccessStatus 'open' -Availability "$($metadata.availability)" -SourceYear "$year"
        if ($results.Count -ge $Request.limit) { break }
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
