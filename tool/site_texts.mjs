// The website's wording as the CRM's defaults: reads `dict` from the website's src/data/site.ts and writes
// server/app/static/site_texts.json = {"hero.h1": {"he": "...", "en": "...", "ru": "..."}, ...}.
// Run after the website's site.ts changes, then deploy the server:  node tool/site_texts.mjs [path to site.ts]
import { readFileSync, writeFileSync } from 'node:fs';

const src = readFileSync(process.argv[2] || 'C:/claude projects/3d/website/src/data/site.ts', 'utf8');
const from = src.indexOf('const he = {'), to = src.indexOf('export const dict');
if (from < 0 || to < 0) throw new Error('site.ts no longer has "const he = {" … "export const dict": update this tool');
// The three dictionaries are plain object literals once the type lines are gone.
const js = src.slice(from, to).replace(/^type .*$/gm, '').replace(/const (en|ru): Dict/g, 'const $1');
const dict = new Function(`${js}; return { he, en, ru };`)();

const out = {};
const walk = (lang, node, path) => {
  if (typeof node === 'string') (out[path] ??= {})[lang] = node;
  else for (const [k, v] of Object.entries(node)) walk(lang, v, path ? `${path}.${k}` : k);
};
for (const lang of ['he', 'en', 'ru']) walk(lang, dict[lang], '');
for (const [key, v] of Object.entries(out)) {
  if (!/^[A-Za-z0-9_.]{1,80}$/.test(key)) throw new Error(`"${key}" does not fit site_texts.key in schema.sql`);
  if (Object.keys(v).length !== 3) throw new Error(`"${key}" is missing a language`);
}
writeFileSync(new URL('../server/app/static/site_texts.json', import.meta.url), JSON.stringify(out, null, 1) + '\n');
console.log(`wrote ${Object.keys(out).length} keys`);
