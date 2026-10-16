const state = { projects: [], pulls: [] };
const $ = (id) => document.getElementById(id);
const API_BASE = location.protocol === "http:" || location.protocol === "https:" ? "" : "http://localhost:8765";

async function api(path, options = {}) {
  const response = await fetch(API_BASE + path, { headers: { "Content-Type": "application/json" }, ...options });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Request fehlgeschlagen");
  return data;
}
function esc(value) { return String(value || "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;"); }
function toast(message) {
  $("toast").textContent = message; $("toast").classList.add("show");
  setTimeout(() => $("toast").classList.remove("show"), 3200);
}
function setView(name) {
  document.querySelectorAll(".nav").forEach((button) => button.classList.toggle("active", button.dataset.view === name));
  document.querySelectorAll(".view").forEach((view) => view.classList.remove("active"));
  $(name + "View").classList.add("active");
  $("viewTitle").textContent = ({ projects: "Projektbereiche", graph: "Code & Speicher-Aktivität", pulls: "Pull Requests" })[name];
}

async function loadStatus() {
  const status = await api("/api/status"), storage = status.storage || {};
  $("repoName").textContent = (storage.provider || "lokal") + " · externer Speicher";
  $("storageBadge").textContent = storage.available ? (storage.provider || "lokal") + " verbunden" : "Speicher prüfen";
  $("syncBadge").textContent = status.ahead + " ↑ / " + status.behind + " ↓ Code";
  $("statusLine").textContent = storage.available
    ? "Anhänge und Projekte: " + storage.path + " — außerhalb von Git und Git LFS"
    : "Der Speicherordner ist nicht erreichbar: " + (storage.path || "nicht konfiguriert");
}
function todoMarkup(project) {
  const todos = project.todos || [];
  if (!todos.length) return '<p class="empty-state">Noch keine TODOs. Plane den nächsten sinnvollen Schritt.</p>';
  return todos.map((todo) => {
    const done = todo.status === "done";
    return '<li class="project-todo ' + (done ? "is-done" : "") + '">' +
      '<button class="todo-toggle" data-project-id="' + project.id + '" data-todo-id="' + todo.id + '" data-todo-status="' + todo.status + '" title="Status wechseln">' + (done ? "✓" : "") + '</button>' +
      '<div><strong>' + esc(todo.title) + '</strong>' + (todo.body ? '<span>' + esc(todo.body) + '</span>' : "") + '</div></li>';
  }).join("");
}
function renderProjects(projects) {
  const target = $("projectsList"); target.innerHTML = "";
  if (!projects.length) {
    target.innerHTML = '<article class="empty-project"><span class="project-icon">✦</span><h2>Dein erster Projektbereich</h2><p>Lege ein Projekt an. Literatur, Quellen und TODOs werden sauber an einem Ort strukturiert.</p><button class="primary-btn" data-new-project>Projekt anlegen</button></article>';
    return;
  }
  projects.forEach((project) => {
    const card = document.createElement("article"); card.className = "project-card";
    card.innerHTML = '<div class="project-head"><div><span class="eyebrow">PROJEKT</span><h2>' + esc(project.name) + '</h2></div><span class="todo-count">' + (project.openTodoCount || 0) + ' offen</span></div>' +
      '<div class="folder-strip"><span>▣ Literatur</span><span>⌁ Quellen</span></div><p class="project-path">Projekte/' + esc(project.folderName) + '</p>' +
      '<ul class="project-todos">' + todoMarkup(project) + '</ul><button class="add-todo" data-new-todo="' + project.id + '" data-project-name="' + esc(project.name) + '">+ TODO für dieses Projekt</button>';
    target.appendChild(card);
  });
}
async function loadProjects() { state.projects = await api("/api/projects"); renderProjects(state.projects); }
function openNewProjectDialog() { $("newProjectName").value = ""; $("newProjectDialog").showModal(); setTimeout(() => $("newProjectName").focus(), 30); }
async function createProject(event) {
  event.preventDefault(); const name = $("newProjectName").value.trim();
  if (!name) return toast("Bitte einen Projektnamen eingeben.");
  await api("/api/projects", { method: "POST", body: JSON.stringify({ name }) });
  $("newProjectDialog").close(); toast("Projekt, Literatur- und Quellenordner wurden angelegt."); await loadProjects();
}
function openNewTodoDialog(id, name) {
  $("newTodoProjectId").value = id; $("newTodoProjectName").textContent = "TODO · " + name;
  $("newTodoTitle").value = ""; $("newTodoBody").value = ""; $("newTodoDialog").showModal(); setTimeout(() => $("newTodoTitle").focus(), 30);
}
async function createTodo(event) {
  event.preventDefault(); const projectId = $("newTodoProjectId").value, title = $("newTodoTitle").value.trim();
  if (!title) return toast("Bitte einen TODO-Titel eingeben.");
  await api("/api/projects/" + projectId + "/todos", { method: "POST", body: JSON.stringify({ title, body: $("newTodoBody").value.trim() }) });
  $("newTodoDialog").close(); toast("TODO im Projekt gespeichert."); await loadProjects();
}
async function toggleTodo(projectId, todoId, status) {
  await api("/api/projects/" + projectId + "/todos/" + todoId, { method: "PATCH", body: JSON.stringify({ status: status === "done" ? "open" : "done" }) });
  await loadProjects();
}
function renderGraphItems(commits, entries) {
  const graph = $("commitGraph"), items = commits.map((data) => ({ type: "commit", ts: new Date(data.date), data }))
    .concat(entries.map((data) => ({ type: "log", ts: new Date(data.ts), data }))).sort((a, b) => b.ts - a.ts);
  graph.innerHTML = items.length ? "" : '<p class="empty-state">Noch keine Aktivität.</p>';
  items.forEach((item) => {
    const row = document.createElement("div");
    if (item.type === "commit") {
      row.className = "commit-row"; row.innerHTML = '<div class="rail"><span class="dot"></span></div><div><div class="commit-subject">' + esc(item.data.subject) + '</div><div class="commit-meta">' + esc(item.data.author) + ' · ' + item.ts.toLocaleString() + '</div></div><div class="commit-hash">' + esc(item.data.short) + '</div>';
    } else {
      row.className = "sync-row"; row.innerHTML = '<div class="rail"><span class="sync-dot ' + esc(item.data.level || "info") + '"></span></div><div class="sync-text"><span class="sync-time">' + item.ts.toLocaleTimeString() + '</span>' + esc(item.data.text) + '</div>';
    } graph.appendChild(row);
  });
}
async function loadGraph() { const both = await Promise.all([api("/api/log"), api("/api/sync-log").catch(() => [])]); renderGraphItems(both[0], Array.isArray(both[1]) ? both[1] : []); }
function renderPulls(items) {
  const target = $("pullsList"); target.innerHTML = items.length ? "" : '<p class="empty-state">Keine Pull Requests gefunden.</p>';
  items.forEach((item) => { const card = document.createElement("article"); card.className = "item-card"; card.innerHTML = '<header><div><h3>#' + item.number + " " + esc(item.title) + '</h3><p>' + esc((item.body || "").slice(0, 220)) + '</p></div><span class="state">' + esc(item.state) + '</span></header><a href="' + item.html_url + '" target="_blank" rel="noreferrer"><button>GitHub ↗</button></a>'; target.appendChild(card); });
}
async function loadPulls() { state.pulls = await api("/api/pulls"); renderPulls(state.pulls); }
async function openSettings() {
  const settings = await api("/api/settings"); $("storageProvider").value = settings.storageProvider || "onedrive"; $("storagePath").value = settings.storagePath || ""; $("storageShareUrl").value = settings.storageShareUrl || "";
  $("githubUsername").value = settings.githubUsername || ""; $("githubEmail").value = settings.githubEmail || ""; $("githubToken").value = ""; $("tokenHint").textContent = settings.tokenSet ? "Ein Token ist gespeichert. Feld leer lassen, um ihn nicht zu ändern." : "Kein GitHub-Token gespeichert.";
  $("webdavUrl").value = settings.webdavUrl || "http://localhost:8080"; $("webdavUsername").value = settings.webdavUsername || "zotero"; $("webdavPassword").value = settings.webdavPassword || "changeme123"; $("settingsDialog").showModal();
}
async function saveSettings(event) {
  event.preventDefault(); const storagePath = $("storagePath").value.trim(); if (!storagePath) return toast("Bitte den lokalen Cloud-Ordner eintragen.");
  await api("/api/settings", { method: "POST", body: JSON.stringify({ storageProvider: $("storageProvider").value, storagePath, storageShareUrl: $("storageShareUrl").value.trim(), githubUsername: $("githubUsername").value.trim(), githubEmail: $("githubEmail").value.trim(), githubToken: $("githubToken").value, webdavUrl: $("webdavUrl").value.trim(), webdavUsername: $("webdavUsername").value.trim(), webdavPassword: $("webdavPassword").value }) });
  $("settingsDialog").close(); toast("Gespeichert. WebDAV über quickstart.bat neu starten, damit Docker den neuen Ordner einbindet."); await Promise.all([loadStatus(), loadProjects()]);
}
async function pullRemote() { const result = await api("/api/pull", { method: "POST", body: "{}" }); toast(result.skipped ? result.reason : result.pulled ? "Code-Pull abgeschlossen" : "Code-Pull fehlgeschlagen"); await Promise.all([loadStatus(), loadGraph()]); }
function openCommitDialog() { $("commitMessage").value = "Code-Update " + new Date().toLocaleString(); $("commitDialog").showModal(); }
async function doManualCommit() {
  const message = $("commitMessage").value.trim(); if (!message) return toast("Bitte eine Commit-Nachricht eingeben."); $("commitDialog").close();
  const result = await api("/api/commit", { method: "POST", body: JSON.stringify({ message, push: $("commitPush").checked }) });
  toast(result.ok ? (result.pushed ? "Code committed und gepusht" : "Code committed") : "Fehler: " + result.error); await Promise.all([loadStatus(), loadGraph()]);
}
async function stopServer() { if (!confirm("Server wirklich stoppen?")) return; try { await api("/api/shutdown", { method: "POST", body: "{}" }); } catch (_) {} $("statusLine").textContent = "Server gestoppt."; }

