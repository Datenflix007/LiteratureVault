#!/usr/bin/env powershell
param(
    [int]$Port = 8765,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$UiDir = Join-Path $ScriptDir "ui"
Set-Location $ScriptDir

function Import-EnvFile {
    $values = [ordered]@{}
    if (-not (Test-Path ".env.local")) { return $values }
    Get-Content ".env.local" -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $value = $line.Split("=", 2)
            $values[$key.Trim()] = $value.Trim()
        }
    }
    return $values
}

function Save-EnvFile {
    param([hashtable]$Values)
    $orderedKeys = @("GITHUB_USERNAME", "GITHUB_EMAIL", "GITHUB_TOKEN", "WEBDAV_URL", "WEBDAV_USERNAME", "WEBDAV_PASSWORD", "STORAGE_PROVIDER", "ZOTERO_STORAGE_PATH", "STORAGE_SHARE_URL")
    $lines = @("# GitHub Configuration")
    foreach ($key in @("GITHUB_USERNAME", "GITHUB_EMAIL", "GITHUB_TOKEN")) {
        $lines += "$key=$($Values[$key])"
    }
    $lines += ""
    $lines += "# WebDAV Server"
    foreach ($key in @("WEBDAV_URL", "WEBDAV_USERNAME", "WEBDAV_PASSWORD")) {
        $lines += "$key=$($Values[$key])"
    }
    $lines += ""
    $lines += "# External attachment storage (the desktop sync client writes this folder to the cloud)"
    foreach ($key in @("STORAGE_PROVIDER", "ZOTERO_STORAGE_PATH", "STORAGE_SHARE_URL")) {
        $lines += "$key=$($Values[$key])"
    }
    foreach ($key in $Values.Keys) {
        if ($orderedKeys -notcontains $key) {
            $lines += "$key=$($Values[$key])"
        }
    }
    $lines | Out-File ".env.local" -Encoding UTF8 -Force
}

function Get-StoragePath {
    param([hashtable]$EnvValues = (Import-EnvFile))
    $path = "$($EnvValues["ZOTERO_STORAGE_PATH"])".Trim()
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $ScriptDir "data" }
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $ScriptDir $path }
    return [IO.Path]::GetFullPath($path)
}

function Ensure-StorageRoot {
    param([hashtable]$EnvValues = (Import-EnvFile))
    $path = Get-StoragePath $EnvValues
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $projectsPath = Join-Path $path "Projekte"
    if (-not (Test-Path -LiteralPath $projectsPath)) { New-Item -ItemType Directory -Path $projectsPath -Force | Out-Null }
    return $path
}

function Get-ProjectStorePath {
    $root = Ensure-StorageRoot
    return Join-Path (Join-Path $root "Projekte") ".myliteraturevault-projects.json"
}

function Get-ProjectsRootPath {
    return [IO.Path]::GetFullPath((Join-Path (Ensure-StorageRoot) "Projekte"))
}

function Get-ProjectStore {
    $storePath = Get-ProjectStorePath
    if (-not (Test-Path -LiteralPath $storePath)) { return [PSCustomObject]@{ version = 2; projects = @() } }
    try {
        $store = Get-Content -LiteralPath $storePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $store.projects) { $store | Add-Member -NotePropertyName projects -NotePropertyValue @() }
        if ($null -eq $store.PSObject.Properties["version"]) { $store | Add-Member -NotePropertyName version -NotePropertyValue 2 }
        foreach ($project in @($store.projects)) { Ensure-ProjectModel $project }
        return $store
    } catch {
        throw "Projektdatei kann nicht gelesen werden: $($_.Exception.Message)"
    }
}

function Save-ProjectStore {
    param($Store)
    $Store.version = 2
    foreach ($project in @($Store.projects)) { Ensure-ProjectModel $project }
    $storePath = Get-ProjectStorePath
    $Store | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $storePath -Encoding UTF8
}

function Get-SafeFolderName {
    param([string]$Name)
    $safe = ($Name -replace '[\\/:*?""<>|]', '-').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { throw "Bitte einen gueltigen Projektnamen eingeben." }
    return $safe
}

