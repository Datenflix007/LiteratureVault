# MyLiteratureVault

Lokaler WebDAV-Speicher für Zotero mit einem **extern synchronisierten Cloud-Ordner** und einer lokalen Projekt-UI.

Zotero-Anhänge werden nicht mehr nach GitHub und nicht nach Git LFS geschrieben. Der Docker-Container bindet stattdessen einen lokalen Ordner ein, den OneDrive, Nextcloud Desktop oder Dropbox bereits mit Ihrem Cloud-Konto synchronisiert.

## So funktioniert der Speicher

Ein Freigabelink ist ein nützlicher Verweis, aber kein beschreibbares Laufwerk für Docker. Deshalb werden in .env.local drei Werte gespeichert:

    STORAGE_PROVIDER=onedrive
    ZOTERO_STORAGE_PATH=C:\Users\IhrName\OneDrive\MyLiteratureVault
    STORAGE_SHARE_URL=https://onedrive.live.com/...

- ZOTERO_STORAGE_PATH ist entscheidend: das ist der lokal synchronisierte Ordner.
- STORAGE_SHARE_URL ist optional und dient als Referenz in den Einstellungen.
- OneDrive, Dropbox und Nextcloud müssen auf dem Computer installiert sein und diesen Ordner synchronisieren.

GitHub bleibt ausschließlich für den Quellcode. .gitignore schützt den alten Fallback-Ordner data/, lokale Konfiguration und Laufzeitdaten.

## Schnellstart (Windows)

Starten Sie quickstart.bat. Beim ersten Start werden Cloud-Anbieter, lokaler synchronisierter Ordner und optionaler Freigabelink abgefragt. Der Ordner wird bei Bedarf angelegt und als Docker-Bind-Mount für WebDAV verwendet.

Danach:

    WebDAV: http://localhost:8080
    UI:     http://localhost:8765

In Zotero: Einstellungen → Sync → Datei-Sync WebDAV, dann die WebDAV-URL sowie Benutzer und Passwort aus .env.local eintragen.

## Projekte, Literatur, Quellen und TODOs

In der Ansicht **Projekte** kann ein Projekt angelegt werden. MyLiteratureVault erzeugt im externen Cloud-Ordner automatisch:

    Projekte/
      Mein Projekt/
        Literatur/
        Quellen/

TODOs gehören immer zu genau einem Projekt. Sie werden gemeinsam mit den Projektdaten im externen Speicher abgelegt und deshalb über den Cloud-Desktop-Client synchronisiert, nicht als GitHub Issue und nicht als Git-Datei.

## Speicher in der UI ändern

1. UI öffnen: http://localhost:8765
2. In der Sidebar **Speicher** wählen.
3. Anbieter, lokal synchronisierten Ordner und optionalen Freigabelink eintragen.
4. Speichern und anschließend quickstart.bat erneut starten, damit Docker den neuen Ordner einbindet.

Beim Wechsel wird kein vorhandener Ordner verschoben oder gelöscht. Kopieren Sie vorhandene Daten bewusst selbst in den neuen Cloud-Ordner, bevor Sie die alte Ablage entfernen.

## Code-Aktionen

Code pullen, Code committen und Pull Requests betreffen weiterhin nur dieses Projekt-Repository. Der Commit-Endpunkt schließt den alten Ordner data/ explizit aus. Der frühere auto-sync ist nun nur noch ein Speicher-Monitor und erzeugt keine Git-Commits für Zotero-Dateien.

## Wichtige Dateien

    docker-compose.yml  Bindet ZOTERO_STORAGE_PATH in den WebDAV-Container ein
    .env.local          Private WebDAV- und Speicher-Konfiguration, nicht committed
    vault-ui.ps1        Lokaler Server, Projekt- und Speicher-API
    ui/                 Projekt-UI
    auto-sync.ps1       Reiner Speicher-Aktivitätsmonitor, kein Git-Sync
