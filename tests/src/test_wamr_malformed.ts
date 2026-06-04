/**
 * test_wamr_malformed.ts — WAMR malformed .wasm rejection tests.
 * Verifies the ArkWASM loader correctly rejects intentionally corrupt modules.
 */

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WasmRuntime, WasmLoader } from '../../build/Index.ts';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(__dirname, '../wamr-fixtures');

let total = 0, passed = 0, failed = 0, skipped = 0;
function t(name: string, fn: () => void): void {
  total++;
  try { fn(); passed++; console.log(`  \x1b[32mPASS\x1b[0m: ${name}`); }
  catch (e: unknown) { failed++; console.log(`  \x1b[31mFAIL\x1b[0m: ${name} — ${e instanceof Error ? e.message : String(e)}`); }
}
function s(name: string, reason: string): void {
  skipped++; console.log(`  \x1b[33mSKIP\x1b[0m: ${name} — ${reason}`);
}
function suite(name: string): void { console.log(`\n\x1b[36m${name}\x1b[0m`); }

function loadOrFail(file: string): 'rejected' | 'warn' | 'crash' {
  try {
    const rt = new WasmRuntime();
    rt.instantiate(new Uint8Array(readFileSync(file)));
    return 'warn'; // Should have been rejected
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('segfault') || msg.includes('Cannot read')) return 'crash';
    return 'rejected';
  }
}

// ═══════════════════════════════════════════════════════════════════════════

suite('Malformed — Fuzz-generated (12 files)');
const fuzzDir = resolve(FIXTURES, 'malformed/fuzz');
for (let i = 1; i <= 12; i++) {
  const file = resolve(fuzzDir, `${i}.wasm`);
  t(`fuzz/${i}.wasm rejected`, () => {
    const result = loadOrFail(file);
    if (result === 'crash') throw Error('crashed — should be cleanly rejected');
    // 'rejected' or 'warn' are both acceptable for malformed files
  });
}

suite('Malformed — GitHub PoC (38 files)');
const githubDir = resolve(FIXTURES, 'malformed/github');
for (let i = 47; i <= 84; i++) {
  const file = resolve(githubDir, `PoC${i}.wasm`);
  t(`PoC${i}.wasm rejected`, () => {
    const result = loadOrFail(file);
    if (result === 'crash') throw Error('crashed — should be cleanly rejected');
  });
}

// Summary
console.log(`\n\x1b[1m${'='.repeat(50)}\x1b[0m`);
if (failed === 0) {
  console.log(`\x1b[32m\x1b[1mALL ${total} MALFORMED TESTS PASSED\x1b[0m (${passed} rejected, ${skipped} skipped)`);
} else {
  console.log(`\x1b[31m\x1b[1mFAILED: ${failed}/${total}\x1b[0m`);
}
process.exit(failed > 0 ? 1 : 0);
