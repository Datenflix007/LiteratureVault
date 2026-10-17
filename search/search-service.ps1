# Scientific research search service. Provider adapters are intentionally kept
# separate so that an unavailable or licensed portal cannot affect the others.

$script:ResearchProviderDefinitions = @(
    [PSCustomObject]@{ id = "openalex"; name = "OpenAlex"; mode = "api"; enabled = $true; documentationUrl = "https://docs.openalex.org/"; searchUrl = "https://api.openalex.org/works"; message = "Freie Metadaten-API; ohne API-Schlüssel gilt ein gemeinsames Tagesbudget."; capabilities = @("keywords", "title", "author", "doi", "year", "language", "type", "openAccess") },
    [PSCustomObject]@{ id = "crossref"; name = "Crossref"; mode = "api"; enabled = $true; documentationUrl = "https://www.crossref.org/documentation/retrieve-metadata/rest-api/"; searchUrl = "https://api.crossref.org/works"; message = "Freie bibliografische Metadaten-API; Volltexte und Abstracts hängen von den Depositen ab."; capabilities = @("keywords", "title", "author", "doi", "isbn", "issn", "year", "type") },
    [PSCustomObject]@{ id = "dnb"; name = "Deutsche Nationalbibliothek"; mode = "sru"; enabled = $true; documentationUrl = "https://www.dnb.de/sru"; searchUrl = "https://services.dnb.de/sru/dnb"; message = "Offizielle DNB-SRU-Schnittstelle für bibliografische Daten."; capabilities = @("keywords", "title", "author", "isbn", "issn", "year") },
    [PSCustomObject]@{ id = "thulb"; name = "ThULB Jena"; mode = "sru"; enabled = $true; documentationUrl = "https://isil.staatsbibliothek-berlin.de/isil/DE-27"; searchUrl = "https://sru.k10plus.de/opac-de-27"; message = "Öffentliche SRU-Suche im ThULB-Katalog (Sigel DE-27); Nachweise und lokale Bestandsinformationen."; capabilities = @("keywords", "title", "author", "isbn", "issn", "year") },
    [PSCustomObject]@{ id = "jstor"; name = "JSTOR"; mode = "institutional"; enabled = $false; documentationUrl = "https://support.jstor.org/hc/en-us/articles/115005075327-JSTOR-XML-Gateway"; searchUrl = "https://www.jstor.org/action/doBasicSearch"; message = "JSTOR XML Gateway verlangt eine institutionelle Metasearch-Lizenz; keine direkte API ohne Zugang."; capabilities = @() },
    [PSCustomObject]@{ id = "base"; name = "BASE"; mode = "external"; enabled = $false; documentationUrl = "https://www.base-search.net/"; searchUrl = "https://www.base-search.net/Search/Results"; message = "Adapter erst aktivieren, wenn ein zulässiger API-Zugang konfiguriert ist."; capabilities = @() },
    [PSCustomObject]@{ id = "ddb"; name = "Deutsche Digitale Bibliothek"; mode = "api-key-required"; enabled = $false; documentationUrl = "https://pro.deutsche-digitale-bibliothek.de/daten-nutzen/api"; searchUrl = "https://www.deutsche-digitale-bibliothek.de/searchresults"; message = "API-Schlüssel erforderlich; bis zur Konfiguration nur externer Zugang."; capabilities = @() },
    [PSCustomObject]@{ id = "europeana"; name = "Europeana"; mode = "api-key-required"; enabled = $false; documentationUrl = "https://pro.europeana.eu/page/apis"; searchUrl = "https://www.europeana.eu/en/search"; message = "API-Schlüssel erforderlich; bis zur Konfiguration nur externer Zugang."; capabilities = @() },
    [PSCustomObject]@{ id = "k10plus"; name = "K10plus / GVK"; mode = "setup-required"; enabled = $false; documentationUrl = "https://www.gbv.de/"; searchUrl = "https://kxp.k10plus.de/"; message = "Kein Adapter ohne dokumentierte SRU-/Z39.50-Konfiguration."; capabilities = @() },
    [PSCustomObject]@{ id = "zdb"; name = "Zeitschriftendatenbank"; mode = "setup-required"; enabled = $false; documentationUrl = "https://www.dnb.de/sru"; searchUrl = "https://zdb-katalog.de/"; message = "Separate ZDB-SRU-Konfiguration erforderlich; keine Artikelmetasuche."; capabilities = @() },
    [PSCustomObject]@{ id = "ezb"; name = "Elektronische Zeitschriftenbibliothek"; mode = "external"; enabled = $false; documentationUrl = "https://ezb.ur.de/"; searchUrl = "https://ezb.ur.de/"; message = "Zeitschriften- und Lizenznachweise, keine frei aktivierte Artikelsuche."; capabilities = @() },
    [PSCustomObject]@{ id = "dta"; name = "Deutsches Textarchiv"; mode = "external"; enabled = $false; documentationUrl = "https://www.deutschestextarchiv.de/"; searchUrl = "https://www.deutschestextarchiv.de/search"; message = "Historische Volltexte; Adapter wird nach Schnittstellenprüfung ergänzt."; capabilities = @() }
)

