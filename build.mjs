/**
 * build.mjs — Full build pipeline for ArkWASM.
 *
 * Targets:
 *   build/            — Transpiled .ts files for local testing (gitignored)
 *   dist/ts/          — Single-file TS artifact for direct import
 *   dist/web/         — ESM bundle + self-contained HTML for browsers
 *   dist/arkwasm.har  — OpenHarmony HAR package
 *
 * Usage:
 *   node build.mjs          → Full build (test + dist)
 *   node build.mjs test     → Test-only build (build/)
 *   node build.mjs dist     → Distribution build (dist/)
 *   node build.mjs ts       → Single-file TS artifact only
 *   node build.mjs har      → HAR package only
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, existsSync, statSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createGzip, createDeflate } from 'node:zlib';
import esbuild from 'esbuild';

const __dirname = dirname(fileURLToPath(import.meta.url));

const SOURCE_DIR = resolve(__dirname, 'entry/src/main/ets/wasm');
const BUILD_DIR = resolve(__dirname, 'build');
const DIST_TS = resolve(__dirname, 'dist/ts');
const DIST_WEB = resolve(__dirname, 'dist/web');
const HAR_FILE = resolve(__dirname, 'dist/arkwasm.har');

// ─── Transforms applied during transpilation ────────────────────────────────

const TRANSFORMS = [
  { file: null, match: /export const enum /g, replace: 'export enum ' },
  {
    file: 'WasmFloatOps.ts',
    match: /^function (i64And|i64Or|i64Xor|i64Wrap|i64SignExtend|i64Shl|i64ShrS|i64ShrU|i64Rotl|i64Rotr)\(/gm,
    replace: 'export function $1('
  },
  {
    file: 'Index.ts',
    match: /export type \{ ImportProvider, InterpResult \} from '\.\/WasmRuntime';/g,
    replace: "export type { ImportProvider } from './WasmRuntime';\nexport type { InterpResult } from './WasmInterpreter';"
  },
];

function applyTransforms(tsFile, content) {
  for (const t of TRANSFORMS) {
    if (t.file === null || t.file === tsFile) {
      content = content.replace(t.match, t.replace);
    }
  }
  return content;
}

// ─── Transpile .ets → .ts ───────────────────────────────────────────────────

function transpileSource(outDir) {
  console.log(`\nTranspile: ${SOURCE_DIR} → ${outDir}`);
  if (existsSync(outDir)) rmSync(outDir, { recursive: true });
  mkdirSync(outDir, { recursive: true });

  const allFiles = [];
  function scan(dir, prefix) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        scan(resolve(dir, entry.name), prefix + entry.name + '/');
      } else if (entry.name.endsWith('.ets')) {
        allFiles.push({ path: resolve(dir, entry.name), rel: prefix + entry.name });
      }
    }
  }
  scan(SOURCE_DIR, '');
  for (const { path, rel } of allFiles) {
    const tsFile = rel.replace(/\.ets$/, '.ts');
    const outPath = resolve(outDir, tsFile);
    mkdirSync(dirname(outPath), { recursive: true });
    let content = readFileSync(path, 'utf-8');
    content = applyTransforms(tsFile, content);
    writeFileSync(outPath, content, 'utf-8');
  }
  console.log(`  Built ${allFiles.length} files`);
  return allFiles.length;
}

// ─── Bundle for web: single ESM file via esbuild ────────────────────────────

async function bundleWeb(distDir) {
  console.log(`\nBundle web: ${distDir}`);
  if (!existsSync(distDir)) mkdirSync(distDir, { recursive: true });

  const entryFile = resolve(SOURCE_DIR, 'Index.ets');
  if (!existsSync(entryFile)) { console.error('  ERROR: source file not found'); return; }

  const resolvePlugin = {
    name: 'resolve-ets',
    setup(build) {
      build.onResolve({ filter: /^\.\.?\/[^.]+$/ }, args => {
        const etsPath = resolve(args.resolveDir, args.path + '.ets');
        if (existsSync(etsPath)) return { path: etsPath };
        const tsPath = resolve(args.resolveDir, args.path + '.ts');
        if (existsSync(tsPath)) return { path: tsPath };
        return undefined;
      });

// ─── Bundle for web: single ESM file via esbuild ────────────────────────────
    }
  };

  const commonOpts = { entryPoints: [entryFile], bundle: true, format: 'esm', target: 'es2020', platform: 'neutral', write: true, loader: { '.ets': 'ts' }, plugins: [resolvePlugin] };
  await esbuild.build({ ...commonOpts, outfile: resolve(distDir, 'arkwasm.mjs'), minify: false });
  await esbuild.build({ ...commonOpts, outfile: resolve(distDir, 'arkwasm.min.mjs'), minify: true });

  const size1 = (statSync(resolve(distDir, 'arkwasm.mjs')).size / 1024).toFixed(1);
  const size2 = (statSync(resolve(distDir, 'arkwasm.min.mjs')).size / 1024).toFixed(1);
  console.log(`  arkwasm.mjs     (${size1} KB)`);
  console.log(`  arkwasm.min.mjs (${size2} KB)`);

  await buildWebTest(distDir);
}

// ─── Self-contained web test page ────────────────────────────────────────────

async function buildWebTest(distDir) {
  console.log(`\nBuild web test: ${distDir}/arktest.html`);

  const entryFile = resolve(SOURCE_DIR, 'Index.ets');
  const resolvePlugin = {
    name: 'resolve-ets',
    setup(build) {
      build.onResolve({ filter: /^\.\.?\/[^.]+$/ }, args => {
        const etsPath = resolve(args.resolveDir, args.path + '.ets');
        if (existsSync(etsPath)) return { path: etsPath };
        const tsPath = resolve(args.resolveDir, args.path + '.ts');
        if (existsSync(tsPath)) return { path: tsPath };
        return undefined;
      });

// ─── Bundle for web: single ESM file via esbuild ────────────────────────────
    }
  };

  const iifeResult = await esbuild.build({
    entryPoints: [entryFile], bundle: true, format: 'iife', globalName: 'ArkWASM',
    target: 'es2020', platform: 'browser', minify: true, write: false,
    loader: { '.ets': 'ts' }, plugins: [resolvePlugin],
  });
  const runtimeCode = iifeResult.outputFiles[0].text;

  const htmlTemplate = resolve(__dirname, 'tests/arktest.template');
  if (!existsSync(htmlTemplate)) { console.log('  skip: tests/arktest.template not found'); return; }
  let html = readFileSync(htmlTemplate, 'utf-8');

  const placeholder = /<!--RUNTIME-->/;
  if (!placeholder.test(html)) { console.log('  skip: no <!--RUNTIME--> placeholder found'); return; }

  html = html.replace(placeholder,
    `<script>\n/* Runtime inlined by build.mjs — no CORS issues */\n${runtimeCode}\nfor (const k of Object.getOwnPropertyNames(ArkWASM)) { window[k] = ArkWASM[k]; }\n</script>\n`);

  const outPath = resolve(distDir, 'arktest.html');
  writeFileSync(outPath, html, 'utf-8');
  console.log(`  arktest.html (${(statSync(outPath).size / 1024).toFixed(0)} KB) — self-contained, double-click to open`);
}

// ═══════════════════════════════════════════════════════════════════════════
// TS single-file artifact
// ═══════════════════════════════════════════════════════════════════════════

/** Topological order: depended-on modules first, dependents after. */
const TS_MODULE_ORDER = [
  'WasmTypes.ts', 'WasmLeb128.ts', 'WasmOpcode.ts', 'WasmByteReader.ts',
  'WasmFloatOps.ts', 'WasmLoader.ts', 'wasi/WasiTypes.ts',
  'wasi/WasiProvider.ts', 'WasmInterpreter.ts', 'WasmRuntime.ts', 'Index.ts',
];

function bundleTs(outDir) {
  console.log(`\nBundle TS: ${outDir}/arkwasm.ts`);
  mkdirSync(outDir, { recursive: true });

  // Ensure build/ has source
  if (!existsSync(BUILD_DIR)) transpileSource(BUILD_DIR);

  const header = `/**
 * ArkWASM — WebAssembly Micro Runtime (single-file TypeScript)
 * Generated by build.mjs — do not edit directly.
 * Source: entry/src/main/ets/wasm/*.ets
 * Usage: import { WasmRuntime, WasmValue } from './dist/ts/arkwasm.ts';
 */
