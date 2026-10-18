const state = {
  projects: [],
  archivedProjects: [],
  trashProjects: [],
  pulls: [],
  selectedProjectId: localStorage.getItem("myliteraturevault.selectedProjectId") || "",
  actionProjectId: "",
  zotero: { available: false },
  zoteroSearchResults: [],
  zoteroCollectionReferences: {},
  zoteroCollectionLoading: {},
  searchTimer: null,
  conceptTimer: null,
  selectedTaskId: "",
  researchProviders: [],
  researchResults: { global: null, project: null },
  researchRequests: { global: null, project: null },
  researchLoadingMore: { global: false, project: false },
  researchResultFilters: { global: { title: '', author: '', fromYear: '', toYear: '', provider: '', classification: '', sort: 'relevance' }, project: { title: '', author: '', fromYear: '', toYear: '', provider: '', classification: '', sort: 'relevance' } },
  savedResearchResults: [],
  savedTargetProjectId: localStorage.getItem("myliteraturevault.savedTargetProjectId") || "",
  savedResearchSearches: [],
  projectHistory: {},
  projectHistoryLoading: {},
  historyScope: {},
  historySelectedCommit: {},
  repositoryGraph: null,
  repositoryGraphSelectedCommit: "",
  zoteroImportDraft: null
};

const $ = (id) => document.getElementById(id);
const API_BASE = location.protocol === "http:" || location.protocol === "https:" ? "" : "http://localhost:8765";
const themeStorageKey = "myliteraturevault.theme";
const phaseLabels = { planning: "Konzept", research: "Recherche", writing: "Schreiben", review: "Überarbeitung", done: "Abgeschlossen" };
const taskStatusLabels = { open: "Offen", in_progress: "In Arbeit", blocked: "Blockiert", done: "Erledigt" };
const priorityLabels = { high: "Hoch", normal: "Normal", low: "Niedrig" };

function applyTheme(theme, { persist = true } = {}) {
  const activeTheme = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = activeTheme;
  if (persist) localStorage.setItem(themeStorageKey, activeTheme);
  $("brandWordmark").src = "assets/branding/wordmark-" + activeTheme + ".svg";
  $("siteFavicon").href = "assets/branding/icon-" + activeTheme + ".svg";
  $("themeColor").content = activeTheme === "light" ? "#f6f7f8" : "#080d14";
  $("themeToggle").setAttribute("aria-checked", String(activeTheme === "light"));
  $("themeToggle").title = activeTheme === "light" ? "Zum dunklen Design wechseln" : "Zum hellen Design wechseln";
  $("themeToggleLabel").textContent = activeTheme === "light" ? "Dunkles Design" : "Helles Design";
}

async function api(path, options = {}) {
  const response = await fetch(API_BASE + path, {
    headers: { "Content-Type": "application/json" },
    ...options
  });
  const raw = await response.text();
  const data = raw ? JSON.parse(raw) : {};
  if (!response.ok) throw new Error(data.error || "Anfrage fehlgeschlagen");
  return data;
}

function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function nl(value) { return esc(value).replaceAll("\n", "<br>"); }

function toast(message, kind = "") {
  const target = $("toast");
  target.textContent = message;
  target.className = "show " + kind;
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => { target.className = ""; }, 4200);
}

function formatDate(value) {
  if (!value) return "Ohne Termin";
  const parts = String(value).match(/^(\d{4})-(\d{2})-(\d{2})/);
  const date = parts ? new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3])) : new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : new Intl.DateTimeFormat("de-DE", { day: "2-digit", month: "short", year: "numeric" }).format(date);
}

function projectById(id = state.selectedProjectId) {
  return state.projects.find((project) => project.id === id) || state.archivedProjects.find((project) => project.id === id) || null;
}

function zoteroCollectionKey(project) {
  return String(project?.zotero?.collectionKey || "").trim().toUpperCase();
}

function collectionReferenceState(project) {
  return project ? state.zoteroCollectionReferences[project.id] || null : null;
}

function projectReferences(project) {
  const collection = collectionReferenceState(project);
  const merged = new Map();
  const addReference = (reference, kind, origin) => {
    const zoteroKey = String(reference?.zoteroKey || "").trim().toUpperCase();
    if (!zoteroKey) return;
    merged.set(zoteroKey, { ...reference, zoteroKey, kind: origin === "collection" ? kind : reference.kind || kind, origin });
  };

  (collection?.literature || []).forEach((reference) => addReference(reference, "literature", "collection"));
  (collection?.sources || []).forEach((reference) => addReference(reference, "source", "collection"));
  (project?.references || []).forEach((reference) => addReference(reference, reference.kind || "literature", "manual"));
  return Array.from(merged.values());
}

async function loadZoteroCollectionReferences(project) {
  const collectionKey = zoteroCollectionKey(project);
  if (!project || !collectionKey || state.zoteroCollectionLoading[project.id]) return;

  state.zoteroCollectionLoading[project.id] = true;
  try {
    const response = await api("/api/projects/" + project.id + "/zotero-collection-items");
    const collection = response && typeof response === "object" ? response : {};
    const fallbackReferences = Array.isArray(collection.references) ? collection.references : [];
    if (zoteroCollectionKey(projectById(project.id)) !== collectionKey) return;
    state.zoteroCollectionReferences[project.id] = {
      ...collection,
      collectionKey,
      literature: Array.isArray(collection.literature) ? collection.literature : fallbackReferences.filter((reference) => reference.kind === "literature"),
      sources: Array.isArray(collection.sources) ? collection.sources : fallbackReferences.filter((reference) => reference.kind === "source")
    };
  } catch (error) {
    if (zoteroCollectionKey(projectById(project.id)) !== collectionKey) return;
    state.zoteroCollectionReferences[project.id] = {
      collectionKey,
      ready: false,
      message: "Die Zotero-Projektsammlungen konnten nicht geladen werden: " + error.message,
      literature: [],
      sources: []
    };
  } finally {
    delete state.zoteroCollectionLoading[project.id];
    if (state.selectedProjectId === project.id) renderWorkspace();
  }
}

function setSelectedProject(id) {
  state.selectedProjectId = id || "";
  if (id) localStorage.setItem("myliteraturevault.selectedProjectId", id);
  else localStorage.removeItem("myliteraturevault.selectedProjectId");
}

function setView(name) {
  if (name === "workspace" && !projectById()) {
    if (state.projects[0]) setSelectedProject(state.projects[0].id);
    else {
      name = "overview";
      toast("Lege zuerst ein Forschungsprojekt an.");
    }
  }
  document.querySelectorAll(".nav").forEach((button) => button.classList.toggle("active", button.dataset.view === name));
  document.querySelectorAll(".view").forEach((view) => view.classList.remove("active"));
  $(name + "View").classList.add("active");
  const titles = {
    overview: ["FORSCHEN · ORDNEN · SCHREIBEN", "Forschungsübersicht"],
    research: ["WISSENSCHAFTLICHE METASUCHE", "Recherche"],
    workspace: ["PROJEKT-WORKSPACE", projectById()?.name || "Projekt-Workspace"],
    activity: ["NACHVOLLZIEHBARKEIT", "Code & Speicher-Aktivität"],
    pulls: ["CODE-KOLLABORATION", "Pull Requests"],
    archive: ["ARCHIV", "Abgeschlossene Projekte"],
    trash: ["PAPIERKORB", "Gelöschte Projekte"]
  };
  $("viewEyebrow").textContent = titles[name][0];
  $("viewTitle").textContent = titles[name][1];
  if (name === "workspace") renderWorkspace();
  if (name === "activity") loadActivity().catch((error) => toast(error.message, "error"));
  if (name === "pulls") loadPulls().catch((error) => toast(error.message, "error"));
  if (name === "trash") loadTrash().catch((error) => toast(error.message, "error"));
  if (name === "archive") loadArchive().catch((error) => toast(error.message, "error"));
}

function progressRing(progress, label = "Fortschritt") {
  const safeProgress = Math.max(0, Math.min(100, Number(progress) || 0));
  return '<div class="progress-ring" style="--progress:' + safeProgress + '%" aria-label="' + esc(label) + ': ' + safeProgress + ' Prozent"><div><strong>' + safeProgress + '%</strong><span>' + esc(label) + '</span></div></div>';
}

function projectTable(projects, { trash = false, archived = false } = {}) {
  if (!projects.length) return '<div class="empty-project"><h2>' + (trash ? "Papierkorb ist leer" : archived ? "Archiv ist leer" : "Noch keine aktiven Projekte") + '</h2><p>' + (trash ? "Gelöschte Projekte können hier wiederhergestellt oder endgültig entfernt werden." : archived ? "Archivierte Projekte erscheinen hier und bleiben vollständig lesbar." : "Lege ein Forschungsprojekt an, um Forschungsfrage, Literatur, Notizen und Aufgaben an einem Ort zu verwalten.") + '</p>' + (trash || archived ? "" : '<button type="button" class="primary-btn" data-new-project>Neues Projekt</button>') + '</div>';
  return '<div class="project-table-wrap"><table class="project-table"><thead><tr><th>Projekt</th><th>Status</th><th>Forschungsfrage</th><th>Aufgaben</th><th>Nächste Aufgabe</th><th>Frist</th><th>Zuletzt bearbeitet</th><th><span class="sr-only">Aktionen</span></th></tr></thead><tbody>' + projects.map((project) => {
    const tasks = project.tasks || project.todos || [];
    const nextTask = tasks.find((task) => task.status !== "done")?.title || "Keine offene Aufgabe";
    const details = [project.projectType, project.subject].filter(Boolean).join(" · ") || "Ohne Einordnung";
    const action = trash
      ? '<button type="button" class="text-btn" data-restore-project="' + project.id + '">Wiederherstellen</button><button type="button" class="icon-button small" title="Endgültig löschen" data-permanent-delete-project="' + project.id + '">×</button>'
      : archived
        ? '<button type="button" class="text-btn" data-restore-project="' + project.id + '">Wiederherstellen</button><button type="button" class="text-btn" data-open-project="' + project.id + '">Öffnen</button>'
      : '<button type="button" class="text-btn" data-open-project="' + project.id + '">Öffnen</button><button type="button" class="icon-button small" title="Projektaktionen" data-project-actions="' + project.id + '">⋯</button>';
    const question = project.researchQuestion || project.researchConcept?.question || "Noch nicht formuliert";
    return '<tr tabindex="0" data-open-project-row="' + project.id + '"><td><strong>' + esc(project.name) + '</strong><small>' + esc(details) + '</small></td><td><span class="state">' + esc(phaseLabels[project.status] || project.status) + '</span></td><td class="question-preview">' + esc(question) + '</td><td><strong>' + (project.todoCount || tasks.length || 0) + '</strong><small>' + (project.openTodoCount || 0) + ' offen</small></td><td>' + esc(nextTask) + '</td><td>' + esc(project.deadline ? formatDate(project.deadline) : "—") + '</td><td>' + esc(formatDate(project.updatedAt)) + '</td><td class="row-actions">' + action + '</td></tr>';
  }).join("") + '</tbody></table></div>';
}

function renderProjects() {
  const target = $("projectsList");
  if (!state.projects.length) {
    target.innerHTML = projectTable([]);
  } else target.innerHTML = projectTable(state.projects);
  renderSidebarProjects();
}

function renderTrash() { $("trashList").innerHTML = projectTable(state.trashProjects, { trash: true }); }
function renderArchive() { $("archiveList").innerHTML = projectTable(state.archivedProjects, { archived: true }); }

function renderSidebarProjects() {
  const target = $("sidebarProjects");
  if (!state.projects.length) {
    target.innerHTML = '<p class="side-empty">Noch kein Projekt</p>';
    return;
  }
  target.innerHTML = state.projects.map((project) =>
    '<button type="button" class="side-project ' + (project.id === state.selectedProjectId ? "selected" : "") + '" data-open-project="' + project.id + '"><span class="side-project-dot phase-dot-' + esc(project.status) + '"></span><span>' + esc(project.name) + '</span></button>'
  ).join("");
}

function providerChoices(scope) {
  if (!state.researchProviders.length) return '<span class="hint">Quellen werden geladen …</span>';
  return state.researchProviders.map((provider) => provider.enabled
    ? '<label class="provider-choice"><input type="checkbox" name="providers" value="' + esc(provider.id) + '" checked> ' + esc(provider.name) + '</label>'
    : '<a class="provider-choice disabled" href="' + esc(provider.searchUrl) + '" target="_blank" rel="noreferrer" title="' + esc(provider.message) + '">' + esc(provider.name) + ' ↗</a>'
  ).join("");
}

function providerMark(provider) {
  const marks = { openalex: 'OA', crossref: 'CR', dnb: 'DNB', thulb: 'ThULB' };
  const key = String(provider || '').toLowerCase();
  return '<span class="provider-mark provider-' + esc(key) + '" title="Quelle: ' + esc(provider) + '">' + esc(marks[key] || provider) + '</span>';
}