function Get-ResearchProviderCatalog {
    return @($script:ResearchProviderDefinitions | ForEach-Object {
        [PSCustomObject]@{
            id = $_.id; name = $_.name; mode = $_.mode; enabled = $_.enabled
            documentationUrl = $_.documentationUrl; searchUrl = $_.searchUrl
            message = $_.message; capabilities = @($_.capabilities)
        }
    })
}

function Get-ResearchProvider {
    param([string]$Id)
    return @($script:ResearchProviderDefinitions | Where-Object { $_.id -eq "$Id".Trim().ToLowerInvariant() } | Select-Object -First 1)[0]
}

function Invoke-ResearchHttpGet {
    param([string]$Uri)
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd("MyLiteratureVault/0.5 (local research metadata client)")
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) von $Uri" }
        # Several SRU catalogues send XML without a charset header. HttpClient
        # then assumes ISO-8859-1 although the document is UTF-8, producing
        # strings such as "FlachdÃ¤cher". Metadata APIs in this application
        # use UTF-8; honour an explicit charset but default to UTF-8 otherwise.
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $charset = "$($response.Content.Headers.ContentType.CharSet)".Trim().Trim('"')
        $encoding = [Text.Encoding]::UTF8
        if ($charset) {
            try { $encoding = [Text.Encoding]::GetEncoding($charset) } catch { $encoding = [Text.Encoding]::UTF8 }
        }
        return $encoding.GetString($bytes)
    } finally {
        $client.Dispose(); $handler.Dispose()
    }
}

function Repair-ResearchTextEncoding {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    # Only touch recognisable UTF-8-as-Windows-1252 artefacts. This keeps
    # legitimate names with characters such as Å unchanged.
    $marker = '(?:\xC3[\x80-\xBF]|\xC2[\x80-\xBF]|\xE2[\x80-\xBF]{1,2}|\xC5[\x80-\xBF])'
    if ($Value -notmatch $marker) { return $Value }
    try {
        $candidate = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(1252).GetBytes($Value))
        if ($candidate -and $candidate -notmatch $marker -and $candidate -notmatch [string][char]0xfffd) { return $candidate }
    } catch { }
    return $Value
}

function Repair-NormalizedResearchResultEncoding {
    param($Result)
    if ($null -eq $Result) { return $false }
    $changed = $false
    foreach ($field in @('title', 'subtitle', 'publicationType', 'abstract', 'language', 'doi', 'sourceUrl', 'fulltextUrl', 'publisher', 'availability', 'sourceYear', 'sourceDate')) {
        $property = $Result.PSObject.Properties[$field]
        if ($null -eq $property) { continue }
        $repaired = Repair-ResearchTextEncoding "$($property.Value)"
        if ($repaired -cne "$($property.Value)") { $property.Value = $repaired; $changed = $true }
    }
    foreach ($field in @('authors', 'keywords', 'isbn', 'issn')) {
        $property = $Result.PSObject.Properties[$field]
        if ($null -eq $property) { continue }
        $values = @($property.Value)
        $repaired = @($values | ForEach-Object { Repair-ResearchTextEncoding "$_" })
        $separator = [string][char]0x1f
        if (($values -join $separator) -cne ($repaired -join $separator)) { $property.Value = $repaired; $changed = $true }
    }
    return $changed
}

function Get-ResearchCachePath {
    return Join-Path (Join-Path (Ensure-StorageRoot) "Projekte") ".myliteraturevault-research-cache.json"
}

function Get-ResearchCache {
    $path = Get-ResearchCachePath
    if (-not (Test-Path -LiteralPath $path)) { return [PSCustomObject]@{ version = 1; entries = @() } }
    try {
        $cache = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $cache.entries) { $cache | Add-Member -NotePropertyName entries -NotePropertyValue @() }
        $changed = $false
        foreach ($entry in @($cache.entries)) {
            foreach ($result in @($entry.response.results)) {
                if (Repair-NormalizedResearchResultEncoding $result) { $changed = $true }
            }
        }
        if ($changed) { Save-ResearchCache $cache }
        return $cache
    } catch {
        return [PSCustomObject]@{ version = 1; entries = @() }
    }
}

function Save-ResearchCache {
    param($Cache)
    $Cache.version = 1
    $Cache.entries = @($Cache.entries | Sort-Object createdAt -Descending | Select-Object -First 40)
    $Cache | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Get-ResearchCachePath) -Encoding UTF8
}

function Get-ResearchCacheKey {
    param($Request, [string]$ProjectId = "")
    $material = @(
        "$ProjectId".Trim().ToLowerInvariant(), "$($Request.query)".Trim().ToLowerInvariant(),
        "$($Request.title)".Trim().ToLowerInvariant(), "$($Request.author)".Trim().ToLowerInvariant(),
        "$($Request.doi)".Trim().ToLowerInvariant(), "$($Request.isbn)".Trim().ToLowerInvariant(),
        "$($Request.issn)".Trim().ToLowerInvariant(), "$($Request.fromYear)", "$($Request.toYear)",
        "$($Request.language)".Trim().ToLowerInvariant(), "$($Request.publicationType)".Trim().ToLowerInvariant(),
        "$($Request.openAccess)", "$($Request.limit)", "$($Request.offset)", (@($Request.providers | Sort-Object) -join ",")
    ) -join "|"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))) -replace "-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-ResearchStringArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value -split "[,;]" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return @($Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

