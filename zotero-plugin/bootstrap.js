var MyLiteratureVault;

const PROJECTS_API_URL = "http://localhost:8765/api/projects";

function log(message) {
  Zotero.debug("MyLiteratureVault: " + message);
}

function getProjectCollectionName(project, projects) {
  const sameNameCount = projects.filter((candidate) => candidate.name === project.name).length;
  return sameNameCount > 1 ? project.name + " (" + project.folderName + ")" : project.name;
}

async function getProjectsFromLocalUi() {
  const request = await Zotero.HTTP.request("GET", PROJECTS_API_URL, {
    responseType: "json",
    timeout: 5000
  });
  if (request.status !== 200 || !Array.isArray(request.response)) {
    throw new Error("Die lokale Projekt-UI ist nicht erreichbar.");
  }
  return request.response;
}

async function getOrCreateCollection(libraryID, parentCollection, name) {
  const candidates = parentCollection
    ? parentCollection.getChildCollections(false)
    : Zotero.Collections.getByLibrary(libraryID, false);
  const existing = candidates.find((collection) => collection.name === name);
  if (existing) {
    return existing;
  }

  const collection = new Zotero.Collection();
  collection.libraryID = libraryID;
  collection.name = name;
  collection.parentID = parentCollection ? parentCollection.id : false;
  const id = await collection.saveTx();
  return Zotero.Collections.get(id);
}

function getLinkedProjectCollection(libraryID, project) {
  const key = String(project.zotero?.collectionKey || "").trim().toUpperCase();
  if (!/^[A-Z0-9]{8}$/.test(key) || typeof Zotero.Collections.getByLibraryAndKey !== "function") {
    return null;
  }
  const collection = Zotero.Collections.getByLibraryAndKey(libraryID, key);
  return collection && !collection.parentID ? collection : null;
}

async function reportProjectCollection(project, libraryID, collection) {
  const payload = JSON.stringify({
    libraryID,
    collectionKey: collection.key,
    collectionName: collection.name
  });
  const request = await Zotero.HTTP.request("POST", PROJECTS_API_URL + "/" + project.id + "/zotero-collection", {
    body: payload,
    headers: { "Content-Type": "application/json" },
    responseType: "json",
    timeout: 5000
  });
  if (request.status < 200 || request.status >= 300) {
    throw new Error("Die Projekt-UI konnte die Zotero-Zuordnung nicht speichern.");
  }
}

async function reportImportedResearchResult(project, importEntry, item) {
  const request = await Zotero.HTTP.request("POST", PROJECTS_API_URL + "/" + project.id + "/zotero-imports/" + importEntry.id + "/complete", {
    body: JSON.stringify({ zoteroKey: item.key }),
    headers: { "Content-Type": "application/json" },
    responseType: "json",
    timeout: 5000
  });
  if (request.status < 200 || request.status >= 300) {
    throw new Error("Die Projekt-UI konnte den Zotero-Import nicht bestätigen.");
  }
}

function zoteroItemType(publicationType) {
  const type = String(publicationType || "").toLowerCase();
  if (type.includes("journal") || type.includes("article")) return "journalArticle";
  if (type.includes("book") || type.includes("monograph")) return "book";
  if (type.includes("thesis") || type.includes("dissertation")) return "thesis";
  if (type.includes("report")) return "report";
  return "document";
}

function creatorFromName(name) {
  const value = String(name || "").trim();
  if (!value) return null;
  const comma = value.indexOf(",");
  if (comma > 0) return { creatorType: "author", lastName: value.slice(0, comma).trim(), firstName: value.slice(comma + 1).trim() };
  const parts = value.split(/\s+/);
  return parts.length > 1
    ? { creatorType: "author", firstName: parts.slice(0, -1).join(" "), lastName: parts[parts.length - 1] }
    : { creatorType: "author", name: value, fieldMode: 1 };
}

