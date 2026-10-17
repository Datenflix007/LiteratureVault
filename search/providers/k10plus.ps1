function Invoke-K10plusResearchProvider {
    param($Request)
    $cql = ConvertTo-ThulbCql $Request
    if (-not $cql) { return [PSCustomObject]@{ results = @(); total = 0 } }
    $count = [math]::Min([int]$Request.limit, 100)
    $startRecord = [int]$Request.offset + 1
    $uri = "https://sru.k10plus.de/gvk?version=1.1&operation=searchRetrieve&recordSchema=picaxml&maximumRecords=$count&startRecord=$startRecord&query=$([uri]::EscapeDataString($cql))"
    [xml]$xml = Invoke-ResearchHttpGet $uri
    $manager = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $manager.AddNamespace('srw', 'http://www.loc.gov/zing/srw/')
    $manager.AddNamespace('pica', 'info:srw/schema/5/picaXML-v1.0')
    $total = 0
    $totalNode = $xml.SelectSingleNode('//srw:numberOfRecords', $manager)
    if ($totalNode) { [void][int]::TryParse("$($totalNode.InnerText)", [ref]$total) }
    $results = @()
    foreach ($record in @($xml.SelectNodes('//srw:recordData/pica:record', $manager))) {
        $id = @(Get-ThulbPicaValues $record $manager '003@' @('0'))[0]
        $title = (Get-ThulbPicaValues $record $manager '021A' @('a', 'd') -join ': ')
        $authors = Get-ThulbPicaPeople $record $manager
        $yearCandidates = @(Get-ThulbPicaValues $record $manager '011@' @('a')) + @(Get-ThulbPicaValues $record $manager '031A' @('j')) + @(Get-ThulbPicaValues $record $manager '033A' @('j'))
        $year = @($yearCandidates | ForEach-Object { if ($_ -match '(1[5-9]|20)\d{2}') { $matches[0] } } | Select-Object -First 1)[0]
        $isbn = Get-ThulbPicaValues $record $manager '004A' @('0', 'a')
        $issn = Get-ThulbPicaValues $record $manager '004C' @('0', 'a')
        $doi = @(Get-ThulbPicaValues $record $manager '004V' @('0', 'a'))[0]
        $keywords = @(Get-ThulbPicaValues $record $manager '044K' @('a', 'j', 'A')) + @(Get-ThulbPicaValues $record $manager '045F' @('a', 'j'))
        $publisher = @(Get-ThulbPicaValues $record $manager '033A' @('n'))[0]
        $availability = @(Get-ThulbPicaValues $record $manager '201@' @('a'))[0]
        $sourceUrl = if ($id) { "https://kxp.k10plus.de/DB=2.1/PPNSET?PPN=$([uri]::EscapeDataString($id))" } else { 'https://kxp.k10plus.de/' }
        $results += New-NormalizedResearchResult -Provider 'k10plus' -ProviderRecordId "$id" -Title $title -Authors $authors -PublicationYear "$year" -PublicationType 'K10plus-Katalognachweis' -Keywords $keywords -Doi "$doi" -Isbn $isbn -Issn $issn -SourceUrl $sourceUrl -Publisher "$publisher" -Availability "$availability"
    }
    return [PSCustomObject]@{ results = @($results); total = $total }
}
