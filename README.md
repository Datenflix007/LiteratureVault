# MyLiteratureVault

MyLiteratureVault verbindet einen lokalen WebDAV-Speicher für Zotero mit einer
lokalen Forschungsprojekt-UI. Zotero-Anhänge, Projektordner und private
Forschungsdaten bleiben in einem lokal synchronisierten Cloud-Ordner – niemals
in Git oder Git LFS.

## Was das Projekt übernimmt

- Docker stellt einen lokalen WebDAV-Endpunkt für Zotero bereit.
- Die UI verwaltet Forschungsprojekte, Aufgaben, Projektmetadaten und lokale
  Projektordner.
- Das Zotero-Plugin legt für jedes UI-Projekt eine Sammlung unter **Meine
  Bibliothek** an und ergänzt die Unterordner **Literatur** und **Quellen**.
- Die UI liest die bibliografischen Einträge aus diesen beiden Zotero-
  Unterordnern. Anhänge, Notizen und Annotationen werden dabei nicht als eigene
  Quellenkarten dargestellt.

## Voraussetzungen

- Docker Desktop unter Windows
- Ein lokal verfügbarer Ordner, den OneDrive, Nextcloud Desktop oder Dropbox
  bereits synchronisiert
- Zotero 10 mit dem MyLiteratureVault-Plugin (siehe unten)

Ein Freigabelink allein ist kein beschreibbares Docker-Laufwerk. Verwenden Sie
als `ZOTERO_STORAGE_PATH` immer den lokalen, vom Cloud-Desktop-Client
synchronisierten Ordner.

## Schnellstart unter Windows

1. `quickstart.bat` starten.
2. Beim ersten Durchlauf Anbieter, lokal synchronisierten Ordner und optional
   einen Freigabelink angeben.
3. Nach erfolgreichem Start sind diese lokalen Adressen verfügbar:

   ```text
   WebDAV: http://localhost:8080
   UI:     http://localhost:8765
   ```

4. In Zotero unter **Einstellungen → Sync → Datei-Synchronisation → WebDAV**
   die WebDAV-URL sowie Benutzername und Passwort aus `.env.local` eintragen.

Der Schnellstart wartet bis zu vier Minuten auf Docker Desktop und anschließend
bis zu zwei Minuten auf den WebDAV-Container. Die Meldung
`Container zotero-webdav Creating` bedeutet während dieser Zeit, dass Docker
den Container noch vorbereitet. Erst nach Ablauf der Wartezeit wird der
Container-Status mitsamt den letzten Logs ausgegeben.

Die lokale Konfiguration liegt in `.env.local` und wird nicht committed:

```text
STORAGE_PROVIDER=onedrive
ZOTERO_STORAGE_PATH=C:\Users\IhrName\OneDrive\MyLiteratureVault
STORAGE_SHARE_URL=https://…
```

`STORAGE_SHARE_URL` ist optional und dient nur als Verweis in der UI. Beim
Wechsel des Speicherorts verschiebt MyLiteratureVault keine Daten automatisch;
kopieren Sie vorhandene Forschungsdaten bewusst in den neuen synchronisierten
Ordner, bevor Sie die alte Ablage entfernen.

## Projekte und externe Datenablage

Beim Anlegen eines Projekts erzeugt die UI im externen Speicher:

```text
Projekte/
  Mein Projekt/
    Literatur/
    Quellen/
```

Projektstatus, Aufgaben und Referenzverknüpfungen liegen gemeinsam mit diesen
Projektordnern im externen Speicher. Der Cloud-Desktop-Client synchronisiert
sie; der mitgestartete Speicher-Monitor erstellt ausdrücklich keine Git-Commits
für Zotero-Dateien.

## Zotero-Projektsammlungen

Nach dem Plugin-Abgleich entsteht in Zotero die passende Struktur:

```text
Meine Bibliothek/
  Mein Projekt/
    Literatur/
    Quellen/
```

