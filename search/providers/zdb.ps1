function Invoke-ZdbResearchProvider {
    param($Request)
    $cql = ConvertTo-DnbCql $Request
    if (-not $cql) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $count = [math]::Min([int]$Request.limit, 100)
    $startRecord = [int]$Request.offset + 1
    $uri = "https://services.dnb.de/sru/zdb?version=1.1&operation=searchRetrieve&recordSchema=MARC21-xml&maximumRecords=$count&startRecord=$startRecord&query=$([uri]::EscapeDataString($cql))"
    [xml]$xml = Invoke-ResearchHttpGet $uri
    $manager = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $manager.AddNamespace('srw', 'http://www.loc.gov/zing/srw/')
    $manager.AddNamespace('marc', 'http://www.loc.gov/MARC21/slim')
    $total = 0
    $totalNode = $xml.SelectSingleNode('//srw:numberOfRecords', $manager)
    if ($totalNode) { [void][int]::TryParse("$($totalNode.InnerText)", [ref]$total) }
    $results = @()
    foreach ($record in @($xml.SelectNodes('//srw:recordData/marc:record', $manager))) {
        $id = @($record.SelectNodes('./marc:controlfield[@tag="001"]', $manager) | ForEach-Object { $_.'#text' })[0]
        $title = (Get-DnbMarcValues $record '245' @('a', 'b') -join ': ')
        $authors = @(Get-DnbMarcValues $record '110' @('a')) + @(Get-DnbMarcValues $record '100' @('a')) + @(Get-DnbMarcValues $record '700' @('a'))
        $year = @((Get-DnbMarcValues $record '264' @('c')) + (Get-DnbMarcValues $record '260' @('c')) | ForEach-Object { if ($_ -match '(1[5-9]|20)\d{2}') { $matches[0] } } | Select-Object -First 1)[0]
        $issn = Get-DnbMarcValues $record '022' @('a')
        $keywords = @(Get-DnbMarcValues $record '650' @('a', 'x', 'y')) + @(Get-DnbMarcValues $record '653' @('a'))
        $publisher = @(Get-DnbMarcValues $record '264' @('b'))[0]
        $sourceUrl = if ($id) { "https://zdb-katalog.de/title.xhtml?idn=$([uri]::EscapeDataString($id))" } else { 'https://zdb-katalog.de/' }
        $results += New-NormalizedResearchResult -Provider 'zdb' -ProviderRecordId "$id" -Title $title -Authors $authors -PublicationYear "$year" -PublicationType 'Zeitschriften-/Reihennachweis' -Keywords $keywords -Issn $issn -SourceUrl $sourceUrl -Publisher "$publisher"
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