function New-ResearchRequest {
    param($Body)
    $providerIds = ConvertTo-ResearchStringArray (Get-BodyValue $Body "providers" @())
    $activeIds = @($script:ResearchProviderDefinitions | Where-Object { $_.enabled } | ForEach-Object { $_.id })
    $providerIds = @($providerIds | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $activeIds -contains $_ } | Select-Object -Unique)
    if (-not $providerIds.Count) { $providerIds = $activeIds }
    $limit = 50; [void][int]::TryParse("$(Get-BodyValue $Body 'limit' 50)", [ref]$limit)
    $offset = 0; [void][int]::TryParse("$(Get-BodyValue $Body 'offset' 0)", [ref]$offset)
    $fromYear = 0; [void][int]::TryParse("$(Get-BodyValue $Body 'fromYear')", [ref]$fromYear)
    $toYear = 0; [void][int]::TryParse("$(Get-BodyValue $Body 'toYear')", [ref]$toYear)
    if ($fromYear -lt 1000 -or $fromYear -gt 2999) { $fromYear = 0 }
    if ($toYear -lt 1000 -or $toYear -gt 2999) { $toYear = 0 }
    if ($offset -lt 0) { $offset = 0 }
    if ($fromYear -and $toYear -and $fromYear -gt $toYear) { $swap = $fromYear; $fromYear = $toYear; $toYear = $swap }
    return [PSCustomObject]@{
        query = "$(Get-BodyValue $Body 'query')".Trim(); title = "$(Get-BodyValue $Body 'title')".Trim(); author = "$(Get-BodyValue $Body 'author')".Trim()
        keywords = "$(Get-BodyValue $Body 'keywords')".Trim(); doi = ("$(Get-BodyValue $Body 'doi')".Trim() -replace '^https?://(dx\.)?doi\.org/', '')
        isbn = "$(Get-BodyValue $Body 'isbn')".Trim(); issn = "$(Get-BodyValue $Body 'issn')".Trim(); fromYear = $fromYear; toYear = $toYear
        language = "$(Get-BodyValue $Body 'language')".Trim().ToLowerInvariant(); publicationType = "$(Get-BodyValue $Body 'publicationType')".Trim().ToLowerInvariant()
        subject = "$(Get-BodyValue $Body 'subject')".Trim(); openAccess = "$(Get-BodyValue $Body 'openAccess' '')".Trim().ToLowerInvariant()
        providers = @($providerIds); limit = [math]::Max(1, [math]::Min(100, $limit)); offset = $offset; sort = "$(Get-BodyValue $Body 'sort' 'relevance')".Trim().ToLowerInvariant()
    }
}

function Get-ResearchQueryText {
    param($Request)
    $parts = @($Request.query, $Request.title, $Request.author, $Request.keywords, $Request.doi, $Request.isbn, $Request.issn, $Request.subject) |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    return ($parts -join " ").Trim()
}

function Get-ResearchQueryRepresentation {
    param($Request)
    $query = Get-ResearchQueryText $Request
    $phrases = [regex]::Matches($query, '"([^"\\]+)"') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ }
    $operators = [regex]::Matches($query, '(?i)\b(AND|OR|NOT)\b') | ForEach-Object { $_.Value.ToUpperInvariant() }
    return [PSCustomObject]@{ raw = $query; phrases = @($phrases); operators = @($operators); hasBooleanOperators = @($operators).Count -gt 0 }
}