Das Plugin gleicht beim Zotero-Start und danach etwa alle 30 Sekunden ab. Für
einen sofortigen Abgleich steht in Zotero unter **Ansicht** der Eintrag
**MyLiteratureVault-Projekte mit Zotero synchronisieren** bereit. Bestehende
Sammlungen werden wiederverwendet; der Abgleich löscht keine eigenen
Zotero-Sammlungen.

Die Projektdatei speichert die stabile Zuordnung aus Projekt-ID, Bibliothek und
Collection-Key. Ist Zotero oder das Plugin beim Anlegen eines Projekts nicht
gestartet, bleibt der Abgleich ausstehend und wird beim nächsten Plugin-Lauf
nachgeholt. Im Projekt-Workspace kann zusätzlich **Zotero-Abgleich anfordern**
gewählt werden.

Einträge, die Sie in den Zotero-Unterordner **Literatur** oder **Quellen**
ablegen, erscheinen automatisch im Quellenregal und bei der Aufgaben-
Verknüpfung der UI. Die geöffnete UI aktualisiert diese Liste ungefähr alle
30 Sekunden. **Zotero-Abgleich anfordern** markiert den Abgleich als
ausstehend; das lokale Plugin übernimmt ihn beim nächsten Lauf. Ein Umbenennen
eines UI-Projekts benennt die bestehende Zotero-Sammlung bewusst nicht
automatisch um.

## Plugin für Zotero 10 installieren

Die aktuelle Erweiterung ist Version **0.4.1** und ist für Zotero `10.0.*`
ausgelegt.

1. Paket bauen:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-zotero-plugin.ps1
   ```

2. In Zotero **Extras → Erweiterungen → Zahnrad → Add-on aus Datei
   installieren…** wählen.
3. `dist\myliteraturevault-zotero.xpi` auswählen und Zotero neu starten.
4. Den manuellen Projekt-Abgleich unter **Ansicht** ausführen oder kurz auf den
   automatischen Abgleich warten.

Das Manifest enthält eine Update-Adresse, aber es wird derzeit kein
veröffentlichtes XPI-Release über `updates.json` verteilt. Aktualisieren Sie das
Plugin daher nach einem lokalen Build bewusst über **Add-on aus Datei
installieren…**.

Falls ein Projekt keine Sammlung erhält, prüfen Sie zuerst, ob die Erweiterung
in Zotero aktiviert ist, starten Zotero neu und führen anschließend den
manuellen Abgleich aus. Die UI unter `http://localhost:8765` zeigt den
Verbindungs- und Abgleichstatus an.

## Nützliche Befehle

```powershell
# WebDAV, Speicher-Monitor und UI starten bzw. prüfen
.\quickstart.bat
.\check-status.bat

# Nur die UI starten
.\start-ui.bat

# Plugin-Paket neu erzeugen
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-zotero-plugin.ps1
```

## Git- und Datenschutzgrenzen

GitHub enthält nur den Quellcode dieses Repositories. `.gitignore` schützt
`.env.local`, Laufzeitprotokolle, den früheren lokalen Fallback `data/` und die
generierte XPI-Datei. WebDAV-Anhänge, Zotero-Daten und private
Forschungsprojektdateien gehören ausschließlich in den externen,
synchronisierten Speicher.

## Wichtige Dateien

| Datei | Zweck |
| --- | --- |
| `quickstart.ps1` / `quickstart.bat` | Richtet Speicher ein, wartet auf Docker und startet WebDAV, UI und Monitor. |
| `docker-compose.yml` | Bindet `ZOTERO_STORAGE_PATH` in den WebDAV-Container ein. |
| `vault-ui.ps1` | Lokaler Server sowie Projekt-, Zotero- und Speicher-API. |
| `ui/` | Forschungsprojekt-UI. |
| `zotero-plugin/` | Zotero-Plugin-Quellen. |
| `build-zotero-plugin.ps1` | Erzeugt `dist/myliteraturevault-zotero.xpi`. |
| `auto-sync.ps1` | Reiner Speicher-Aktivitätsmonitor, kein Git-Sync. |
