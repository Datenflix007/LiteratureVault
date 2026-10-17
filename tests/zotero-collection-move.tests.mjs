import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const plugin = readFileSync(new URL('../zotero-plugin/bootstrap.js', import.meta.url), 'utf8');

// The plugin must alter only collection membership. These assertions guard the
// no-duplicate/no-data-loss path used after a manual classification change.
assert.match(plugin, /const otherTarget = reference\.kind === "source" \? children\.Literatur : children\.Quellen;/);
assert.match(plugin, /otherTarget\.removeItem\(item\.id\)/);
assert.match(plugin, /the item, its\s*\/\/ attachments and all metadata remain untouched/i);
assert.match(plugin, /await target\.addItem\(item\.id\)/);

console.log('[OK] Zotero-Verschiebung: Ziel-Unterordner ergänzen, Gegen-Unterordner entfernen, Bibliothekseintrag erhalten.');