function ConvertTo-ResearchTokens {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $normal = $Text.Normalize([Text.NormalizationForm]::FormD) -replace "\p{Mn}", ""
    $stopWords = @("und", "oder", "nicht", "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "einem", "mit", "von", "fur", "für", "auf", "im", "in", "zu", "an", "als", "bei", "the", "and", "or", "not", "for", "with", "from", "into", "about", "this", "that", "are", "was")
    return @($normal.ToLowerInvariant() -split "[^\p{L}\p{Nd}]+" | Where-Object { $_.Length -ge 3 -and $stopWords -notcontains $_ } | Select-Object -Unique)
}

function ConvertFrom-ResearchHtml {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return [Net.WebUtility]::HtmlDecode(($Text -replace "<[^>]+>", " " -replace "\s+", " ").Trim())
}

function New-NormalizedResearchResult {
    param(
        [string]$Provider, [string]$ProviderRecordId, [string]$Title, [string[]]$Authors = @(), [string]$PublicationYear = "",
        [string]$PublicationType = "", [string]$Abstract = "", [string[]]$Keywords = @(), [string]$Language = "",
        [string]$Doi = "", [string[]]$Isbn = @(), [string[]]$Issn = @(), [string]$SourceUrl = "", [string]$FulltextUrl = "",
        [string]$OpenAccessStatus = "unknown", [string]$Publisher = "", [string]$Availability = "nicht ermittelt",
        [string]$SourceYear = "", [string]$SourceDate = ""
    )
    $Title = Repair-ResearchTextEncoding $Title
    $Authors = @($Authors | ForEach-Object { Repair-ResearchTextEncoding "$_" })
    $PublicationType = Repair-ResearchTextEncoding $PublicationType
    $Abstract = Repair-ResearchTextEncoding $Abstract
    $Keywords = @($Keywords | ForEach-Object { Repair-ResearchTextEncoding "$_" })
    $Language = Repair-ResearchTextEncoding $Language
    $Doi = Repair-ResearchTextEncoding $Doi
    $Isbn = @($Isbn | ForEach-Object { Repair-ResearchTextEncoding "$_" })
    $Issn = @($Issn | ForEach-Object { Repair-ResearchTextEncoding "$_" })
    $SourceUrl = Repair-ResearchTextEncoding $SourceUrl
    $FulltextUrl = Repair-ResearchTextEncoding $FulltextUrl
    $Publisher = Repair-ResearchTextEncoding $Publisher
    $Availability = Repair-ResearchTextEncoding $Availability
    $SourceYear = Repair-ResearchTextEncoding $SourceYear
    $SourceDate = Repair-ResearchTextEncoding $SourceDate
    $doiValue = "$Doi".Trim() -replace "^https?://(dx\.)?doi\.org/", ""
    $fingerprint = if ($doiValue) { "doi:$($doiValue.ToLowerInvariant())" } elseif ($Isbn.Count) { "isbn:$((@($Isbn)[0] -replace '[^0-9Xx]', '').ToUpperInvariant())" } else { "title:$((ConvertTo-ResearchTokens $Title) -join '-')|author:$((ConvertTo-ResearchTokens (@($Authors)[0])) -join '-')|year:$PublicationYear" }
    $hash = [Security.Cryptography.SHA1]::Create()
    try { $resultId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint))) -replace "-", "").ToLowerInvariant() }
    finally { $hash.Dispose() }
    return [PSCustomObject]@{
        resultId = $resultId; provider = $Provider; providers = @($Provider); providerRecordId = "$ProviderRecordId"; providerRecordIds = @([PSCustomObject]@{ provider = $Provider; id = "$ProviderRecordId" })
        title = if ("$Title".Trim()) { "$Title".Trim() } else { "Ohne Titel" }; subtitle = ""; authors = @($Authors | Where-Object { "$_".Trim() } | Select-Object -Unique)
        publicationYear = "$PublicationYear"; publicationType = "$PublicationType"; abstract = ConvertFrom-ResearchHtml $Abstract; keywords = @($Keywords | Where-Object { "$_".Trim() } | Select-Object -Unique)
        language = "$Language".Trim().ToLowerInvariant(); doi = $doiValue; isbn = @($Isbn | Where-Object { "$_".Trim() } | Select-Object -Unique); issn = @($Issn | Where-Object { "$_".Trim() } | Select-Object -Unique)
        sourceUrl = "$SourceUrl".Trim(); fulltextUrl = "$FulltextUrl".Trim(); openAccessStatus = "$OpenAccessStatus".Trim(); publisher = "$Publisher".Trim(); availability = "$Availability".Trim()
        # publicationYear is the bibliographic publication date. sourceYear/sourceDate
        # may only be populated when a provider explicitly reports an historical
        # document's creation date; they are never inferred from a title.
        sourceYear = "$SourceYear"; sourceDate = "$SourceDate"; retrievedAt = (Get-Date).ToString("o"); relevance = $null; classification = $null
    }
}

function Merge-NormalizedResearchResults {
    param($Results)
    $merged = @{}
    foreach ($result in @($Results)) {
        if ($null -eq $result) { continue }
        $key = "$($result.resultId)".Trim()
        if (-not $merged.ContainsKey($key)) { $merged[$key] = $result; continue }
        $existing = $merged[$key]
        $existing.providers = @($existing.providers + $result.providers | Select-Object -Unique)
        $existing.providerRecordIds = @($existing.providerRecordIds + $result.providerRecordIds)
        foreach ($field in @("abstract", "language", "doi", "sourceUrl", "fulltextUrl", "publisher")) {
            if (-not "$($existing.$field)".Trim() -and "$($result.$field)".Trim()) { $existing.$field = $result.$field }
        }
        foreach ($field in @("authors", "keywords", "isbn", "issn")) { $existing.$field = @($existing.$field + $result.$field | Where-Object { "$_".Trim() } | Select-Object -Unique) }
        if ($existing.openAccessStatus -ne "open" -and $result.openAccessStatus -eq "open") { $existing.openAccessStatus = "open"; $existing.fulltextUrl = $result.fulltextUrl }
    }
    return @($merged.Values)
}

function Get-ResearchProfile {
    param($Project, $Request)
    $projectText = @($Project.name, $Project.researchQuestion, $Project.hypothesis, $Project.paperGoal, $Project.subject, ($Project.tags -join " "), $Project.researchConcept.topic, $Project.researchConcept.question, $Project.researchConcept.terms, $Project.researchConcept.method, $Project.outline) -join " "
    $important = ConvertTo-ResearchStringArray $Project.researchSettings.importantTerms
    $tokens = @(ConvertTo-ResearchTokens ("$projectText " + (Get-ResearchQueryText $Request)))
    return [PSCustomObject]@{ text = $projectText; tokens = @($tokens); importantTerms = @($important); hasContext = $tokens.Count -gt 0 }
}