document.querySelectorAll(".nav").forEach((button) => button.addEventListener("click", () => setView(button.dataset.view)));
document.body.addEventListener("click", (event) => {
  if (event.target.closest("[data-new-project]")) return openNewProjectDialog();
  const add = event.target.closest("[data-new-todo]"); if (add) return openNewTodoDialog(add.dataset.newTodo, add.dataset.projectName);
  const todo = event.target.closest("[data-todo-id]"); if (todo) toggleTodo(todo.dataset.projectId, todo.dataset.todoId, todo.dataset.todoStatus).catch((error) => toast(error.message));
});
$("newProjectBtn").addEventListener("click", openNewProjectDialog);
$("newProjectSaveBtn").addEventListener("click", (event) => createProject(event).catch((error) => toast(error.message)));
$("newTodoSaveBtn").addEventListener("click", (event) => createTodo(event).catch((error) => toast(error.message)));
$("refreshGraph").addEventListener("click", () => Promise.all([loadStatus(), loadGraph()]).catch((error) => toast(error.message)));
$("refreshPulls").addEventListener("click", () => loadPulls().catch((error) => toast(error.message)));
$("settingsBtn").addEventListener("click", () => openSettings().catch((error) => toast(error.message)));
$("pullBtn").addEventListener("click", () => pullRemote().catch((error) => toast(error.message)));
$("commitBtn").addEventListener("click", openCommitDialog); $("commitSaveBtn").addEventListener("click", () => doManualCommit().catch((error) => toast(error.message)));
$("stopServerBtn").addEventListener("click", () => stopServer().catch((error) => toast(error.message)));
$("sidebarToggle").addEventListener("click", () => document.body.classList.toggle("sidebar-collapsed"));

(function () { const handle = $("resizeHandle"); let dragging = false, startX = 0, startW = 0; const setWidth = (width) => document.documentElement.style.setProperty("--sidebar-w", Math.max(180, Math.min(440, width)) + "px");
  handle.addEventListener("mousedown", (event) => { dragging = true; startX = event.clientX; startW = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--sidebar-w")) || 260; event.preventDefault(); });
  document.addEventListener("mousemove", (event) => { if (dragging) setWidth(startW + event.clientX - startX); }); document.addEventListener("mouseup", () => { if (dragging) localStorage.setItem("sidebarW", parseInt(getComputedStyle(document.documentElement).getPropertyValue("--sidebar-w"))); dragging = false; });
  if (localStorage.getItem("sidebarW")) setWidth(Number(localStorage.getItem("sidebarW"))); })();
Promise.all([loadStatus(), loadProjects(), loadGraph()]).then(() => loadPulls().catch(() => {})).catch((error) => toast(error.message));
