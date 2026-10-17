# MyLiteratureVault Zotero-Plugin

Das Plugin verbindet die lokale MyLiteratureVault-UI mit Zotero und legt für
jedes Projekt echte Sammlungen in **Meine Bibliothek** an. Aktuelle Version:
**0.4.3**. Sie ist für **Zotero 10.0.\*** freigegeben.

## Voraussetzungen

- Zotero 10.0.x
- MyLiteratureVault muss über `quickstart.bat` laufen, damit
  `http://localhost:8765` erreichbar ist.

## XPI bauen und manuell installieren

Das Plugin wird aus dem Wurzelordner des Repositories gebaut:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-zotero-plugin.ps1
```

Danach die erzeugte `dist/myliteraturevault-zotero.xpi` in Zotero installieren:

1. **Extras** → **Erweiterungen** öffnen.
2. Das Zahnrad-Menü öffnen.
3. **Add-on aus Datei installieren…** wählen.
4. `dist/myliteraturevault-zotero.xpi` auswählen.
5. Zotero neu starten.

Die Erweiterung wird nicht automatisch installiert oder aktualisiert. Das
Manifest enthält zwar eine `update_url`, aber `updates.json` ist bewusst leer:
Solange kein passendes XPI als GitHub-Release veröffentlicht wurde, gibt es
keine automatische Aktualisierung. Neue lokale Builds werden daher über die
oben beschriebenen Schritte installiert.

## Projekt-Sammlungen und Abgleich

Beim Start und anschließend etwa alle 30 Sekunden gleicht das Plugin die
Projekte aus der lokalen UI mit Zotero ab. Für jedes Projekt entsteht oder
bleibt erhalten:

```text
Meine Bibliothek
  Projektname
    Literatur
    Quellen
```

Vorhandene passende Sammlungen werden wiederverwendet; der Abgleich löscht
keine eigenen Zotero-Sammlungen. Bei einem sofortigen Abgleich in Zotero:

```text
Ansicht → MyLiteratureVault-Projekte mit Zotero synchronisieren
```

Die Projekt-UI liest die bibliografischen Einträge aus den Unterordnern direkt
aus: Einträge in **Literatur** erscheinen im Literatur-Regal, Einträge in
**Quellen** im Quellen-Regal. PDF-Anhänge, Notizen und Annotationen werden
dabei nicht als eigenständige Quellenkarten gelistet.

Zum Öffnen der lokalen Oberfläche in Zotero:

```text
Ansicht → MyLiteratureVault öffnen
```