function Get-ResearchWeights {
    param($Project)
    $defaults = [ordered]@{ title = 30; abstract = 40; keywords = 20; subject = 10 }
    $source = $Project.researchSettings.weights
    foreach ($key in @($defaults.Keys)) {
        $value = 0
        [void][double]::TryParse("$($source.$key)", [ref]$value)
        if ($value -ge 0) { $defaults[$key] = $value }
    }
    return $defaults
}

function Get-ResearchTokenOverlap {
    param([string[]]$ProfileTokens, [string[]]$ImportantTerms, [string]$Text)
    $documentTokens = ConvertTo-ResearchTokens $Text
    if (-not $ProfileTokens.Count -or -not $documentTokens.Count) { return [PSCustomObject]@{ score = 0; matches = @() } }
    $documentSet = @{}; foreach ($token in $documentTokens) { $documentSet[$token] = $true }
    $matches = @($ProfileTokens | Where-Object { $documentSet.ContainsKey($_) } | Select-Object -Unique)
    $importantTokens = @(ConvertTo-ResearchTokens ($ImportantTerms -join " "))
    $denominator = 0.0; $numerator = 0.0
    foreach ($token in $ProfileTokens) {
        $weight = if ($importantTokens -contains $token) { 2.0 } else { 1.0 }
        $denominator += $weight
        if ($documentSet.ContainsKey($token)) { $numerator += $weight }
    }
    return [PSCustomObject]@{ score = if ($denominator) { [math]::Round(100 * $numerator / $denominator, 1) } else { 0 }; matches = $matches }
}

function Add-ResearchRelevance {
    param($Result, $Project, $Request)
    if ($null -eq $Project) { return $Result }
    $profile = Get-ResearchProfile $Project $Request
    $weights = Get-ResearchWeights $Project
    $fields = [ordered]@{
        title = "$($Result.title) $($Result.subtitle)"
        abstract = "$($Result.abstract)"
        keywords = (@($Result.keywords) -join " ")
        # Only result metadata belongs on this side of the comparison. Project
        # terms live in the profile; adding them here would create false matches.
        subject = "$($Result.publicationType) $($Result.publisher)"
    }
    $availableWeight = 0.0; $weightedScore = 0.0; $matched = @(); $basis = @(); $missing = @(); $fieldMatches = @()
    foreach ($field in $fields.Keys) {
        if (-not "$($fields[$field])".Trim()) { $missing += $field; continue }
        $overlap = Get-ResearchTokenOverlap $profile.tokens $profile.importantTerms $fields[$field]
        $availableWeight += [double]$weights[$field]
        $weightedScore += [double]$weights[$field] * $overlap.score
        $matched += @($overlap.matches)
        $basis += $field
        $fieldMatches += [PSCustomObject]@{ field = $field; label = @{ title = 'Titel'; abstract = 'Abstract'; keywords = 'Schlagwörter'; subject = 'Projektkontext' }[$field]; weight = [double]$weights[$field]; overlap = $overlap.score; matches = @($overlap.matches) }
    }
    $score = if ($availableWeight -gt 0 -and $profile.hasContext) { [math]::Round($weightedScore / $availableWeight) } else { 0 }
    $label = if ($score -ge 75) { "Sehr hohe thematische Übereinstimmung" } elseif ($score -ge 55) { "Hohe Übereinstimmung" } elseif ($score -ge 30) { "Mittlere Übereinstimmung" } else { "Geringe Übereinstimmung" }
    $Result.relevance = [PSCustomObject]@{
        score = $score; label = $label; matchedTerms = @($matched | Select-Object -Unique); dataBasis = @($basis); missingFields = @($missing); fields = @($fieldMatches); weights = [PSCustomObject]@{ title = $weights.title; abstract = $weights.abstract; keywords = $weights.keywords; subject = $weights.subject }; availableWeight = [math]::Round($availableWeight, 2)
        explanation = if ($profile.hasContext) { "Deterministischer Relevanzscore aus direkten Begriffstreffern; keine Wahrscheinlichkeit und keine semantische Schlussfolgerung." } else { "Für einen Relevanzscore fehlen Forschungsfrage, Schlagwörter oder Suchbegriffe." }
    }
    return $Result
}

function Get-ProjectClassificationSettings {
    param($Project)
    $cutoffYear = 1945
    if ($null -ne $Project -and $null -ne $Project.researchSettings -and $null -ne $Project.researchSettings.classification) {
        $candidate = 0
        [void][int]::TryParse("$($Project.researchSettings.classification.cutoffYear)", [ref]$candidate)
        if ($candidate -ge 1000 -and $candidate -le 2999) { $cutoffYear = $candidate }
    }
    return [PSCustomObject]@{ cutoffYear = $cutoffYear }
}

