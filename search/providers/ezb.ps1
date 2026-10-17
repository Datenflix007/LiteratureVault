function Invoke-EzbResearchProvider {
    param($Request)

    $query = (Get-ResearchQueryText $Request).Trim()
    if (-not $query) { return [PSCustomObject]@{ results = @(); total = 0 } }

    $queryType = if ("$($Request.issn)".Trim()) { 'IS' } else { 'KT' }
    $queryTerm = if ($queryType -eq 'IS') { "$($Request.issn)".Trim() } else { $query }
    $count = [math]::Min([math]::Max([int]$Request.limit, 10), 50)
    $offset = [math]::Max([int]$Request.offset, 0)
    $uri = "https://ezb.ur.de/searchres.phtml?bibid=UBR&colors=1&lang=de&xmloutput=1&xmlv=3&hits_per_page=$count&offset=$offset&jq_type1=$queryType&jq_term1=$([uri]::EscapeDataString($queryTerm))"

    [xml]$xml = Invoke-ResearchHttpGet $uri
    $total = 0
    $totalNode = $xml.SelectSingleNode("//*[local-name()='search_count']")
    if ($totalNode) { [void][int]::TryParse("$($totalNode.InnerText)", [ref]$total) }

    $results = @()
    foreach ($journal in @($xml.SelectNodes("//*[local-name()='journals']/*[local-name()='journal']") | Select-Object -First $Request.limit)) {
        $id = "$($journal.GetAttribute('jourid'))".Trim()
        $title = "$($journal.SelectSingleNode("./*[local-name()='title']").InnerText)".Trim()
        if (-not $title) { continue }
        $sourceUrl = if ($id) { "https://ezb.ur.de/detail.phtml?bibid=UBR&jour_id=$([uri]::EscapeDataString($id))" } else { 'https://ezb.ur.de/' }
        $results += New-NormalizedResearchResult -Provider 'ezb' -ProviderRecordId $id -Title $title -PublicationType 'Elektronische Zeitschrift' -SourceUrl $sourceUrl -OpenAccessStatus 'open' -Availability 'Frei zugängliche E-Zeitschrift (EZB-Ampel grün).'
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