`;

  let output = header;

  for (const fileName of TS_MODULE_ORDER) {
    const filePath = resolve(BUILD_DIR, fileName);
    if (!existsSync(filePath)) {
      console.log(`  WARNING: ${fileName} not found, skipping`);
      continue;
    }
    let content = readFileSync(filePath, 'utf-8');

    // Strip all local imports (from './Xxx')
    content = content.replace(/^import\s*\{[^}]*\}\s*from\s*['"]\.\/[^'"]*['"];?\s*$/gm, '');
    content = content.replace(/^import\s+type\s*\{[^}]*\}\s*from\s*['"]\.\/[^'"]*['"];?\s*$/gm, '');
    content = content.replace(/^import\s+\*\s+as\s+\w+\s+from\s*['"]\.\/[^'"]*['"];?\s*$/gm, '');

    // Strip re-export lines from Index.ts (names already exported by their source modules)
    content = content.replace(/^export\s*\{[^}]*\}\s*from\s*['"]\.\/[^'"]*['"];?\s*$/gm, '');
    content = content.replace(/^export\s+type\s*\{[^}]*\}\s*from\s*['"]\.\/[^'"]*['"];?\s*$/gm, '');

    // Remove 'esbuild' import (build dependency, not runtime)
    content = content.replace(/^import\s+.*\s+from\s*['"]esbuild['"];?\s*$/gm, '');

    // Collapse multiple blank lines
    content = content.replace(/\n{3,}/g, '\n\n');

    output += `\n// === ${fileName.replace('.ts', '')} ===\n`;
    output += content.trim() + '\n';
  }

  const outPath = resolve(outDir, 'arkwasm.ts');
  writeFileSync(outPath, output, 'utf-8');
  const size = (statSync(outPath).size / 1024).toFixed(0);
  console.log(`  arkwasm.ts (${size} KB)`);

  return outPath;
}