function Get-ResearchClassificationOverride {
    param($Project, [string]$ResultId)
    if ($null -eq $Project -or -not $ResultId) { return $null }
    return @($Project.researchClassifications | Where-Object { "$($_.resultId)" -eq $ResultId -and "$($_.category)" -in @('source', 'literature') } | Sort-Object updatedAt -Descending | Select-Object -First 1)[0]
}

function Get-ResearchYear {
    param($Value)
    $year = 0
    if ("$Value" -match '(?<!\d)(1[0-9]{3}|2[0-9]{3})(?!\d)') { [void][int]::TryParse($matches[1], [ref]$year) }
    return $year
}

function Add-ResearchClassification {
    param($Result, $Project)
    if ($null -eq $Project) { return $Result }
    $override = Get-ResearchClassificationOverride $Project "$($Result.resultId)"
    if ($override) {
        $Result.classification = [PSCustomObject]@{
            category = "$($override.category)"; origin = 'manual'; confidence = 'manual'; cutoffYear = (Get-ProjectClassificationSettings $Project).cutoffYear
            reason = 'Manuell für dieses Projekt zugeordnet.'; signals = @('Manuelle Entscheidung hat Vorrang.'); sourceYear = "$($Result.sourceYear)"; publicationYear = "$($Result.publicationYear)"
        }
        return $Result
    }

    $settings = Get-ProjectClassificationSettings $Project
    $publicationYear = Get-ResearchYear $Result.publicationYear
    $sourceYear = Get-ResearchYear $(if ("$($Result.sourceYear)".Trim()) { $Result.sourceYear } else { $Result.sourceDate })
    $text = (@($Result.title, $Result.publicationType, $Result.keywords, $Result.abstract) -join ' ').ToLowerInvariant()
    $sourcePattern = '(?i)\b(archiv|archival|handschrift|manuskript|brief|briefe|korrespondenz|tagebuch|diary|akte[n]?|protokoll|chronik|zeitung|rede|gesetz|verordnung|quelle[n]?|primary source|quellenedition|edition|ediert|dokumente?)\b'
    $literaturePattern = '(?i)\b(studie|study|analyse|analysis|forschung|research|monograph|monografie|journal|article|aufsatz|dissertation|thesis|review|literaturbericht)\b'
    $sourceSignal = $text -match $sourcePattern
    $literatureSignal = $text -match $literaturePattern
    $signals = @()
    $category = 'unclear'; $confidence = 'low'; $reason = 'Die vorhandenen Metadaten reichen für eine belastbare Einordnung nicht aus.'

    if ($sourceYear -and $sourceYear -le $settings.cutoffYear) {
        $category = 'source'; $confidence = if ($sourceSignal) { 'high' } else { 'medium' }
        $signals += "Explizites Entstehungsjahr $sourceYear liegt am oder vor dem Grenzjahr $($settings.cutoffYear)."
        if ($publicationYear -and $publicationYear -gt $settings.cutoffYear) { $signals += "Das Publikationsjahr $publicationYear ist davon getrennt (z. B. Edition oder Neuveröffentlichung)." }
        $reason = 'Als historische Primärquelle eingeordnet, weil ein separates Entstehungsjahr vorliegt.'
    } elseif ($sourceSignal -and $publicationYear -and $publicationYear -le $settings.cutoffYear) {
        $category = 'source'; $confidence = 'medium'
        $signals += "Dokumenttyp/Titel weist auf eine Quelle hin; Publikationsjahr $publicationYear liegt am oder vor $($settings.cutoffYear)."
        $reason = 'Als wahrscheinliche Primärquelle eingeordnet; das Entstehungsjahr ist nicht separat belegt.'
    } elseif ($sourceSignal -and $sourceYear -eq 0) {
        $category = 'unclear'; $confidence = 'low'
        $signals += 'Titel, Typ oder Schlagwörter deuten auf eine Quelle, aber ein separates Entstehungsjahr fehlt.'
        $reason = 'Mögliche historische Quelle, aber ohne belegtes Entstehungsjahr nicht automatisch zugeordnet.'
    } elseif ($literatureSignal -or ($publicationYear -and $publicationYear -gt $settings.cutoffYear)) {
        $category = 'literature'; $confidence = if ($literatureSignal -and $publicationYear) { 'high' } else { 'medium' }
        if ($literatureSignal) { $signals += 'Dokumenttyp, Titel, Abstract oder Schlagwörter weisen auf Forschungsliteratur hin.' }
        if ($publicationYear -and $publicationYear -gt $settings.cutoffYear) { $signals += "Publikationsjahr $publicationYear liegt nach dem Grenzjahr $($settings.cutoffYear) (nur Heuristik)." }
        $reason = 'Als Sekundärliteratur eingeordnet; ein separates historisches Entstehungsjahr ist nicht vorhanden.'
    } elseif ($publicationYear -and $publicationYear -le $settings.cutoffYear) {
        $signals += "Publikationsjahr $publicationYear liegt am oder vor dem Grenzjahr, ist ohne Dokumenttyp aber nur eine Heuristik."
    } else {
        $signals += 'Publikationsjahr, Dokumenttyp oder historisches Entstehungsjahr fehlen oder sind nicht aussagekräftig.'
    }

    $Result.classification = [PSCustomObject]@{
        category = $category; origin = 'automatic'; confidence = $confidence; cutoffYear = $settings.cutoffYear; reason = $reason
        signals = @($signals); sourceYear = if ($sourceYear) { "$sourceYear" } else { '' }; publicationYear = "$($Result.publicationYear)"
    }
    return $Result
}

