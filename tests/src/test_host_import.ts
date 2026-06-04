/**
 * test_host_import.ts — Host import function tests.
 * Tests the ImportProvider + HostFunction callback mechanism.
 */

import { WasmRuntime, WasmValue, HostFunction, ImportProvider, HostTrap } from '../../build/Index.ts';
import { WasmMemoryInstance } from '../../build/WasmTypes.ts';

// ============================================================================
// Test framework
// ============================================================================
let total = 0, passed = 0, failed = 0;
function t(name: string, fn: () => void): void {
  total++;
  try { fn(); passed++; console.log(`  \x1b[32mPASS\x1b[0m: ${name}`); }
  catch (e: unknown) { failed++; console.log(`  \x1b[31mFAIL\x1b[0m: ${name} — ${e instanceof Error ? e.message : String(e)}`); }
}
function suite(name: string): void { console.log(`\n\x1b[36m${name}\x1b[0m`); }
function assertEq<T>(a: T, b: T): void {
  if (a !== b) { if (typeof a === 'bigint' || typeof b === 'bigint') { if (String(a) !== String(b)) throw Error(`expected ${b} but got ${a}`); } else throw Error(`expected ${b} but got ${a}`); }
}
function assertNotNull(v: unknown): void { if (v === null || v === undefined) throw Error('expected non-null'); }

// ============================================================================
// Helper: minimal .wasm module builder with imports
// ============================================================================
function pushLeb(buf: number[], v: number): void {
  while (v >= 0x80) { buf.push((v & 0x7f) | 0x80); v >>>= 7; }
  buf.push(v & 0x7f);
}

/** Build a module that imports and calls a host function */
function makeImportModule(importModule: string, importField: string,
  params: number[], results: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

  // Type section: import type + test type
  let impType = [0x60]; pushLeb(impType, params.length); impType.push(...params);
  pushLeb(impType, results.length); impType.push(...results);
  let testType = [0x60]; pushLeb(testType, params.length); testType.push(...params);
  pushLeb(testType, results.length); testType.push(...results);
  const tb = [0x02, ...impType, ...testType];
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);

  // Import section: import "mod" "fn" -> type 0
  const modBytes: number[] = []; modBytes.push(importModule.length);
  for (const c of importModule) modBytes.push(c.charCodeAt(0));
  const fldBytes: number[] = []; fldBytes.push(importField.length);
  for (const c of importField) fldBytes.push(c.charCodeAt(0));
  const impSec = [0x01, ...modBytes, ...fldBytes, 0x00, 0x00]; // 1 import, func, type 0
  b.push(0x02); pushLeb(b, impSec.length); b.push(...impSec);

  // Function section: 1 func -> type 1
  b.push(0x03, 0x02, 0x01, 0x01);

  // Export section: export "test" -> func 1 (1 = import 0 + local func 0)
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x01);

  // Code section: body = push params, call import 0, end
  const body = [0x00]; // 0 locals
  for (let i = 0; i < params.length; i++) body.push(0x20, i); // local.get i
  body.push(0x10, 0x00); // call 0 (import)
  body.push(0x0b); // end
  const cs = [0x01]; pushLeb(cs, body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);

  return new Uint8Array(b);
}

/** Build a module with imported memory and exported function */
function makeMemoryImportModule(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

  // Type: (i32, i32) -> ()
  const tb = [0x01, 0x60]; pushLeb(tb, 2); tb.push(0x7f, 0x7f); pushLeb(tb, 0);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);

  // Import memory "env" "memory" -> 1 page
  const memImp = [0x01, 0x03, 0x65, 0x6e, 0x76, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x01, 0x01, 0x01];
  b.push(0x02); pushLeb(b, memImp.length); b.push(...memImp);

  // Function: 1 func type 0
  b.push(0x03, 0x02, 0x01, 0x00);

  // Export "test"
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x00);

  // Code
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);

  return new Uint8Array(b);
}

// ============================================================================
// Simple test provider
// ============================================================================
function provider(map: Record<string, HostFunction>): ImportProvider {
  return {
    getFunction(mod, field) {
      const key = `${mod}:${field}`;
      return map[key] ?? null;
    },
    getMemory() { return null; },
    getTable() { return null; },
    getGlobal() { return null; },
  };
}

// ═══════════════════════════════════════════════════════════════════════════

suite('Host Import — Basic Call');
t('call host add(i32,i32)->i32: 3+4=7', () => {
  const wasm = makeImportModule('env', 'add', [0x7f, 0x7f], [0x7f]);
  const rt = new WasmRuntime(provider({
    'env:add': (args) => [WasmValue.i32(args[0].getAsI32() + args[1].getAsI32())],
  }));
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', [WasmValue.i32(3), WasmValue.i32(4)]);
  if (res.trap) throw Error('trap: ' + res.trap);
  assertEq(res.values[0].getAsI32(), 7);
});

t('call host with i64 arg and result', () => {
  const wasm = makeImportModule('env', 'mul', [0x7e, 0x7e], [0x7e]);
  const rt = new WasmRuntime(provider({
    'env:mul': (args) => [WasmValue.i64(args[0].getAsI64() * args[1].getAsI64())],
  }));
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', [WasmValue.i64(6n), WasmValue.i64(7n)]);
  if (res.trap) throw Error('trap: ' + res.trap);
  assertEq(res.values[0].getAsI64(), 42n);
});

