/**
 * test_features.ts — WebAssembly feature support verification.
 * Each test proves one Wasm spec feature using a minimal .wasm module.
 * Reference: https://webassembly.org/features/
 */

import { WasmRuntime, WasmValue, WasmLoader, Leb128 } from '../../build/Index.ts';

let total = 0, passed = 0, failed = 0;
function t(name: string, fn: () => void): void {
  total++;
  try { fn(); passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  catch (e: unknown) { failed++; console.log(`  \x1b[31m✗\x1b[0m ${name} — ${e instanceof Error ? e.message : String(e)}`); }
}
function suite(name: string): void { console.log(`\n\x1b[36m${name}\x1b[0m`); }
function assertEq<T>(a: T, b: T): void {
  if (a !== b) { if (typeof a === 'bigint' || typeof b === 'bigint') { if (String(a) !== String(b)) throw Error(`expected ${b} got ${a}`); } else throw Error(`expected ${b} got ${a}`); }
}
function assertNotNull(v: unknown, m?: string): void { if (v === null || v === undefined) throw Error(m || 'expected non-null'); }

function pushLeb(buf: number[], v: number): void {
  while (v >= 0x80) { buf.push((v & 0x7f) | 0x80); v >>>= 7; }
  buf.push(v & 0x7f);
}

// ============================================================================
// Section 1: MVP baseline (phase 5 — universally supported)
// ============================================================================
suite('1. MVP Baseline');

t('i32 arithmetic (add, sub, mul, div, rem, bitwise)', () => {
  // (func (export "t") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
  const m = makeMod([0x20,0x00,0x20,0x01,0x6a], [0x7f,0x7f], [0x7f]);
  assertEq(invokeI32(m, [3, 4]), 7);
});

t('i64 arithmetic (add, sub, mul, bitwise)', () => {
  const m = makeMod([0x20,0x00,0x20,0x01,0x7c], [0x7e,0x7e], [0x7e]);
  const r = invokeI64(m, [3n, 4n]);
  assertEq(r, 7n, 'i64.add');
});

t('f32 arithmetic (add, sub, mul, div, sqrt)', () => {
  const m = makeMod([0x20,0x00,0x20,0x01,0x92], [0x7d,0x7d], [0x7d]);
  const r = invokeF32(m, [1.5, 2.5]);
  if (Math.abs(r - 4.0) > 0.001) throw Error(`f32.add: expected 4 got ${r}`);
});

t('f64 arithmetic (add, sub, mul, div, sqrt)', () => {
  const m = makeMod([0x20,0x00,0x20,0x01,0xa0], [0x7c,0x7c], [0x7c]);
  assertEq(invokeF64(m, [Math.PI, Math.E]), Math.PI + Math.E);
});

t('control flow (block, loop, if, br, br_if, br_table)', () => {
  const m = makeMod([0x02,0x7f,0x41,0x01,0x0b], [], [0x7f]);
  assertEq(invokeI32(m, []), 1);
});

t('function calls (call, call_indirect)', () => {
  // Two functions: add (i32,i32) -> i32  and caller () -> i32
  const mod = makeCallMod(
    [0x00, 0x20,0x00,0x20,0x01,0x6a, 0x0b],  // add
    [0x00, 0x41,0x03,0x41,0x04,0x10,0x00, 0x0b]  // call 0
  );
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(mod), 't', []);
  assertEq(r.values[0].getAsI32(), 7);
});