function Test-ResearchResultFilter {
    param($Result, $Request)
    $year = 0; [void][int]::TryParse("$($Result.publicationYear)", [ref]$year)
    if ($Request.fromYear -and ($year -eq 0 -or $year -lt $Request.fromYear)) { return $false }
    if ($Request.toYear -and ($year -eq 0 -or $year -gt $Request.toYear)) { return $false }
    if ($Request.language -and "$($Result.language)".ToLowerInvariant() -ne $Request.language) { return $false }
    if ($Request.publicationType -and "$($Result.publicationType)".ToLowerInvariant() -notlike "*$($Request.publicationType)*") { return $false }
    if ($Request.openAccess -eq "open" -and $Result.openAccessStatus -ne "open") { return $false }
    if ($Request.openAccess -eq "closed" -and $Result.openAccessStatus -eq "open") { return $false }
    return $true
}

function Get-ResearchSuggestions {
    param($Project)
    if ($null -eq $Project) { return @() }
    $terms = @($Project.tags) + @($Project.researchConcept.terms -split "[,;`n]") + @($Project.researchQuestion, $Project.hypothesis, $Project.subject)
    $terms = @($terms | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $suggestions = @()
    foreach ($term in $terms | Select-Object -First 8) { $suggestions += [PSCustomObject]@{ label = $term; query = $term; origin = "Projektprofil" } }
    if ($Project.tags.Count -ge 2) {
        $suggestions += [PSCustomObject]@{ label = "$($Project.tags[0]) AND $($Project.tags[1])"; query = "$($Project.tags[0]) AND $($Project.tags[1])"; origin = "Schlagwörter" }
    }
    return @($suggestions | Select-Object -Unique label)
}

function Invoke-ResearchSearch {
    param($Request, $Project = $null, [switch]$SkipCache)
    $cacheKey = Get-ResearchCacheKey $Request $(if ($Project) { $Project.id } else { "" })
    $cache = Get-ResearchCache
    $cached = @($cache.entries | Where-Object { $_.key -eq $cacheKey -and $_.expiresAt -gt (Get-Date).ToString("o") } | Select-Object -First 1)
    if ($cached -and -not $SkipCache) {
        $cachedResults = @($cached[0].response.results | ForEach-Object { Add-ResearchClassification (Add-ResearchRelevance $_ $Project $Request) $Project })
        return [PSCustomObject]@{ query = Get-ResearchQueryRepresentation $Request; results = $cachedResults; providers = @($cached[0].response.providers); errors = @($cached[0].response.errors); totalAvailable = $cached[0].response.totalAvailable; hasMore = $cached[0].response.hasMore; offset = $Request.offset; cached = $true; retrievedAt = $cached[0].response.retrievedAt; suggestions = if ($Project) { Get-ResearchSuggestions $Project } else { @() } }
    }
    $allResults = @(); $providerStates = @(); $errors = @()
    foreach ($providerId in @($Request.providers)) {
        $provider = Get-ResearchProvider $providerId
        if ($null -eq $provider -or -not $provider.enabled) { continue }
        try {
            $providerResponse = switch ($providerId) {
                "openalex" { Invoke-OpenAlexResearchProvider $Request }
                "crossref" { Invoke-CrossrefResearchProvider $Request }
                "dnb" { Invoke-DnbResearchProvider $Request }
                "thulb" { Invoke-ThulbResearchProvider $Request }
                default { [PSCustomObject]@{ results = @(); total = 0 } }
            }
            $providerResults = @($providerResponse.results)
            $allResults += @($providerResults)
            $providerStates += [PSCustomObject]@{ id = $providerId; name = $provider.name; status = "ok"; count = @($providerResults).Count; total = [int]$providerResponse.total; message = "Antwort erhalten."; lastSuccessAt = (Get-Date).ToString("o") }
        } catch {
            $message = "$($_.Exception.Message)"
            $errors += [PSCustomObject]@{ provider = $providerId; message = $message }
            $providerStates += [PSCustomObject]@{ id = $providerId; name = $provider.name; status = "error"; count = 0; total = 0; message = $message; lastSuccessAt = "" }
        }
    }
    $results = @(Merge-NormalizedResearchResults $allResults | Where-Object { Test-ResearchResultFilter $_ $Request } | ForEach-Object { Add-ResearchClassification (Add-ResearchRelevance $_ $Project $Request) $Project })
    $results = switch ($Request.sort) {
        "year-asc" { @($results | Sort-Object @{ Expression = { [int]($_.publicationYear -as [int]) }; Descending = $false }, title) }
        "year-desc" { @($results | Sort-Object @{ Expression = { [int]($_.publicationYear -as [int]) }; Descending = $true }, title) }
        "title" { @($results | Sort-Object title) }
        "author" { @($results | Sort-Object { ($_.authors -join "; ") }, title) }
        "provider" { @($results | Sort-Object provider, title) }
        default { @($results | Sort-Object @{ Expression = { if ($_.relevance) { $_.relevance.score } else { 0 } }; Descending = $true }, title) }
    }
    $totalAvailable = @($providerStates | Where-Object { $_.status -eq 'ok' } | Measure-Object -Property total -Sum).Sum
    $hasMore = @($providerStates | Where-Object { $_.status -eq 'ok' -and $_.total -gt ($Request.offset + $_.count) }).Count -gt 0
    $response = [PSCustomObject]@{ query = Get-ResearchQueryRepresentation $Request; results = @($results | Select-Object -First $Request.limit); providers = @($providerStates); errors = @($errors); totalAvailable = [int]$totalAvailable; hasMore = $hasMore; offset = $Request.offset; cached = $false; retrievedAt = (Get-Date).ToString("o"); suggestions = if ($Project) { Get-ResearchSuggestions $Project } else { @() } }
    $cache.entries = @($cache.entries | Where-Object { $_.key -ne $cacheKey }) + @([PSCustomObject]@{ key = $cacheKey; createdAt = (Get-Date).ToString("o"); expiresAt = (Get-Date).AddMinutes(15).ToString("o"); response = $response })
    Save-ResearchCache $cache
    return $response
}

function Get-ProjectResearchProfile {
    param([string]$ProjectId)
    $project = Get-ProjectById $ProjectId
    Ensure-ProjectModel $project
    return [PSCustomObject]@{ projectId = $project.id; suggestions = Get-ResearchSuggestions $project; weights = Get-ResearchWeights $project; importantTerms = @(ConvertTo-ResearchStringArray $project.researchSettings.importantTerms); classification = Get-ProjectClassificationSettings $project }
}

function Set-ProjectResearchSettings {
    param([string]$ProjectId, $Body)
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    Ensure-ProjectModel $project[0]
    $weightKeys = @("title", "abstract", "keywords", "subject")
    if (Test-BodyProperty $Body "weights") {
        $sum = 0.0; $candidate = [ordered]@{}
        foreach ($key in $weightKeys) {
            $value = 0.0; [void][double]::TryParse("$($Body.weights.$key)", [ref]$value)
            $candidate[$key] = [math]::Max(0, $value); $sum += $candidate[$key]
        }
        if ($sum -le 0) { throw "Mindestens ein Relevanzgewicht muss größer als null sein." }
        foreach ($key in $weightKeys) { $project[0].researchSettings.weights.$key = [math]::Round(100 * $candidate[$key] / $sum, 2) }
    }
    if (Test-BodyProperty $Body "importantTerms") { $project[0].researchSettings.importantTerms = ConvertTo-ResearchStringArray $Body.importantTerms }
    if (Test-BodyProperty $Body "cutoffYear") {
        $cutoffYear = 0; [void][int]::TryParse("$(Get-BodyValue $Body 'cutoffYear')", [ref]$cutoffYear)
        if ($cutoffYear -lt 1000 -or $cutoffYear -gt 2999) { throw 'Das Grenzjahr muss zwischen 1000 und 2999 liegen.' }
        $project[0].researchSettings.classification.cutoffYear = $cutoffYear
    }
    $project[0].updatedAt = (Get-Date).ToString("o"); Save-ProjectStore $store
    return Get-ProjectResearchProfile $ProjectId
}

function Get-ProjectSavedResearchSearches {
    param([string]$ProjectId)
    $project = Get-ProjectById $ProjectId; Ensure-ProjectModel $project
    return @($project.savedResearchSearches | Sort-Object updatedAt -Descending)
}

function Save-ProjectResearchSearch {
    param([string]$ProjectId, $Body)
    $request = New-ResearchRequest (Get-BodyValue $Body "request" $Body)
    $label = "$(Get-BodyValue $Body "label" $request.query)".Trim()
    if ([string]::IsNullOrWhiteSpace($label)) { throw "Gespeicherte Suchen benötigen einen Namen oder Suchbegriff." }
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    Ensure-ProjectModel $project[0]; $now = (Get-Date).ToString("o")
    $entry = [PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); label = $label; request = $request; createdAt = $now; updatedAt = $now }
    $project[0].savedResearchSearches = @($project[0].savedResearchSearches) + @($entry); $project[0].updatedAt = $now
    Save-ProjectStore $store; return $entry
}

function Remove-ProjectResearchSearch {
    param([string]$ProjectId, [string]$SearchId)
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $before = @($project[0].savedResearchSearches).Count
    $project[0].savedResearchSearches = @($project[0].savedResearchSearches | Where-Object { $_.id -ne $SearchId })
    if (@($project[0].savedResearchSearches).Count -eq $before) { throw "Gespeicherte Suche wurde nicht gefunden." }
    $project[0].updatedAt = (Get-Date).ToString("o"); Save-ProjectStore $store
    return @{ ok = $true }
}

. (Join-Path $PSScriptRoot "providers\openalex.ps1")
. (Join-Path $PSScriptRoot "providers\crossref.ps1")
. (Join-Path $PSScriptRoot "providers\dnb.ps1")
. (Join-Path $PSScriptRoot "providers\thulb.ps1")