// ═══════════════════════════════════════════════════════════════════════════
// OpenHarmony HAR package
// ═══════════════════════════════════════════════════════════════════════════

// Type declarations stub
const STUB_DTS = `// ArkWASM type declarations
export const VALUE_TYPE_I32: number;
export const VALUE_TYPE_I64: number;
export const VALUE_TYPE_F32: number;
export const VALUE_TYPE_F64: number;
export class WasmValue {
  type: number; i32Val: number; i64Val: bigint; f32Val: number; f64Val: number;
  static i32(v: number): WasmValue; static i64(v: bigint): WasmValue;
  static f32(v: number): WasmValue; static f64(v: number): WasmValue;
  getAsI32(): number; getAsI64(): bigint; getAsF32(): number; getAsF64(): number;
}
export type HostFunction = (args: WasmValue[], memory: any) => WasmValue[];
export class HostTrap extends Error {}
export interface ImportProvider {
  getFunction(m: string, f: string): HostFunction | null;
  getMemory(m: string, f: string): any;
  getTable(m: string, f: string): any;
  getGlobal(m: string, f: string): WasmValue | null;
}
export class WasmRuntime {
  constructor(ip?: ImportProvider);
  instantiate(d: Uint8Array): any;
  invokeByName(i: any, n: string, a: WasmValue[]): InterpResult;
}
export interface InterpResult { values: WasmValue[]; trap: string | null; }
export enum WasmOp { UNREACHABLE=0, NOP=1, BLOCK=2, LOOP=3, IF=4, ELSE=5, END=11, BR=12, BR_IF=13, BR_TABLE=14, RETURN=15, CALL=16, CALL_INDIRECT=17, I32_ADD=106 }
export class WasmLoader { load(d: Uint8Array): any; }
export class Leb128 { static readU32(d: Uint8Array, p: {v:number}): number; static readI32(d: Uint8Array, p: {v:number}): number; static readI64(d: Uint8Array, p: {v:number}): bigint; }
export class WasiProvider implements ImportProvider { constructor(a?: string[]); }
export class DefaultImportProvider implements ImportProvider {}
`;

