function ConvertTo-DnbCql {
    param($Request)
    $query = (Get-ResearchQueryText $Request) -replace '"', ''
    if ([string]::IsNullOrWhiteSpace($query)) { return "" }
    $tokens = $query -split '(?i)\s+(AND|OR|NOT)\s+'
    $operators = [regex]::Matches($query, '(?i)\s+(AND|OR|NOT)\s+') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() }
    $parts = @()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($index -gt 0) { $parts += $operators[$index - 1] }
        $term = "$($tokens[$index])".Trim()
        if ($term) { $parts += ('woe="' + ($term -replace '"', '') + '"') }
    }
    return ($parts -join ' ')
}

function Get-DnbMarcValues {
    param($Record, [string]$Tag, [string[]]$Codes)
    $values = @()
    foreach ($field in @($Record.SelectNodes("./*[local-name()='datafield'][@tag='$Tag']"))) {
        foreach ($subfield in @($field.SelectNodes("./*[local-name()='subfield']") | Where-Object { $Codes -contains "$($_.GetAttribute('code'))" })) {
            $value = "$($subfield.InnerText)".Trim()
            if ($value) { $values += $value }
        }
    }
    return @($values | Select-Object -Unique)
}

function Invoke-DnbResearchProvider {
    param($Request)
    $cql = ConvertTo-DnbCql $Request
    if (-not $cql) { return @() }
    $count = [math]::Min([int]$Request.limit, 100)
    $uri = "https://services.dnb.de/sru/dnb?version=1.1&operation=searchRetrieve&recordSchema=MARC21-xml&maximumRecords=$count&query=$([uri]::EscapeDataString($cql))"
    [xml]$xml = Invoke-ResearchHttpGet $uri
    $manager = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $manager.AddNamespace('srw', 'http://www.loc.gov/zing/srw/')
    $manager.AddNamespace('marc', 'http://www.loc.gov/MARC21/slim')
    $results = @()
    foreach ($record in @($xml.SelectNodes('//srw:recordData/marc:record', $manager))) {
        $id = @($record.SelectNodes('./marc:controlfield[@tag="001"]', $manager) | ForEach-Object { $_.'#text' })[0]
        $title = (Get-DnbMarcValues $record '245' @('a', 'b') -join ': ')
        $authors = @(Get-DnbMarcValues $record '100' @('a')) + @(Get-DnbMarcValues $record '700' @('a'))
        $year = @((Get-DnbMarcValues $record '264' @('c')) + (Get-DnbMarcValues $record '260' @('c')) | ForEach-Object { if ($_ -match '(1[5-9]|20)\d{2}') { $matches[0] } } | Select-Object -First 1)[0]
        $isbn = Get-DnbMarcValues $record '020' @('a')
        $issn = Get-DnbMarcValues $record '022' @('a')
        $keywords = @(Get-DnbMarcValues $record '650' @('a', 'x', 'y')) + @(Get-DnbMarcValues $record '653' @('a'))
        $publisher = @(Get-DnbMarcValues $record '264' @('b'))[0]
        $sourceUrl = $(if ($id) { "https://portal.dnb.de/opac.htm?method=showFullRecord&currentResultId=$id%26any&currentPosition=1" } else { "https://portal.dnb.de/" })
        $results += New-NormalizedResearchResult -Provider 'dnb' -ProviderRecordId "$id" -Title $title -Authors $authors -PublicationYear "$year" -PublicationType 'bibliografischer Nachweis' -Keywords $keywords -Isbn $isbn -Issn $issn -SourceUrl $sourceUrl -Publisher "$publisher"
    }
    return @($results)
}