function Set-ModelProperty {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

function Get-BodyValue {
    param($Body, [string]$Name, $Default = "")
    if ($null -eq $Body) { return $Default }
    $property = $Body.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-BodyProperty {
    param($Body, [string]$Name)
    return $null -ne $Body -and $null -ne $Body.PSObject.Properties[$Name]
}

. (Join-Path $ScriptDir "search\search-service.ps1")

function Get-NormalizedReferenceKeys {
    param($Values)
    $keys = @()
    foreach ($value in @($Values)) {
        $key = "$value".Trim().ToUpperInvariant()
        if ($key -match "^[A-Z0-9]{8}$" -and $keys -notcontains $key) { $keys += $key }
    }
    return @($keys)
}

function Ensure-ProjectModel {
    param($Project)
    if ($null -eq $Project) { return }
    $defaults = [ordered]@{
        description = ""
        hypothesis = ""
        projectType = "other"
        subject = ""
        priority = "normal"
        tags = @()
        status = "planning"
        researchQuestion = ""
        researchConcept = $null
        paperGoal = ""
        abstract = ""
        notes = ""
        deadline = ""
        outline = ""
        updatedAt = "$($Project.createdAt)"
        references = @()
        todos = @()
        researchSettings = [PSCustomObject]@{ weights = [PSCustomObject]@{ title = 30; abstract = 40; keywords = 20; subject = 10 }; importantTerms = @() }
        savedResearchSearches = @()
        zoteroImportQueue = @()
        archivedAt = ""
        trashedAt = ""
        zoteroLibraryID = $null
        zoteroCollectionKey = ""
        zoteroCollectionName = ""
        zoteroSyncStatus = "pending"
        zoteroLastSyncAt = ""
        zoteroSyncMessage = "Wartet auf den lokalen Zotero-Plugin-Abgleich."
        nextIssueNumber = 1
    }
    foreach ($property in $defaults.GetEnumerator()) {
        if ($null -eq $Project.PSObject.Properties[$property.Key] -or $null -eq $Project.$($property.Key)) {
            Set-ModelProperty $Project $property.Key $property.Value
        }
    }
    $conceptDefaults = [ordered]@{ topic = ""; question = ""; relevance = ""; gap = ""; theory = ""; terms = ""; method = ""; sources = ""; contribution = ""; limits = "" }
    if ($null -eq $Project.researchConcept -or $Project.researchConcept -is [string]) { $Project.researchConcept = [PSCustomObject]@{} }
    foreach ($property in $conceptDefaults.GetEnumerator()) {
        if ($null -eq $Project.researchConcept.PSObject.Properties[$property.Key] -or $null -eq $Project.researchConcept.$($property.Key)) {
            Set-ModelProperty $Project.researchConcept $property.Key $property.Value
        }
    }
    if ("$($Project.status)" -notin @("planning", "research", "writing", "review", "done")) { $Project.status = "planning" }
    if ("$($Project.projectType)" -notin @("term_paper", "seminar_paper", "paper", "research_project", "dissertation", "other")) { $Project.projectType = "other" }
    if ("$($Project.priority)" -notin @("low", "normal", "high")) { $Project.priority = "normal" }
    $Project.tags = @("$($Project.tags -join '|')".Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($null -eq $Project.researchSettings -or $Project.researchSettings -is [string]) { $Project.researchSettings = [PSCustomObject]@{} }
    if ($null -eq $Project.researchSettings.PSObject.Properties['weights'] -or $null -eq $Project.researchSettings.weights) { Set-ModelProperty $Project.researchSettings 'weights' ([PSCustomObject]@{}) }
    foreach ($weight in @('title', 'abstract', 'keywords', 'subject')) {
        if ($null -eq $Project.researchSettings.weights.PSObject.Properties[$weight]) { Set-ModelProperty $Project.researchSettings.weights $weight (@{ title = 30; abstract = 40; keywords = 20; subject = 10 }[$weight]) }
    }
    if ($null -eq $Project.researchSettings.PSObject.Properties['importantTerms'] -or $null -eq $Project.researchSettings.importantTerms) { Set-ModelProperty $Project.researchSettings 'importantTerms' @() }
    $Project.researchSettings.importantTerms = @($Project.researchSettings.importantTerms | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $Project.savedResearchSearches = @($Project.savedResearchSearches | Where-Object { $null -ne $_ })
    $Project.zoteroImportQueue = @($Project.zoteroImportQueue | Where-Object { $null -ne $_ })

    $normalizedTodos = @()
    $seenIssueNumbers = @{}
    $nextIssueNumber = 1
    foreach ($todo in @($Project.todos)) {
        if ($null -eq $todo) { continue }
        $todoDefaults = [ordered]@{
            body = ""
            status = "open"
            priority = "normal"
            dueDate = ""
            referenceKeys = @()
            githubIssueNumber = $null
            githubIssueUrl = ""
            issueNumber = 0
            comments = @()
            checklist = @()
            events = @()
            createdAt = (Get-Date).ToString("o")
            updatedAt = "$($todo.createdAt)"
        }
        foreach ($property in $todoDefaults.GetEnumerator()) {
            if ($null -eq $todo.PSObject.Properties[$property.Key] -or $null -eq $todo.$($property.Key)) {
                Set-ModelProperty $todo $property.Key $property.Value
            }
        }
        if ("$($todo.status)" -notin @("open", "in_progress", "blocked", "done")) {
            $todo.status = if ("$($todo.status)" -eq "done") { "done" } else { "open" }
        }
        if ("$($todo.priority)" -notin @("low", "normal", "high")) { $todo.priority = "normal" }
        $todo.referenceKeys = Get-NormalizedReferenceKeys $todo.referenceKeys
        $issueNumber = 0
        [void][int]::TryParse("$($todo.issueNumber)", [ref]$issueNumber)
        if ($issueNumber -lt 1 -or $seenIssueNumbers.ContainsKey($issueNumber)) { $issueNumber = $nextIssueNumber }
        $seenIssueNumbers[$issueNumber] = $true
        $todo.issueNumber = $issueNumber
        if ($issueNumber -ge $nextIssueNumber) { $nextIssueNumber = $issueNumber + 1 }
        $todo.comments = @($todo.comments | Where-Object { $null -ne $_ })
        $todo.checklist = @($todo.checklist | Where-Object { $null -ne $_ })
        $todo.events = @($todo.events | Where-Object { $null -ne $_ })
        $normalizedTodos += $todo
    }
    $Project.todos = @($normalizedTodos)
    $Project.nextIssueNumber = [math]::Max($nextIssueNumber, 1)
    if ("$($Project.zoteroSyncStatus)" -notin @("pending", "linked", "error")) { $Project.zoteroSyncStatus = "pending" }

    $normalizedReferences = @()
    foreach ($reference in @($Project.references)) {
        if ($null -eq $reference) { continue }
        $referenceDefaults = [ordered]@{
            id = [guid]::NewGuid().ToString("N")
            zoteroKey = ""
            kind = "literature"
            title = "Ohne Titel"
            creators = ""
            year = ""
            itemType = ""
            doi = ""
            url = ""
            note = ""
            addedAt = (Get-Date).ToString("o")
        }
        foreach ($property in $referenceDefaults.GetEnumerator()) {
            if ($null -eq $reference.PSObject.Properties[$property.Key] -or $null -eq $reference.$($property.Key)) {
                Set-ModelProperty $reference $property.Key $property.Value
            }
        }
        $reference.zoteroKey = "$($reference.zoteroKey)".Trim().ToUpperInvariant()
        if ($reference.zoteroKey -notmatch "^[A-Z0-9]{8}$") { continue }
        if ("$($reference.kind)" -notin @("literature", "source")) { $reference.kind = "literature" }
        $normalizedReferences += $reference
    }
    $Project.references = @($normalizedReferences)
}

function Get-SavedResearchResultsPath {
    return Join-Path (Join-Path (Ensure-StorageRoot) 'Projekte') '.myliteraturevault-saved-results.json'
}

function Get-SavedResearchResults {
    $path = Get-SavedResearchResultsPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json
        return @($parsed | Where-Object { $null -ne $_ -and "$(Get-BodyValue $_ 'resultId')".Trim() })
    } catch {
        throw "Die Merkliste konnte nicht gelesen werden: $($_.Exception.Message)"
    }
}

function Save-SavedResearchResults {
    param([object[]]$Results)
    $json = if (@($Results).Count) { ConvertTo-Json -InputObject $Results -Depth 20 } else { '[]' }
    Set-Content -LiteralPath (Get-SavedResearchResultsPath) -Value $json -Encoding UTF8
}

function ConvertTo-SavedResearchResult {
    param($Result)
    $title = "$(Get-BodyValue $Result 'title')".Trim()
    if ([string]::IsNullOrWhiteSpace($title) -or $title -eq 'Ohne Titel') { throw 'Ein gemerkter Treffer benötigt einen Titel.' }
    $resultId = "$(Get-BodyValue $Result 'resultId')".Trim().ToLowerInvariant()
    if ($resultId -notmatch '^[a-f0-9]{40}$') {
        $hash = [Security.Cryptography.SHA1]::Create()
        try { $resultId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$title|$(Get-BodyValue $Result 'doi')|$(Get-BodyValue $Result 'publicationYear')"))) -replace '-', '').ToLowerInvariant() }
        finally { $hash.Dispose() }
    }
    return [PSCustomObject]@{
        resultId = $resultId; provider = "$(Get-BodyValue $Result 'provider')".Trim(); providers = @(Get-BodyValue $Result 'providers' @())
        title = $title; authors = @(Get-BodyValue $Result 'authors' @()); publicationYear = "$(Get-BodyValue $Result 'publicationYear')".Trim(); publicationType = "$(Get-BodyValue $Result 'publicationType')".Trim()
        abstract = "$(Get-BodyValue $Result 'abstract')".Trim(); keywords = @(Get-BodyValue $Result 'keywords' @()); language = "$(Get-BodyValue $Result 'language')".Trim(); doi = "$(Get-BodyValue $Result 'doi')".Trim()
        isbn = @(Get-BodyValue $Result 'isbn' @()); issn = @(Get-BodyValue $Result 'issn' @()); sourceUrl = "$(Get-BodyValue $Result 'sourceUrl')".Trim(); fulltextUrl = "$(Get-BodyValue $Result 'fulltextUrl')".Trim()
        publisher = "$(Get-BodyValue $Result 'publisher')".Trim(); availability = "$(Get-BodyValue $Result 'availability')".Trim(); savedAt = (Get-Date).ToString('o')
    }
}

function Add-SavedResearchResult {
    param($Body)
    $saved = ConvertTo-SavedResearchResult (Get-BodyValue $Body 'result' $Body)
    $results = @(Get-SavedResearchResults)
    $existing = @($results | Where-Object { $_.resultId -eq $saved.resultId } | Select-Object -First 1)
    if ($existing) { return $existing[0] }
    $allResults = [System.Collections.Generic.List[object]]::new()
    [void]$allResults.Add($saved)
    foreach ($result in $results) { [void]$allResults.Add($result) }
    Save-SavedResearchResults -Results $allResults.ToArray()
    return $saved
}

function Remove-SavedResearchResult {
    param([string]$ResultId)
    $results = @(Get-SavedResearchResults)
    $remaining = @($results | Where-Object { $_.resultId -ne $ResultId })
    if ($remaining.Count -eq $results.Count) { throw 'Der gemerkte Treffer wurde nicht gefunden.' }
    Save-SavedResearchResults -Results $remaining
    return @{ ok = $true }
}

function Get-ProjectSummary {
    param($Project)
    Ensure-ProjectModel $Project
    $todos = @($Project.todos)
    $references = @($Project.references)
    $doneTodoCount = @($todos | Where-Object { $_.status -eq "done" }).Count
    $inProgressTodoCount = @($todos | Where-Object { $_.status -eq "in_progress" }).Count
    $openTodoCount = @($todos | Where-Object { $_.status -eq "open" }).Count
    $blockedTodoCount = @($todos | Where-Object { $_.status -eq "blocked" }).Count
    $progress = if ($todos.Count) { [math]::Round(($doneTodoCount / $todos.Count) * 100) } else { 0 }
    return @{
        id = $Project.id; name = $Project.name; folderName = $Project.folderName; createdAt = $Project.createdAt; updatedAt = $Project.updatedAt
        status = $Project.status; researchQuestion = $Project.researchQuestion; researchConcept = $Project.researchConcept; paperGoal = $Project.paperGoal; abstract = $Project.abstract
        description = $Project.description; hypothesis = $Project.hypothesis; projectType = $Project.projectType; subject = $Project.subject; priority = $Project.priority; tags = @($Project.tags)
        archivedAt = $Project.archivedAt; trashedAt = $Project.trashedAt
        zotero = @{ libraryID = $Project.zoteroLibraryID; collectionKey = $Project.zoteroCollectionKey; collectionName = $Project.zoteroCollectionName; status = $Project.zoteroSyncStatus; lastSyncAt = $Project.zoteroLastSyncAt; message = $Project.zoteroSyncMessage }
        notes = $Project.notes; deadline = $Project.deadline; outline = $Project.outline
        researchSettings = $Project.researchSettings; savedResearchSearches = @($Project.savedResearchSearches)
        zoteroImportQueue = @($Project.zoteroImportQueue)
        todoCount = $todos.Count; openTodoCount = $openTodoCount; inProgressTodoCount = $inProgressTodoCount; blockedTodoCount = $blockedTodoCount; doneTodoCount = $doneTodoCount; progress = $progress
        referenceCount = $references.Count; literatureCount = @($references | Where-Object { $_.kind -eq "literature" }).Count; sourceCount = @($references | Where-Object { $_.kind -eq "source" }).Count
        todos = $todos; tasks = $todos; references = $references
    }
}

function Get-ProjectById {
    param([string]$Id)
    $project = @((Get-ProjectStore).projects | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    return $project[0]
}

function New-Project {
    param([string]$Name, $Body = $null)
    $name = "$Name".Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Bitte einen Projektnamen eingeben." }
    $store = Get-ProjectStore
    $baseFolder = Get-SafeFolderName $name
    $folderName = $baseFolder
    $suffix = 2
    while (@($store.projects | Where-Object { $_.folderName -ieq $folderName }).Count -gt 0) { $folderName = "$baseFolder-$suffix"; $suffix++ }
    $projectRoot = Join-Path (Join-Path (Ensure-StorageRoot) "Projekte") $folderName
    New-Item -ItemType Directory -Path (Join-Path $projectRoot "Literatur") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $projectRoot "Quellen") -Force | Out-Null
    $now = (Get-Date).ToString("o")
    $project = [PSCustomObject]@{
        id = [guid]::NewGuid().ToString("N"); name = $name; folderName = $folderName; createdAt = $now; updatedAt = $now
        description = "$(Get-BodyValue $Body 'description')".Trim(); hypothesis = "$(Get-BodyValue $Body 'hypothesis')".Trim()
        projectType = "$(Get-BodyValue $Body 'projectType' 'other')"; subject = "$(Get-BodyValue $Body 'subject')".Trim(); priority = "$(Get-BodyValue $Body 'priority' 'normal')"
        tags = @("$(Get-BodyValue $Body 'tags' @())" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        status = "planning"; researchQuestion = "$(Get-BodyValue $Body 'researchQuestion')".Trim(); researchConcept = [PSCustomObject]@{ topic = ""; question = ""; relevance = ""; gap = ""; theory = ""; terms = ""; method = ""; sources = ""; contribution = ""; limits = "" }; paperGoal = "$(Get-BodyValue $Body 'paperGoal')".Trim()
        abstract = ""; notes = ""; deadline = "$(Get-BodyValue $Body 'deadline')".Trim(); outline = ""; references = @(); todos = @(); researchSettings = [PSCustomObject]@{ weights = [PSCustomObject]@{ title = 30; abstract = 40; keywords = 20; subject = 10 }; importantTerms = @() }; savedResearchSearches = @(); zoteroImportQueue = @(); archivedAt = ""; trashedAt = ""
        zoteroLibraryID = $null; zoteroCollectionKey = ""; zoteroCollectionName = ""; zoteroSyncStatus = "pending"; zoteroLastSyncAt = ""; zoteroSyncMessage = "Wartet auf den lokalen Zotero-Plugin-Abgleich."; nextIssueNumber = 1
    }
    if ("$(Get-BodyValue $Body 'status')" -in @("planning", "research", "writing", "review", "done")) { $project.status = "$(Get-BodyValue $Body 'status')" }
    if ("$(Get-BodyValue $Body 'projectType')" -in @("term_paper", "seminar_paper", "paper", "research_project", "dissertation", "other")) { $project.projectType = "$(Get-BodyValue $Body 'projectType')" }
    if ("$(Get-BodyValue $Body 'priority')" -in @("low", "normal", "high")) { $project.priority = "$(Get-BodyValue $Body 'priority')" }
    $store.projects = @($store.projects) + @($project)
    Save-ProjectStore $store
    return Get-ProjectSummary $project
}

function New-ProjectTodo {
    param([string]$ProjectId, $Body)
    $title = "$(Get-BodyValue $Body 'title')".Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { throw "Bitte einen TODO-Titel eingeben." }
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $now = (Get-Date).ToString("o")
    $status = "$(Get-BodyValue $Body 'status' 'open')"
    if ($status -notin @("open", "in_progress", "blocked", "done")) { $status = "open" }
    $priority = "$(Get-BodyValue $Body 'priority' 'normal')"
    if ($priority -notin @("low", "normal", "high")) { $priority = "normal" }
    $issueNumber = [math]::Max(1, [int]$project[0].nextIssueNumber)
    $todo = [PSCustomObject]@{
        id = [guid]::NewGuid().ToString("N"); title = $title; body = "$(Get-BodyValue $Body 'body')".Trim(); status = $status; priority = $priority
        dueDate = "$(Get-BodyValue $Body 'dueDate')".Trim(); referenceKeys = Get-NormalizedReferenceKeys (Get-BodyValue $Body 'referenceKeys' @())
        githubIssueNumber = $null; githubIssueUrl = ""; issueNumber = $issueNumber; comments = @(); checklist = @()
        events = @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); type = "created"; message = "Aufgabe erstellt."; createdAt = $now })
        createdAt = $now; updatedAt = $now
    }
    $project[0].todos = @($project[0].todos) + @($todo)
    $project[0].nextIssueNumber = $issueNumber + 1
    $project[0].updatedAt = $now
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Set-ProjectTodo {
    param([string]$ProjectId, [string]$TodoId, $Body)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $todo = @($project[0].todos | Where-Object { $_.id -eq $TodoId } | Select-Object -First 1)
    if (-not $todo) { throw "TODO wurde nicht gefunden." }
    $events = @()
    if (Test-BodyProperty $Body "title") {
        $title = "$(Get-BodyValue $Body 'title')".Trim()
        if ([string]::IsNullOrWhiteSpace($title)) { throw "Bitte einen TODO-Titel eingeben." }
        if ($todo[0].title -ne $title) { $events += "Titel geändert." }
        $todo[0].title = $title
    }
    if (Test-BodyProperty $Body "body") {
        $bodyValue = "$(Get-BodyValue $Body 'body')".Trim()
        if ($todo[0].body -ne $bodyValue) { $events += "Beschreibung geändert." }
        $todo[0].body = $bodyValue
    }
    $status = "$(Get-BodyValue $Body 'status')"
    if ($status -in @("open", "in_progress", "blocked", "done") -and $todo[0].status -ne $status) { $todo[0].status = $status; $events += "Status auf '$status' gesetzt." }
    $priority = "$(Get-BodyValue $Body 'priority')"
    if ($priority -in @("low", "normal", "high") -and $todo[0].priority -ne $priority) { $todo[0].priority = $priority; $events += "Priorität auf '$priority' gesetzt." }
    if (Test-BodyProperty $Body "dueDate") {
        $dueDate = "$(Get-BodyValue $Body 'dueDate')".Trim()
        if ($todo[0].dueDate -ne $dueDate) { $events += "Termin geändert." }
        $todo[0].dueDate = $dueDate
    }
    if (Test-BodyProperty $Body "referenceKeys") {
        $referenceKeys = Get-NormalizedReferenceKeys (Get-BodyValue $Body 'referenceKeys' @())
        if ("$($todo[0].referenceKeys -join '|')" -ne "$($referenceKeys -join '|')") { $events += "Verknüpfte Literatur geändert." }
        $todo[0].referenceKeys = $referenceKeys
    }
    $todo[0].updatedAt = (Get-Date).ToString("o")
    foreach ($eventMessage in $events) {
        $todo[0].events = @($todo[0].events) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); type = "updated"; message = $eventMessage; createdAt = $todo[0].updatedAt })
    }
    $project[0].updatedAt = $todo[0].updatedAt
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Get-ProjectTodo {
    param($Project, [string]$TodoId)
    $todo = @($Project.todos | Where-Object { $_.id -eq $TodoId } | Select-Object -First 1)
    if (-not $todo) { throw "TODO wurde nicht gefunden." }
    return $todo[0]
}

function Add-ProjectTodoComment {
    param([string]$ProjectId, [string]$TodoId, $Body)
    $message = "$(Get-BodyValue $Body 'message')".Trim()
    if ([string]::IsNullOrWhiteSpace($message)) { throw "Bitte einen Kommentar eingeben." }
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $todo = Get-ProjectTodo $project[0] $TodoId
    $now = (Get-Date).ToString("o")
    $todo.comments = @($todo.comments) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); message = $message; createdAt = $now })
    $todo.events = @($todo.events) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); type = "comment"; message = "Kommentar hinzugefügt."; createdAt = $now })
    $todo.updatedAt = $now; $project[0].updatedAt = $now
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Add-ProjectTodoChecklistItem {
    param([string]$ProjectId, [string]$TodoId, $Body)
    $title = "$(Get-BodyValue $Body 'title')".Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { throw "Bitte einen Checklistenpunkt eingeben." }
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $todo = Get-ProjectTodo $project[0] $TodoId; $now = (Get-Date).ToString("o")
    $todo.checklist = @($todo.checklist) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); title = $title; done = $false; createdAt = $now })
    $todo.events = @($todo.events) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); type = "checklist"; message = "Checklistenpunkt hinzugefügt."; createdAt = $now })
    $todo.updatedAt = $now; $project[0].updatedAt = $now; Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Set-ProjectTodoChecklistItem {
    param([string]$ProjectId, [string]$TodoId, [string]$ChecklistId, $Body)
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $todo = Get-ProjectTodo $project[0] $TodoId
    $item = @($todo.checklist | Where-Object { $_.id -eq $ChecklistId } | Select-Object -First 1)
    if (-not $item) { throw "Checklistenpunkt wurde nicht gefunden." }
    if (Test-BodyProperty $Body "done") { $item[0].done = [bool](Get-BodyValue $Body 'done') }
    if (Test-BodyProperty $Body "title") { $item[0].title = "$(Get-BodyValue $Body 'title')".Trim() }
    $now = (Get-Date).ToString("o"); $todo.events = @($todo.events) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString("N"); type = "checklist"; message = "Checklistenpunkt aktualisiert."; createdAt = $now })
    $todo.updatedAt = $now; $project[0].updatedAt = $now; Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Set-ProjectZoteroCollection {
    param([string]$ProjectId, $Body)
    $libraryID = 0; [void][int]::TryParse("$(Get-BodyValue $Body 'libraryID')", [ref]$libraryID)
    $collectionKey = "$(Get-BodyValue $Body 'collectionKey')".Trim().ToUpperInvariant()
    if ($libraryID -lt 1 -or $collectionKey -notmatch "^[A-Z0-9]{8}$") { throw "Ungültige Zotero-Sammlungszuordnung." }
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $project[0].zoteroLibraryID = $libraryID; $project[0].zoteroCollectionKey = $collectionKey
    $project[0].zoteroCollectionName = "$(Get-BodyValue $Body 'collectionName')".Trim()
    $project[0].zoteroSyncStatus = "linked"; $project[0].zoteroLastSyncAt = (Get-Date).ToString("o")
    $project[0].zoteroSyncMessage = "Sammlung in Meine Bibliothek verknüpft."
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Request-ProjectZoteroSync {
    param([string]$ProjectId)
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $project[0].zoteroSyncStatus = "pending"; $project[0].zoteroSyncMessage = "Abgleich mit dem lokalen Zotero-Plugin angefordert."; $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Set-ProjectDetails {
    param([string]$ProjectId, $Body)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    foreach ($field in @("description", "hypothesis", "subject", "researchQuestion", "paperGoal", "abstract", "notes", "deadline", "outline")) {
        if (Test-BodyProperty $Body $field) { $project[0].$field = "$(Get-BodyValue $Body $field)".Trim() }
    }
    if (Test-BodyProperty $Body "name") {
        $name = "$(Get-BodyValue $Body 'name')".Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { throw "Bitte einen Projektnamen eingeben." }
        $project[0].name = $name
    }
    if ("$(Get-BodyValue $Body 'status')" -in @("planning", "research", "writing", "review", "done")) { $project[0].status = "$(Get-BodyValue $Body 'status')" }
    if ("$(Get-BodyValue $Body 'projectType')" -in @("term_paper", "seminar_paper", "paper", "research_project", "dissertation", "other")) { $project[0].projectType = "$(Get-BodyValue $Body 'projectType')" }
    if ("$(Get-BodyValue $Body 'priority')" -in @("low", "normal", "high")) { $project[0].priority = "$(Get-BodyValue $Body 'priority')" }
    if (Test-BodyProperty $Body "tags") { $project[0].tags = @("$(Get-BodyValue $Body 'tags')" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
    if (Test-BodyProperty $Body "researchConcept" -and $null -ne $Body.researchConcept) {
        foreach ($field in @("topic", "question", "relevance", "gap", "theory", "terms", "method", "sources", "contribution", "limits")) {
            if ($null -ne $Body.researchConcept.PSObject.Properties[$field]) { $project[0].researchConcept.$field = "$(Get-BodyValue $Body.researchConcept $field)".Trim() }
        }
    }
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Set-ProjectArchiveState {
    param([string]$ProjectId, [bool]$Archived)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    if ($project[0].trashedAt) { throw "Ein Projekt im Papierkorb muss zuerst wiederhergestellt werden." }
    $project[0].archivedAt = if ($Archived) { (Get-Date).ToString("o") } else { "" }
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Restore-Project {
    param([string]$ProjectId)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $project[0].trashedAt = ""
    $project[0].archivedAt = ""
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Move-ProjectToTrash {
    param([string]$ProjectId)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    if (-not $project[0].trashedAt) { $project[0].trashedAt = (Get-Date).ToString("o") }
    $project[0].archivedAt = ""
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return @{ id = $project[0].id; trashedAt = $project[0].trashedAt; filesKept = $true; zoteroItemsKept = $true }
}

function Get-ManagedProjectFolderPath {
    param($Project)
    $projectsRoot = Get-ProjectsRootPath
    $candidate = [IO.Path]::GetFullPath((Join-Path $projectsRoot "$($Project.folderName)"))
    $rootPrefix = $projectsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsicherer Projektordner wurde blockiert." }
    return $candidate
}

function Remove-ProjectPermanently {
    param([string]$ProjectId, [bool]$DeleteProjectFiles = $false)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    if (-not $project[0].trashedAt) { throw "Ein Projekt muss vor dem endgültigen Löschen zuerst im Papierkorb liegen." }
    $projectFolder = Get-ManagedProjectFolderPath $project[0]
    if ($DeleteProjectFiles -and (Test-Path -LiteralPath $projectFolder)) {
        Remove-Item -LiteralPath $projectFolder -Recurse -Force
    }
    $store.projects = @($store.projects | Where-Object { $_.id -ne $ProjectId })
    Save-ProjectStore $store
    return @{ id = $ProjectId; projectDataDeleted = $true; projectFilesDeleted = $DeleteProjectFiles; preservedProjectFolder = if ($DeleteProjectFiles) { "" } else { $projectFolder }; zoteroItemsKept = $true }
}

function Copy-Project {
    param([string]$ProjectId)
    $source = Get-ProjectById $ProjectId
    if ($source.trashedAt) { throw "Projekte im Papierkorb können nicht dupliziert werden." }
    $copy = New-Project "$($source.name) - Kopie" ([PSCustomObject]@{
        description = $source.description; hypothesis = $source.hypothesis; projectType = $source.projectType; subject = $source.subject; priority = $source.priority; tags = @($source.tags)
        researchQuestion = $source.researchQuestion; paperGoal = $source.paperGoal; deadline = $source.deadline; status = "planning"
    })
    return $copy
}

function Invoke-ZoteroLocalApi {
    param([string]$Path)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $client.DefaultRequestHeaders.Add("Zotero-API-Version", "3")
    try {
        $response = $client.GetAsync("http://127.0.0.1:23119/api$Path").GetAwaiter().GetResult()
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Zotero antwortet mit HTTP $([int]$response.StatusCode)."
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -is [array]) {
            foreach ($entry in $parsed) { Write-Output $entry }
        } else {
            Write-Output $parsed
        }
    } catch {
        throw "Zotero ist lokal nicht erreichbar. Starte Zotero und aktiviere in Einstellungen → Erweitert den Zugriff für andere Anwendungen. Details: $($_.Exception.Message)"
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function ConvertTo-ProjectReference {
    param($ZoteroItem)
    if ($null -eq $ZoteroItem -or $null -eq $ZoteroItem.data) { return $null }
    $data = $ZoteroItem.data
    $key = "$($data.key)".Trim().ToUpperInvariant()
    if ($key -notmatch "^[A-Z0-9]{8}$") { return $null }
    if ("$($data.itemType)" -in @("attachment", "note", "annotation")) { return $null }
    $creatorNames = @()
    foreach ($creator in @($data.creators)) {
        $name = if ("$($creator.name)".Trim()) { "$($creator.name)" } else { ("$($creator.lastName) $($creator.firstName)").Trim() }
        if ($name) { $creatorNames += $name }
    }
    $year = ""
    if ("$($data.date)" -match "(?<!\d)(1[5-9]\d{2}|20\d{2})(?!\d)") { $year = $matches[1] }
    return [PSCustomObject]@{
        zoteroKey = $key
        title = if ("$($data.title)".Trim()) { "$($data.title)".Trim() } else { "Ohne Titel" }
        creators = ($creatorNames -join "; ")
        year = $year
        itemType = "$($data.itemType)"
        doi = "$($data.DOI)".Trim()
        url = "$($data.url)".Trim()
        zoteroUri = "zotero://select/library/items/$key"
    }
}

function Get-ZoteroPluginStatus {
    $profileRoot = Join-Path $env:APPDATA "Zotero\Zotero\Profiles"
    if (-not (Test-Path -LiteralPath $profileRoot)) {
        return @{ installed = $false; active = $false; version = ""; message = "Kein Zotero-Profil gefunden." }
    }
    $extensionFiles = @(Get-ChildItem -LiteralPath $profileRoot -Filter "extensions.json" -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($extensionFile in $extensionFiles) {
        try {
            $registry = Get-Content -LiteralPath $extensionFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $addon = @($registry.addons | Where-Object { $_.id -eq "myliteraturevault@datenflix007.github" } | Select-Object -First 1)
            if (-not $addon) { continue }
            $active = [bool]$addon[0].active -and -not [bool]$addon[0].appDisabled -and -not [bool]$addon[0].userDisabled
            $message = if ($active) {
                "MyLiteratureVault-Plugin $($addon[0].version) ist aktiv."
            } elseif ($addon[0].appDisabled) {
                "MyLiteratureVault-Plugin $($addon[0].version) ist mit dieser Zotero-Version nicht kompatibel."
            } elseif ($addon[0].userDisabled) {
                "MyLiteratureVault-Plugin $($addon[0].version) wurde in Zotero deaktiviert."
            } else {
                "MyLiteratureVault-Plugin $($addon[0].version) ist nicht aktiv."
            }
            return @{ installed = $true; active = $active; version = "$($addon[0].version)"; message = $message }
        } catch {
            continue
        }
    }
    return @{ installed = $false; active = $false; version = ""; message = "MyLiteratureVault-Plugin ist nicht installiert." }
}

function Get-ZoteroStatus {
    $plugin = Get-ZoteroPluginStatus
    try {
        $items = @(Invoke-ZoteroLocalApi "/users/0/items/top?format=json&limit=1")
        return @{ available = $true; message = "Zotero ist lokal verbunden"; sampleCount = $items.Count; plugin = $plugin }
    } catch {
        return @{ available = $false; message = "$($_.Exception.Message)"; plugin = $plugin }
    }
}

function Get-ZoteroSearchResults {
    param([string]$Query, [int]$Limit = 20)
    $query = "$Query".Trim()
    if ($query.Length -lt 2) { return @() }
    $safeLimit = [math]::Max(1, [math]::Min(30, $Limit))
    $encodedQuery = [Uri]::EscapeDataString($query)
    $items = @(Invoke-ZoteroLocalApi "/users/0/items/top?format=json&limit=$safeLimit&q=$encodedQuery")
    return @($items | ForEach-Object { ConvertTo-ProjectReference $_ } | Where-Object { $null -ne $_ })
}

function Get-ZoteroReferenceByKey {
    param([string]$ZoteroKey)
    $key = "$ZoteroKey".Trim().ToUpperInvariant()
    if ($key -notmatch "^[A-Z0-9]{8}$") { throw "Ungültiger Zotero-Schlüssel." }
    $item = Invoke-ZoteroLocalApi "/users/0/items/${key}?format=json"
    $reference = ConvertTo-ProjectReference $item
    if ($null -eq $reference) { throw "Der gewählte Zotero-Eintrag kann nicht als Literatur oder Quelle verknüpft werden." }
    return $reference
}

function Get-ZoteroCollectionPage {
    param([string]$Path)
    return @(Invoke-ZoteroLocalApi $Path)
}

function Get-ZoteroCollectionChildren {
    param([string]$CollectionKey)
    $children = @()
    $start = 0
    do {
        $page = @(Get-ZoteroCollectionPage "/users/0/collections/${CollectionKey}/collections?format=json&limit=100&start=$start")
        $children += @($page)
        $start += $page.Count
    } while ($page.Count -eq 100)
    return @($children)
}

function Get-ZoteroCollectionReferences {
    param([string]$CollectionKey)
    $references = @()
    $start = 0
    do {
        # Top-Level-Einträge reichen hier aus: Kind-Anhänge, Notizen und Annotationen
        # gehören nicht in das Quellenregal und werden zusätzlich beim Konvertieren gefiltert.
        $page = @(Get-ZoteroCollectionPage "/users/0/collections/${CollectionKey}/items/top?format=json&limit=100&start=$start")
        $references += @($page)
        $start += $page.Count
    } while ($page.Count -eq 100)
    return @($references)
}

function Get-ZoteroProjectCollectionReferences {
    param($Project)
    Ensure-ProjectModel $Project
    $rootCollectionKey = "$($Project.zoteroCollectionKey)".Trim().ToUpperInvariant()
    if ($rootCollectionKey -notmatch "^[A-Z0-9]{8}$") {
        return @{ ready = $false; message = "Die Zotero-Projektsammlungen werden nach dem ersten Plugin-Abgleich automatisch hier gelesen."; literature = @(); sources = @(); references = @() }
    }

    try {
        # Die lokale Zotero-Web-API verwendet users/0 für Meine Bibliothek. Die
        # vom Desktop-Plugin gespeicherte Library-ID ist bewusst kein Web-API-Pfad.
        $children = @(Get-ZoteroCollectionChildren $rootCollectionKey)
        $result = [ordered]@{ ready = $true; message = "Inhalte der Zotero-Unterordner Literatur und Quellen."; literature = @(); sources = @(); references = @() }
        $missingFolders = @()

        foreach ($definition in @(
            @{ name = "Literatur"; kind = "literature"; resultKey = "literature" },
            @{ name = "Quellen"; kind = "source"; resultKey = "sources" }
        )) {
            $folder = @($children | Where-Object { "$($_.data.name)" -ieq $definition.name } | Select-Object -First 1)
            if (-not $folder) {
                $missingFolders += $definition.name
                continue
            }
            $folderKey = "$($folder[0].data.key)".Trim().ToUpperInvariant()
            if ($folderKey -notmatch "^[A-Z0-9]{8}$") { continue }
            foreach ($item in @(Get-ZoteroCollectionReferences $folderKey)) {
                $reference = ConvertTo-ProjectReference $item
                if ($null -eq $reference) { continue }
                $reference | Add-Member -NotePropertyName kind -NotePropertyValue $definition.kind
                $reference | Add-Member -NotePropertyName origin -NotePropertyValue "collection"
                $reference | Add-Member -NotePropertyName collectionKey -NotePropertyValue $folderKey
                $result[$definition.resultKey] += @($reference)
            }
        }

        $result.references = @($result.literature + $result.sources | Group-Object zoteroKey | ForEach-Object { $_.Group[0] })
        if ($missingFolders.Count) {
            $result.message = "In der Zotero-Projektsammlung fehlen noch: " + ($missingFolders -join ", ") + "."
        }
        return $result
    } catch {
        return @{ ready = $false; message = "Die Zotero-Projektsammlungen konnten nicht gelesen werden: $($_.Exception.Message)"; literature = @(); sources = @(); references = @() }
    }
}

function Add-ProjectReference {
    param([string]$ProjectId, $Body)
    $key = "$(Get-BodyValue $Body 'zoteroKey')".Trim().ToUpperInvariant()
    $reference = Get-ZoteroReferenceByKey $key
    $kind = "$(Get-BodyValue $Body 'kind' 'literature')"
    if ($kind -notin @("literature", "source")) { $kind = "literature" }
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $existing = @($project[0].references | Where-Object { $_.zoteroKey -eq $key } | Select-Object -First 1)
    if ($existing) {
        $existing[0].kind = $kind
        if (Test-BodyProperty $Body "note") { $existing[0].note = "$(Get-BodyValue $Body 'note')".Trim() }
    } else {
        $entry = [PSCustomObject]@{
            id = [guid]::NewGuid().ToString("N"); zoteroKey = $reference.zoteroKey; kind = $kind; title = $reference.title
            creators = $reference.creators; year = $reference.year; itemType = $reference.itemType; doi = $reference.doi; url = $reference.url
            note = "$(Get-BodyValue $Body 'note')".Trim(); addedAt = (Get-Date).ToString("o")
        }
        $project[0].references = @($project[0].references) + @($entry)
    }
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Queue-ResearchResultForZotero {
    param([string]$ProjectId, $Body)
    $result = Get-BodyValue $Body 'result' $null
    if ($null -eq $result) { throw "Es fehlen die Metadaten des Recherchetreffers." }
    $title = "$(Get-BodyValue $result 'title')".Trim()
    if ([string]::IsNullOrWhiteSpace($title) -or $title -eq 'Ohne Titel') { throw "Ein Zotero-Import benötigt einen Titel." }
    $kind = "$(Get-BodyValue $Body 'kind' 'literature')".Trim().ToLowerInvariant()
    if ($kind -notin @('literature', 'source')) { $kind = 'literature' }
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    Ensure-ProjectModel $project[0]
    $doi = "$(Get-BodyValue $result 'doi')".Trim() -replace '^https?://(dx\.)?doi\.org/', ''
    $fingerprint = if ($doi) { "doi:$($doi.ToLowerInvariant())" } else { "title:$($title.ToLowerInvariant())|year:$(Get-BodyValue $result 'publicationYear')" }
    $existing = @($project[0].zoteroImportQueue | Where-Object { $_.fingerprint -eq $fingerprint -and $_.status -in @('pending', 'completed') } | Select-Object -First 1)
    if ($existing) { return $existing[0] }
    $metadata = [PSCustomObject]@{
        resultId = "$(Get-BodyValue $result 'resultId')".Trim(); title = $title; authors = @(Get-BodyValue $result 'authors' @()); publicationYear = "$(Get-BodyValue $result 'publicationYear')".Trim(); publicationType = "$(Get-BodyValue $result 'publicationType')".Trim()
        abstract = "$(Get-BodyValue $result 'abstract')".Trim(); keywords = @(Get-BodyValue $result 'keywords' @()); language = "$(Get-BodyValue $result 'language')".Trim(); doi = $doi; isbn = @(Get-BodyValue $result 'isbn' @()); issn = @(Get-BodyValue $result 'issn' @())
        sourceUrl = "$(Get-BodyValue $result 'sourceUrl')".Trim(); fulltextUrl = "$(Get-BodyValue $result 'fulltextUrl')".Trim(); publisher = "$(Get-BodyValue $result 'publisher')".Trim(); providers = @(Get-BodyValue $result 'providers' @())
    }
    $entry = [PSCustomObject]@{ id = [guid]::NewGuid().ToString('N'); fingerprint = $fingerprint; kind = $kind; status = 'pending'; result = $metadata; requestedAt = (Get-Date).ToString('o'); completedAt = ''; zoteroKey = ''; message = 'Wartet auf den lokalen Zotero-Plugin-Import.' }
    $project[0].zoteroImportQueue = @($project[0].zoteroImportQueue) + @($entry); $project[0].updatedAt = (Get-Date).ToString('o'); Save-ProjectStore $store
    return $entry
}

function Complete-ResearchResultZoteroImport {
    param([string]$ProjectId, [string]$ImportId, $Body)
    $key = "$(Get-BodyValue $Body 'zoteroKey')".Trim().ToUpperInvariant()
    if ($key -notmatch '^[A-Z0-9]{8}$') { throw 'Ungültiger Zotero-Schlüssel für den Import.' }
    $store = Get-ProjectStore; $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw 'Projekt wurde nicht gefunden.' }
    Ensure-ProjectModel $project[0]; $entry = @($project[0].zoteroImportQueue | Where-Object { $_.id -eq $ImportId } | Select-Object -First 1)
    if (-not $entry) { throw 'Importauftrag wurde nicht gefunden.' }
    $entry[0].status = 'completed'; $entry[0].zoteroKey = $key; $entry[0].completedAt = (Get-Date).ToString('o'); $entry[0].message = "In Zotero angelegt oder wiederverwendet: $key"
    if (-not @($project[0].references | Where-Object { $_.zoteroKey -eq $key } | Select-Object -First 1)) {
        $project[0].references = @($project[0].references) + @([PSCustomObject]@{ id = [guid]::NewGuid().ToString('N'); zoteroKey = $key; kind = $entry[0].kind; title = $entry[0].result.title; creators = (@($entry[0].result.authors) -join '; '); year = $entry[0].result.publicationYear; itemType = $entry[0].result.publicationType; doi = $entry[0].result.doi; url = if ($entry[0].result.sourceUrl) { $entry[0].result.sourceUrl } else { $entry[0].result.fulltextUrl }; note = ''; addedAt = (Get-Date).ToString('o') })
    }
    $project[0].updatedAt = (Get-Date).ToString('o'); Save-ProjectStore $store
    return @{ ok = $true; zoteroKey = $key }
}

function Set-ProjectReference {
    param([string]$ProjectId, [string]$ReferenceId, $Body)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $reference = @($project[0].references | Where-Object { $_.id -eq $ReferenceId } | Select-Object -First 1)
    if (-not $reference) { throw "Verknüpfte Zotero-Quelle wurde nicht gefunden." }
    if ("$(Get-BodyValue $Body 'kind')" -in @("literature", "source")) { $reference[0].kind = "$(Get-BodyValue $Body 'kind')" }
    if (Test-BodyProperty $Body "note") { $reference[0].note = "$(Get-BodyValue $Body 'note')".Trim() }
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Remove-ProjectReference {
    param([string]$ProjectId, [string]$ReferenceId)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $before = @($project[0].references).Count
    $project[0].references = @($project[0].references | Where-Object { $_.id -ne $ReferenceId })
    if ($project[0].references.Count -eq $before) { throw "Verknüpfte Zotero-Quelle wurde nicht gefunden." }
    $project[0].updatedAt = (Get-Date).ToString("o")
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Get-RepoInfo {
    $remote = (git remote get-url origin 2>$null)
    if ($remote -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(\.git)?/?$") {
        return @{ owner = $matches.owner; repo = $matches.repo; remote = $remote }
    }
    return @{ owner = ""; repo = ""; remote = $remote }
}

function Invoke-Git {
    param([string[]]$GitArgs)
    $output = & git @GitArgs 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
}

function Invoke-GitRemote {
    param([string[]]$GitArgs)
    $env = Import-EnvFile
    if ($env["GITHUB_TOKEN"]) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env["GITHUB_TOKEN"])"))
        $output = & git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" @GitArgs 2>&1
    }
    else {
        $output = & git @GitArgs 2>&1
    }
    return @{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
}

function Get-AuthHeaders {
    $env = Import-EnvFile
    if (-not $env["GITHUB_TOKEN"]) { throw "GITHUB_TOKEN fehlt in .env.local" }
    return @{
        Authorization = "Bearer $($env["GITHUB_TOKEN"])"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "MyLiteratureVault"
    }
}

function Invoke-GitHub {
    param([string]$Method, [string]$Path, $Body = $null)
    $repo = Get-RepoInfo
    if (-not $repo.owner -or -not $repo.repo) { throw "GitHub Remote konnte nicht erkannt werden." }
    $uri = "https://api.github.com/repos/$($repo.owner)/$($repo.repo)$Path"
    $headers = Get-AuthHeaders
    if ($Body -ne $null) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Publish-ProjectTodoIssue {
    param([string]$ProjectId, [string]$TodoId)
    $store = Get-ProjectStore
    $project = @($store.projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1)
    if (-not $project) { throw "Projekt wurde nicht gefunden." }
    $todo = @($project[0].todos | Where-Object { $_.id -eq $TodoId } | Select-Object -First 1)
    if (-not $todo) { throw "TODO wurde nicht gefunden." }
    if ($todo[0].githubIssueUrl) { return Get-ProjectSummary $project[0] }

    $linkedReferences = @($project[0].references | Where-Object { $todo[0].referenceKeys -contains $_.zoteroKey })
    $referenceBlock = if ($linkedReferences.Count) {
        "`n## Verknüpfte Zotero-Literatur`n" + (($linkedReferences | ForEach-Object { "- $($_.title) (Zotero: $($_.zoteroKey))" }) -join "`n")
    } else { "" }
    $issueBody = @(
        "<!-- myliteraturevault-project:$ProjectId todo:$TodoId -->"
        "## Forschungsaufgabe"
        ""
        "**Projekt:** $($project[0].name)"
        "**Priorität:** $($todo[0].priority)"
        "**Status:** $($todo[0].status)"
        ""
        "$($todo[0].body)"
        $referenceBlock
        ""
        "_Erstellt aus MyLiteratureVault. Die vollständigen privaten Forschungsnotizen bleiben im externen Projektordner._"
    ) -join "`n"
    $label = "mvl-project-$ProjectId"
    try {
        Invoke-GitHub "POST" "/labels" @{ name = $label; color = "1f6feb"; description = "MyLiteratureVault: $($project[0].name)" } | Out-Null
    } catch {
        # A label that already exists produces a validation response; the issue request below remains authoritative.
    }
    $issue = Invoke-GitHub "POST" "/issues" @{ title = "[$($project[0].name)] $($todo[0].title)"; body = $issueBody; labels = @($label, "myliteraturevault") }
    $todo[0].githubIssueNumber = $issue.number
    $todo[0].githubIssueUrl = $issue.html_url
    $todo[0].updatedAt = (Get-Date).ToString("o")
    $project[0].updatedAt = $todo[0].updatedAt
    Save-ProjectStore $store
    return Get-ProjectSummary $project[0]
}

function Send-Response {
    param($Context, [int]$Status, [string]$Body, [string]$ContentType = "application/json")
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = "$ContentType; charset=utf-8"
    $Context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $Context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
    $Context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    Send-Response $Context $Status (ConvertTo-Json -InputObject $Object -Depth 20)
}

function Read-JsonBody {
    param($Request)
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return $raw | ConvertFrom-Json
}

function Pull-RemoteUpdates {
    $fetch = Invoke-GitRemote @("fetch", "--prune")
    $status = (git status --porcelain)
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return @{ pulled = $false; skipped = $true; reason = "Lokale Aenderungen vorhanden"; fetch = $fetch.output }
    }
    $pull = Invoke-GitRemote @("pull", "--ff-only")
    return @{ pulled = ($pull.exitCode -eq 0); skipped = $false; output = $pull.output; exitCode = $pull.exitCode }
}

function Get-Status {
    $repo = Get-RepoInfo
    $branch = (git branch --show-current 2>$null)
    $short = (git status -sb 2>$null) -join "`n"
    $porcelain = (git status --porcelain 2>$null)
    $env = Import-EnvFile
    $storagePath = Get-StoragePath $env
    $ahead = 0
    $behind = 0
    $counts = (git rev-list --left-right --count HEAD...@{u} 2>$null)
    if ($LASTEXITCODE -eq 0 -and $counts) {
        $parts = "$counts".Trim() -split "\s+"
        $ahead = [int]$parts[0]
        $behind = [int]$parts[1]
    }
    return @{ repo = $repo; branch = $branch; short = $short; dirty = -not [string]::IsNullOrWhiteSpace($porcelain); ahead = $ahead; behind = $behind; storage = @{ provider = if ($env["STORAGE_PROVIDER"]) { $env["STORAGE_PROVIDER"] } else { "local" }; path = $storagePath; shareUrl = $env["STORAGE_SHARE_URL"]; available = Test-Path -LiteralPath $storagePath } }
}

function Get-Log {
    $raw = git log --date=iso --max-count=80 --pretty=format:"%H%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%s" 2>$null
    $commits = @()
    foreach ($line in $raw) {
        $p = $line -split [char]31
        if ($p.Count -ge 6) {
            $commits += @{ hash = $p[0]; short = $p[1]; author = $p[2]; email = $p[3]; date = $p[4]; subject = $p[5] }
        }
    }
    return $commits
}

function Handle-Api {
    param($Context, [string]$Path)
    try {
        $method = $Context.Request.HttpMethod
        if ($method -eq "OPTIONS") { Send-Response $Context 204 "" "text/plain"; return }
        if ($Path -eq "/api/status") { Send-Json $Context (Get-Status); return }
        if ($Path -eq "/api/log") { Send-Json $Context (Get-Log); return }
        if ($Path -eq "/api/zotero/status" -and $method -eq "GET") { Send-Json $Context (Get-ZoteroStatus); return }
        if ($Path -eq "/api/zotero/items" -and $method -eq "GET") {
            $limit = 20
            [void][int]::TryParse("$($Context.Request.QueryString["limit"])", [ref]$limit)
            Send-Json $Context @(Get-ZoteroSearchResults "$($Context.Request.QueryString["q"])" $limit)
            return
        }
        if ($Path -eq "/api/pull" -and $method -eq "POST") { Send-Json $Context (Pull-RemoteUpdates); return }
        if ($Path -eq "/api/settings" -and $method -eq "GET") {
            $env = Import-EnvFile
            Send-Json $Context @{
                githubUsername = $env["GITHUB_USERNAME"]
                githubEmail = $env["GITHUB_EMAIL"]
                tokenSet = -not [string]::IsNullOrWhiteSpace($env["GITHUB_TOKEN"])
                webdavUrl = $env["WEBDAV_URL"]
                webdavUsername = $env["WEBDAV_USERNAME"]
                webdavPassword = $env["WEBDAV_PASSWORD"]
                storageProvider = if ($env["STORAGE_PROVIDER"]) { $env["STORAGE_PROVIDER"] } else { "local" }
                storagePath = Get-StoragePath $env
                storageShareUrl = $env["STORAGE_SHARE_URL"]
            }
            return
        }
        if ($Path -eq "/api/settings" -and $method -eq "POST") {
            $body = Read-JsonBody $Context.Request
            $env = Import-EnvFile
            if ($body.PSObject.Properties.Name -contains "githubUsername") { $env["GITHUB_USERNAME"] = "$($body.githubUsername)" }
            if ($body.PSObject.Properties.Name -contains "githubEmail") { $env["GITHUB_EMAIL"] = "$($body.githubEmail)" }
            if (($body.PSObject.Properties.Name -contains "githubToken") -and -not [string]::IsNullOrWhiteSpace("$($body.githubToken)")) { $env["GITHUB_TOKEN"] = "$($body.githubToken)" }
            $env["WEBDAV_URL"] = "$($body.webdavUrl)"
            $env["WEBDAV_USERNAME"] = "$($body.webdavUsername)"
            $env["WEBDAV_PASSWORD"] = "$($body.webdavPassword)"
            $env["STORAGE_PROVIDER"] = "$($body.storageProvider)"
            $env["ZOTERO_STORAGE_PATH"] = "$($body.storagePath)"
            $env["STORAGE_SHARE_URL"] = "$($body.storageShareUrl)"
            $storagePath = Ensure-StorageRoot $env
            Save-EnvFile $env
            if ($env["GITHUB_USERNAME"]) { git config user.name "$($env["GITHUB_USERNAME"])" | Out-Null }
            if ($env["GITHUB_EMAIL"]) { git config user.email "$($env["GITHUB_EMAIL"])" | Out-Null }
            Send-Json $Context @{ ok = $true; storagePath = $storagePath; restartRequired = $true }
            return
        }
        if ($Path -eq "/api/sync-log") {
            $logFile = Join-Path $ScriptDir ".sync-log.json"
            if (Test-Path $logFile) {
                try {
                    $entries = Get-Content $logFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    Send-Json $Context @($entries)
                } catch {
                    Send-Json $Context @()
                }
            } else {
                Send-Json $Context @()
            }
            return
        }
        if ($Path -eq "/api/commit" -and $method -eq "POST") {
            $body = Read-JsonBody $Context.Request
            $msg = if ("$($body.message)".Trim()) { "$($body.message)".Trim() } else { "Manueller Sync [$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]" }
            # Attachment storage is outside the repository; never stage the legacy data fallback either.
            git add -A -- . ":(exclude)data" | Out-Null
            $diffCheck = Invoke-Git @("diff", "--cached", "--quiet")
            if ($diffCheck.exitCode -eq 0) {
                Send-Json $Context @{ ok = $false; error = "Keine Aenderungen zum Committen vorhanden." } 400
                return
            }
            $commit = Invoke-Git @("commit", "-m", $msg)
            if ($commit.exitCode -ne 0) {
                Send-Json $Context @{ ok = $false; error = $commit.output } 400
                return
            }
            $pushed = $false
            if ($body.push -eq $true) {
                $pushResult = Invoke-GitRemote @("push")
                if ($pushResult.exitCode -ne 0) {
                    $pushResult = Invoke-GitRemote @("push", "-u", "origin", "HEAD")
                }
                $pushed = ($pushResult.exitCode -eq 0)
            }
            Send-Json $Context @{ ok = $true; message = $msg; pushed = $pushed }
            return
        }
        if ($Path -eq "/api/shutdown" -and $method -eq "POST") {
            Send-Json $Context @{ ok = $true }
            $script:listener.Stop()
            return
        }
        if ($Path -eq "/api/issues" -and $method -eq "GET") {
            $items = Invoke-GitHub "GET" "/issues?state=all&per_page=100"
            Send-Json $Context @($items | Where-Object { -not $_.pull_request })
            return
        }
        if ($Path -eq "/api/research/providers" -and $method -eq "GET") {
            Send-Json $Context @(Get-ResearchProviderCatalog)
            return
        }
        if ($Path -eq "/api/research/saved" -and $method -eq "GET") {
            Send-Json $Context @(Get-SavedResearchResults)
            return
        }
        if ($Path -eq "/api/research/saved" -and $method -eq "POST") {
            Send-Json $Context (Add-SavedResearchResult (Read-JsonBody $Context.Request)) 201
            return
        }
        if ($Path -match '^/api/research/saved/([a-f0-9]{40})$' -and $method -eq "DELETE") {
            Send-Json $Context (Remove-SavedResearchResult $matches[1])
            return
        }
        if ($Path -eq "/api/research/search" -and $method -eq "POST") {
            $request = New-ResearchRequest (Read-JsonBody $Context.Request)
            if (-not (Get-ResearchQueryText $request)) { throw "Bitte mindestens einen Suchbegriff, DOI, ISBN oder eine ISSN eingeben." }
            Send-Json $Context (Invoke-ResearchSearch $request)
            return
        }
        if ($Path -eq "/api/projects" -and $method -eq "GET") {
            $store = Get-ProjectStore
            $scope = [string]$Context.Request.QueryString.Get("scope")
            $projects = @($store.projects)
            if ($scope -eq "trash") {
                $projects = @($projects | Where-Object { $_.trashedAt })
            } elseif ($scope -eq "archived") {
                $projects = @($projects | Where-Object { -not $_.trashedAt -and $_.archivedAt })
            } elseif ($scope -ne "all") {
                $projects = @($projects | Where-Object { -not $_.trashedAt -and -not $_.archivedAt })
            }
            Send-Json $Context @($projects | ForEach-Object { Get-ProjectSummary $_ })
            return
        }
        if ($Path -eq "/api/projects" -and $method -eq "POST") {
            $body = Read-JsonBody $Context.Request
            Send-Json $Context (New-Project "$(Get-BodyValue $body 'name')" $body) 201
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/profile$" -and $method -eq "GET") {
            Send-Json $Context (Get-ProjectResearchProfile $matches[1])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/settings$" -and $method -eq "PATCH") {
            Send-Json $Context (Set-ProjectResearchSettings $matches[1] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/search$" -and $method -eq "POST") {
            $request = New-ResearchRequest (Read-JsonBody $Context.Request)
            if (-not (Get-ResearchQueryText $request)) { throw "Bitte mindestens einen Suchbegriff, DOI, ISBN oder eine ISSN eingeben." }
            Send-Json $Context (Invoke-ResearchSearch $request (Get-ProjectById $matches[1]))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/saved-searches$" -and $method -eq "GET") {
            Send-Json $Context @(Get-ProjectSavedResearchSearches $matches[1])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/saved-searches$" -and $method -eq "POST") {
            Send-Json $Context (Save-ProjectResearchSearch $matches[1] (Read-JsonBody $Context.Request)) 201
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/saved-searches/([a-f0-9]{32})$" -and $method -eq "DELETE") {
            Send-Json $Context (Remove-ProjectResearchSearch $matches[1] $matches[2])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})$" -and $method -eq "GET") {
            Send-Json $Context (Get-ProjectSummary (Get-ProjectById $matches[1]))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})$" -and $method -eq "PATCH") {
            Send-Json $Context (Set-ProjectDetails $matches[1] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/archive$" -and $method -eq "POST") {
            Send-Json $Context (Set-ProjectArchiveState $matches[1] $true)
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/restore$" -and $method -eq "POST") {
            Send-Json $Context (Restore-Project $matches[1])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/duplicate$" -and $method -eq "POST") {
            Send-Json $Context (Copy-Project $matches[1]) 201
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/zotero-collection$" -and $method -eq "POST") {
            Send-Json $Context (Set-ProjectZoteroCollection $matches[1] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/zotero-collection-items$" -and $method -eq "GET") {
            Send-Json $Context (Get-ZoteroProjectCollectionReferences (Get-ProjectById $matches[1]))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/zotero-collection/request$" -and $method -eq "POST") {
            Send-Json $Context (Request-ProjectZoteroSync $matches[1])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/research/import-zotero$" -and $method -eq "POST") {
            Send-Json $Context (Queue-ResearchResultForZotero $matches[1] (Read-JsonBody $Context.Request)) 202
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/zotero-imports/([a-f0-9]{32})/complete$" -and $method -eq "POST") {
            Send-Json $Context (Complete-ResearchResultZoteroImport $matches[1] $matches[2] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})$" -and $method -eq "DELETE") {
            $permanent = ([string]$Context.Request.QueryString.Get("permanent")) -eq "true"
            if ($permanent) {
                $deleteFiles = ([string]$Context.Request.QueryString.Get("deleteProjectFiles")) -eq "true"
                Send-Json $Context (Remove-ProjectPermanently $matches[1] $deleteFiles)
            } else {
                Send-Json $Context (Move-ProjectToTrash $matches[1])
            }
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/references$" -and $method -eq "POST") {
            Send-Json $Context (Add-ProjectReference $matches[1] (Read-JsonBody $Context.Request)) 201
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/references/([a-f0-9]{32})$" -and $method -eq "PATCH") {
            Send-Json $Context (Set-ProjectReference $matches[1] $matches[2] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/references/([a-f0-9]{32})$" -and $method -eq "DELETE") {
            Send-Json $Context (Remove-ProjectReference $matches[1] $matches[2])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/(todos|tasks)$" -and $method -eq "POST") {
            $body = Read-JsonBody $Context.Request
            Send-Json $Context (New-ProjectTodo $matches[1] $body) 201
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/(todos|tasks)/([a-f0-9]{32})/github-issue$" -and $method -eq "POST") {
            Send-Json $Context (Publish-ProjectTodoIssue $matches[1] $matches[3])
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/(todos|tasks)/([a-f0-9]{32})/comments$" -and $method -eq "POST") {
            Send-Json $Context (Add-ProjectTodoComment $matches[1] $matches[3] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/(todos|tasks)/([a-f0-9]{32})/checklist$" -and $method -eq "POST") {
            Send-Json $Context (Add-ProjectTodoChecklistItem $matches[1] $matches[3] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/(todos|tasks)/([a-f0-9]{32})/checklist/([a-f0-9]{32})$" -and $method -eq "PATCH") {
            Send-Json $Context (Set-ProjectTodoChecklistItem $matches[1] $matches[3] $matches[4] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/projects/([a-f0-9]{32})/(todos|tasks)/([a-f0-9]{32})$" -and $method -eq "PATCH") {
            Send-Json $Context (Set-ProjectTodo $matches[1] $matches[3] (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -eq "/api/issues" -and $method -eq "POST") {
            $body = Read-JsonBody $Context.Request
            $payload = @{ title = "$($body.title)" }
            if (-not [string]::IsNullOrWhiteSpace("$($body.body)")) { $payload["body"] = "$($body.body)" }
            Send-Json $Context (Invoke-GitHub "POST" "/issues" $payload)
            return
        }
        if ($Path -eq "/api/pulls") {
            Send-Json $Context (Invoke-GitHub "GET" "/pulls?state=all&per_page=50")
            return
        }
        if ($Path -match "^/api/issues/(\d+)$" -and $method -eq "PATCH") {
            Send-Json $Context (Invoke-GitHub "PATCH" "/issues/$($matches[1])" (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/pulls/(\d+)$" -and $method -eq "PATCH") {
            Send-Json $Context (Invoke-GitHub "PATCH" "/pulls/$($matches[1])" (Read-JsonBody $Context.Request))
            return
        }
        Send-Json $Context @{ error = "Not found" } 404
    }
    catch {
        Send-Json $Context @{ error = "$($_.Exception.Message)" } 500
    }
}

function Serve-File {
    param($Context, [string]$Path)
    if ($Path -eq "/") { $Path = "/index.html" }
    if ($Path -eq "/favicon.ico") { $Path = "/favicon.svg" }
    $relative = $Path.TrimStart("/") -replace "/", [IO.Path]::DirectorySeparatorChar
    $file = Join-Path $UiDir $relative
    if (-not (Test-Path $file)) { Send-Response $Context 404 "Not found" "text/plain"; return }
    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
    $type = switch ($ext) { ".html" { "text/html" } ".css" { "text/css" } ".js" { "application/javascript" } ".svg" { "image/svg+xml" } default { "text/plain" } }
    Send-Response $Context 200 (Get-Content -Raw -Encoding UTF8 $file) $type
}

$script:listener = New-Object Net.HttpListener
$prefix = "http://localhost:$Port/"
$script:listener.Prefixes.Add($prefix)
$script:listener.Start()
Write-Host "MyLiteratureVault UI laeuft: $prefix" -ForegroundColor Green
if ($OpenBrowser) { Start-Process $prefix }

try {
    while ($script:listener.IsListening) {
        try {
            $context = $script:listener.GetContext()
            $path = $context.Request.Url.AbsolutePath
            if ($path.StartsWith("/api/")) { Handle-Api $context $path } else { Serve-File $context $path }
        } catch [System.Net.HttpListenerException] {
            break
        }
    }
}
finally {
    if ($script:listener.IsListening) { $script:listener.Stop() }
}