async function buildHar() {
  console.log(`\nBuild HAR: ${HAR_FILE}`);

  // 1. Ensure TS artifact exists
  if (!existsSync(resolve(DIST_TS, 'arkwasm.ts'))) {
    bundleTs(DIST_TS);
  }

  // 2. Create temp directory structure
  const tmpDir = resolve(__dirname, '.har-tmp');
  if (existsSync(tmpDir)) rmSync(tmpDir, { recursive: true });

  const srcDir = resolve(tmpDir, 'src/main/ets');
  mkdirSync(srcDir, { recursive: true });

  // 3. Copy TS artifact
  const tsContent = readFileSync(resolve(DIST_TS, 'arkwasm.ts'), 'utf-8');
  writeFileSync(resolve(srcDir, 'arkwasm.ts'), tsContent, 'utf-8');

  // 4. Generate .d.ts declaration file
  const dtsPath = resolve(DIST_TS, 'arkwasm.d.ts');
  // Always write stub .d.ts (esbuild can't auto-generate from bundled TS)
  try {
    writeFileSync(dtsPath, STUB_DTS, 'utf-8');
  } catch (e) {
    console.log(`  WARNING: ${e.message}`);
  }
  const dtsSrc = resolve(DIST_TS, 'arkwasm.d.ts');
  if (existsSync(dtsSrc)) {
    const dtsContent = readFileSync(dtsSrc, 'utf-8');
    writeFileSync(resolve(srcDir, 'arkwasm.d.ts'), dtsContent, 'utf-8');
  }

  // 5. oh-package.json5
  const pkgJson = JSON.stringify({
    name: 'arkwasm',
    version: '1.0.0',
    description: 'WebAssembly Micro Runtime for OpenHarmony',
    main: 'Index.ets',
    types: 'Index.d.ts',
    dependencies: {}
  }, null, 2);
  writeFileSync(resolve(tmpDir, 'oh-package.json5'), pkgJson, 'utf-8');

  // 6. Index.ets (re-export from bundled TS)
  const indexEts = `/**
 * ArkWASM — WebAssembly Micro Runtime
 * OpenHarmony HAR entry point
 */
export { WasmRuntime, WasmValue, WasmLoader, WasmOp, Leb128 } from './src/main/ets/arkwasm';
export type { ImportProvider, InterpResult, HostFunction } from './src/main/ets/arkwasm';
export { HostTrap } from './src/main/ets/arkwasm';
export { WasiProvider } from './src/main/ets/arkwasm';
export { DefaultImportProvider } from './src/main/ets/arkwasm';
`;
  writeFileSync(resolve(tmpDir, 'Index.ets'), indexEts, 'utf-8');

  // 7. Index.d.ts
  const indexDts = `export { WasmRuntime, WasmValue, WasmLoader, WasmOp, Leb128 } from './src/main/ets/arkwasm';
export type { ImportProvider, InterpResult, HostFunction } from './src/main/ets/arkwasm';
export { HostTrap } from './src/main/ets/arkwasm';
export { WasiProvider } from './src/main/ets/arkwasm';
export { DefaultImportProvider } from './src/main/ets/arkwasm';
`;
  writeFileSync(resolve(tmpDir, 'Index.d.ts'), indexDts, 'utf-8');

  // 8. Create ZIP (simple stored format, no compression — HAR spec allows stored)
  const zipPath = await createZip(tmpDir, HAR_FILE);

  // 9. Cleanup
  rmSync(tmpDir, { recursive: true });

  const size = (statSync(HAR_FILE).size / 1024).toFixed(0);
  console.log(`  arkwasm.har (${size} KB)`);
}

// ─── Minimal ZIP creator (stored, no compression) ───────────────────────────