function researchResultCard(result, scope) {
  const authors = (result.authors || []).join(", ");
  const score = Number(result.relevance?.score || 0);
  const relevance = result.relevance
    ? '<div class="relevance-summary"><span class="relevance-score">Relevanz ' + esc(score) + '/100</span><span class="relevance-bar" role="img" aria-label="Relevanz ' + esc(score) + ' von 100"><i style="width:' + Math.max(0, Math.min(100, score)) + '%"></i></span></div>'
    : '';
  const urls = result.fulltextUrl || result.sourceUrl;
  const provider = (result.providers || [result.provider]).join(" · ");
  const relevanceDetails = result.relevance
    ? '<details class="relevance-explanation"><summary>' + esc(result.relevance.label) + ' · Begründung</summary><p class="hint">' + esc(result.relevance.explanation) + '</p><ul>' + (result.relevance.fields || []).map((field) => '<li><strong>' + esc(field.label) + ' (' + esc(field.weight) + ' %):</strong> ' + esc((field.matches || []).join(', ') || 'keine direkten Begriffstreffer') + (field.overlap !== undefined ? ' <span>' + esc(field.overlap) + ' % Feldübereinstimmung</span>' : '') + '</li>').join('') + '</ul>' + ((result.relevance.missingFields || []).length ? '<p class="hint">Nicht vorhanden: ' + esc((result.relevance.missingFields || []).map((field) => ({ title: 'Titel', abstract: 'Abstract', keywords: 'Schlagwörter', subject: 'Projektkontext' }[field] || field)).join(', ')) + '.</p>' : '') + '</details>'
    : '';
  const classification = result.classification;
  const classificationLabel = { source: 'Primärquelle', literature: 'Sekundärliteratur', unclear: 'Unklar' }[classification?.category] || 'Unklar';
  const classificationTag = classification ? '<span class="classification-tag ' + esc(classification.category) + '" title="' + esc(classification.reason || '') + '">' + esc(classificationLabel) + (classification.origin === 'manual' ? ' · manuell' : classification.confidence === 'low' ? ' · unsicher' : '') + '</span>' : '';
  const classificationInfo = classification ? '<p class="classification-reason">' + esc(classification.reason || '') + (classification.signals?.length ? ' ' + esc(classification.signals.join(' ')) : '') + '</p>' : '';
  const bookmarked = state.savedResearchResults.some((entry) => entry.resultId === result.resultId);
  const bookmark = '<button type="button" class="bookmark-button' + (bookmarked ? ' saved' : '') + '" data-toggle-saved-research="' + esc(result.resultId) + '" aria-pressed="' + bookmarked + '" title="' + (bookmarked ? 'Aus Merkliste entfernen' : 'In Merkliste speichern') + '"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.75 3.75h10.5v16.5L12 17.1l-5.25 3.15z"/></svg><span class="sr-only">' + (bookmarked ? 'Aus Merkliste entfernen' : 'In Merkliste speichern') + '</span></button>';
  const importAction = scope === 'project'
    ? '<button type="button" class="primary-btn" data-import-zotero="' + esc(result.resultId) + '" data-import-kind="' + esc(classification?.category === 'source' ? 'source' : 'literature') + '">Zu Zotero</button>'
    : scope === 'saved' && state.projects.length
      ? '<button type="button" class="secondary-btn" data-import-saved-zotero="' + esc(result.resultId) + '" data-import-kind="source">Quelle → Zotero</button><button type="button" class="primary-btn" data-import-saved-zotero="' + esc(result.resultId) + '" data-import-kind="literature">Literatur → Zotero</button>'
      : '';
  const manualActions = scope === 'project'
    ? '<div class="classification-actions" aria-label="Manuelle Zuordnung"><span>Zuordnen:</span><button type="button" class="quiet-btn" data-set-research-classification="' + esc(result.resultId) + '" data-classification-category="source">Quelle</button><button type="button" class="quiet-btn" data-set-research-classification="' + esc(result.resultId) + '" data-classification-category="literature">Literatur</button></div>'
    : '';
  const actions = '<div class="research-result-actions">' + bookmark + '<button type="button" class="secondary-btn" data-research-detail="' + esc(result.resultId) + '">Infos</button>' + (urls ? '<a class="secondary-btn" href="' + esc(urls) + '" target="_blank" rel="noreferrer">Original ↗</a>' : '') + importAction + '</div>';
  return '<article class="research-result">' + providerMark(result.provider) + '<div class="research-result-main"><span class="source-key">' + esc(provider) + '</span>' + relevance + classificationTag + '<h3>' + esc(result.title) + '</h3><p>' + esc([authors, result.publicationYear, result.publicationType].filter(Boolean).join(" · ")) + '</p>' + classificationInfo + relevanceDetails + manualActions + '</div>' + actions + '</article>';
}

