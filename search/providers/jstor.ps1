function Get-JstorDcValues {
    param($Record, [string]$Name)
    return @($Record.SelectNodes(".//*[local-name()='$Name']") | ForEach-Object { "$($_.InnerText)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

function Invoke-JstorResearchProvider {
    param($Request)
    $query = Get-ResearchQueryText $Request
    if ([string]::IsNullOrWhiteSpace($query)) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $configuration = Get-ResearchProviderConfiguration
    $endpoint = "$($configuration['JSTOR_SRU_URL'])".Trim()
    if ($endpoint -notmatch '^https://') { throw 'JSTOR-SRU-Adresse fehlt oder ist ungültig.' }
    $separator = if ($endpoint.Contains('?')) { '&' } else { '?' }
    $cql = 'cql.serverChoice any "' + ($query -replace '"', ' ') + '"'
    $count = [math]::Min([int]$Request.limit, 100)
    $uri = "$endpoint$separator" + "version=1.2&operation=searchRetrieve&recordSchema=dc&maximumRecords=$count&startRecord=$([int]$Request.offset + 1)&query=$([uri]::EscapeDataString($cql))"
    [xml]$xml = Invoke-ResearchHttpGet $uri
    $total = 0
    $totalNode = $xml.SelectSingleNode("//*[local-name()='numberOfRecords']")
    if ($totalNode) { [void][int]::TryParse("$($totalNode.InnerText)", [ref]$total) }
    $results = @()
    foreach ($record in @($xml.SelectNodes("//*[local-name()='recordData']"))) {
        $identifier = "@((Get-JstorDcValues $record 'identifier')[0])"
        $sourceUrl = @((Get-JstorDcValues $record 'identifier') | Where-Object { $_ -match '^https?://' } | Select-Object -First 1)[0]
        if (-not $sourceUrl) { $sourceUrl = 'https://www.jstor.org/' }
        $year = "@((Get-JstorDcValues $record 'date')[0])"
        if ($year -match '(1[5-9]|20)\d{2}') { $year = $matches[0] }
        $results += New-NormalizedResearchResult -Provider 'jstor' -ProviderRecordId $identifier -Title "@((Get-JstorDcValues $record 'title')[0])" -Authors (Get-JstorDcValues $record 'creator') -PublicationYear $year -PublicationType "@((Get-JstorDcValues $record 'type')[0])" -Abstract "@((Get-JstorDcValues $record 'description')[0])" -Keywords (Get-JstorDcValues $record 'subject') -Language "@((Get-JstorDcValues $record 'language')[0])" -SourceUrl $sourceUrl -Publisher "@((Get-JstorDcValues $record 'publisher')[0])"
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
