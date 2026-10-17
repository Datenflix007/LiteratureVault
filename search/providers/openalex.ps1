function ConvertFrom-OpenAlexAbstract {
    param($InvertedIndex)
    if ($null -eq $InvertedIndex) { return "" }
    $words = @{}
    $entries = if ($InvertedIndex -is [System.Collections.IDictionary]) { $InvertedIndex.GetEnumerator() } else { $InvertedIndex.PSObject.Properties }
    foreach ($property in $entries) {
        $word = if ($property.Key) { "$($property.Key)" } else { "$($property.Name)" }
        foreach ($position in @($property.Value)) { $words[[int]$position] = $word }
    }
    return (($words.GetEnumerator() | Sort-Object Key | ForEach-Object Value) -join " ")
}

function Invoke-OpenAlexResearchProvider {
    param($Request)
    $query = Get-ResearchQueryText $Request
    if ([string]::IsNullOrWhiteSpace($query)) { return @() }
    $count = [math]::Min([int]$Request.limit, 100)
    $uri = "https://api.openalex.org/works?search=$([uri]::EscapeDataString($query))&per-page=$count"
    # OpenAlex abstracts may contain case-distinct dictionary keys (for example
    # “The” and “the”); PowerShell's ConvertFrom-Json rejects those keys.
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = [int]::MaxValue
    $payload = $serializer.DeserializeObject((Invoke-ResearchHttpGet $uri))
    $results = @()
    foreach ($item in @($payload.results)) {
        $authors = @($item.authorships | ForEach-Object { if ($_.author.display_name) { $_.author.display_name } elseif ($_.raw_author_name) { $_.raw_author_name } } | Where-Object { $_ })
        $keywords = @($item.keywords | ForEach-Object { $_.display_name }) + @($item.topics | ForEach-Object { $_.display_name })
        $location = if ($item.best_oa_location) { $item.best_oa_location } else { $item.primary_location }
        $fulltext = if ($location.pdf_url) { "$($location.pdf_url)" } elseif ($item.open_access.oa_url) { "$($item.open_access.oa_url)" } else { "" }
        $sourceUrl = if ($location.landing_page_url) { "$($location.landing_page_url)" } elseif ($item.doi) { "$($item.doi)" } else { "$($item.id)" }
        $oa = if ($item.open_access.is_oa) { "open" } elseif ($item.open_access.oa_status) { "$($item.open_access.oa_status)" } else { "unknown" }
        $results += New-NormalizedResearchResult -Provider "openalex" -ProviderRecordId "$($item.id)" -Title "$($item.title)" -Authors $authors -PublicationYear "$($item.publication_year)" -PublicationType "$($item.type)" -Abstract (ConvertFrom-OpenAlexAbstract $item.abstract_inverted_index) -Keywords $keywords -Language "$($item.language)" -Doi "$($item.doi)" -Isbn @() -Issn @() -SourceUrl $sourceUrl -FulltextUrl $fulltext -OpenAccessStatus $oa -Publisher "$($location.source.display_name)"
    }
    return @($results)
}