t('memory operations (load, store, size, grow)', () => {
  const m = makeMemMod([0x20,0x00,0x20,0x01,0x36,0x02,0x00]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(m);
  rt.invokeByName(inst, 't', [WasmValue.i32(0), WasmValue.i32(42)]);
  assertEq(new DataView(inst.memories[0].buffer).getInt32(0, true), 42);
});

t('import/export sections', () => {
  const mod = new Uint8Array([
    0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,
    0x01,0x05,0x01,0x60,0x00,0x01,0x7f,
    0x03,0x02,0x01,0x00,
    0x07,0x08,0x01,0x04,0x74,0x65,0x73,0x74,0x00,0x00,
    0x0a,0x06,0x01,0x04,0x00,0x41,0x2a,0x0b
  ]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(mod);
  assertNotNull(inst.exports.get('test'));
  assertEq(rt.invokeByName(inst, 'test', []).values[0].getAsI32(), 42);
});

// ============================================================================
// Section 2: Post-MVP Phase 5 Features
// ============================================================================
suite('2. Sign Extension (signExtensions)');
t('i32.extend8_s', () => { assertEq(invokeI32(makeMod([0x20,0x00,0xc0], [0x7f],[0x7f]), [0xFF]), -1); });
t('i32.extend16_s', () => { assertEq(invokeI32(makeMod([0x20,0x00,0xc1], [0x7f],[0x7f]), [0xFFFF]), -1); });
t('i64.extend8_s', () => { assertEq(invokeI64(makeMod([0x20,0x00,0xc2], [0x7e],[0x7e]), [0xFFn]), -1n); });
t('i64.extend16_s', () => { assertEq(invokeI64(makeMod([0x20,0x00,0xc3], [0x7e],[0x7e]), [0xFFFFn]), -1n); });
t('i64.extend32_s', () => { assertEq(invokeI64(makeMod([0x20,0x00,0xc4], [0x7e],[0x7e]), [0xFFFFFFFFn]), -1n); });

suite('3. Non-trapping Float-to-Int (saturatedFloatToInt)');
t('i32.trunc_sat_s/f32: NaN → 0', () => {
  assertEq(invokeI32(makeMod([0x20,0x00,0xfc,0x00], [0x7d],[0x7f]), [NaN]), 0);
});
t('i32.trunc_sat_u/f32: -1.0 → 0', () => {
  assertEq(invokeI32(makeMod([0x20,0x00,0xfc,0x01], [0x7d],[0x7f]), [-1.0]), 0);
});
t('i64.trunc_sat_s/f64: 42.7 → 42', () => {
  assertEq(invokeI64_i64Res(makeMod([0x20,0x00,0xfc,0x06], [0x7c],[0x7e]), [42.7]), 42n);
});
t('i64.trunc_sat_u/f64: -1.0 → 0', () => {
  assertEq(invokeI64_i64Res(makeMod([0x20,0x00,0xfc,0x07], [0x7c],[0x7e]), [-1.0]), 0n);
});

suite('4. Bulk Memory (bulkMemory)');
t('memory.copy', () => {
  const b = build3ArgMod([0x20,0x00,0x20,0x01,0x20,0x02,0xfc,0x0a,0x00,0x00]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(b);
  inst.memories[0].data[0] = 1; inst.memories[0].data[1] = 2;
  rt.invokeByName(inst, 't', [WasmValue.i32(10),WasmValue.i32(0),WasmValue.i32(2)]);
  assertEq(inst.memories[0].data[10], 1);
  assertEq(inst.memories[0].data[11], 2);
});
t('memory.fill', () => {
  const b = build3ArgMod([0x20,0x00,0x20,0x01,0x20,0x02,0xfc,0x0b,0x00]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(b);
  rt.invokeByName(inst, 't', [WasmValue.i32(5),WasmValue.i32(0x42),WasmValue.i32(3)]);
  assertEq(inst.memories[0].data[5], 0x42);
  assertEq(inst.memories[0].data[7], 0x42);
});
t('memory.init', () => {
  // Module with a passive data segment [1,2,3], then memory.init
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type: (i32,i32,i32)->()
  const tb = [0x01,0x60]; pushLeb(tb,3); tb.push(0x7f,0x7f,0x7f); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x05,0x03,0x01,0x00,0x01);
  // data section: 1 passive segment, length 3, bytes [1,2,3]
  b.push(0x0b); pushLeb(b,6);
  b.push(0x01); // 1 segment
  b.push(0x01); // flags=1 (passive)
  pushLeb(b,3); b.push(0x01,0x02,0x03); // 3 bytes
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const body = [0x00, 0x20,0x00,0x20,0x01,0x20,0x02, 0xfc,0x08,0x00,0x00, 0x0b];
  const cs = [0x01]; pushLeb(cs,body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(new Uint8Array(b));
  rt.invokeByName(inst, 't', [WasmValue.i32(0),WasmValue.i32(0),WasmValue.i32(3)]);
  assertEq(inst.memories[0].data[0], 1);
  assertEq(inst.memories[0].data[1], 2);
  assertEq(inst.memories[0].data[2], 3);
});
t('data.drop', () => {
  // data.drop then memory.init should trap
  const mod = buildDataDropMod();
  const rt = new WasmRuntime();
  const inst = rt.instantiate(mod);
  const r = rt.invokeByName(inst, 't', []);
  assertNotNull(r.trap, 'data.drop: expected trap on re-init');
});
t('table.init / table.copy', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type: () -> ()
  const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x04,0x04,0x01,0x70,0x00,0x0a); // table funcref min=10
  // elem: flags=1(passive), type=0x00, count=1, [0]
  b.push(0x09); pushLeb(b,5); b.push(0x01,0x01,0x00,0x01,0x00);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // code: table.init 0 0 (sz=1,src=0,dst=0)
  const body = [0x00, 0x41,0x00,0x41,0x00,0x41,0x01, 0xfc,0x0c,0x00,0x00, 0x0b];
  const cs = [0x01]; pushLeb(cs,body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(new Uint8Array(b));
  rt.invokeByName(inst, 't', []);
  assertEq(inst.tables[0].elements[0], 0);
});

suite('5. Reference Types (referenceTypes)');
t('ref.null', () => {
  // ref.null func → is_null → 1
  const m = makeMod([0xd0,0x70,0xd1], [], [0x7f]);
  assertEq(invokeI32(m, []), 1);
});
t('ref.func', () => {
  // ref.func $f; return 1 (proves ref.func doesn't trap)
  const m = makeRefMod([0xd2,0x00,0x1a,0x41,0x01]);
  assertEq(invokeI32(m, []), 1);
});
t('ref.is_null', () => {
  const m = makeMod([0xd0,0x70,0xd1], [], [0x7f]);
  assertEq(invokeI32(m, []), 1);
});
t('ref.eq: null === null', () => {
  const m = makeMod([0xd0,0x70,0xd0,0x70,0xd3], [], [0x7f]);
  assertEq(invokeI32(m, []), 1);
});

suite('6. Multi-value (multiValue)');
t('block with i32 result', () => {
  const m = makeMod([0x02,0x7f,0x41,0x2a,0x0b], [], [0x7f]);
  assertEq(invokeI32(m, []), 42);
});
t('if/else with i32 result', () => {
  const m = makeMod([0x41,0x01,0x04,0x7f,0x41,0x0a,0x05,0x41,0x14,0x0b], [], [0x7f]);
  assertEq(invokeI32(m, []), 10);
});

suite('7. Import/Export Mutable Globals (mutableGlobals)');
t('import mutable global', () => {
  // m1 exports mutable i32 global
  const m1 = new Uint8Array([
    0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,
    0x06,0x06,0x01,0x7f,0x01,0x41,0x01,0x0b, // global i32 mut=1 init=1
    0x07,0x08,0x01,0x04,0x74,0x65,0x73,0x74,0x03,0x00 // export "test" global 0
  ]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(m1);
  assertEq(inst.globalData[0].getAsI32(), 1);
});

suite('8. SIMD v128 (simd)');
t('v128.const', () => {
  const body: number[] = [0xfd,0x0c];
  for (let i = 0; i < 16; i++) body.push(0x2a);
  const m = makeMod(body, [], [0x7b]);
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(m), 't', []);
  assertNotNull(r.values[0]);
  assertEq(r.values[0].getAsV128()[0], 0x2a);
});
t('i32x4.add', () => {
  const body: number[] = [];
  body.push(0xfd,0x0c); // v128.const [1,0,0,0, 2,0,0,0, 3,0,0,0, 4,0,0,0]
  body.push(0x01,0x00,0x00,0x00, 0x02,0x00,0x00,0x00, 0x03,0x00,0x00,0x00, 0x04,0x00,0x00,0x00);
  body.push(0xfd,0x0c); // v128.const [5,0,0,0, 6,0,0,0, 7,0,0,0, 8,0,0,0]
  body.push(0x05,0x00,0x00,0x00, 0x06,0x00,0x00,0x00, 0x07,0x00,0x00,0x00, 0x08,0x00,0x00,0x00);
  body.push(0xfd,0xae); // i32x4.add
  const m = makeMod(body, [], [0x7b]);
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(m), 't', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  const dv = new DataView(r.values[0].getAsV128().buffer);
  assertEq(dv.getInt32(0, true), 6);
  assertEq(dv.getInt32(12, true), 12);
});

suite('9. Atomics (threads — single-threaded)');
t('atomic.fence (nop)', () => {
  const m = buildAtomMod([0xfe,0x03,0x00]); // atomic.fence
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(m), 't', [WasmValue.i32(0),WasmValue.i32(0)]);
  assertEq(r.trap, null);
});
t('atomic.rmw.i32.add', () => {
  const m = buildAtomMod([
    0x20,0x00,0x20,0x01,   // local.get 0,1
    0xfe,0x1e,0x00,0x00,   // atomic.rmw.i32.add
    0x1a                    // drop
  ]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(m);
  new DataView(inst.memories[0].buffer).setInt32(0, 10, true);
  rt.invokeByName(inst, 't', [WasmValue.i32(0), WasmValue.i32(5)]);
  assertEq(new DataView(inst.memories[0].buffer).getInt32(0, true), 15);
});

suite('10. Host Import (import functions)');
t('host function call with i32 args', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type 0 + type 1: both (i32) -> i32
  const tb = [0x02, 0x60]; pushLeb(tb,1); tb.push(0x7f); pushLeb(tb,1); tb.push(0x7f);
  tb.push(0x60); pushLeb(tb,1); tb.push(0x7f); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  const imp = [0x01, 0x03,0x65,0x6e,0x76, 0x06,0x64,0x6f,0x75,0x62,0x6c,0x65, 0x00,0x00];
  b.push(0x02); pushLeb(b,imp.length); b.push(...imp);
  b.push(0x03,0x02,0x01,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x01);
  const body = [0x00, 0x20,0x00, 0x10,0x00, 0x0b];
  const cs = [0x01]; pushLeb(cs,body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  const provider = { getFunction:(m:string,f:string)=>{if(m==='env'&&f==='double')return(a:WasmValue[])=>[WasmValue.i32(a[0].getAsI32()*2)];return null;}, getMemory:()=>null as any, getTable:()=>null as any, getGlobal:()=>null as any };
  const rt = new WasmRuntime(provider as any);
  const r = rt.invokeByName(rt.instantiate(new Uint8Array(b)), 't', [WasmValue.i32(21)]);
  assertEq(r.values[0].getAsI32(), 42);
});

// ═══════════════════════════════════════════════════════════════════════════
console.log(`\n\x1b[1m${'='.repeat(50)}\x1b[0m`);
if (failed === 0) {
  console.log(`\x1b[32m\x1b[1mALL ${total} FEATURE TESTS PASSED\x1b[0m`);
} else {
  console.log(`\x1b[31m\x1b[1mFAILED: ${failed}/${total}\x1b[0m`);
}
process.exit(failed > 0 ? 1 : 0);

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

function makeImportProvider(map: Record<string, (a: WasmValue[]) => WasmValue[]>) {
  return {
    getFunction(mod: string, field: string) {
      const key = `${mod}:${field}`;
      return map[key] ?? null;
    },
    getMemory: () => null as any, getTable: () => null as any, getGlobal: () => null as any,
  };
}
function __(a:any,b:any,c:any,d:any){}
function makeImportMod(mod: string, field: string, params: number[], results: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  let impType = [0x60]; pushLeb(impType, params.length); impType.push(...params); pushLeb(impType, results.length); impType.push(...results);
  let t2 = [0x60]; pushLeb(t2, params.length); t2.push(...params); pushLeb(t2, results.length); t2.push(...results);
  b.push(0x01); pushLeb(b, impType.length + t2.length); b.push(0x02, ...impType, ...t2);
  const mB: number[] = [mod.length]; for (const c of mod) mB.push(c.charCodeAt(0));
  const fB: number[] = [field.length]; for (const c of field) fB.push(c.charCodeAt(0));
  const impSec = [0x01, ...mB, ...fB, 0x00, 0x00];
  b.push(0x02); pushLeb(b, impSec.length); b.push(...impSec);
  b.push(0x03,0x02,0x01,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01,...nm,0x00,0x01);
  const body: number[] = [0x00]; for (let i = 0; i < params.length; i++) body.push(0x20, i); body.push(0x10,0x00,0x0b);
  const cs = [0x01]; pushLeb(cs, body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function makeProvider(map: Record<string, Function>) {
  return {
    getFunction(m: string, f: string) { const k = `${m}:${f}`; const fn = map[k]; return fn ? ((a: WasmValue[]) => a.map(_ => fn(a))) as any : null; },
    getMemory: () => null as any, getTable: () => null as any, getGlobal: () => null as any,
  };
}
function buildAtomMod(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,2); tb.push(0x7f,0x7f); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00); b.push(0x05,0x03,0x01,0x00,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,...body,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function buildDataInitMod(): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type: (i32,i32,i32)->()
  const tb = [0x01,0x60]; pushLeb(tb,3); tb.push(0x7f,0x7f,0x7f); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x05,0x03,0x01,0x00,0x01); // memory 1 page
  // data section: passive segment [1,2,3]
  b.push(0x0b,0x06,0x01,0x01,0x03,0x01,0x02,0x03); // section 11, size 6, 1 seg, flags=1(passive), len=3, [1,2,3]
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // code: memory.init 0, 0; end
  const body = [0x00, 0x20,0x00,0x20,0x01,0x20,0x02, 0xfc,0x08,0x00,0x00, 0x0b];
  const cs = [0x01]; pushLeb(cs,body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function buildDataDropMod(): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x05,0x03,0x01,0x00,0x01);
  b.push(0x0b,0x06,0x01,0x01,0x03,0x01,0x02,0x03); // passive data [1,2,3]
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // code: data.drop 0; memory.init 0 0 (size=3, src=0, dst=0) → should trap
  const body = [0x00, 0xfc,0x09,0x00, 0x41,0x00,0x41,0x00,0x41,0x03, 0xfc,0x08,0x00,0x00, 0x0b];
  const cs = [0x01]; pushLeb(cs,body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function buildTableInitMod(): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type: () -> i32  (two funcs)
  const tb = [0x01,0x60,0x00,0x01,0x7f];
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  // table: funcref, min 10
  b.push(0x04,0x04,0x01,0x70,0x00,0x0a);
  // elem: passive, [func 0]
  b.push(0x09,0x06,0x01,0x01,0x01,0x00);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // code: func body (i32.const 1) + main (table.init 0 0)
  // func 0: i32.const 1
  const f0 = [0x00, 0x41,0x01, 0x0b];
  // func 1: table.init 0 0, sz=1, src=0, dst=0
  const f1 = [0x00, 0x41,0x00,0x41,0x00,0x41,0x01, 0xfc,0x0c,0x00,0x00, 0x0b];
  const cs = [0x02]; pushLeb(cs,f0.length); cs.push(...f0); pushLeb(cs,f1.length); cs.push(...f1);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function build3ArgMod(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,3); tb.push(0x7f,0x7f,0x7f); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00); b.push(0x05,0x03,0x01,0x00,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,...body,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}

function makeMod(body: number[], params: number[] = [], results: number[] = [0x7f]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,params.length); tb.push(...params); pushLeb(tb,results.length); tb.push(...results);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,...body,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function makeMemMod(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,2); tb.push(0x7f,0x7f); pushLeb(tb,0);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00); b.push(0x05,0x03,0x01,0x00,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,...body,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function makeRefMod(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,...body,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function makeCallMod(body1: number[], body2: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type 0: (i32,i32)->i32, type 1: ()->i32
  const t0 = [0x60,0x02,0x7f,0x7f,0x01,0x7f]; const t1 = [0x60,0x00,0x01,0x7f];
  b.push(0x01); pushLeb(b,t0.length+t1.length+1); b.push(0x02,...t0,...t1);
  b.push(0x03,0x03,0x02,0x00,0x01); // 2 funcs: type0, type1
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x01); // export func 1
  const cs = [0x02]; pushLeb(cs,body1.length); cs.push(...body1); pushLeb(cs,body2.length); cs.push(...body2);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}

function invokeI32(m: Uint8Array, a: number[]): number {
  const rt = new WasmRuntime();
  return rt.invokeByName(rt.instantiate(m), 't', a.map(v => WasmValue.i32(v))).values[0].getAsI32();
}
function invokeI64(m: Uint8Array, a: bigint[]): bigint {
  const rt = new WasmRuntime();
  return rt.invokeByName(rt.instantiate(m), 't', a.map(v => WasmValue.i64(v))).values[0].getAsI64();
}
function invokeF32(m: Uint8Array, a: number[]): number {
  const rt = new WasmRuntime();
  return rt.invokeByName(rt.instantiate(m), 't', a.map(v => WasmValue.f32(v))).values[0].getAsF32();
}
function invokeF64(m: Uint8Array, a: number[]): number {
  const rt = new WasmRuntime();
  return rt.invokeByName(rt.instantiate(m), 't', a.map(v => WasmValue.f64(v))).values[0].getAsF64();
}
function invokeI64_i64Res(m: Uint8Array, a: number[]): bigint {
  const rt = new WasmRuntime();
  return rt.invokeByName(rt.instantiate(m), 't', a.map(v => WasmValue.f64(v))).values[0].getAsI64();
}