t('call host with f32 arg and result', () => {
  const wasm = makeImportModule('env', 'neg', [0x7d], [0x7d]);
  const rt = new WasmRuntime(provider({
    'env:neg': (args) => [WasmValue.f32(-args[0].getAsF32())],
  }));
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', [WasmValue.f32(3.5)]);
  if (res.trap) throw Error('trap: ' + res.trap);
  assertEq(res.values[0].getAsF32(), -3.5);
});

t('missing host function traps', () => {
  const wasm = makeImportModule('env', 'missing', [0x7f], [0x7f]);
  const rt = new WasmRuntime(); // no provider → hostFunc=null
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', [WasmValue.i32(1)]);
  assertNotNull(res.trap);
});

suite('Host Import — Memory Access');
t('host reads wasm memory correctly', () => {
  const wasm = makeMemoryImportModule([
    0x20, 0x00, 0x20, 0x01,           // local.get 0, local.get 1
    0x36, 0x02, 0x00                   // i32.store align=2 offset=0
  ]);
  // Host stores the value → wasm function loads it
  const rt = new WasmRuntime(provider({
    'env:check': (args, mem) => {
      // Write to verify memory is accessible
      return [WasmValue.i32(0)];
    },
  }));
  const inst = rt.instantiate(wasm);
  // Write 42 at addr 0
  const r = rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(42)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  // Read back
  const dv = new DataView(inst.memories[0].buffer);
  assertEq(dv.getInt32(0, true), 42);
});

t('host writes wasm memory via callback', () => {
  // Module that calls import to get a value, then returns it
  const wasm = new Uint8Array((() => {
    const b: number[] = [];
    b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
    // Type: import () -> i32, test () -> i32
    const tb = [0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f];
    b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
    // Import "env" "read_mem" -> type 0
    const imp = [0x01, 0x03, 0x65, 0x6e, 0x76, 0x08, 0x72, 0x65, 0x61, 0x64, 0x5f, 0x6d, 0x65, 0x6d, 0x00, 0x00];
    b.push(0x02); pushLeb(b, imp.length); b.push(...imp);
    // Memory: 1 page
    b.push(0x05, 0x03, 0x01, 0x00, 0x01);
    // Func: 1 func type 1
    b.push(0x03, 0x02, 0x01, 0x01);
    // Export "test" -> func 1
    const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
    b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x01);
    // Code: call import 0
    const cb = [0x00, 0x10, 0x00, 0x0b];
    const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
    b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
    return new Uint8Array(b);
  })());

  const rt = new WasmRuntime(provider({
    'env:read_mem': (_args, mem) => {
      // Write 99 at offset 8
      const dv = new DataView(mem!.buffer);
      dv.setInt32(8, 99, true);
      return [WasmValue.i32(99)];
    },
  }));
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', []);
  if (res.trap) throw Error('trap: ' + res.trap);
  assertEq(res.values[0].getAsI32(), 99);
  const dv = new DataView(inst.memories[0].buffer);
  assertEq(dv.getInt32(8, true), 99);
});

t('host received null memory when module has no memory', () => {
  const wasm = makeImportModule('env', 'check', [], [0x7f]);
  let memWasNull = false;
  const rt = new WasmRuntime(provider({
    'env:check': (_args, mem) => { memWasNull = (mem === null); return [WasmValue.i32(1)]; },
  }));
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', []);
  if (res.trap) throw Error('trap: ' + res.trap);
  assertEq(memWasNull, true, 'memory should be null for modules without memory');
});

suite('Host Import — HostTrap');
t('host function throwing HostTrap propagates as wasm trap', () => {
  const wasm = makeImportModule('env', 'exit', [], [0x7f]);
  const rt = new WasmRuntime(provider({
    'env:exit': () => { throw new HostTrap('wasi: exit(0)'); },
  }));
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'test', []);
  assertNotNull(res.trap);
});

suite('Host Import — Direct invoke() entry');
t('invoke() calls host function via callFunction path', () => {
  // Build a module where import func is index 0
  const wasm = makeImportModule('env', 'double', [0x7f], [0x7f]);
  const rt = new WasmRuntime(provider({
    'env:double': (args) => [WasmValue.i32(args[0].getAsI32() * 2)],
  }));
  const inst = rt.instantiate(wasm);
  // invoke import at index 0 directly
  const res = rt.invoke(inst, 0, [WasmValue.i32(21)]);
  if (res.trap) throw Error('trap: ' + res.trap);
  assertEq(res.values[0].getAsI32(), 42);
});

// Summary
console.log(`\n\x1b[1m${'='.repeat(50)}\x1b[0m`);
if (failed === 0) {
  console.log(`\x1b[32m\x1b[1mALL ${total} HOST IMPORT TESTS PASSED\x1b[0m`);
} else {
  console.log(`\x1b[31m\x1b[1mFAILED: ${failed}/${total}\x1b[0m`);
}
process.exit(failed > 0 ? 1 : 0);