function normalizedResearchText(value) {
  return String(value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLocaleLowerCase('de-DE');
}

function filteredResearchResults(scope, results) {
  const filters = state.researchResultFilters[scope];
  const titleNeedle = normalizedResearchText(filters.title);
  const authorNeedle = normalizedResearchText(filters.author);
  const provider = String(filters.provider || '').toLowerCase();
  const classification = String(filters.classification || '');
  const fromYear = Number(filters.fromYear || 0);
  const toYear = Number(filters.toYear || 0);
  const visible = (results || []).filter((result) => {
    const year = Number(result.publicationYear || 0);
    const providers = (result.providers || [result.provider]).map((entry) => String(entry).toLowerCase());
    return (!titleNeedle || normalizedResearchText(result.title).includes(titleNeedle))
      && (!authorNeedle || normalizedResearchText((result.authors || []).join(' ')).includes(authorNeedle))
      && (!provider || providers.includes(provider))
      && (!classification || String(result.classification?.category || 'unclear') === classification)
      && (!fromYear || (year && year >= fromYear))
      && (!toYear || (year && year <= toYear));
  });
  const compareText = (left, right) => normalizedResearchText(left).localeCompare(normalizedResearchText(right), 'de-DE', { sensitivity: 'base' });
  return visible.sort((left, right) => {
    if (filters.sort === 'title') return compareText(left.title, right.title);
    if (filters.sort === 'author') return compareText((left.authors || []).join(' '), (right.authors || []).join(' ')) || compareText(left.title, right.title);
    if (filters.sort === 'year-asc') return Number(left.publicationYear || 0) - Number(right.publicationYear || 0) || compareText(left.title, right.title);
    if (filters.sort === 'year-desc') return Number(right.publicationYear || 0) - Number(left.publicationYear || 0) || compareText(left.title, right.title);
    if (filters.sort === 'provider') return compareText((left.providers || [left.provider]).join(', '), (right.providers || [right.provider]).join(', ')) || compareText(left.title, right.title);
    return 0;
  });
}

function researchResultFilterControls(scope, results) {
  const filters = state.researchResultFilters[scope];
  const providers = [...new Set((results || []).flatMap((result) => result.providers || [result.provider]).filter(Boolean))].sort((left, right) => String(left).localeCompare(String(right), 'de-DE'));
  const bind = (name) => 'data-research-result-filter="' + scope + '" name="' + name + '"';
  const classificationFilter = scope === 'project' ? '<label>Bereich<select ' + bind('classification') + '><option value="">Alle Bereiche</option><option value="source"' + (filters.classification === 'source' ? ' selected' : '') + '>Quellen</option><option value="literature"' + (filters.classification === 'literature' ? ' selected' : '') + '>Literatur</option><option value="unclear"' + (filters.classification === 'unclear' ? ' selected' : '') + '>Unklar</option></select></label>' : '';
  return '<div class="research-result-filters" aria-label="Trefferliste filtern"><label>Titel<input ' + bind('title') + ' value="' + esc(filters.title) + '" placeholder="Titel filtern …"></label><label>Autor:in<input ' + bind('author') + ' value="' + esc(filters.author) + '" placeholder="Name suchen …"></label><label>Jahr ab<input ' + bind('fromYear') + ' type="number" min="1000" max="2999" value="' + esc(filters.fromYear) + '" placeholder="z. B. 1900"></label><label>bis<input ' + bind('toYear') + ' type="number" min="1000" max="2999" value="' + esc(filters.toYear) + '" placeholder="z. B. 2026"></label><label>Provider<select ' + bind('provider') + '><option value="">Alle Quellen</option>' + providers.map((entry) => '<option value="' + esc(entry) + '"' + (String(filters.provider) === String(entry) ? ' selected' : '') + '>' + esc(entry) + '</option>').join('') + '</select></label>' + classificationFilter + '<label>Sortieren<select ' + bind('sort') + '><option value="relevance"' + (filters.sort === 'relevance' ? ' selected' : '') + '>Relevanz 0–100</option><option value="title"' + (filters.sort === 'title' ? ' selected' : '') + '>Titel A–Z</option><option value="author"' + (filters.sort === 'author' ? ' selected' : '') + '>Autor:in A–Z</option><option value="year-desc"' + (filters.sort === 'year-desc' ? ' selected' : '') + '>Jahr absteigend</option><option value="year-asc"' + (filters.sort === 'year-asc' ? ' selected' : '') + '>Jahr aufsteigend</option><option value="provider"' + (filters.sort === 'provider' ? ' selected' : '') + '>Provider A–Z</option></select></label><button type="button" class="quiet-btn" data-clear-research-result-filters="' + scope + '">Filter zurücksetzen</button></div>';
}

function classifiedResearchResultList(scope, results) {
  if (scope !== 'project') return results.map((result) => researchResultCard(result, scope)).join('');
  const groups = [
    ['source', 'Quellen', 'Primärquellen und historische Dokumente'],
    ['literature', 'Literatur', 'Sekundärliteratur und Forschung'],
    ['unclear', 'Unklar', 'Für diese Treffer reichen die Metadaten nicht für eine sichere Zuordnung']
  ];
  return groups.map(([category, title, hint]) => {
    const entries = results.filter((result) => String(result.classification?.category || 'unclear') === category);
    if (!entries.length) return '';
    return '<section class="research-classification-group ' + category + '"><header><div><h3>' + title + '</h3><p>' + hint + '</p></div><span>' + entries.length + '</span></header>' + entries.map((result) => researchResultCard(result, scope)).join('') + '</section>';
  }).join('');
}

function renderResearch(scope, response) {
  const status = document.querySelector('[data-research-status="' + scope + '"]');
  const target = document.querySelector('[data-research-results="' + scope + '"]');
  if (!status || !target) return;
  if (!response) { status.textContent = "Noch keine Suche ausgeführt."; target.innerHTML = ""; return; }
  const total = Number(response.totalAvailable || 0);
  const loaded = (response.results || []).length;
  const visibleResults = filteredResearchResults(scope, response.results || []);
  const providers = (response.providers || []).map((provider) => {
    if (provider.status === 'error') return provider.name + ': Fehler';
    return provider.name + ': ' + provider.count + ' geladen / ' + Number(provider.total || 0).toLocaleString('de-DE');
  }).join(' · ');
  const totalText = total ? total.toLocaleString('de-DE') + ' Roh-Treffer in aktivierten Datenbanken' : loaded + ' Treffer';
  status.textContent = (response.cached ? 'Zwischengespeicherte' : 'Live-') + 'Ergebnisse: ' + visibleResults.length + ' von ' + loaded + ' angezeigt · ' + totalText + '. ' + providers;
  const errors = (response.errors || []).map((error) => '<p class="hint error-copy">' + esc(error.provider + ': ' + error.message) + '</p>').join("");
  const more = response.hasMore
    ? '<div class="research-more"><p class="hint">Die Datenbanken melden weitere Treffer. Die Liste wird seitenweise erweitert.</p><button type="button" class="secondary-btn" data-load-more-research="' + esc(scope) + '"' + (state.researchLoadingMore[scope] ? ' disabled' : '') + '>' + (state.researchLoadingMore[scope] ? 'Weitere Treffer werden geladen …' : 'Weitere Treffer laden') + '</button></div>'
    : '<p class="hint research-end">Alle von den aktivierten Datenbanken erreichbaren Trefferseiten wurden geladen.</p>';
  target.innerHTML = researchResultFilterControls(scope, response.results || []) + errors + (visibleResults.length ? classifiedResearchResultList(scope, visibleResults) : '<p class="empty-mini">Keine Treffer mit den gewählten Filtern.</p>') + more;
}

function researchResultById(resultId) {
  return Object.values(state.researchResults).flatMap((response) => response?.results || []).concat(state.savedResearchResults).find((result) => result.resultId === resultId) || null;
}

function renderSavedResearchResults() {
  const target = $('savedResearchPanel');
  if (!target) return;
  const projects = state.projects || [];
  if (!projects.some((project) => project.id === state.savedTargetProjectId)) state.savedTargetProjectId = projects[0]?.id || '';
  const options = projects.length
    ? projects.map((project) => '<option value="' + esc(project.id) + '"' + (project.id === state.savedTargetProjectId ? ' selected' : '') + '>' + esc(project.name) + '</option>').join('')
    : '<option value="">Zuerst ein Projekt anlegen</option>';
  const results = state.savedResearchResults || [];
  target.innerHTML = '<section class="saved-research-panel panel-card"><header><div><p class="eyebrow">MERKLISTE</p><h2>Für später gespeichert</h2><p class="hint">Die Metadaten und Original- bzw. Volltext-URLs bleiben lokal im synchronisierten Projektordner. Wähle ein Projekt für den Zotero-Import.</p></div><span class="saved-result-count">' + results.length + '</span></header><div class="saved-research-toolbar"><label>Projekt für Import<select data-saved-project-select' + (projects.length ? '' : ' disabled') + '>' + options + '</select></label></div><div class="research-results">' + (results.length ? results.map((result) => researchResultCard(result, 'saved')).join('') : '<p class="empty-mini">Noch keine Treffer gemerkt. Nutze das Lesezeichen an einem Recherchetreffer.</p>') + '</div></section>';
}

async function loadSavedResearchResults() {
  state.savedResearchResults = await api('/api/research/saved');
  renderSavedResearchResults();
}

function renderResearchBookmarks() {
  Object.entries(state.researchResults).forEach(([scope, response]) => { if (response) renderResearch(scope, response); });
  renderSavedResearchResults();
}

async function toggleSavedResearchResult(resultId) {
  const existing = state.savedResearchResults.find((result) => result.resultId === resultId);
  if (existing) {
    await api('/api/research/saved/' + encodeURIComponent(resultId), { method: 'DELETE' });
    state.savedResearchResults = state.savedResearchResults.filter((result) => result.resultId !== resultId);
    toast('Treffer aus der Merkliste entfernt.');
  } else {
    const result = researchResultById(resultId);
    if (!result) throw new Error('Der Recherchetreffer ist nicht mehr verfügbar.');
    const saved = await api('/api/research/saved', { method: 'POST', body: JSON.stringify({ result }) });
    state.savedResearchResults = [saved, ...state.savedResearchResults.filter((entry) => entry.resultId !== saved.resultId)];
    toast('Treffer in der Merkliste gespeichert.');
  }
  renderResearchBookmarks();
}

function zoteroItemTypeForResearchResult(publicationType) {
  const type = String(publicationType || '').toLowerCase();
  if (type.includes('journal') || type.includes('article')) return 'journalArticle';
  if (type.includes('chapter') || type.includes('book section')) return 'bookSection';
  if (type.includes('book') || type.includes('monograph')) return 'book';
  if (type.includes('thesis') || type.includes('dissertation')) return 'thesis';
  if (type.includes('report')) return 'report';
  if (type.includes('web')) return 'webpage';
  return 'document';
}

function splitMetadataList(value, separator = /[,;\n]/) {
  return String(value || '').split(separator).map((entry) => entry.trim()).filter(Boolean);
}

function openZoteroImportDialog(result, kind, project) {
  if (!result || !project) throw new Error('Für den Zotero-Import fehlen Treffer oder Zielprojekt.');
  state.zoteroImportDraft = { result: { ...result }, projectId: project.id };
  $('zoteroImportForm').reset();
  $('zoteroImportProject').textContent = 'Zielprojekt: ' + project.name;
  $('zoteroImportKind').value = kind === 'source' ? 'source' : 'literature';
  $('zoteroImportItemType').value = zoteroItemTypeForResearchResult(result.publicationType);
  $('zoteroImportTitle').value = result.title || '';
  $('zoteroImportAuthors').value = (result.authors || []).join('; ');
  $('zoteroImportDate').value = result.publicationYear || result.sourceDate || '';
  $('zoteroImportPublisher').value = result.publisher || '';
  $('zoteroImportLanguage').value = result.language || '';
  $('zoteroImportDoi').value = result.doi || '';
  $('zoteroImportIsbn').value = (result.isbn || []).join(', ');
  $('zoteroImportIssn').value = (result.issn || []).join(', ');
  $('zoteroImportVolume').value = result.volume || '';
  $('zoteroImportIssue').value = result.issue || '';
  $('zoteroImportPages').value = result.pages || '';
  $('zoteroImportSourceUrl').value = result.sourceUrl || '';
  $('zoteroImportFulltextUrl').value = result.fulltextUrl || '';
  $('zoteroImportKeywords').value = (result.keywords || []).join(', ');
  $('zoteroImportAbstract').value = result.abstract || '';
  $('zoteroImportDialog').showModal();
  window.setTimeout(() => $('zoteroImportTitle').focus(), 30);
}

async function submitZoteroImport(event) {
  event.preventDefault();
  const draft = state.zoteroImportDraft;
  const project = state.projects.find((entry) => entry.id === draft?.projectId);
  if (!draft || !project) throw new Error('Der Importentwurf ist nicht mehr verfügbar.');
  const result = {
    ...draft.result,
    title: $('zoteroImportTitle').value.trim(),
    itemType: $('zoteroImportItemType').value,
    authors: splitMetadataList($('zoteroImportAuthors').value, /[;\n]/),
    publicationYear: $('zoteroImportDate').value.trim(),
    publisher: $('zoteroImportPublisher').value.trim(),
    language: $('zoteroImportLanguage').value.trim(),
    doi: $('zoteroImportDoi').value.trim(),
    isbn: splitMetadataList($('zoteroImportIsbn').value),
    issn: splitMetadataList($('zoteroImportIssn').value),
    volume: $('zoteroImportVolume').value.trim(),
    issue: $('zoteroImportIssue').value.trim(),
    pages: $('zoteroImportPages').value.trim(),
    sourceUrl: $('zoteroImportSourceUrl').value.trim(),
    fulltextUrl: $('zoteroImportFulltextUrl').value.trim(),
    keywords: splitMetadataList($('zoteroImportKeywords').value),
    abstract: $('zoteroImportAbstract').value.trim()
  };
  if (!result.title) throw new Error('Bitte einen Titel für den Zotero-Eintrag angeben.');
  const submit = event.submitter;
  if (submit) submit.disabled = true;
  try {
    const imported = await api('/api/projects/' + project.id + '/research/import-zotero', { method: 'POST', body: JSON.stringify({ kind: $('zoteroImportKind').value, result }) });
    $('zoteroImportDialog').close();
    state.zoteroImportDraft = null;
    await api('/api/projects/' + project.id + '/zotero-collection/request', { method: 'POST', body: '{}' });
    await loadProjects();
    toast(imported.created ? 'Direkt in Zotero angelegt (' + imported.zoteroKey + '). Der nächste Zotero-Abgleich ordnet den Eintrag dem Projekt zu.' : imported.message || 'Zotero-Eintrag verknüpft.');
  } finally {
    if (submit) submit.disabled = false;
  }
}

async function importSavedResearchResultToZotero(resultId, kind) {
  const project = state.projects.find((entry) => entry.id === state.savedTargetProjectId);
  const result = state.savedResearchResults.find((entry) => entry.resultId === resultId);
  if (!project) throw new Error('Bitte wähle ein Projekt für den Zotero-Import.');
  if (!result) throw new Error('Der gemerkte Treffer wurde nicht gefunden.');
  openZoteroImportDialog(result, kind, project);
}

function openResearchDetail(resultId) {
  const result = researchResultById(resultId);
  if (!result) return;
  const meta = [
    ['Autor:innen', (result.authors || []).join('; ')], ['Erscheinungsjahr', result.publicationYear], ['Entstehungsjahr des Dokuments', result.sourceYear || result.sourceDate], ['Typ', result.publicationType], ['Einordnung', result.classification ? ({ source: 'Primärquelle', literature: 'Sekundärliteratur', unclear: 'Unklar' }[result.classification.category] || 'Unklar') + (result.classification.origin === 'manual' ? ' (manuell)' : '') : ''], ['Quelle', (result.providers || [result.provider]).join(', ')], ['DOI', result.doi], ['ISBN', (result.isbn || []).join(', ')], ['ISSN', (result.issn || []).join(', ')], ['Sprache', result.language], ['Verlag / Journal', result.publisher], ['Bestand / Verfügbarkeit', result.availability], ['Open Access', result.openAccessStatus]
  ].filter(([, value]) => value);
  $('researchDetailTitle').textContent = result.title;
  $('researchDetailBody').innerHTML = '<dl class="metadata-list">' + meta.map(([label, value]) => '<div><dt>' + esc(label) + '</dt><dd>' + esc(value) + '</dd></div>').join('') + '</dl>' + (result.abstract ? '<section><h3>Abstract</h3><p>' + nl(result.abstract) + '</p></section>' : '') + (result.keywords?.length ? '<section><h3>Schlagwörter</h3><p>' + esc(result.keywords.join(', ')) + '</p></section>' : '');
  $('researchDetailActions').innerHTML = (result.sourceUrl || result.fulltextUrl ? '<a class="secondary-btn" target="_blank" rel="noreferrer" href="' + esc(result.fulltextUrl || result.sourceUrl) + '">Original öffnen ↗</a>' : '') + (projectById() ? '<button type="button" class="secondary-btn" data-import-zotero="' + esc(result.resultId) + '" data-import-kind="source">Als Quelle nach Zotero</button><button type="button" class="primary-btn" data-import-zotero="' + esc(result.resultId) + '" data-import-kind="literature">Als Literatur nach Zotero</button>' : '');
  $('researchDetailDialog').showModal();
}

async function importResearchResultToZotero(resultId, kind) {
  const project = projectById();
  const result = researchResultById(resultId);
  if (!project || !result) throw new Error('Bitte öffne zuerst ein Forschungsprojekt.');
  $('researchDetailDialog').close();
  openZoteroImportDialog(result, kind, project);
}

async function setResearchClassification(resultId, category) {
  const project = projectById();
  if (!project) throw new Error('Bitte öffne zuerst ein Forschungsprojekt.');
  await api('/api/projects/' + project.id + '/research/classifications/' + encodeURIComponent(resultId), { method: 'PATCH', body: JSON.stringify({ category }) });
  const response = state.researchResults.project;
  const result = response?.results?.find((entry) => entry.resultId === resultId);
  if (result) {
    result.classification = { ...(result.classification || {}), category, origin: 'manual', confidence: 'manual', reason: 'Manuell für dieses Projekt zugeordnet.', signals: ['Manuelle Entscheidung hat Vorrang.'] };
  }
  await api('/api/projects/' + project.id + '/zotero-collection/request', { method: 'POST', body: '{}' });
  await loadProjects();
  renderResearch('project', state.researchResults.project);
  toast('Manuelle Zuordnung gespeichert. Bestehende Zotero-Verknüpfungen werden beim nächsten Plugin-Abgleich verschoben.');
}

function projectResearchPanel(project) {
  const saved = state.savedResearchSearches || project.savedResearchSearches || [];
  const weights = project.researchSettings?.weights || { title: 30, abstract: 40, keywords: 20, subject: 10 };
  const cutoffYear = project.researchSettings?.classification?.cutoffYear || 1945;
  return '<section class="research-panel panel-card"><header><div><p class="eyebrow">LITERATURRECHERCHE</p><h3>Projektbezogen recherchieren</h3><p class="hint">Der Score nutzt direkte Wortübereinstimmungen aus Forschungsprofil und Metadaten; er ist keine Trefferwahrscheinlichkeit. Quellen bis ' + esc(cutoffYear) + ' werden nur heuristisch eingeordnet.</p></div></header><form data-research-form="project" class="research-form"><div class="research-query-row"><input name="query" required placeholder="Suchbegriffe, Boolesche Operatoren oder DOI …"><label class="result-limit">Treffer<select name="limit"><option value="25">25</option><option value="50" selected>50</option><option value="100">100</option></select></label><button class="primary-btn" type="submit">Suchen</button><button class="secondary-btn" type="button" data-save-research>Suche speichern</button></div><div class="research-provider-list" data-research-providers="project">' + providerChoices('project') + '</div></form><details class="research-settings"><summary>Relevanzkriterien</summary><div class="form-three"><label>Titel %<input data-research-weight="title" type="number" min="0" value="' + esc(weights.title) + '"></label><label>Abstract %<input data-research-weight="abstract" type="number" min="0" value="' + esc(weights.abstract) + '"></label><label>Schlagwörter %<input data-research-weight="keywords" type="number" min="0" value="' + esc(weights.keywords) + '"></label><label>Projektkontext %<input data-research-weight="subject" type="number" min="0" value="' + esc(weights.subject) + '"></label></div><button type="button" class="secondary-btn" data-save-research-settings>Gewichtung speichern</button></details><div class="research-suggestions">' + (project.tags || []).slice(0, 6).map((tag) => '<button type="button" class="quiet-btn" data-research-suggestion="' + esc(tag) + '">' + esc(tag) + '</button>').join("") + '</div><div class="research-status" data-research-status="project">Noch keine Suche ausgeführt.</div><div class="research-results" data-research-results="project"></div><div class="saved-searches"><strong>Gespeicherte Suchen</strong>' + (saved.length ? saved.map((entry) => '<button type="button" class="quiet-btn" data-run-saved-search="' + esc(entry.id) + '">' + esc(entry.label) + '</button>').join("") : '<span class="hint"> Noch keine.</span>') + '</div></section>';
}

async function loadResearchProviders() {
  state.researchProviders = await api('/api/research/providers');
  document.querySelectorAll('[data-research-providers="global"]').forEach((target) => { target.innerHTML = providerChoices('global'); });
  renderWorkspace();
}

function requestFromForm(form) {
  const formData = new FormData(form);
  const value = (name) => String(formData.get(name) || '').trim();
  return { query: value('query'), title: value('title'), author: value('author'), keywords: value('keywords'), doi: value('doi'), isbn: value('isbn'), issn: value('issn'), language: value('language'), fromYear: value('fromYear'), toYear: value('toYear'), limit: value('limit') || '50', offset: 0, sort: value('sort') || 'relevance', providers: formData.getAll('providers') };
}

async function runResearch(form) {
  const scope = form.dataset.researchForm;
  const request = requestFromForm(form);
  if (!request.query && !request.title && !request.author && !request.doi && !request.isbn && !request.issn) throw new Error('Bitte einen Suchbegriff oder Identifier eingeben.');
  const project = scope === 'project' ? projectById() : null;
  const path = project ? '/api/projects/' + project.id + '/research/search' : '/api/research/search';
  const response = await api(path, { method: 'POST', body: JSON.stringify(request) });
  state.researchResults[scope] = response;
  state.researchRequests[scope] = request;
  renderResearch(scope, response);
}

async function loadMoreResearch(scope) {
  const current = state.researchResults[scope];
  const previousRequest = state.researchRequests[scope];
  if (!current || !previousRequest || !current.hasMore || state.researchLoadingMore[scope]) return;
  const project = scope === 'project' ? projectById() : null;
  const path = project ? '/api/projects/' + project.id + '/research/search' : '/api/research/search';
  const nextRequest = { ...previousRequest, offset: Number(previousRequest.offset || 0) + Number(previousRequest.limit || 50) };
  state.researchLoadingMore[scope] = true;
  renderResearch(scope, current);
  try {
    const nextPage = await api(path, { method: 'POST', body: JSON.stringify(nextRequest) });
    const uniqueResults = new Map();
    [...(current.results || []), ...(nextPage.results || [])].forEach((result) => uniqueResults.set(result.resultId, result));
    state.researchResults[scope] = { ...nextPage, results: [...uniqueResults.values()] };
    state.researchRequests[scope] = nextRequest;
  } finally {
    state.researchLoadingMore[scope] = false;
    renderResearch(scope, state.researchResults[scope]);
  }
}

function updateResearchResultFilter(control) {
  const scope = control.dataset.researchResultFilter;
  if (!scope || !state.researchResultFilters[scope] || !control.name) return;
  state.researchResultFilters[scope][control.name] = control.value;
  const cursor = typeof control.selectionStart === 'number' ? control.selectionStart : null;
  renderResearch(scope, state.researchResults[scope]);
  const replacement = document.querySelector('[data-research-result-filter="' + scope + '"][name="' + control.name + '"]');
  if (replacement) {
    replacement.focus();
    if (cursor !== null && typeof replacement.setSelectionRange === 'function') replacement.setSelectionRange(cursor, cursor);
  }
}

function workspaceTaskCard(task, references) {
  const linked = (task.referenceKeys || []).map((key) => references.find((reference) => reference.zoteroKey === String(key || "").trim().toUpperCase())).filter(Boolean);
  const due = task.dueDate ? '<span class="task-due">◷ ' + esc(formatDate(task.dueDate)) + '</span>' : "";
  const issue = task.githubIssueUrl
    ? '<a class="issue-link" href="' + esc(task.githubIssueUrl) + '" target="_blank" rel="noreferrer">Issue #' + esc(task.githubIssueNumber) + ' ↗</a>'
    : '<button type="button" class="quiet-btn" data-publish-issue="' + task.id + '">Als GitHub-Issue veröffentlichen</button>';
  return '<article class="task-card priority-' + esc(task.priority) + '">' +
    '<div class="task-card-head"><span class="priority-tag ' + esc(task.priority) + '">' + esc(priorityLabels[task.priority] || "Normal") + '</span><button type="button" class="icon-button small" title="Aufgabe bearbeiten" data-edit-task="' + task.id + '">✎</button></div>' +
    '<button type="button" class="task-title-button" data-open-task="' + task.id + '"><span class="issue-number">#' + esc(task.issueNumber || "?") + '</span><span class="task-card-heading">' + esc(task.title) + '</span></button>' + (task.body ? '<p>' + nl(task.body) + '</p>' : '<p class="muted">Keine Beschreibung hinterlegt.</p>') +
    '<div class="task-reference-chips">' + linked.map((reference) => '<a href="zotero://select/library/items/' + esc(reference.zoteroKey) + '" title="In Zotero öffnen">' + esc(reference.title) + '</a>').join("") + '</div>' +
    '<div class="task-card-footer"><select aria-label="Status von ' + esc(task.title) + '" class="inline-select" data-task-status="' + task.id + '"><option value="open"' + (task.status === "open" ? " selected" : "") + '>Offen</option><option value="in_progress"' + (task.status === "in_progress" ? " selected" : "") + '>In Arbeit</option><option value="blocked"' + (task.status === "blocked" ? " selected" : "") + '>Blockiert</option><option value="done"' + (task.status === "done" ? " selected" : "") + '>Erledigt</option></select>' + due + '</div>' +
    '<div class="task-remote">' + issue + '</div>' +
  '</article>';
}

function taskColumn(project, references, status, title, hint) {
  const tasks = (project.tasks || project.todos || []).filter((task) => task.status === status);
  return '<section class="task-column status-' + status + '"><header><div><span class="column-dot"></span><h4>' + title + '</h4></div><span>' + tasks.length + '</span></header><p class="column-hint">' + hint + '</p><div class="task-list">' + (tasks.length ? tasks.map((task) => workspaceTaskCard(task, references)).join("") : '<p class="empty-mini">Keine Aufgaben.</p>') + '</div></section>';
}

function sourceShelf(project, allReferences, kind, label, icon, collectionState, collectionLoading) {
  const references = allReferences.filter((reference) => reference.kind === kind);
  const cards = references.length ? references.map((reference) => {
    const metadata = [reference.creators, reference.year, reference.itemType].filter(Boolean).join(" · ");
    const external = reference.doi ? "https://doi.org/" + encodeURIComponent(reference.doi.replace(/^https?:\/\/(dx\.)?doi\.org\//i, "")) : reference.url;
    const action = reference.origin === "collection"
      ? '<span class="source-key" title="Direkt aus der Zotero-Projektsammlung gelesen">Projekt-Sammlung</span>'
      : '<button type="button" class="icon-button small" title="Verknüpfung aus Projekt entfernen" data-remove-reference="' + esc(reference.id) + '">×</button>';
    return '<article class="source-card"><div class="source-card-head"><span class="source-key">' + esc(reference.zoteroKey) + '</span>' + action + '</div><h4>' + esc(reference.title) + '</h4><p>' + esc(metadata || "Zotero-Eintrag") + '</p>' + (reference.note ? '<blockquote>' + nl(reference.note) + '</blockquote>' : "") + '<div class="source-links"><a href="zotero://select/library/items/' + esc(reference.zoteroKey) + '">In Zotero öffnen</a>' + (external ? '<a href="' + esc(external) + '" target="_blank" rel="noreferrer">Web ↗</a>' : "") + '</div></article>';
  }).join("") : '<div class="source-empty"><p>' + esc(
    collectionLoading
      ? "Zotero-Sammlung wird geladen …"
      : collectionState?.message || (zoteroCollectionKey(project)
        ? "Noch keine " + label.toLowerCase() + " in der Zotero-Sammlung."
        : "Die Projekt-Sammlungen werden nach dem ersten Zotero-Plugin-Abgleich automatisch hier angezeigt.")
  ) + '</p><button type="button" class="quiet-btn" data-add-source>Aus Zotero zusätzlich verknüpfen</button></div>';
  return '<section class="source-shelf"><header><div><span class="shelf-icon">' + icon + '</span><div><p class="eyebrow">ZOTERO</p><h3>' + esc(label) + '</h3></div></div><span>' + references.length + '</span></header><div class="source-list">' + cards + '</div></section>';
}

function researchConceptEditor(project) {
  const fields = [
    ["topic", "Gegenstand"], ["question", "Präzise Forschungsfrage"], ["relevance", "Relevanz"], ["gap", "Forschungslücke"], ["theory", "Theorie / Ansatz"],
    ["terms", "Zentrale Begriffe"], ["method", "Material & Methode"], ["sources", "Schlüsselquellen"], ["contribution", "Erkenntnisbeitrag"], ["limits", "Abgrenzung / Grenzen"]
  ];
  const concept = project.researchConcept || {};
  return '<section class="concept-editor panel-card"><header><div><p class="eyebrow">FORSCHUNGSKONZEPT</p><h3>Frage präzisieren</h3><p class="hint">Änderungen werden lokal automatisch gespeichert.</p></div><span id="conceptSaveState" class="autosave-state">Gespeichert</span></header><div class="concept-fields">' + fields.map(([field, label]) => '<label><span>' + label + '</span><textarea rows="2" data-concept-field="' + field + '" placeholder="' + label + ' formulieren …">' + esc(concept[field] || "") + '</textarea></label>').join("") + '</div></section>';
}

async function loadProjectHistory(project, force = false) {
  if (!project || (!force && (state.projectHistory[project.id] || state.projectHistoryLoading[project.id]))) return;
  state.projectHistoryLoading[project.id] = true;
  renderWorkspace();
  try {
    state.projectHistory[project.id] = await api('/api/projects/' + project.id + '/history');
  } finally {
    delete state.projectHistoryLoading[project.id];
    if (projectById(project.id)) renderWorkspace();
  }
}

function historyLayout(commits) {
  const lanes = [];
  return commits.map((commit, row) => {
    let lane = lanes.indexOf(commit.hash);
    if (lane < 0) { lane = lanes.length; lanes.push(commit.hash); }
    const node = { ...commit, lane, row };
    const parents = Array.isArray(commit.parents) ? commit.parents.filter(Boolean) : [];
    if (parents.length) {
      lanes[lane] = parents[0];
      if (parents.length > 1) lanes.splice(lane + 1, 0, ...parents.slice(1));
    } else {
      lanes.splice(lane, 1);
    }
    return node;
  });
}

function renderRepositoryGraph() {
  const target = $("repositoryGraph");
  const graph = state.repositoryGraph;
  if (!graph) {
    target.innerHTML = '<p class="repository-graph-loading">Repository-Graph wird geladen …</p>';
    return;
  }
  const nodes = historyLayout(graph.commits || []);
  if (!nodes.length) {
    target.innerHTML = '<p class="repository-graph-loading">In diesem Repository sind noch keine Commits vorhanden.</p>';
    return;
  }
  const nodeByHash = new Map(nodes.map((node) => [node.hash, node]));
  const selectedHash = nodeByHash.has(state.repositoryGraphSelectedCommit)
    ? state.repositoryGraphSelectedCommit
    : nodes[0].hash;
  const selected = nodeByHash.get(selectedHash);
  const laneWidth = 28;
  const rowHeight = 44;
  const maxLane = Math.max(0, ...nodes.map((node) => node.lane));
  const graphWidth = Math.max(720, (maxLane + 1) * laneWidth + 590);
  const graphHeight = Math.max(116, nodes.length * rowHeight + 26);
  const laneColor = (lane) => 'var(--graph-lane-' + (lane % 5) + ')';
  const edges = nodes.flatMap((node) => (node.parents || []).map((parentHash) => {
    const parent = nodeByHash.get(parentHash);
    if (!parent) return '';
    const x1 = 28 + node.lane * laneWidth;
    const y1 = 27 + node.row * rowHeight;
    const x2 = 28 + parent.lane * laneWidth;
    const y2 = 27 + parent.row * rowHeight;
    return '<path style="--graph-color:' + laneColor(node.lane) + '" d="M ' + x1 + ' ' + y1 + ' V ' + y2 + ' H ' + x2 + '" />';
  })).join('');
  const nodeButtons = nodes.map((node) => {
    const refs = (node.refs || []).map((ref) => '<span class="repository-ref">' + esc(ref) + '</span>').join('');
    const merge = (node.parents || []).length > 1;
    const initials = String(node.author || '?').trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toUpperCase();
    return '<button type="button" class="repository-node' + (node.hash === selectedHash ? ' selected' : '') + (merge ? ' merge' : '') + '" data-repository-commit="' + esc(node.hash) + '" style="--repository-x:' + (28 + node.lane * laneWidth) + 'px;--repository-y:' + (27 + node.row * rowHeight) + 'px;--graph-color:' + laneColor(node.lane) + '" title="' + esc(node.hash) + '"><span class="repository-node-dot"></span><span class="repository-avatar" aria-hidden="true">' + esc(initials || '?') + '</span><span class="repository-node-copy"><strong>' + esc(node.subject || '(ohne Nachricht)') + '</strong><small>' + esc(node.author || '') + ' · ' + esc(formatDate(node.date)) + '</small></span><code class="repository-short">' + esc(node.short) + '</code>' + (refs ? '<span class="repository-refs">' + refs + '</span>' : '') + '</button>';
  }).join('');
  const selectedDetail = selected
    ? '<div class="repository-selected"><span class="repository-selected-dot" style="--graph-color:' + laneColor(selected.lane) + '"></span><div><span>Ausgewählter Commit</span><strong>' + esc(selected.subject || '(ohne Nachricht)') + '</strong><small>' + esc(selected.short) + ' · ' + esc(selected.author || '') + ' · ' + esc(formatDate(selected.date)) + '</small></div><code>' + esc(selected.hash) + '</code></div>'
    : '';
  target.innerHTML = '<div class="repository-summary"><span><strong>' + nodes.length + '</strong> Commits</span><span><strong>' + (graph.branchCount || 0) + '</strong> Referenzen</span><span><strong>' + (graph.mergeCount || 0) + '</strong> Merges</span><span>Lokaler Verlauf</span></div><div class="repository-graph-scroll" tabindex="0" aria-label="Scrollbarer Git-Graph"><div class="repository-graph-canvas" style="width:' + graphWidth + 'px;height:' + graphHeight + 'px"><svg class="repository-edges" viewBox="0 0 ' + graphWidth + ' ' + graphHeight + '" width="' + graphWidth + '" height="' + graphHeight + '" aria-hidden="true">' + edges + '</svg>' + nodeButtons + '</div></div>' + selectedDetail;
}

async function loadRepositoryGraph() {
  state.repositoryGraph = await api("/api/repository-graph");
  renderRepositoryGraph();
}

function projectHistoryPanel(project) {
  const history = state.projectHistory[project.id];
  const loading = state.projectHistoryLoading[project.id];
  if (!history) {
    if (!loading) void loadProjectHistory(project);
    return '<section class="project-history panel-card"><header><div><p class="eyebrow">CODE-HISTORIE</p><h3>Projektverlauf</h3><p class="hint">Git-Graph wird lokal geladen.</p></div></header><div class="history-empty">Historie wird geladen ...</div></section>';
  }
  const linked = new Set(history.linkedCommitHashes || []);
  const scope = state.historyScope[project.id] || 'all';
  const nodes = historyLayout(history.commits || []);
  const visible = scope === 'linked' ? nodes.filter((node) => linked.has(node.hash)) : nodes;
  const nodeByHash = new Map(visible.map((node) => [node.hash, node]));
  const selectedHash = state.historySelectedCommit[project.id] && nodeByHash.has(state.historySelectedCommit[project.id])
    ? state.historySelectedCommit[project.id]
    : (visible[0] || {}).hash;
  const selected = nodeByHash.get(selectedHash);
  const laneWidth = 42;
  const rowHeight = 54;
  const maxLane = Math.max(0, ...visible.map((node) => node.lane));
  const graphWidth = Math.max(590, (maxLane + 1) * laneWidth + 470);
  const graphHeight = Math.max(96, visible.length * rowHeight + 24);
  const edges = visible.flatMap((node) => (node.parents || []).map((parentHash) => {
    const parent = nodeByHash.get(parentHash);
    if (!parent) return '';
    const x1 = 28 + node.lane * laneWidth;
    const y1 = 27 + node.row * rowHeight;
    const x2 = 28 + parent.lane * laneWidth;
    const y2 = 27 + parent.row * rowHeight;
    const bend = Math.max(x1, x2) + 16;
    return '<path d="M ' + x1 + ' ' + y1 + ' C ' + bend + ' ' + y1 + ', ' + bend + ' ' + y2 + ', ' + x2 + ' ' + y2 + '" />';
  })).join('');
  const nodeButtons = visible.map((node) => {
    const refs = (node.refs || []).map((ref) => '<span class="history-ref">' + esc(ref) + '</span>').join('');
    const classes = ['history-node', linked.has(node.hash) ? 'linked' : '', (node.parents || []).length > 1 ? 'merge' : '', node.hash === selectedHash ? 'selected' : ''].filter(Boolean).join(' ');
    return '<button type="button" class="' + classes + '" data-history-commit="' + esc(node.hash) + '" style="--history-x:' + (28 + node.lane * laneWidth) + 'px;--history-y:' + (27 + node.row * rowHeight) + 'px" title="' + esc(node.hash) + '"><span class="history-node-dot"></span><span class="history-node-copy"><strong>' + esc(node.subject || '(ohne Nachricht)') + '</strong><small>' + esc(node.short) + ' · ' + esc(node.author || '') + ' · ' + esc(formatDate(node.date)) + '</small></span>' + (refs ? '<span class="history-refs">' + refs + '</span>' : '') + '</button>';
  }).join('');
  const linkedLabel = linked.size ? linked.size + ' zugeordnet' : 'keine Zuordnung';
  const graph = visible.length
    ? '<div class="history-graph-scroll"><div class="history-canvas" style="width:' + graphWidth + 'px;height:' + graphHeight + 'px"><svg class="history-edges" viewBox="0 0 ' + graphWidth + ' ' + graphHeight + '" width="' + graphWidth + '" height="' + graphHeight + '" aria-hidden="true">' + edges + '</svg>' + nodeButtons + '</div></div>'
    : '<div class="history-empty">Diesem Projekt sind noch keine Commits zugeordnet.</div>';
  const detail = selected
    ? '<aside class="history-detail"><div><p class="eyebrow">AUSGEWAEHLTER COMMIT</p><h4>' + esc(selected.subject || '(ohne Nachricht)') + '</h4><p><code>' + esc(selected.hash) + '</code></p><p class="hint">' + esc(selected.author || 'Unbekannt') + ' · ' + esc(selected.email || '') + '<br>' + esc(formatDate(selected.date)) + '</p></div><div class="history-detail-actions"><button type="button" class="' + (linked.has(selected.hash) ? 'secondary-btn' : 'primary-btn') + ' compact" data-history-link="' + esc(selected.hash) + '" data-history-linked="' + (linked.has(selected.hash) ? 'true' : 'false') + '">' + (linked.has(selected.hash) ? 'Zuordnung entfernen' : 'Diesem Projekt zuordnen') + '</button></div></aside>'
    : '';
  return '<section class="project-history panel-card"><header><div><p class="eyebrow">CODE-HISTORIE</p><h3>Projektverlauf</h3><p class="hint">Jeder Commit ist ein Knoten; Verzweigungen und Merge-Commit-Eltern bleiben sichtbar.</p></div><div class="history-header-actions"><button type="button" class="quiet-btn" data-history-refresh>Aktualisieren</button><button type="button" class="secondary-btn compact" data-export-project-report="html">HTML-Bericht</button><button type="button" class="primary-btn compact" data-export-project-report="pdf">PDF-Bericht</button></div></header><div class="history-summary"><span><strong>' + (history.commits || []).length + '</strong> Commits</span><span><strong>' + (history.branchCount || 0) + '</strong> Referenzen</span><span><strong>' + (history.mergeCount || 0) + '</strong> Merges</span><span>' + esc(linkedLabel) + '</span><div class="history-scope" role="group" aria-label="Commit-Auswahl"><button type="button" class="' + (scope === 'all' ? 'active' : '') + '" data-history-scope="all">Alle</button><button type="button" class="' + (scope === 'linked' ? 'active' : '') + '" data-history-scope="linked">Nur Projekt</button></div></div><div class="history-content">' + graph + detail + '</div></section>';
}

async function downloadProjectReport(projectId, format) {
  const response = await fetch(API_BASE + '/api/projects/' + projectId + '/report?format=' + encodeURIComponent(format));
  if (!response.ok) {
    let message = 'Bericht konnte nicht exportiert werden.';
    try { message = (await response.json()).error || message; } catch (_) { /* non-JSON error */ }
    throw new Error(message);
  }
  const blob = await response.blob();
  const disposition = response.headers.get('Content-Disposition') || '';
  const match = disposition.match(/filename="?([^";]+)"?/i);
  const anchor = document.createElement('a');
  anchor.href = URL.createObjectURL(blob);
  anchor.download = match ? match[1] : 'projektbericht.' + (format === 'pdf' ? 'pdf' : 'html');
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(anchor.href), 1000);
}

function renderWorkspace() {
  const project = projectById();
  $("workspaceContent").hidden = !project;
  if (!project) return;
  const phase = phaseLabels[project.status] || "Konzept";
  const question = project.researchQuestion || "";
  const goal = project.paperGoal || "";
  const conceptQuestion = project.researchConcept?.question || question;
  const researchQuestionCard = conceptQuestion
    ? '<section class="research-question-card"><p class="eyebrow">LEITENDE FORSCHUNGSFRAGE</p><h3>' + nl(conceptQuestion) + '</h3>' + (goal ? '<div><span>Arbeitsthese / Ziel</span><p>' + nl(goal) + '</p></div>' : '') + '</section>'
    : "";
  const zotero = project.zotero || {};
  const collectionState = collectionReferenceState(project);
  let collectionLoading = Boolean(state.zoteroCollectionLoading[project.id]);
  if (zoteroCollectionKey(project) && !collectionState && !collectionLoading) {
    void loadZoteroCollectionReferences(project);
    collectionLoading = true;
  }
  const references = projectReferences(project);
  const literatureCount = references.filter((reference) => reference.kind === "literature").length;
  const sourceCount = references.filter((reference) => reference.kind === "source").length;
  const zoteroLabel = zotero.status === "linked" ? "Zotero: " + (zotero.collectionName || "verknüpft") : "Zotero-Abgleich ausstehend";
  $("projectWorkspace").innerHTML =
    '<section class="workspace-header compact-header phase-' + esc(project.status) + '"><div class="workspace-title"><p class="eyebrow">' + esc(phase) + ' · ' + (project.deadline ? "Termin " + esc(formatDate(project.deadline)) : "Termin offen") + '</p><h2>' + esc(project.name) + '</h2><div class="workspace-meta"><span class="state">' + esc(project.projectType || "Projekt") + '</span><span class="zotero-state ' + esc(zotero.status || "pending") + '">' + esc(zoteroLabel) + '</span></div></div>' + progressRing(project.progress, "Aufgaben") + '</section>' +
    researchQuestionCard +
    '<div class="workspace-metrics compact-metrics"><article><span>Aufgaben</span><strong>' + (project.todoCount || 0) + '</strong><p>' + (project.inProgressTodoCount || 0) + ' in Arbeit · ' + (project.doneTodoCount || 0) + ' erledigt</p></article><article><span>Literatur</span><strong>' + literatureCount + '</strong><p>aus der Zotero-Projektsammlung</p></article><article><span>Quellen</span><strong>' + sourceCount + '</strong><p>aus der Zotero-Projektsammlung</p></article><article><span>Termin</span><strong class="date-metric">' + esc(project.deadline ? formatDate(project.deadline) : "—") + '</strong><p>Projektbrief</p></article></div>' +
    researchConceptEditor(project) +
    projectResearchPanel(project) +
    '<section class="tasks-panel panel-card"><header><div><p class="eyebrow">LOKALE ISSUES</p><h3>Aufgaben</h3><p class="hint">Jede Aufgabe hat eine lokale Issue-Nummer, Verlauf, Kommentare und Checkliste.</p></div><button type="button" class="primary-btn compact" data-new-task>+ Aufgabe</button></header><div class="task-board">' +
      taskColumn(project, references, "open", "Offen", "Nächster sinnvoller Schritt") + taskColumn(project, references, "in_progress", "In Arbeit", "Gerade im Fokus") + taskColumn(project, references, "blocked", "Blockiert", "Benötigt eine Klärung") + taskColumn(project, references, "done", "Erledigt", "Dokumentierter Fortschritt") +
    '</div></section>' +
    '<section class="sources-panel"><header class="section-heading"><div><p class="eyebrow">QUELLENREGAL</p><h2>Zotero-Projektsammlungen</h2><p>Die Unterordner „Literatur“ und „Quellen“ deiner Projekt-Sammlung werden automatisch aus Zotero gelesen. „In Zotero öffnen“ führt direkt zum Originaleintrag.</p></div><button type="button" class="primary-btn" data-add-source>+ Zusätzlich verknüpfen</button></header><div class="source-grid">' + sourceShelf(project, references, "literature", "Literatur", "▣", collectionState, collectionLoading) + sourceShelf(project, references, "source", "Quellen", "⌁", collectionState, collectionLoading) + '</div></section>';
}

async function loadProjects() {
  state.projects = await api("/api/projects");
  Object.keys(state.zoteroCollectionReferences).forEach((projectId) => {
    const project = state.projects.find((item) => item.id === projectId);
    if (!project || state.zoteroCollectionReferences[projectId].collectionKey !== zoteroCollectionKey(project)) {
      delete state.zoteroCollectionReferences[projectId];
    }
  });
  if (state.selectedProjectId && !projectById()) setSelectedProject("");
  if (!state.selectedProjectId && state.projects.length) setSelectedProject(state.projects[0].id);
  renderProjects();
  renderWorkspace();
  renderSavedResearchResults();
}

async function loadTrash() {
  state.trashProjects = await api("/api/projects?scope=trash");
  renderTrash();
}

async function loadArchive() {
  state.archivedProjects = await api("/api/projects?scope=archived");
  renderArchive();
}

async function loadStatus() {
  const [status, zotero] = await Promise.all([
    api("/api/status"),
    api("/api/zotero/status").catch((error) => ({ available: false, message: error.message }))
  ]);
  state.zotero = zotero;
  const storage = status.storage || {};
  const repoName = $("repoName");
  if (repoName) repoName.textContent = (storage.provider || "lokal") + " · externer Speicher";
  $("storageBadge").textContent = storage.available ? (storage.provider || "lokal") + " verbunden" : "Speicher prüfen";
  $("storageBadge").className = storage.available ? "badge-online" : "badge-warning";
  const plugin = zotero.plugin || {};
  const syncReady = zotero.available && plugin.active;
  $("zoteroBadge").textContent = !zotero.available ? "Zotero nicht erreichbar" : syncReady ? "Zotero + Plugin verbunden" : "Zotero-Plugin aktualisieren";
  $("zoteroBadge").className = syncReady ? "badge-online" : "badge-warning";
  $("zoteroBadge").title = [zotero.message, plugin.message].filter(Boolean).join("\n");
  $("syncBadge").textContent = status.ahead + " ↑ / " + status.behind + " ↓ Code";
  $("statusLine").textContent = storage.available
    ? "Cloud-Projekte und Anhänge: " + storage.path + " — außerhalb von Git und Git LFS"
    : "Der Speicherordner ist nicht erreichbar: " + (storage.path || "nicht konfiguriert");
}

function openProject(id) {
  if (!projectById(id)) return;
  setSelectedProject(id);
  renderProjects();
  setView("workspace");
}

function openNewProjectDialog() {
  $("newProjectForm").reset();
  $("newProjectStatus").value = "planning";
  $("newProjectDialog").showModal();
  setTimeout(() => $("newProjectName").focus(), 30);
}

async function createProject(event) {
  event.preventDefault();
  const name = $("newProjectName").value.trim();
  if (!name) return toast("Bitte einen Projektnamen eingeben.", "error");
  const project = await api("/api/projects", { method: "POST", body: JSON.stringify({
    name,
    projectType: $("newProjectType").value,
    subject: $("newProjectSubject").value.trim(),
    researchQuestion: $("newProjectQuestion").value.trim(),
    status: $("newProjectStatus").value,
    deadline: $("newProjectDeadline").value
  }) });
  $("newProjectDialog").close();
  setSelectedProject(project.id);
  await loadProjects();
  setView("workspace");
  toast("Projekt und Cloud-Ordner wurden angelegt. Zotero erstellt beim nächsten Abgleich die Sammlung unter Meine Bibliothek.");
}

function openProjectDialog() {
  const project = projectById();
  if (!project) return;
  $("projectDialogTitle").textContent = "Projektbrief · " + project.name;
  $("projectName").value = project.name || "";
  $("projectDescription").value = project.description || "";
  $("projectType").value = project.projectType || "other";
  $("projectSubject").value = project.subject || "";
  $("projectPriority").value = project.priority || "normal";
  $("projectTags").value = (project.tags || []).join(", ");
  $("projectClassificationCutoffYear").value = project.researchSettings?.classification?.cutoffYear || 1945;
  $("projectQuestion").value = project.researchQuestion || "";
  $("projectGoal").value = project.paperGoal || "";
  $("projectHypothesis").value = project.hypothesis || "";
  $("projectStatus").value = project.status || "planning";
  $("projectDeadline").value = project.deadline || "";
  $("projectOutline").value = project.outline || "";
  $("projectNotes").value = project.notes || "";
  $("projectDialog").showModal();
}

async function saveProjectDialog(event) {
  event.preventDefault();
  const project = projectById();
  if (!project) return;
  const name = $("projectName").value.trim();
  if (!name) return toast("Bitte einen Projektnamen eingeben.", "error");
  await api("/api/projects/" + project.id, { method: "PATCH", body: JSON.stringify({
    name,
    description: $("projectDescription").value.trim(),
    projectType: $("projectType").value,
    subject: $("projectSubject").value.trim(),
    priority: $("projectPriority").value,
    tags: $("projectTags").value.trim(),
    classificationCutoffYear: $("projectClassificationCutoffYear").value,
    researchQuestion: $("projectQuestion").value.trim(),
    paperGoal: $("projectGoal").value.trim(),
    hypothesis: $("projectHypothesis").value.trim(),
    status: $("projectStatus").value,
    deadline: $("projectDeadline").value,
    outline: $("projectOutline").value.trim(),
    notes: $("projectNotes").value.trim()
  }) });
  $("projectDialog").close();
  await loadProjects();
  setView("workspace");
  toast("Projektbrief gespeichert.");
}

function actionProject() {
  return state.projects.find((project) => project.id === state.actionProjectId) || state.archivedProjects.find((project) => project.id === state.actionProjectId) || state.trashProjects.find((project) => project.id === state.actionProjectId) || null;
}

function openProjectActions(projectId) {
  const project = state.projects.find((item) => item.id === projectId);
  if (!project) return;
  state.actionProjectId = projectId;
  $("projectActionsTitle").textContent = project.name;
  $("projectActionsDialog").showModal();
}

async function duplicateActionProject() {
  const project = actionProject();
  if (!project) return;
  const copy = await api("/api/projects/" + project.id + "/duplicate", { method: "POST", body: "{}" });
  $("projectActionsDialog").close();
  await loadProjects();
  openProject(copy.id);
  toast("Projektduplikat angelegt. Zotero-Einträge wurden nur als Verknüpfungen übernommen.");
}

async function archiveActionProject() {
  const project = actionProject();
  if (!project) return;
  await api("/api/projects/" + project.id + "/archive", { method: "POST", body: "{}" });
  $("projectActionsDialog").close();
  if (state.selectedProjectId === project.id) setSelectedProject("");
  await loadProjects();
  setView("overview");
  toast("Projekt archiviert. Es bleibt vollständig lesbar und kann wiederhergestellt werden.");
}

function openDeleteProjectDialog(projectId, permanent = false) {
  const project = state.projects.find((item) => item.id === projectId) || state.trashProjects.find((item) => item.id === projectId);
  if (!project) return;
  state.actionProjectId = projectId;
  $("deleteProjectForm").dataset.permanent = permanent ? "true" : "false";
  $("deleteProjectTitle").textContent = permanent ? "Projekt endgültig löschen" : "Projekt in Papierkorb verschieben";
  $("deleteProjectHint").textContent = permanent
    ? "Projektmetadaten werden endgültig entfernt. Projektdateien bleiben standardmäßig erhalten; optional kannst du ausschließlich den verwalteten Projektordner entfernen."
    : "Das Projekt verschwindet aus der aktiven Übersicht, bleibt aber mit seinen Dateien und Referenzen vollständig wiederherstellbar.";
  $("deleteProjectFiles").checked = false;
  $("deleteProjectFiles").parentElement.hidden = !permanent;
  $("deleteProjectDialog").showModal();
}

async function confirmProjectDeletion(event) {
  event.preventDefault();
  const project = actionProject();
  if (!project) return;
  const permanent = $("deleteProjectForm").dataset.permanent === "true";
  const suffix = permanent ? "?permanent=true&deleteProjectFiles=" + $("deleteProjectFiles").checked : "";
  await api("/api/projects/" + project.id + suffix, { method: "DELETE" });
  $("deleteProjectDialog").close();
  $("projectActionsDialog").close();
  if (state.selectedProjectId === project.id) setSelectedProject("");
  await Promise.all([loadProjects(), loadArchive(), loadTrash()]);
  setView(permanent ? "trash" : "overview");
  toast(permanent ? "Projekt endgültig gelöscht. Zotero-Inhalte bleiben unverändert." : "Projekt in Papierkorb verschoben.");
}

async function restoreProject(projectId) {
  await api("/api/projects/" + projectId + "/restore", { method: "POST", body: "{}" });
  await Promise.all([loadProjects(), loadArchive(), loadTrash()]);
  toast("Projekt wiederhergestellt.");
}

function taskReferenceOptions(project, selectedKeys = []) {
  const references = projectReferences(project);
  const selected = new Set(selectedKeys.map((key) => String(key || "").trim().toUpperCase()));
  return references.length ? references.map((reference) => '<label class="reference-option"><input type="checkbox" name="taskReference" value="' + esc(reference.zoteroKey) + '"' + (selected.has(reference.zoteroKey) ? " checked" : "") + '><span><strong>' + esc(reference.title) + '</strong><small>' + esc([reference.creators, reference.year].filter(Boolean).join(" · ") || reference.zoteroKey) + '</small></span></label>').join("") : '<p class="empty-mini">Die Literatur und Quellen der Zotero-Projektsammlung erscheinen hier automatisch nach dem Abgleich.</p>';
}

function openTaskDialog(task = null) {
  const project = projectById();
  if (!project) return toast("Wähle zuerst ein Projekt.", "error");
  $("taskForm").reset();
  $("taskProjectId").value = project.id;
  $("taskId").value = task?.id || "";
  $("taskDialogTitle").textContent = task ? "Aufgabe bearbeiten" : "Neue Aufgabe · " + project.name;
  $("taskTitle").value = task?.title || "";
  $("taskBody").value = task?.body || "";
  $("taskStatus").value = task?.status || "open";
  $("taskPriority").value = task?.priority || "normal";
  $("taskDueDate").value = task?.dueDate || "";
  $("taskReferenceList").innerHTML = taskReferenceOptions(project, task?.referenceKeys || []);
  $("taskDialog").showModal();
  setTimeout(() => $("taskTitle").focus(), 30);
}

async function saveTaskDialog(event) {
  event.preventDefault();
  const projectId = $("taskProjectId").value;
  const taskId = $("taskId").value;
  const title = $("taskTitle").value.trim();
  if (!title) return toast("Bitte einen Aufgabentitel eingeben.", "error");
  const referenceKeys = Array.from(document.querySelectorAll('input[name="taskReference"]:checked')).map((input) => input.value);
  const body = { title, body: $("taskBody").value.trim(), status: $("taskStatus").value, priority: $("taskPriority").value, dueDate: $("taskDueDate").value, referenceKeys };
  const path = "/api/projects/" + projectId + "/tasks" + (taskId ? "/" + taskId : "");
  await api(path, { method: taskId ? "PATCH" : "POST", body: JSON.stringify(body) });
  $("taskDialog").close();
  await loadProjects();
  setView("workspace");
  toast(taskId ? "Aufgabe aktualisiert." : "Aufgabe im Projekt gespeichert.");
}

async function setTaskStatus(taskId, status) {
  const project = projectById();
  if (!project) return;
  await api("/api/projects/" + project.id + "/tasks/" + taskId, { method: "PATCH", body: JSON.stringify({ status }) });
  await loadProjects();
  renderWorkspace();
}

function selectedTask() {
  const project = projectById();
  return (project?.tasks || project?.todos || []).find((task) => task.id === state.selectedTaskId) || null;
}

function renderTaskIssue(task) {
  const project = projectById();
  if (!task || !project) return;
  $("issueDetailTitle").textContent = "#" + (task.issueNumber || "?") + " " + task.title;
  $("issueDetailMeta").textContent = (taskStatusLabels[task.status] || task.status) + " · " + (priorityLabels[task.priority] || task.priority) + (task.dueDate ? " · Termin " + formatDate(task.dueDate) : "");
  $("issueDetailBody").innerHTML = task.body ? nl(task.body) : '<p class="muted">Noch keine ausführliche Beschreibung.</p>';
  const checklist = task.checklist || [];
  const done = checklist.filter((item) => item.done).length;
  $("issueChecklistProgress").textContent = checklist.length ? done + "/" + checklist.length + " erledigt" : "Noch keine Punkte";
  $("issueChecklistItems").innerHTML = checklist.length ? checklist.map((item) => '<label class="issue-check-item"><input type="checkbox" data-checklist-item="' + item.id + '"' + (item.done ? " checked" : "") + '><span>' + esc(item.title) + '</span></label>').join("") : '<p class="empty-mini">Mit kleinen Checklistenpunkten bleibt der nächste Schritt klar.</p>';
  const timeline = (task.events || []).map((item) => ({ ...item, label: item.message, kind: "Ereignis" }))
    .concat((task.comments || []).map((item) => ({ ...item, label: item.message, kind: "Kommentar" })))
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  $("issueTimeline").innerHTML = timeline.length ? timeline.map((item) => '<article class="timeline-item"><span>' + esc(item.kind) + ' · ' + esc(formatDate(item.createdAt)) + '</span><p>' + nl(item.label) + '</p></article>').join("") : '<p class="empty-mini">Der Verlauf beginnt mit der ersten Änderung oder einem Kommentar.</p>';
}

function openTaskIssue(taskId) {
  const task = (projectById()?.tasks || projectById()?.todos || []).find((item) => item.id === taskId);
  if (!task) return;
  state.selectedTaskId = taskId;
  $("taskCommentForm").reset();
  $("issueChecklistForm").reset();
  renderTaskIssue(task);
  $("taskIssueDialog").showModal();
}

async function addTaskComment(event) {
  event.preventDefault();
  const project = projectById();
  const task = selectedTask();
  const message = $("taskCommentMessage").value.trim();
  if (!project || !task || !message) return;
  await api("/api/projects/" + project.id + "/tasks/" + task.id + "/comments", { method: "POST", body: JSON.stringify({ message }) });
  $("taskCommentForm").reset();
  await loadProjects();
  renderTaskIssue(selectedTask());
}

async function addChecklistItem(event) {
  event.preventDefault();
  const project = projectById();
  const task = selectedTask();
  const title = $("issueChecklistTitle").value.trim();
  if (!project || !task || !title) return;
  await api("/api/projects/" + project.id + "/tasks/" + task.id + "/checklist", { method: "POST", body: JSON.stringify({ title }) });
  $("issueChecklistForm").reset();
  await loadProjects();
  renderTaskIssue(selectedTask());
}

async function setChecklistItem(checklistId, done) {
  const project = projectById();
  const task = selectedTask();
  if (!project || !task) return;
  await api("/api/projects/" + project.id + "/tasks/" + task.id + "/checklist/" + checklistId, { method: "PATCH", body: JSON.stringify({ done }) });
  await loadProjects();
  renderTaskIssue(selectedTask());
}

async function saveResearchConcept(field, value) {
  const project = projectById();
  if (!project) return;
  project.researchConcept = { ...(project.researchConcept || {}), [field]: value };
  const status = $("conceptSaveState");
  if (status) status.textContent = "Speichert …";
  await api("/api/projects/" + project.id, { method: "PATCH", body: JSON.stringify({ researchConcept: project.researchConcept }) });
  if (status) status.textContent = "Gespeichert";
}

function openSourceDialog() {
  const project = projectById();
  if (!project) return toast("Wähle zuerst ein Projekt.", "error");
  $("sourceForm").reset();
  $("sourceProjectId").value = project.id;
  $("sourceZoteroKey").value = "";
  $("zoteroResults").innerHTML = "";
  $("zoteroSearchStatus").textContent = state.zotero.available ? "Durchsuche deine lokale Zotero-Bibliothek." : "Zotero ist noch nicht erreichbar. Starte Zotero und prüfe den lokalen Zugriff.";
  $("sourceSelection").hidden = true;
  $("sourceSaveBtn").disabled = true;
  $("sourceDialog").showModal();
  setTimeout(() => $("zoteroSearch").focus(), 30);
}

async function searchZotero(query) {
  const value = query.trim();
  if (value.length < 2) {
    $("zoteroResults").innerHTML = "";
    $("zoteroSearchStatus").textContent = "Mindestens zwei Zeichen eingeben.";
    return;
  }
  $("zoteroSearchStatus").textContent = "Zotero wird durchsucht …";
  const results = await api("/api/zotero/items?q=" + encodeURIComponent(value) + "&limit=20");
  state.zoteroSearchResults = results;
  $("zoteroSearchStatus").textContent = results.length ? results.length + " passende Einträge gefunden." : "Keine passenden bibliografischen Einträge gefunden.";
  $("zoteroResults").innerHTML = results.map((reference) => '<button type="button" class="zotero-result" data-zotero-result="' + esc(reference.zoteroKey) + '"><strong>' + esc(reference.title) + '</strong><span>' + esc([reference.creators, reference.year, reference.itemType].filter(Boolean).join(" · ") || reference.zoteroKey) + '</span></button>').join("");
}

function selectZoteroResult(key) {
  const reference = state.zoteroSearchResults.find((item) => item.zoteroKey === key);
  if (!reference) return;
  $("sourceZoteroKey").value = reference.zoteroKey;
  $("sourceSelection").hidden = false;
  $("sourceSelection").innerHTML = '<strong>Ausgewählt</strong><span>' + esc(reference.title) + '</span><small>' + esc([reference.creators, reference.year].filter(Boolean).join(" · ")) + '</small>';
  $("sourceSaveBtn").disabled = false;
  document.querySelectorAll(".zotero-result").forEach((button) => button.classList.toggle("selected", button.dataset.zoteroResult === key));
}

async function saveSourceDialog(event) {
  event.preventDefault();
  const projectId = $("sourceProjectId").value;
  const zoteroKey = $("sourceZoteroKey").value;
  if (!zoteroKey) return toast("Bitte wähle einen Zotero-Eintrag aus.", "error");
  await api("/api/projects/" + projectId + "/references", { method: "POST", body: JSON.stringify({ zoteroKey, kind: $("sourceKind").value, note: $("sourceNote").value.trim() }) });
  $("sourceDialog").close();
  await loadProjects();
  setView("workspace");
  toast("Zotero-Eintrag verknüpft. Er erscheint beim nächsten Plugin-Abgleich in der Projekt-Sammlung.");
}

async function removeReference(referenceId) {
  const project = projectById();
  if (!project || !confirm("Diese Verknüpfung aus dem Projekt entfernen? Der Zotero-Eintrag selbst bleibt unverändert.")) return;
  await api("/api/projects/" + project.id + "/references/" + referenceId, { method: "DELETE" });
  await loadProjects();
  renderWorkspace();
  toast("Verknüpfung aus dem Projekt entfernt.");
}

async function publishIssue(taskId) {
  const project = projectById();
  if (!project) return;
  if (!confirm("Diese Aufgabe als GitHub-Issue veröffentlichen? Titel und Beschreibung werden an GitHub übertragen.")) return;
  await api("/api/projects/" + project.id + "/tasks/" + taskId + "/github-issue", { method: "POST", body: "{}" });
  await loadProjects();
  renderWorkspace();
  toast("Aufgabe als GitHub-Issue veröffentlicht.");
}

function renderGraphItems(commits, entries) {
  const graph = $("commitGraph");
  const items = commits.map((data) => ({ type: "commit", ts: new Date(data.date), data }))
    .concat(entries.map((data) => ({ type: "log", ts: new Date(data.ts), data })))
    .sort((a, b) => b.ts - a.ts);
  graph.innerHTML = items.length ? "" : '<p class="empty-state">Noch keine Aktivität.</p>';
  items.forEach((item) => {
    const row = document.createElement("div");
    if (item.type === "commit") {
      row.className = "activity-row";
      row.innerHTML = '<span class="activity-dot commit-dot"></span><div><strong>' + esc(item.data.subject) + '</strong><p>' + esc(item.data.author) + ' · ' + item.ts.toLocaleString("de-DE") + '</p></div><code>' + esc(item.data.short) + '</code>';
    } else {
      row.className = "activity-row";
      row.innerHTML = '<span class="activity-dot log-dot ' + esc(item.data.level || "info") + '"></span><div><strong>' + esc(item.data.text) + '</strong><p>' + item.ts.toLocaleString("de-DE") + '</p></div>';
    }
    graph.appendChild(row);
  });
}

async function loadActivity() {
  const [commits, entries] = await Promise.all([api("/api/log"), api("/api/sync-log").catch(() => [])]);
  renderGraphItems(commits, Array.isArray(entries) ? entries : []);
}

function renderPulls(items) {
  const target = $("pullsList");
  target.innerHTML = items.length ? "" : '<p class="empty-state">Keine Pull Requests gefunden.</p>';
  items.forEach((item) => {
    const card = document.createElement("article");
    card.className = "pull-card";
    card.innerHTML = '<div><span class="state">' + esc(item.state) + '</span><h3>#' + item.number + " " + esc(item.title) + '</h3><p>' + esc((item.body || "").slice(0, 300)) + '</p></div><a href="' + esc(item.html_url) + '" target="_blank" rel="noreferrer" class="secondary-btn">GitHub ↗</a>';
    target.appendChild(card);
  });
}

async function loadPulls() {
  state.pulls = await api("/api/pulls");
  renderPulls(state.pulls);
}

async function openSettings() {
  const settings = await api("/api/settings");
  $("storageProvider").value = settings.storageProvider || "onedrive";
  $("storagePath").value = settings.storagePath || "";
  $("storageShareUrl").value = settings.storageShareUrl || "";
  $("githubUsername").value = settings.githubUsername || "";
  $("githubEmail").value = settings.githubEmail || "";
  $("githubToken").value = "";
  $("tokenHint").textContent = settings.tokenSet ? "Ein Token ist gespeichert. Feld leer lassen, um ihn nicht zu ändern." : "Kein GitHub-Token gespeichert. GitHub-Issues bleiben dann deaktiviert.";
  $("webdavUrl").value = settings.webdavUrl || "http://localhost:8080";
  $("webdavUsername").value = settings.webdavUsername || "zotero";
  $("webdavPassword").value = settings.webdavPassword || "";
  $("settingsDialog").showModal();
}

async function saveSettings(event) {
  event.preventDefault();
  const storagePath = $("storagePath").value.trim();
  if (!storagePath) return toast("Bitte den lokalen Cloud-Ordner eintragen.", "error");
  await api("/api/settings", { method: "POST", body: JSON.stringify({
    storageProvider: $("storageProvider").value,
    storagePath,
    storageShareUrl: $("storageShareUrl").value.trim(),
    githubUsername: $("githubUsername").value.trim(),
    githubEmail: $("githubEmail").value.trim(),
    githubToken: $("githubToken").value,
    webdavUrl: $("webdavUrl").value.trim(),
    webdavUsername: $("webdavUsername").value.trim(),
    webdavPassword: $("webdavPassword").value
  }) });
  $("settingsDialog").close();
  toast("Gespeichert. WebDAV über quickstart.bat neu starten, falls sich der Ordner geändert hat.");
  await Promise.all([loadStatus(), loadProjects()]);
}

async function pullRemote() {
  const result = await api("/api/pull", { method: "POST", body: "{}" });
  toast(result.skipped ? result.reason : result.pulled ? "Code-Pull abgeschlossen." : "Code-Pull fehlgeschlagen.", result.pulled ? "" : "error");
  await Promise.all([loadStatus(), loadActivity().catch(() => {})]);
}

function openCommitDialog() {
  $("commitMessage").value = "Code-Update " + new Date().toLocaleString("de-DE");
  $("commitDialog").showModal();
}

async function doManualCommit(event) {
  event.preventDefault();
  const message = $("commitMessage").value.trim();
  if (!message) return toast("Bitte eine Commit-Nachricht eingeben.", "error");
  $("commitDialog").close();
  const result = await api("/api/commit", { method: "POST", body: JSON.stringify({ message, push: $("commitPush").checked }) });
  toast(result.pushed ? "Code committed und gepusht." : "Code committed.");
  await Promise.all([loadStatus(), loadActivity().catch(() => {})]);
}

async function stopServer() {
  if (!confirm("Server wirklich stoppen?")) return;
  try { await api("/api/shutdown", { method: "POST", body: "{}" }); } catch (_) { /* listener intentionally closes */ }
  $("statusLine").textContent = "Server gestoppt.";
}

document.addEventListener("click", (event) => {
  const viewButton = event.target.closest("[data-view]");
  if (viewButton) return setView(viewButton.dataset.view);
  const closeButton = event.target.closest("[data-close]");
  if (closeButton) return $(closeButton.dataset.close).close();
  if (event.target.closest("[data-new-project]")) return openNewProjectDialog();
  const openProjectButton = event.target.closest("[data-open-project]");
  if (openProjectButton) return openProject(openProjectButton.dataset.openProject);
  const actionsButton = event.target.closest("[data-project-actions]");
  if (actionsButton) return openProjectActions(actionsButton.dataset.projectActions);
  const restoreButton = event.target.closest("[data-restore-project]");
  if (restoreButton) return restoreProject(restoreButton.dataset.restoreProject).catch((error) => toast(error.message, "error"));
  const permanentDeleteButton = event.target.closest("[data-permanent-delete-project]");
  if (permanentDeleteButton) return openDeleteProjectDialog(permanentDeleteButton.dataset.permanentDeleteProject, true);
  if (event.target.closest("[data-new-task]")) return openTaskDialog();
  const historyCommit = event.target.closest('[data-history-commit]');
  if (historyCommit) { const project = projectById(); if (project) { state.historySelectedCommit[project.id] = historyCommit.dataset.historyCommit; renderWorkspace(); } return; }
  const repositoryCommit = event.target.closest('[data-repository-commit]');
  if (repositoryCommit) { state.repositoryGraphSelectedCommit = repositoryCommit.dataset.repositoryCommit; renderRepositoryGraph(); return; }
  const historyScope = event.target.closest('[data-history-scope]');
  if (historyScope) { const project = projectById(); if (project) { state.historyScope[project.id] = historyScope.dataset.historyScope; renderWorkspace(); } return; }
  if (event.target.closest('[data-history-refresh]')) { const project = projectById(); if (project) return loadProjectHistory(project, true).catch((error) => toast(error.message, 'error')); }
  const historyLink = event.target.closest('[data-history-link]');
  if (historyLink) { const project = projectById(); if (project) { const linked = historyLink.dataset.historyLinked === 'true'; return api('/api/projects/' + project.id + '/history/commits/' + historyLink.dataset.historyLink, { method: linked ? 'DELETE' : 'POST', body: '{}' }).then(async (result) => { state.projectHistory[project.id] = result; await loadProjects(); toast(linked ? 'Commit-Zuordnung entfernt.' : 'Commit dem Projekt zugeordnet.'); }).catch((error) => toast(error.message, 'error')); } return; }
  const reportExport = event.target.closest('[data-export-project-report]');
  if (reportExport) { const project = projectById(); if (project) return downloadProjectReport(project.id, reportExport.dataset.exportProjectReport).then(() => toast('Projektbericht wird heruntergeladen.')).catch((error) => toast(error.message, 'error')); }
  const editTaskButton = event.target.closest("[data-edit-task]");
  if (editTaskButton) {
    const task = (projectById()?.tasks || projectById()?.todos || []).find((item) => item.id === editTaskButton.dataset.editTask);
    return openTaskDialog(task);
  }
  const openTaskButton = event.target.closest("[data-open-task]");
  if (openTaskButton) return openTaskIssue(openTaskButton.dataset.openTask);
  if (event.target.closest("[data-add-source]")) return openSourceDialog();
  const sourceResult = event.target.closest("[data-zotero-result]");
  if (sourceResult) return selectZoteroResult(sourceResult.dataset.zoteroResult);
  const detailButton = event.target.closest('[data-research-detail]');
  if (detailButton) return openResearchDetail(detailButton.dataset.researchDetail);
  const clearResearchFilters = event.target.closest('[data-clear-research-result-filters]');
  if (clearResearchFilters) {
    const scope = clearResearchFilters.dataset.clearResearchResultFilters;
    state.researchResultFilters[scope] = { title: '', author: '', fromYear: '', toYear: '', provider: '', classification: '', sort: 'relevance' };
    return renderResearch(scope, state.researchResults[scope]);
  }
  const bookmarkButton = event.target.closest('[data-toggle-saved-research]');
  if (bookmarkButton) return toggleSavedResearchResult(bookmarkButton.dataset.toggleSavedResearch).catch((error) => toast(error.message, 'error'));
  const loadMoreButton = event.target.closest('[data-load-more-research]');
  if (loadMoreButton) return loadMoreResearch(loadMoreButton.dataset.loadMoreResearch).catch((error) => toast(error.message, 'error'));
  const savedImportButton = event.target.closest('[data-import-saved-zotero]');
  if (savedImportButton) return importSavedResearchResultToZotero(savedImportButton.dataset.importSavedZotero, savedImportButton.dataset.importKind).catch((error) => toast(error.message, 'error'));
  const importButton = event.target.closest('[data-import-zotero]');
  if (importButton) return importResearchResultToZotero(importButton.dataset.importZotero, importButton.dataset.importKind).catch((error) => toast(error.message, 'error'));
  const classificationButton = event.target.closest('[data-set-research-classification]');
  if (classificationButton) return setResearchClassification(classificationButton.dataset.setResearchClassification, classificationButton.dataset.classificationCategory).catch((error) => toast(error.message, 'error'));
  const removeButton = event.target.closest("[data-remove-reference]");
  if (removeButton) return removeReference(removeButton.dataset.removeReference).catch((error) => toast(error.message, "error"));
  const issueButton = event.target.closest("[data-publish-issue]");
  if (issueButton) return publishIssue(issueButton.dataset.publishIssue).catch((error) => toast(error.message, "error"));
  const suggestion = event.target.closest('[data-research-suggestion]');
  if (suggestion) { const input = document.querySelector('[data-research-form="project"] input[name="query"]'); if (input) { input.value = suggestion.dataset.researchSuggestion; input.focus(); } return; }
  const saved = event.target.closest('[data-run-saved-search]');
  if (saved) { const entry = (state.savedResearchSearches || []).find((item) => item.id === saved.dataset.runSavedSearch); const form = document.querySelector('[data-research-form="project"]'); if (entry && form) { Object.entries(entry.request || {}).forEach(([key, value]) => { const field = form.elements.namedItem(key); if (field && typeof value === 'string') field.value = value; }); runResearch(form).catch((error) => toast(error.message, 'error')); } return; }
  if (event.target.closest('[data-save-research]')) { const project = projectById(); const form = document.querySelector('[data-research-form="project"]'); if (project && form) { const request = requestFromForm(form); const label = window.prompt('Name der gespeicherten Suche:', request.query); if (label) api('/api/projects/' + project.id + '/research/saved-searches', { method: 'POST', body: JSON.stringify({ label, request }) }).then(async () => { state.savedResearchSearches = await api('/api/projects/' + project.id + '/research/saved-searches'); renderWorkspace(); toast('Suche gespeichert.'); }).catch((error) => toast(error.message, 'error')); } return; }
  if (event.target.closest('[data-save-research-settings]')) { const project = projectById(); if (project) { const weights = {}; document.querySelectorAll('[data-research-weight]').forEach((input) => { weights[input.dataset.researchWeight] = input.value; }); api('/api/projects/' + project.id + '/research/settings', { method: 'PATCH', body: JSON.stringify({ weights }) }).then(async () => { await loadProjects(); renderWorkspace(); toast('Relevanzgewichtung gespeichert und auf 100 % normalisiert.'); }).catch((error) => toast(error.message, 'error')); } return; }
  const row = event.target.closest("[data-open-project-row]");
  if (row && !event.target.closest("button, a, select, input")) return openProject(row.dataset.openProjectRow);
});

document.addEventListener('submit', (event) => {
  const form = event.target.closest('[data-research-form]');
  if (!form) return;
  event.preventDefault();
  runResearch(form).catch((error) => toast(error.message, 'error'));
});

document.addEventListener("change", (event) => {
  const researchResultFilter = event.target.closest('[data-research-result-filter]');
  if (researchResultFilter) return updateResearchResultFilter(researchResultFilter);
  const savedProjectSelect = event.target.closest('[data-saved-project-select]');
  if (savedProjectSelect) {
    state.savedTargetProjectId = savedProjectSelect.value;
    localStorage.setItem('myliteraturevault.savedTargetProjectId', state.savedTargetProjectId);
    return;
  }
  const statusControl = event.target.closest("[data-task-status]");
  if (statusControl) setTaskStatus(statusControl.dataset.taskStatus, statusControl.value).catch((error) => toast(error.message, "error"));
  const checklistControl = event.target.closest("[data-checklist-item]");
  if (checklistControl) setChecklistItem(checklistControl.dataset.checklistItem, checklistControl.checked).catch((error) => toast(error.message, "error"));
});

document.addEventListener("input", (event) => {
  const researchResultFilter = event.target.closest('[data-research-result-filter]');
  if (researchResultFilter) return updateResearchResultFilter(researchResultFilter);
  const conceptField = event.target.closest("[data-concept-field]");
  if (!conceptField) return;
  window.clearTimeout(state.conceptTimer);
  const status = $("conceptSaveState");
  if (status) status.textContent = "Ungespeichert";
  state.conceptTimer = window.setTimeout(() => saveResearchConcept(conceptField.dataset.conceptField, conceptField.value).catch((error) => {
    if (status) status.textContent = "Fehler beim Speichern";
    toast(error.message, "error");
  }), 500);
});

$("zoteroSearch").addEventListener("input", () => {
  window.clearTimeout(state.searchTimer);
  state.searchTimer = window.setTimeout(() => searchZotero($("zoteroSearch").value).catch((error) => {
    $("zoteroSearchStatus").textContent = error.message;
    $("zoteroResults").innerHTML = "";
  }), 320);
});

$("newProjectBtn").addEventListener("click", openNewProjectDialog);
$("editProjectBtn").addEventListener("click", openProjectDialog);
$("syncZoteroBtn").addEventListener("click", async () => {
  const project = projectById();
  if (!project) return;
  await api("/api/projects/" + project.id + "/zotero-collection/request", { method: "POST", body: "{}" });
  delete state.zoteroCollectionReferences[project.id];
  await loadProjects();
  renderWorkspace();
  toast("Zotero-Abgleich angefordert. Das lokale Zotero-Plugin übernimmt ihn beim nächsten Lauf.");
});
$("newTaskBtn").addEventListener("click", () => openTaskDialog());
$("newProjectForm").addEventListener("submit", (event) => createProject(event).catch((error) => toast(error.message, "error")));
$("projectForm").addEventListener("submit", (event) => saveProjectDialog(event).catch((error) => toast(error.message, "error")));
$("zoteroImportForm").addEventListener("submit", (event) => submitZoteroImport(event).catch((error) => toast(error.message, "error")));
$("deleteProjectForm").addEventListener("submit", (event) => confirmProjectDeletion(event).catch((error) => toast(error.message, "error")));
$("actionOpenProject").addEventListener("click", () => { const project = actionProject(); if (project) { $("projectActionsDialog").close(); openProject(project.id); } });
$("actionEditProject").addEventListener("click", () => { const project = actionProject(); if (project) setSelectedProject(project.id); $("projectActionsDialog").close(); openProjectDialog(); });
$("actionDuplicateProject").addEventListener("click", () => duplicateActionProject().catch((error) => toast(error.message, "error")));
$("actionArchiveProject").addEventListener("click", () => archiveActionProject().catch((error) => toast(error.message, "error")));
$("actionTrashProject").addEventListener("click", () => { $("projectActionsDialog").close(); openDeleteProjectDialog(state.actionProjectId); });
$("taskForm").addEventListener("submit", (event) => saveTaskDialog(event).catch((error) => toast(error.message, "error")));
$("taskCommentForm").addEventListener("submit", (event) => addTaskComment(event).catch((error) => toast(error.message, "error")));
$("issueChecklistForm").addEventListener("submit", (event) => addChecklistItem(event).catch((error) => toast(error.message, "error")));
$("sourceForm").addEventListener("submit", (event) => saveSourceDialog(event).catch((error) => toast(error.message, "error")));
$("refreshActivity").addEventListener("click", () => loadActivity().catch((error) => toast(error.message, "error")));
$("refreshRepositoryGraph").addEventListener("click", () => loadRepositoryGraph().catch((error) => toast(error.message, "error")));
$("refreshPulls").addEventListener("click", () => loadPulls().catch((error) => toast(error.message, "error")));
$("settingsBtn").addEventListener("click", () => openSettings().catch((error) => toast(error.message, "error")));
$("settingsForm").addEventListener("submit", (event) => saveSettings(event).catch((error) => toast(error.message, "error")));
$("pullBtn").addEventListener("click", () => pullRemote().catch((error) => toast(error.message, "error")));
$("commitBtn").addEventListener("click", openCommitDialog);
$("commitForm").addEventListener("submit", (event) => doManualCommit(event).catch((error) => toast(error.message, "error")));
$("stopServerBtn").addEventListener("click", () => stopServer().catch((error) => toast(error.message, "error")));
$("sidebarToggle").addEventListener("click", () => document.body.classList.toggle("sidebar-collapsed"));
applyTheme(localStorage.getItem(themeStorageKey));
$("themeToggle").addEventListener("click", () => applyTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light"));

window.setInterval(() => {
  const project = projectById();
  if (document.hidden || !project || !zoteroCollectionKey(project)) return;
  void loadZoteroCollectionReferences(project);
}, 30000);

(function setupSidebarResize() {
  const handle = $("resizeHandle");
  let dragging = false;
  let startX = 0;
  let startW = 0;
  const setWidth = (width) => document.documentElement.style.setProperty("--sidebar-w", Math.max(216, Math.min(410, width)) + "px");
  handle.addEventListener("mousedown", (event) => { dragging = true; startX = event.clientX; startW = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--sidebar-w"), 10) || 276; event.preventDefault(); });
  document.addEventListener("mousemove", (event) => { if (dragging) setWidth(startW + event.clientX - startX); });
  document.addEventListener("mouseup", () => { if (dragging) localStorage.setItem("myliteraturevault.sidebarWidth", parseInt(getComputedStyle(document.documentElement).getPropertyValue("--sidebar-w"), 10)); dragging = false; });
  const saved = Number(localStorage.getItem("myliteraturevault.sidebarWidth"));
  if (saved) setWidth(saved);
})();

Promise.all([loadStatus(), loadProjects(), loadResearchProviders(), loadSavedResearchResults()]).catch((error) => toast(error.message, "error"));
loadRepositoryGraph().catch((error) => {
  $("repositoryGraph").innerHTML = '<p class="repository-graph-loading error-copy">Repository-Graph konnte nicht geladen werden: ' + esc(error.message) + '</p>';
});
