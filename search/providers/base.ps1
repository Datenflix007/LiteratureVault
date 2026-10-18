function Get-BaseDcValues {
    param($Record, [string]$Name)
    return @($Record.SelectNodes(".//*[local-name()='$Name']") | ForEach-Object { "$($_.InnerText)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

function ConvertTo-BaseDynamicSet {
    param($Request)
    $query = (Get-ResearchQueryText $Request) -replace '[\[\]{}]', ' '
    $query = $query.Trim()
    if (-not $query) { return '' }
    return '(title:"' + ($query -replace '"', ' ') + '" OR subject:"' + ($query -replace '"', ' ') + '" OR description:"' + ($query -replace '"', ' ') + '")'
}

function Invoke-BaseResearchProvider {
    param($Request)
    $dynamicSet = ConvertTo-BaseDynamicSet $Request
    if (-not $dynamicSet) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $uri = "https://oai.base-search.net/oai?verb=ListRecords&metadataPrefix=base_dc&set=$([uri]::EscapeDataString($dynamicSet))"
    [xml]$xml = Invoke-ResearchHttpGet $uri
    $errorNode = $xml.SelectSingleNode("//*[local-name()='error']")
    if ($errorNode) { throw "BASE OAI-PMH: $($errorNode.InnerText.Trim())" }
    $total = 0
    $token = $xml.SelectSingleNode("//*[local-name()='resumptionToken']")
    if ($token) { [void][int]::TryParse("$($token.GetAttribute('completeListSize'))", [ref]$total) }
    $results = @()
    foreach ($record in @($xml.SelectNodes("//*[local-name()='record']") | Select-Object -First $Request.limit)) {
        $identifier = "@((Get-BaseDcValues $record 'identifier')[0])"
        $sourceUrl = "@((Get-BaseDcValues $record 'link')[0])"
        if (-not $sourceUrl) { $sourceUrl = "@((Get-BaseDcValues $record 'identifier' | Where-Object { $_ -match '^https?://' })[0])" }
        $doi = "@((Get-BaseDcValues $record 'doi')[0])"
        $year = "@((Get-BaseDcValues $record 'year')[0])"
        if (-not $year) { $year = "@((Get-BaseDcValues $record 'date')[0])" }
        if ($year -match '(1[5-9]|20)\d{2}') { $year = $matches[0] }
        $openAccess = if ((Get-BaseDcValues $record 'oa') -contains '1') { 'open' } else { 'unknown' }
        $results += New-NormalizedResearchResult -Provider 'base' -ProviderRecordId $identifier -Title "@((Get-BaseDcValues $record 'title')[0])" -Authors (Get-BaseDcValues $record 'creator') -PublicationYear $year -PublicationType "@((Get-BaseDcValues $record 'type')[0])" -Abstract "@((Get-BaseDcValues $record 'description')[0])" -Keywords (Get-BaseDcValues $record 'subject') -Language "@((Get-BaseDcValues $record 'lang')[0])" -Doi $doi -SourceUrl $sourceUrl -OpenAccessStatus $openAccess -Publisher "@((Get-BaseDcValues $record 'collname')[0])"
    }
    if (-not $total) { $total = $results.Count }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
