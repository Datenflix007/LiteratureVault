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

async function ensureProjectCollections(projects) {
  const libraryID = Zotero.Libraries.userLibraryID;
  let created = 0;
  let linkedItems = 0;
  let missingItems = 0;

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
  }

  return { projects: projects.length, created, linkedItems, missingItems };
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
  window.alert("MyLiteratureVault\n\n" + collectionsMessage + itemsMessage + missingMessage);
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