function createZip(srcDir, outPath) {
  const files = [];
  walkDir(srcDir, '', files);

  // ZIP format: local headers + data + central directory + EOCD
  const chunks = [];
  const centralDir = [];
  let offset = 0;

  for (const f of files) {
    const data = readFileSync(f.fullPath);
    const nameBytes = Buffer.from(f.zipPath, 'utf-8');
    const crc = crc32(data);

    // Local file header
    const localHeader = Buffer.alloc(30 + nameBytes.length);
    localHeader.writeUInt32LE(0x04034b50, 0);  // signature
    localHeader.writeUInt16LE(20, 4);           // version needed
    localHeader.writeUInt16LE(0, 6);            // flags
    localHeader.writeUInt16LE(0, 8);            // compression (stored)
    localHeader.writeUInt16LE(0, 10);           // mod time
    localHeader.writeUInt16LE(0, 12);           // mod date
    localHeader.writeUInt32LE(crc, 14);         // crc32
    localHeader.writeUInt32LE(data.length, 18); // compressed size
    localHeader.writeUInt32LE(data.length, 22); // uncompressed size
    localHeader.writeUInt16LE(nameBytes.length, 26); // name length
    localHeader.writeUInt16LE(0, 28);           // extra field length
    nameBytes.copy(localHeader, 30);

    chunks.push(localHeader);
    chunks.push(data);
    offset += localHeader.length + data.length;

    // Central directory entry
    const cdEntry = Buffer.alloc(46 + nameBytes.length);
    cdEntry.writeUInt32LE(0x02014b50, 0);  // signature
    cdEntry.writeUInt16LE(20, 4);           // version made by
    cdEntry.writeUInt16LE(20, 6);           // version needed
    cdEntry.writeUInt16LE(0, 8);            // flags
    cdEntry.writeUInt16LE(0, 10);           // compression
    cdEntry.writeUInt16LE(0, 12);           // mod time
    cdEntry.writeUInt16LE(0, 14);           // mod date
    cdEntry.writeUInt32LE(crc, 16);         // crc32
    cdEntry.writeUInt32LE(data.length, 20); // compressed size
    cdEntry.writeUInt32LE(data.length, 24); // uncompressed size
    cdEntry.writeUInt16LE(nameBytes.length, 28); // name length
    cdEntry.writeUInt16LE(0, 30);           // extra length
    cdEntry.writeUInt16LE(0, 32);           // comment length
    cdEntry.writeUInt16LE(0, 34);           // disk start
    cdEntry.writeUInt16LE(0, 36);           // internal attr
    cdEntry.writeUInt32LE(0, 38);           // external attr
    cdEntry.writeUInt32LE(offset - data.length, 42); // local header offset
    nameBytes.copy(cdEntry, 46);

    centralDir.push(cdEntry);
  }

  const cdOffset = offset;
  for (const cd of centralDir) {
    chunks.push(cd);
    offset += cd.length;
  }

  // EOCD
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(files.length, 8);
  eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(offset - cdOffset, 12);
  eocd.writeUInt32LE(cdOffset, 16);
  eocd.writeUInt16LE(0, 20);
  chunks.push(eocd);

  const zipData = Buffer.concat(chunks);
  writeFileSync(outPath, zipData);
  return outPath;
}

function walkDir(dir, basePath, files) {
  const entries = readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = resolve(dir, entry.name);
    const zipPath = basePath ? `${basePath}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      walkDir(fullPath, zipPath, files);
    } else {
      files.push({ fullPath, zipPath });
    }
  }
}

function crc32(data) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i++) {
    crc ^= data[i];
    for (let j = 0; j < 8; j++) {
      if (crc & 1) crc = (crc >>> 1) ^ 0xEDB88320;
      else crc >>>= 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

const target = process.argv[2] || 'all';

async function main() {
  if (target === 'test' || target === 'all') {
    transpileSource(BUILD_DIR);
  }

  if (target === 'ts') {
    bundleTs(DIST_TS);
  }

  if (target === 'har') {
    await buildHar();
  }

  if (target === 'dist' || target === 'all') {
    if (!existsSync(BUILD_DIR)) transpileSource(BUILD_DIR);

    // 1. TS single-file artifact
    bundleTs(DIST_TS);

    // 2. Web bundle
    await bundleWeb(DIST_WEB);

    // 3. HAR package
    await buildHar();

    console.log(`\n✦ Distribution artifacts ready:`);
    console.log(`  dist/ts/arkwasm.ts — Single-file TS for direct import`);
    console.log(`  dist/web/          — ESM bundle + self-contained HTML`);
    console.log(`  dist/arkwasm.har   — OpenHarmony HAR package`);
  }

  if (target === 'test' || target === 'all') {
    console.log(`\n✦ Test build ready: npx tsx tests/src/test_all.ts`);
  }
}

main();