async function findExistingResearchItem(libraryID, result) {
  const doi = String(result.doi || "").replace(/^https?:\/\/(dx\.)?doi\.org\//i, "").trim();
  if (doi) {
    const search = new Zotero.Search();
    search.libraryID = libraryID;
    search.addCondition("DOI", "is", doi);
    const ids = await search.search();
    if (ids.length) return Zotero.Items.get(ids[0]);
  }
  return null;
}

async function importResearchResult(libraryID, result) {
  const existing = await findExistingResearchItem(libraryID, result);
  if (existing) return { item: existing, created: false };
  const item = new Zotero.Item(zoteroItemType(result.publicationType));
  item.libraryID = libraryID;
  item.setField("title", String(result.title || "Ohne Titel"));
  if (result.publicationYear) item.setField("date", String(result.publicationYear));
  if (result.doi) item.setField("DOI", String(result.doi));
  if (result.isbn?.length) item.setField("ISBN", result.isbn.join("; "));
  if (result.issn?.length) item.setField("ISSN", result.issn.join("; "));
  if (result.language) item.setField("language", String(result.language));
  if (result.abstract) item.setField("abstractNote", String(result.abstract));
  if (result.publisher) item.setField("publisher", String(result.publisher));
  item.setField("url", String(result.sourceUrl || result.fulltextUrl || ""));
  const creators = (result.authors || []).map(creatorFromName).filter(Boolean);
  if (creators.length) item.setCreators(creators);
  await item.saveTx();
  return { item, created: true };
}

async function ensureProjectCollections(projects) {
  const libraryID = Zotero.Libraries.userLibraryID;
  let created = 0;
  let linkedItems = 0;
  let missingItems = 0;
  let importedItems = 0;

  for (const project of projects) {
    const projectName = getProjectCollectionName(project, projects);
    const linkedProject = getLinkedProjectCollection(libraryID, project);
    const beforeProject = linkedProject || Zotero.Collections.getByLibrary(libraryID, false)
      .find((collection) => collection.name === projectName);
    const projectCollection = linkedProject || await getOrCreateCollection(libraryID, null, projectName);
    if (!beforeProject) {
      created++;
    }

    try {
      await reportProjectCollection(project, libraryID, projectCollection);
    } catch (error) {
      // The collection is still valid. Retrying in the next cycle repairs a temporarily unavailable UI.
      log("Could not persist collection mapping for " + project.name + ": " + error);
    }

    const children = {};
    for (const childName of ["Literatur", "Quellen"]) {
      const beforeChild = projectCollection.getChildCollections(false)
        .find((collection) => collection.name === childName);
      children[childName] = await getOrCreateCollection(libraryID, projectCollection, childName);
      if (!beforeChild) {
        created++;
      }
    }

    for (const reference of project.references || []) {
      const key = String(reference.zoteroKey || "").trim().toUpperCase();
      if (!/^[A-Z0-9]{8}$/.test(key)) {
        continue;
      }
      const target = reference.kind === "source" ? children.Quellen : children.Literatur;
      const item = Zotero.Items.getByLibraryAndKey(libraryID, key);
      if (!item) {
        missingItems++;
        log("Linked Zotero item not found: " + key + " (project " + project.name + ")");
        continue;
      }
      const existingItemIDs = new Set(target.getChildItems(true));
      if (!existingItemIDs.has(item.id)) {
        await Zotero.DB.executeTransaction(async () => {
          await target.addItem(item.id);
        });
        linkedItems++;
      }
    }

    for (const importEntry of project.zoteroImportQueue || []) {
      if (importEntry.status !== "pending" || !importEntry.result) continue;
      const target = importEntry.kind === "source" ? children.Quellen : children.Literatur;
      try {
        const imported = await importResearchResult(libraryID, importEntry.result);
        const existingItemIDs = new Set(target.getChildItems(true));
        if (!existingItemIDs.has(imported.item.id)) {
          await Zotero.DB.executeTransaction(async () => target.addItem(imported.item.id));
          linkedItems++;
        }
        await reportImportedResearchResult(project, importEntry, imported.item);
        if (imported.created) importedItems++;
      } catch (error) {
        log("Research import failed for " + project.name + ": " + error);
      }
    }
  }

  return { projects: projects.length, created, linkedItems, missingItems, importedItems };
}

function showSyncResult(window, result) {
  const collectionsMessage = result.created
    ? result.created + " Zotero-Sammlung(en) angelegt."
    : "Alle " + result.projects + " Projektbereiche sind bereits in Zotero vorhanden.";
  const itemsMessage = result.linkedItems
    ? "\n" + result.linkedItems + " verknüpfte Literatur-/Quelleneinträge ergänzt."
    : "";
  const missingMessage = result.missingItems
    ? "\n" + result.missingItems + " verknüpfte Einträge wurden in Zotero nicht gefunden."
    : "";
  const importsMessage = result.importedItems ? "\n" + result.importedItems + " Recherchetreffer neu in Zotero angelegt." : "";
  window.alert("MyLiteratureVault\n\n" + collectionsMessage + itemsMessage + importsMessage + missingMessage);
}

function installMenuItem(window, id, label, callback) {
  const doc = window.document;
  if (doc.getElementById(id)) {
    return;
  }
  const menuItem = doc.createXULElement("menuitem");
  menuItem.id = id;
  menuItem.setAttribute("label", label);
  menuItem.addEventListener("command", callback);
  const menu = doc.getElementById("menu_viewPopup") || doc.getElementById("menu_ToolsPopup");
  if (menu) {
    menu.appendChild(menuItem);
  }
}

function install() {
  log("Installed");
}

async function startup({ id, version, rootURI }) {
  log("Starting");
  MyLiteratureVault = {
    id,
    version,
    rootURI,
    syncTimer: null,
    syncPromise: null,

    async syncProjects({ window, interactive = false } = {}) {
      if (this.syncPromise) {
        return this.syncPromise;
      }
      this.syncPromise = (async () => {
        try {
          const projects = await getProjectsFromLocalUi();
          const result = await ensureProjectCollections(projects);
          log("Synced " + result.projects + " projects; created " + result.created + " collections; linked " + result.linkedItems + " items.");
          if (interactive && window) {
            showSyncResult(window, result);
          }
          return result;
        } catch (error) {
          log("Project sync skipped: " + error);
          if (interactive && window) {
            window.alert("MyLiteratureVault\n\nProjekt-Synchronisation fehlgeschlagen: " + error.message);
          }
          return null;
        } finally {
          this.syncPromise = null;
        }
      })();
      return this.syncPromise;
    },

    addToWindow(window) {
      if (!window.ZoteroPane) {
        return;
      }
      installMenuItem(
        window,
        "myliteraturevault-open-ui",
        "MyLiteratureVault öffnen",
        () => this.openUi(window)
      );
      installMenuItem(
        window,
        "myliteraturevault-sync-projects",
        "MyLiteratureVault-Projekte mit Zotero synchronisieren",
        () => this.syncProjects({ window, interactive: true })
      );
    },

    addToAllWindows() {
      for (const win of Zotero.getMainWindows()) {
        this.addToWindow(win);
      }
    },

    removeFromWindow(window) {
      for (const id of ["myliteraturevault-open-ui", "myliteraturevault-sync-projects"]) {
        window.document.getElementById(id)?.remove();
      }
    },

    removeFromAllWindows() {
      for (const win of Zotero.getMainWindows()) {
        this.removeFromWindow(win);
      }
    },

    openUi(window) {
      window.openDialog(
        this.rootURI + "vault.xhtml",
        "myliteraturevault-ui",
        "chrome,resizable,centerscreen,width=1200,height=800"
      );
    }
  };

  MyLiteratureVault.addToAllWindows();
  MyLiteratureVault.syncProjects();
  MyLiteratureVault.syncTimer = setInterval(() => MyLiteratureVault.syncProjects(), 30000);
}

function onMainWindowLoad({ window }) {
  MyLiteratureVault?.addToWindow(window);
}

function onMainWindowUnload({ window }) {
  MyLiteratureVault?.removeFromWindow(window);
}

function shutdown() {
  log("Shutting down");
  if (MyLiteratureVault?.syncTimer) {
    clearInterval(MyLiteratureVault.syncTimer);
  }
  MyLiteratureVault?.removeFromAllWindows();
  MyLiteratureVault = undefined;
}

function uninstall() {
  log("Uninstalled");
}
