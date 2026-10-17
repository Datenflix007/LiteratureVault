const state = {
  projects: [],
  archivedProjects: [],
  trashProjects: [],
  pulls: [],
  selectedProjectId: localStorage.getItem("myliteraturevault.selectedProjectId") || "",
  actionProjectId: "",
  zotero: { available: false },
  zoteroSearchResults: [],
  searchTimer: null,
  conceptTimer: null,
  selectedTaskId: ""
};

const $ = (id) => document.getElementById(id);
const API_BASE = location.protocol === "http:" || location.protocol === "https:" ? "" : "http://localhost:8765";
const phaseLabels = { planning: "Konzept", research: "Recherche", writing: "Schreiben", review: "Überarbeitung", done: "Abgeschlossen" };
const taskStatusLabels = { open: "Offen", in_progress: "In Arbeit", blocked: "Blockiert", done: "Erledigt" };
const priorityLabels = { high: "Hoch", normal: "Normal", low: "Niedrig" };

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

function workspaceTaskCard(task, project) {
  const linked = (task.referenceKeys || []).map((key) => (project.references || []).find((reference) => reference.zoteroKey === key)).filter(Boolean);
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

function taskColumn(project, status, title, hint) {
  const tasks = (project.tasks || project.todos || []).filter((task) => task.status === status);
  return '<section class="task-column status-' + status + '"><header><div><span class="column-dot"></span><h4>' + title + '</h4></div><span>' + tasks.length + '</span></header><p class="column-hint">' + hint + '</p><div class="task-list">' + (tasks.length ? tasks.map((task) => workspaceTaskCard(task, project)).join("") : '<p class="empty-mini">Keine Aufgaben.</p>') + '</div></section>';
}

function sourceShelf(project, kind, label, icon) {
  const references = (project.references || []).filter((reference) => reference.kind === kind);
  const cards = references.length ? references.map((reference) => {
    const metadata = [reference.creators, reference.year, reference.itemType].filter(Boolean).join(" · ");
    const external = reference.doi ? "https://doi.org/" + encodeURIComponent(reference.doi.replace(/^https?:\/\/(dx\.)?doi\.org\//i, "")) : reference.url;
    return '<article class="source-card"><div class="source-card-head"><span class="source-key">' + esc(reference.zoteroKey) + '</span><button type="button" class="icon-button small" title="Verknüpfung aus Projekt entfernen" data-remove-reference="' + reference.id + '">×</button></div><h4>' + esc(reference.title) + '</h4><p>' + esc(metadata || "Zotero-Eintrag") + '</p>' + (reference.note ? '<blockquote>' + nl(reference.note) + '</blockquote>' : "") + '<div class="source-links"><a href="zotero://select/library/items/' + esc(reference.zoteroKey) + '">In Zotero öffnen</a>' + (external ? '<a href="' + esc(external) + '" target="_blank" rel="noreferrer">Web ↗</a>' : "") + '</div></article>';
  }).join("") : '<div class="source-empty"><p>Noch keine ' + esc(label.toLowerCase()) + ' verknüpft.</p><button type="button" class="quiet-btn" data-add-source>Aus Zotero hinzufügen</button></div>';
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

function renderWorkspace() {
  const project = projectById();
  $("workspaceEmpty").hidden = Boolean(project);
  $("workspaceContent").hidden = !project;
  if (!project) return;
  const phase = phaseLabels[project.status] || "Konzept";
  const question = project.researchQuestion || "Formuliere hier die Frage, die dein Projekt leitet.";
  const goal = project.paperGoal || "Definiere eine Arbeitsthese oder ein klares Ergebnis, auf das du hinarbeitest.";
  const conceptQuestion = project.researchConcept?.question || question;
  const zotero = project.zotero || {};
  const zoteroLabel = zotero.status === "linked" ? "Zotero: " + (zotero.collectionName || "verknüpft") : "Zotero-Abgleich ausstehend";
  $("projectWorkspace").innerHTML =
    '<section class="workspace-header compact-header phase-' + esc(project.status) + '"><div class="workspace-title"><p class="eyebrow">' + esc(phase) + ' · ' + (project.deadline ? "Termin " + esc(formatDate(project.deadline)) : "Termin offen") + '</p><h2>' + esc(project.name) + '</h2><div class="workspace-meta"><span class="state">' + esc(project.projectType || "Projekt") + '</span><span class="zotero-state ' + esc(zotero.status || "pending") + '">' + esc(zoteroLabel) + '</span></div></div>' + progressRing(project.progress, "Aufgaben") + '</section>' +
    '<section class="research-question-card"><p class="eyebrow">LEITENDE FORSCHUNGSFRAGE</p><h3>' + nl(conceptQuestion) + '</h3><div><span>Arbeitsthese / Ziel</span><p>' + nl(goal) + '</p></div></section>' +
    '<div class="workspace-metrics compact-metrics"><article><span>Aufgaben</span><strong>' + (project.todoCount || 0) + '</strong><p>' + (project.inProgressTodoCount || 0) + ' in Arbeit · ' + (project.doneTodoCount || 0) + ' erledigt</p></article><article><span>Literatur</span><strong>' + (project.literatureCount || 0) + '</strong><p>aus Zotero verknüpft</p></article><article><span>Quellen</span><strong>' + (project.sourceCount || 0) + '</strong><p>aus Zotero verknüpft</p></article><article><span>Termin</span><strong class="date-metric">' + esc(project.deadline ? formatDate(project.deadline) : "—") + '</strong><p>Projektbrief</p></article></div>' +
    researchConceptEditor(project) +
    '<section class="tasks-panel panel-card"><header><div><p class="eyebrow">LOKALE ISSUES</p><h3>Aufgaben</h3><p class="hint">Jede Aufgabe hat eine lokale Issue-Nummer, Verlauf, Kommentare und Checkliste.</p></div><button type="button" class="primary-btn compact" data-new-task>+ Aufgabe</button></header><div class="task-board">' +
      taskColumn(project, "open", "Offen", "Nächster sinnvoller Schritt") + taskColumn(project, "in_progress", "In Arbeit", "Gerade im Fokus") + taskColumn(project, "blocked", "Blockiert", "Benötigt eine Klärung") + taskColumn(project, "done", "Erledigt", "Dokumentierter Fortschritt") +
    '</div></section>' +
    '<section class="sources-panel"><header class="section-heading"><div><p class="eyebrow">QUELLENREGAL</p><h2>Verknüpfte Zotero-Literatur</h2><p>Ein Klick auf „In Zotero öffnen“ führt direkt zum Originaleintrag. Beim nächsten Plugin-Abgleich erscheinen die Einträge zusätzlich in den Projekt-Sammlungen.</p></div><button type="button" class="primary-btn" data-add-source>+ Aus Zotero verknüpfen</button></header><div class="source-grid">' + sourceShelf(project, "literature", "Literatur", "▣") + sourceShelf(project, "source", "Quellen", "⌁") + '</div></section>';
}

async function loadProjects() {
  state.projects = await api("/api/projects");
  if (state.selectedProjectId && !projectById()) setSelectedProject("");
  if (!state.selectedProjectId && state.projects.length) setSelectedProject(state.projects[0].id);
  renderProjects();
  renderWorkspace();
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
  $("repoName").textContent = (storage.provider || "lokal") + " · externer Speicher";
  $("storageBadge").textContent = storage.available ? (storage.provider || "lokal") + " verbunden" : "Speicher prüfen";
  $("storageBadge").className = storage.available ? "badge-online" : "badge-warning";
  $("zoteroBadge").textContent = zotero.available ? "Zotero verbunden" : "Zotero nicht erreichbar";
  $("zoteroBadge").className = zotero.available ? "badge-online" : "badge-warning";
  $("zoteroBadge").title = zotero.message || "";
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
  const references = project.references || [];
  return references.length ? references.map((reference) => '<label class="reference-option"><input type="checkbox" name="taskReference" value="' + esc(reference.zoteroKey) + '"' + (selectedKeys.includes(reference.zoteroKey) ? " checked" : "") + '><span><strong>' + esc(reference.title) + '</strong><small>' + esc([reference.creators, reference.year].filter(Boolean).join(" · ") || reference.zoteroKey) + '</small></span></label>').join("") : '<p class="empty-mini">Füge zunächst Literatur oder Quellen aus Zotero hinzu.</p>';
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
  const removeButton = event.target.closest("[data-remove-reference]");
  if (removeButton) return removeReference(removeButton.dataset.removeReference).catch((error) => toast(error.message, "error"));
  const issueButton = event.target.closest("[data-publish-issue]");
  if (issueButton) return publishIssue(issueButton.dataset.publishIssue).catch((error) => toast(error.message, "error"));
  const row = event.target.closest("[data-open-project-row]");
  if (row && !event.target.closest("button, a, select, input")) return openProject(row.dataset.openProjectRow);
  if (event.target.closest("#editProjectBrief")) return openProjectDialog();
});

document.addEventListener("change", (event) => {
  const statusControl = event.target.closest("[data-task-status]");
  if (statusControl) setTaskStatus(statusControl.dataset.taskStatus, statusControl.value).catch((error) => toast(error.message, "error"));
  const checklistControl = event.target.closest("[data-checklist-item]");
  if (checklistControl) setChecklistItem(checklistControl.dataset.checklistItem, checklistControl.checked).catch((error) => toast(error.message, "error"));
});

document.addEventListener("input", (event) => {
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
  await loadProjects();
  renderWorkspace();
  toast("Zotero-Abgleich angefordert. Das lokale Zotero-Plugin übernimmt ihn beim nächsten Lauf.");
});
$("newTaskBtn").addEventListener("click", () => openTaskDialog());
$("newProjectForm").addEventListener("submit", (event) => createProject(event).catch((error) => toast(error.message, "error")));
$("projectForm").addEventListener("submit", (event) => saveProjectDialog(event).catch((error) => toast(error.message, "error")));
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
$("refreshPulls").addEventListener("click", () => loadPulls().catch((error) => toast(error.message, "error")));
$("settingsBtn").addEventListener("click", () => openSettings().catch((error) => toast(error.message, "error")));
$("settingsForm").addEventListener("submit", (event) => saveSettings(event).catch((error) => toast(error.message, "error")));
$("pullBtn").addEventListener("click", () => pullRemote().catch((error) => toast(error.message, "error")));
$("commitBtn").addEventListener("click", openCommitDialog);
$("commitForm").addEventListener("submit", (event) => doManualCommit(event).catch((error) => toast(error.message, "error")));
$("stopServerBtn").addEventListener("click", () => stopServer().catch((error) => toast(error.message, "error")));
$("sidebarToggle").addEventListener("click", () => document.body.classList.toggle("sidebar-collapsed"));

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

Promise.all([loadStatus(), loadProjects()]).catch((error) => toast(error.message, "error"));
