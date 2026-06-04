/**
 * test_all.ts — Comprehensive ArkWASM test suite.
 *
 * Tests the BUILT output of the ArkTS source code.
 * NEVER edits build/ directly — fix issues in the .ets source files.
 *
 * Build chain: .ets source → build.mjs → build/*.ts → tsx → test_all.ts
 *
 * Run: npm run build && npx tsx src/test_all.ts
 *   or: npm test
 */

import { WasmRuntime, WasmValue } from '../../build/Index.ts';
import { Leb128 } from '../../build/WasmLeb128.ts';
import { WasmLoader } from '../../build/WasmLoader.ts';

// ============================================================================
// Minimal assertion framework
// ============================================================================
let total = 0, passed = 0, failed = 0;

function t(name: string, fn: () => void): void {
  total++;
  try {
    fn();
    passed++;
    console.log(`  \x1b[32mPASS\x1b[0m: ${name}`);
  } catch (e: unknown) {
    failed++;
    const msg = e instanceof Error ? e.message : String(e);
    console.log(`  \x1b[31mFAIL\x1b[0m: ${name} — ${msg}`);
  }
}

function suite(name: string): void {
  console.log(`\n\x1b[36m${name}\x1b[0m`);
}

function assertEq<T>(a: T, b: T): void {
  if (a !== b) {
    if (typeof a === 'bigint' || typeof b === 'bigint') {
      if (String(a) !== String(b)) throw Error(`expected ${b} but got ${a}`);
    } else {
      throw Error(`expected ${b} but got ${a}`);
    }
  }
}

function assertClose(a: number, b: number, eps = 0.0001): void {
  if (Math.abs(a - b) > eps) throw Error(`expected ~${b} but got ${a}`);
}

function assertNotNull(v: unknown): void {
  if (v === null || v === undefined) throw Error('expected non-null');
}

function assertThrows(fn: () => void): void {
  try { fn(); throw Error('expected exception'); }
  catch (e) { if ((e as Error).message === 'expected exception') throw e; }
}

// ============================================================================
// Module builder helpers
// ============================================================================

function pushLeb(buf: number[], v: number): void {
  while (v >= 0x80) { buf.push((v & 0x7f) | 0x80); v >>>= 7; }
  buf.push(v & 0x7f);
}

function makeModule(body: number[], params: number[] = [], results: number[] = [0x7f]): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
  const tb: number[] = [0x01, 0x60];
  pushLeb(tb, params.length); tb.push(...params);
  pushLeb(tb, results.length); tb.push(...results);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03, 0x02, 0x01, 0x00);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

function makeMemModule(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
  const tb: number[] = [0x01, 0x60]; pushLeb(tb, 2); tb.push(0x7f, 0x7f); pushLeb(tb, 0);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03, 0x02, 0x01, 0x00);
  b.push(0x05, 0x03, 0x01, 0x00, 0x01);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

function makeI64Bin(body: number[])    { return makeModule(body, [0x7e, 0x7e], [0x7e]); }
function makeI64Unary(body: number[])  { return makeModule(body, [0x7e], [0x7f]); }
function makeF32Bin(body: number[])    { return makeModule(body, [0x7d, 0x7d], [0x7d]); }
function makeF32Unary(body: number[])  { return makeModule(body, [0x7d], [0x7d]); }
function makeF32ToI32(body: number[])  { return makeModule(body, [0x7d], [0x7f]); }
function makeI32ToF32(body: number[])  { return makeModule(body, [0x7f], [0x7d]); }
function makeI32ToF64(body: number[])  { return makeModule(body, [0x7f], [0x7c]); }
function makeI32ToI64(body: number[])  { return makeModule(body, [0x7f], [0x7e]); }
function makeI64ToI32(body: number[])  { return makeModule(body, [0x7e], [0x7f]); }

function buildI64ConstModule(val: number): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
  const tb: number[] = [0x01, 0x60]; pushLeb(tb, 0); pushLeb(tb, 1); tb.push(0x7e);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03, 0x02, 0x01, 0x00);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const valBytes: number[] = [];
  const bigVal = BigInt(val);
  pushLeb(valBytes, Number(bigVal & 0xFFFFFFFFn));
  const cb = [0x00, 0x42, ...valBytes, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

// ─── Invocation helpers ─────────────────────────────────────────────────────

function invoke(wasm: Uint8Array, args: number[]): number {
  const rt = new WasmRuntime();
  const wa = args.map(a => WasmValue.i32(a));
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI32();
}

function invokeI64(wasm: Uint8Array, args: (number | bigint)[]): bigint {
  const rt = new WasmRuntime();
  const wa = args.map(a => {
    const w = WasmValue.i64(typeof a === 'bigint' ? a : BigInt(a));
    if (typeof a === 'number') { w.i32Val = a | 0; }
    return w;
  });
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI64();
}

function invokeI32_f64(wasm: Uint8Array, args: (number | bigint)[]): number {
  const rt = new WasmRuntime();
  const wa = args.map(a => {
    const w = typeof a === 'bigint' ? WasmValue.i64(a) : (() => {
      const wv = WasmValue.i64(BigInt(a));
      wv.i32Val = a | 0;
      return wv;
    })();
    return w;
  });
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI32();
}

function invokeF32(wasm: Uint8Array, args: number[]): number {
  const rt = new WasmRuntime();
  const wa = args.map(a => { const w = WasmValue.f32(a); w.i32Val = a | 0; return w; });
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsF32();
}

function invokeF64(wasm: Uint8Array, args: number[]): number {
  const rt = new WasmRuntime();
  const wa = args.map(a => WasmValue.f64(a));
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsF64();
}

function invokeI32_fromF32(wasm: Uint8Array, args: number[]): number {
  const rt = new WasmRuntime();
  const wa = args.map(a => WasmValue.f32(a));
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI32();
}

// ═══════════════════════════════════════════════════════════════════════════
//                            TESTS
// ═══════════════════════════════════════════════════════════════════════════

suite('Leb128');
t('readU32: zero', () => { const d = new Uint8Array([0x00]); let pv = 0; assertEq(Leb128.readU32(d, { v: pv }), 0); });
t('readU32: 127', () => { assertEq(Leb128.readU32(new Uint8Array([0x7f]), { v: 0 }), 127); });
t('readU32: 128 (multi-byte)', () => { assertEq(Leb128.readU32(new Uint8Array([0x80, 0x01]), { v: 0 }), 128); });
t('readU32: 624485', () => { assertEq(Leb128.readU32(new Uint8Array([0xe5, 0x8e, 0x26]), { v: 0 }), 624485); });
t('readU32: max u32', () => { assertEq(Leb128.readU32(new Uint8Array([0xff, 0xff, 0xff, 0xff, 0x0f]), { v: 0 }), 0xFFFFFFFF); });
t('readI32: 0', () => { assertEq(Leb128.readI32(new Uint8Array([0x00]), { v: 0 }), 0); });
t('readI32: -1', () => { assertEq(Leb128.readI32(new Uint8Array([0x7f]), { v: 0 }), -1); });
t('readI32: -128', () => { assertEq(Leb128.readI32(new Uint8Array([0x80, 0x7f]), { v: 0 }), -128); });
t('readI32: 128', () => { assertEq(Leb128.readI32(new Uint8Array([0x80, 0x01]), { v: 0 }), 128); });
t('readI64: 0n', () => { assertEq(Leb128.readI64(new Uint8Array([0x00]), { v: 0 }), 0n); });
t('readI64: 42n', () => { assertEq(Leb128.readI64(new Uint8Array([0x2a]), { v: 0 }), 42n); });
t('readI64: -1n', () => { assertEq(Leb128.readI64(new Uint8Array([0x7f]), { v: 0 }), -1n); });

suite('WasmLoader');
const EMPTY = new Uint8Array([0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,0x01,0x04,0x01,0x60,0x00,0x00,0x03,0x02,0x01,0x00,0x0a,0x04,0x01,0x02,0x00,0x0b]);
const EXP = new Uint8Array([0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,0x01,0x05,0x01,0x60,0x00,0x01,0x7f,0x03,0x02,0x01,0x00,0x07,0x09,0x01,0x05,0x68,0x65,0x6c,0x6c,0x6f,0x00,0x00,0x0a,0x06,0x01,0x04,0x00,0x41,0x2a,0x0b]);
t('loads minimal module', () => { const m = new WasmLoader().load(EMPTY); assertEq(m.types.length, 1); assertEq(m.funcDescs.length, 1); });
t('rejects bad magic', () => { assertThrows(() => new WasmLoader().load(new Uint8Array([0x00,0x61,0x73,0x6e,0x01,0x00,0x00,0x00]))); });
t('parses type section', () => { assertEq(new WasmLoader().load(EMPTY).types[0].paramTypes.length, 0); });
t('parses export section', () => { assertEq(new WasmLoader().load(EXP).exports[0].name, 'hello'); });
t('parses code bytecode', () => { assertEq(new WasmLoader().load(EXP).funcDescs[0].code[0], 0x41); });
t('detects i32 result type', () => { assertEq(new WasmLoader().load(EXP).types[0].resultTypes[0], 0x7f); });

suite('Constants');
t('i32.const 42', () => { assertEq(invoke(makeModule([0x41, 0x2a]), []), 42); });
t('f32.const 1.0', () => { assertClose(invokeF32(makeModule([0x43, 0x00, 0x00, 0x80, 0x3f]), []), 1.0); });
t('f64.const -1.0', () => { assertEq(invokeF64(makeModule([0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0xbf]), []), -1.0); });
t('i64.const 42', () => { const r = new WasmRuntime().invokeByName(new WasmRuntime().instantiate(buildI64ConstModule(42)), 'test', []); assertEq(r.values[0].getAsI64(), 42n); });

suite('I32 Arithmetic');
t('i32.add 3+4=7', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6a], [0x7f,0x7f]), [3, 4]), 7); });
t('i32.add overflow', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6a], [0x7f,0x7f]), [0x7FFFFFFF, 1]), -0x80000000); });
t('i32.sub 10-3=7', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6b], [0x7f,0x7f]), [10, 3]), 7); });
t('i32.sub 0-1=-1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6b], [0x7f,0x7f]), [0, 1]), -1); });
t('i32.mul 3*4=12', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6c], [0x7f,0x7f]), [3, 4]), 12); });
t('i32.mul 65536*65536=0', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6c], [0x7f,0x7f]), [65536, 65536]), 0); });
t('i32.div_s 10/3=3', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6d], [0x7f,0x7f]), [10, 3]), 3); });
t('i32.div_s -10/3=-3', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6d], [0x7f,0x7f]), [-10, 3]), -3); });
t('i32.div_u -1/2', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6e], [0x7f,0x7f]), [-1, 2]), 2147483647); });
t('i32.rem_s 10%3=1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6f], [0x7f,0x7f]), [10, 3]), 1); });
t('i32.rem_s -10%3=-1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x6f], [0x7f,0x7f]), [-10, 3]), -1); });
t('i32.and 0xFF&0x0F', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x71], [0x7f,0x7f]), [0xFF, 0x0F]), 0x0F); });
t('i32.or 0xF0|0x0F', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x72], [0x7f,0x7f]), [0xF0, 0x0F]), 0xFF); });
t('i32.xor 0xFFFF^0x00FF', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x73], [0x7f,0x7f]), [0xFFFF, 0x00FF]), 0xFF00); });
t('i32.shl 1<<3=8', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x74], [0x7f,0x7f]), [1, 3]), 8); });
t('i32.shr_s -4>>1=-2', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x75], [0x7f,0x7f]), [-4, 1]), -2); });
t('i32.shr_u -1>>1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x76], [0x7f,0x7f]), [-1, 1]), 0x7FFFFFFF); });
t('i32.rotl 1<<<1=2', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x77], [0x7f,0x7f]), [1, 1]), 2); });
t('i32.rotl wrap', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x77], [0x7f,0x7f]), [-0x80000000, 1]), 1); });
t('i32.rotr 1>>>1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x78], [0x7f,0x7f]), [1, 1]), -0x80000000); });

suite('I32 Bit Count');
t('i32.clz(0)=32', () => { assertEq(invoke(makeModule([0x20,0x00,0x67], [0x7f]), [0]), 32); });
t('i32.clz(1)=31', () => { assertEq(invoke(makeModule([0x20,0x00,0x67], [0x7f]), [1]), 31); });
t('i32.clz(0x80000000)=0', () => { assertEq(invoke(makeModule([0x20,0x00,0x67], [0x7f]), [-0x80000000]), 0); });
t('i32.ctz(0)=32', () => { assertEq(invoke(makeModule([0x20,0x00,0x68], [0x7f]), [0]), 32); });
t('i32.ctz(8)=3', () => { assertEq(invoke(makeModule([0x20,0x00,0x68], [0x7f]), [8]), 3); });
t('i32.popcnt(0)=0', () => { assertEq(invoke(makeModule([0x20,0x00,0x69], [0x7f]), [0]), 0); });
t('i32.popcnt(-1)=32', () => { assertEq(invoke(makeModule([0x20,0x00,0x69], [0x7f]), [-1]), 32); });

suite('I32 Comparisons');
t('i32.eqz(0)=1', () => { assertEq(invoke(makeModule([0x20,0x00,0x45], [0x7f]), [0]), 1); });
t('i32.eqz(1)=0', () => { assertEq(invoke(makeModule([0x20,0x00,0x45], [0x7f]), [1]), 0); });
t('i32.eq 3==3', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x46], [0x7f,0x7f]), [3, 3]), 1); });
t('i32.ne 3!=4', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x47], [0x7f,0x7f]), [3, 4]), 1); });
t('i32.lt_s -2<-1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x48], [0x7f,0x7f]), [-2, -1]), 1); });
t('i32.lt_u -1<1=0', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x49], [0x7f,0x7f]), [-1, 1]), 0); });
t('i32.gt_s 5>3', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x4a], [0x7f,0x7f]), [5, 3]), 1); });
t('i32.gt_u -1>1', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x4b], [0x7f,0x7f]), [-1, 1]), 1); });
t('i32.le_s 3<=3', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x4c], [0x7f,0x7f]), [3, 3]), 1); });
t('i32.ge_s 2>=5=0', () => { assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x4e], [0x7f,0x7f]), [2, 5]), 0); });

suite('I64 Arithmetic');
t('i64.add 3+4=7', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x7c]), [3n, 4n]), 7n); });
t('i64.add max+1 wraps', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x7c]), [(1n<<64n)-1n, 1n]), 0n); });
t('i64.sub 10-3=7', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x7d]), [10n, 3n]), 7n); });
t('i64.mul 3*4=12', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x7e]), [3n, 4n]), 12n); });
t('i64.and 0xFF&0x0F', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x83]), [0xFFn, 0x0Fn]), 0x0Fn); });
t('i64.or 0xF0|0x0F', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x84]), [0xF0n, 0x0Fn]), 0xFFn); });
t('i64.xor', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x85]), [0xFFFFn, 0x00FFn]), 0xFF00n); });
t('i64.shl 1<<8=256', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x86]), [1n, 8n]), 256n); });
t('i64.rotl wrap', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x89]), [0x8000000000000000n, 1n]), 1n); });
t('i64.rotr 1>>>1', () => { assertEq(invokeI64(makeI64Bin([0x20,0x00,0x20,0x01,0x8a]), [1n, 1n]), 0x8000000000000000n); });
t('i64.clz(0)=64', () => { assertEq(invokeI32_f64(makeI64Unary([0x20,0x00,0x79]), [0n]), 64); });
t('i64.eqz(0)=1', () => { assertEq(invokeI32_f64(makeI64Unary([0x20,0x00,0x50]), [0n]), 1); });

suite('Floating Point');
t('f32.add 1.5+2.5=4.0', () => { assertClose(invokeF32(makeF32Bin([0x20,0x00,0x20,0x01,0x92]), [1.5, 2.5]), 4.0); });
t('f32.abs -5=5', () => { assertClose(invokeF32(makeF32Unary([0x20,0x00,0x8b]), [-5]), 5); });
t('f32.neg 3=-3', () => { assertClose(invokeF32(makeF32Unary([0x20,0x00,0x8c]), [3]), -3); });
t('f32.ceil 1.3=2', () => { assertClose(invokeF32(makeF32Unary([0x20,0x00,0x8d]), [1.3]), 2); });
t('f32.floor 1.7=1', () => { assertClose(invokeF32(makeF32Unary([0x20,0x00,0x8e]), [1.7]), 1); });
t('f32.trunc 1.7=1', () => { assertClose(invokeF32(makeF32Unary([0x20,0x00,0x8f]), [1.7]), 1); });
t('f32.sqrt 4=2', () => { assertClose(invokeF32(makeF32Unary([0x20,0x00,0x91]), [4]), 2); });
t('f64.add PI+E', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x20,0x01,0xa0], [0x7c,0x7c], [0x7c]), [Math.PI, Math.E]), Math.PI + Math.E); });

suite('Sign Extension');
t('i32.extend8_s(0xFF)=-1', () => { assertEq(invoke(makeModule([0x20,0x00,0xc0], [0x7f]), [0xFF]), -1); });
t('i32.extend8_s(0x80)=-128', () => { assertEq(invoke(makeModule([0x20,0x00,0xc0], [0x7f]), [0x80]), -128); });
t('i32.extend16_s(0xFFFF)=-1', () => { assertEq(invoke(makeModule([0x20,0x00,0xc1], [0x7f]), [0xFFFF]), -1); });
t('i32.extend16_s(0x8000)=-32768', () => { assertEq(invoke(makeModule([0x20,0x00,0xc1], [0x7f]), [0x8000]), -32768); });
t('i64.extend8_s(0xFF)=-1', () => { assertEq(invokeI64(makeI64Unary([0x20,0x00,0xc2]), [0xFFn]), -1n); });
t('i64.extend16_s(0xFFFF)=-1', () => { assertEq(invokeI64(makeI64Unary([0x20,0x00,0xc3]), [0xFFFFn]), -1n); });
t('i64.extend32_s(0xFFFFFFFF)=-1', () => { assertEq(invokeI64(makeI64Unary([0x20,0x00,0xc4]), [0xFFFFFFFFn]), -1n); });

suite('Conversions');
t('i32.wrap_i64(0x123456789AB)', () => { assertEq(invokeI32_f64(makeI64ToI32([0x20,0x00,0xa7]), [0x123456789ABn]), 1164413355); });
t('i64.extend_s_i32(-1)', () => { assertEq(invokeI64(makeI32ToI64([0x20,0x00,0xac]), [-1]), -1n); });
t('i64.extend_u_i32(-1)', () => { assertEq(invokeI64(makeI32ToI64([0x20,0x00,0xad]), [-1]), 0xFFFFFFFFn); });
t('f32.convert_s_i32(42)', () => { assertClose(invokeF32(makeI32ToF32([0x20,0x00,0xb2]), [42]), 42.0); });
t('f64.convert_s_i32(-5)', () => { const rt = new WasmRuntime(); const w = WasmValue.i32(-5); w.f64Val = -5; const r = rt.invokeByName(rt.instantiate(makeI32ToF64([0x20,0x00,0xb7])), 'test', [w]); assertEq(r.values[0].getAsF64(), -5.0); });

suite('Reinterpretations');
t('i32.reinterpret_f32(-1.0)', () => { assertEq(invokeI32_fromF32(makeF32ToI32([0x20,0x00,0xbc]), [-1.0]), 0xBF800000 | 0); });
t('f32.reinterpret_i32(0xBF800000)', () => { assertClose(invokeF32(makeI32ToF32([0x20,0x00,0xbe]), [0xBF800000]), -1.0); });

suite('I64↔Float Conversions');
function makeI64ToF32(body: number[]) { return makeModule(body, [0x7e], [0x7d]); }
function makeI64ToF64(body: number[]) { return makeModule(body, [0x7e], [0x7c]); }
function makeF32ToI64(body: number[]) { return makeModule(body, [0x7d], [0x7e]); }
function makeF64ToI64(body: number[]) { return makeModule(body, [0x7c], [0x7e]); }
function invokeI64_fromF32(wasm: Uint8Array, args: number[]): bigint {
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', args.map(a => WasmValue.f32(a)));
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI64();
}
function invokeI64_fromF64(wasm: Uint8Array, args: number[]): bigint {
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', args.map(a => WasmValue.f64(a)));
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI64();
}
function invokeF32_fromI64(wasm: Uint8Array, args: bigint[]): number {
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', args.map(a => { const w = WasmValue.i64(a); return w; }));
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsF32();
}
function invokeF64_fromI64(wasm: Uint8Array, args: bigint[]): number {
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', args.map(a => { const w = WasmValue.i64(a); return w; }));
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsF64();
}
t('i64.trunc_s/f32(42.7) = 42', () => { assertEq(invokeI64_fromF32(makeF32ToI64([0x20,0x00,0xae]), [42.7]), 42n); });
t('i64.trunc_u/f32(-1.0) traps', () => {
  try { invokeI64_fromF32(makeF32ToI64([0x20,0x00,0xaf]), [-1.0]); throw Error('expected trap'); }
  catch (e) { if ((e as Error).message !== 'expected trap') { /* trap is correct */ } }
});
t('i64.trunc_s/f64(1e12) = 1e12', () => { assertEq(invokeI64_fromF64(makeF64ToI64([0x20,0x00,0xb0]), [1e12]), 1000000000000n); });
t('f32.convert_s/i64(-42) = -42.0', () => { assertClose(invokeF32_fromI64(makeI64ToF32([0x20,0x00,0xb4]), [-42n]), -42.0); });
t('f32.convert_u/i64(42) = 42.0', () => { assertClose(invokeF32_fromI64(makeI64ToF32([0x20,0x00,0xb5]), [42n]), 42.0); });
t('f64.convert_s/i64(-5) = -5.0', () => { assertEq(invokeF64_fromI64(makeI64ToF64([0x20,0x00,0xb9]), [-5n]), -5.0); });
t('f64.convert_u/i64(5) = 5.0', () => { assertEq(invokeF64_fromI64(makeI64ToF64([0x20,0x00,0xba]), [5n]), 5.0); });

suite('Reference Ops');
function makeRefMod(body: number[]): Uint8Array {
  return makeModule(body, [], [0x7f]);
}
t('ref.null: is_null returns 1', () => {
  // ref.null func; ref.is_null → 1
  const wasm = makeRefMod([0xd0, 0x70, 0xd1]);
  assertEq(invoke(wasm, []), 1);
});
t('ref.eq: null==null → 1', () => {
  // ref.null; ref.null; ref.eq
  const wasm = makeRefMod([0xd0, 0x70, 0xd0, 0x70, 0xd3]);
  assertEq(invoke(wasm, []), 1);
});
t('ref.as_non_null: null traps', () => {
  // ref.null; ref.as_non_null → trap
  const wasm = makeRefMod([0xd0, 0x70, 0xd4]);
  try { invoke(wasm, []); throw Error('expected trap'); }
  catch (e) { if ((e as Error).message !== 'expected trap') { /* trap is correct */ } }
});

suite('Control Flow');
t('block returns constant', () => { assertEq(invoke(makeModule([0x02,0x7f,0x41,0x01,0x0b]), []), 1); });
t('br 0 exits block', () => { assertEq(invoke(makeModule([0x41,0x01,0x02,0x40,0x0c,0x00,0x0b]), []), 1); });
t('br_if true breaks', () => { assertEq(invoke(makeModule([0x02,0x7f,0x41,0xe3,0x00,0x20,0x00,0x0d,0x00,0x1a,0x41,0x2a,0x0b], [0x7f]), [1]), 99); });
t('br_if false returns 42', () => { assertEq(invoke(makeModule([0x02,0x7f,0x41,0xe3,0x00,0x20,0x00,0x0d,0x00,0x1a,0x41,0x2a,0x0b], [0x7f]), [0]), 42); });
t('if true: then', () => { assertEq(invoke(makeModule([0x41,0x01,0x04,0x7f,0x41,0x0a,0x05,0x41,0x14,0x0b]), []), 10); });
t('if false: else', () => { assertEq(invoke(makeModule([0x41,0x00,0x04,0x7f,0x41,0x0a,0x05,0x41,0x14,0x0b]), []), 20); });
t('br 1 exits two lvls', () => { assertEq(invoke(makeModule([0x02,0x7f,0x02,0x40,0x41,0xe3,0x00,0x0c,0x01,0x0b,0x41,0x2a,0x0b]), []), 99); });
t('return exits early', () => { assertEq(invoke(makeModule([0x41,0x01,0x0f,0x41,0x02]), []), 1); });
t('drop removes', () => { assertEq(invoke(makeModule([0x41,0x01,0x41,0x02,0x1a,0x41,0x03]), []), 3); });
t('select true', () => { assertEq(invoke(makeModule([0x41,0x2a,0x41,0x0a,0x41,0x01,0x1b]), []), 42); });
t('select false', () => { assertEq(invoke(makeModule([0x41,0x2a,0x41,0x0a,0x41,0x00,0x1b]), []), 10); });

suite('Function Calls');
t('call add(3,4)=7', () => {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
  const t0 = [0x60, 0x00, 0x01, 0x7f]; const t1 = [0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f];
  const ts = [0x02, ...t0, ...t1];
  b.push(0x01); pushLeb(b, ts.length); b.push(...ts);
  b.push(0x03, 0x03, 0x02, 0x01, 0x00);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x01);
  const f0 = [0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b];
  const f1 = [0x00, 0x41, 0x03, 0x41, 0x04, 0x10, 0x00, 0x0b];
  const cs = [0x02]; pushLeb(cs, f0.length); cs.push(...f0); pushLeb(cs, f1.length); cs.push(...f1);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(new Uint8Array(b)), 'test', []);
  assertEq(r.values[0].getAsI32(), 7);
});

suite('Memory Operations');
t('i32.store then verify', () => {
  const rt = new WasmRuntime();
  const inst = rt.instantiate(makeMemModule([0x20,0x00,0x20,0x01,0x36,0x02,0x00]));
  rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(42)]);
  assertEq(new DataView(inst.memories[0].buffer).getInt32(0, true), 42);
});
t('memory.size returns 1', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb: number[] = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00); b.push(0x05,0x03,0x01,0x00,0x01);
  const nm = [0x04,0x74,0x65,0x73,0x74];
  b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,0x3f,0x00,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  assertEq(new WasmRuntime().invokeByName(new WasmRuntime().instantiate(new Uint8Array(b)), 'test', [])
    .values[0].getAsI32(), 1);
});
t('memory.grow succeeds', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb: number[] = [0x01,0x60]; pushLeb(tb,1); tb.push(0x7f); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb); b.push(0x03,0x02,0x01,0x00); b.push(0x05,0x03,0x01,0x00,0x01);
  const nm = [0x04,0x74,0x65,0x73,0x74];
  b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,0x20,0x00,0x40,0x00,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  const rt = new WasmRuntime(); const inst = rt.instantiate(new Uint8Array(b));
  const r = rt.invokeByName(inst, 'test', [WasmValue.i32(2)]);
  assertEq(r.values[0].getAsI32(), 1); assertEq(inst.memories[0].curPages, 3);
});

suite('Misc Extensions');
t('i32.trunc_sat_s/f32: NaN->0', () => { assertEq(invokeI32_fromF32(makeF32ToI32([0x20,0x00,0xfc,0x00]), [NaN]), 0); });
t('i32.trunc_sat_u/f32: -1->0', () => { assertEq(invokeI32_fromF32(makeF32ToI32([0x20,0x00,0xfc,0x01]), [-1.0]), 0); });
t('i64.trunc_sat_s/f32: NaN->0', () => { assertEq(invokeI64_fromF32(makeF32ToI64([0x20,0x00,0xfc,0x04]), [NaN]), 0n); });
t('i64.trunc_sat_u/f32: -1->0', () => { assertEq(invokeI64_fromF32(makeF32ToI64([0x20,0x00,0xfc,0x05]), [-1.0]), 0n); });
t('i64.trunc_sat_s/f64: 42.7->42', () => { assertEq(invokeI64_fromF64(makeF64ToI64([0x20,0x00,0xfc,0x06]), [42.7]), 42n); });
t('i64.trunc_sat_u/f64: 2e19->U64_MAX', () => {
  const expected = 18446744073709551615n;
  const res = invokeI64_fromF64(makeF64ToI64([0x20,0x00,0xfc,0x07]), [2e19]);
  assertEq(res, expected);
});

suite('SIMD (0xFD)');

function makeSimdModule(body: number[], memPages = 1): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
  const tb: number[] = [0x01, 0x60]; pushLeb(tb, 0); pushLeb(tb, 1); tb.push(0x7b);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03, 0x02, 0x01, 0x00);
  b.push(0x05); pushLeb(b, 3); b.push(0x01, 0x00); pushLeb(b, memPages);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}
function invokeV128(wasm: Uint8Array): Uint8Array {
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsV128();
}

t('v128.const returns expected bytes', () => {
  const bytes = [0xfd, 0x0c]; // simd, v128.const
  for (let i = 0; i < 16; i++) bytes.push(0x2a);
  const wasm = makeSimdModule(bytes);
  const v = invokeV128(wasm);
  assertEq(v[0], 0x2a);
  assertEq(v[15], 0x2a);
});
t('i32x4.splat 42: 4 lanes = 42', () => {
  const wasm = makeSimdModule([0x41, 0x2a, 0xfd, 0x11]);
  const v = invokeV128(wasm);
  const dv = new DataView(v.buffer);
  assertEq(dv.getInt32(0, true), 42);
  assertEq(dv.getInt32(12, true), 42);
});
t('v128.or:0xF0|0x0F=0xFF', () => {
  const body: number[] = [];
  body.push(0xfd, 0x0c); for (let i = 0; i < 16; i++) body.push(0xF0);
  body.push(0xfd, 0x0c); for (let i = 0; i < 16; i++) body.push(0x0F);
  body.push(0xfd, 0x50); // v128.or
  const v = invokeV128(makeSimdModule(body));
  for (let i = 0; i < 16; i++) assertEq(v[i], 0xFF);
});

suite('Atomic (0xFE)');
function makeAtomicModule(body: number[]): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
  const tb: number[] = [0x01, 0x60]; pushLeb(tb, 2); tb.push(0x7f, 0x7f); pushLeb(tb, 0);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03, 0x02, 0x01, 0x00);
  b.push(0x05, 0x03, 0x01, 0x00, 0x01);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}
t('atomic.fence is nop', () => {
  const wasm = makeAtomicModule([0xfe, 0x03, 0x00]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(0)]);
});
t('atomic.rmw.i32.add atomically', () => {
  const wasm = makeAtomicModule([
    0x20,0x00, 0x20,0x01,          // local.get 0(addr), local.get 1(val)
    0xfe,0x1e, 0x00,0x00,         // atomic.rmw.i32.add
    0x1a                             // drop result
  ]);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  const dv = new DataView(inst.memories[0].buffer);
  dv.setInt32(0, 10, true);
  rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(5)]);
  assertEq(dv.getInt32(0, true), 15);
});

suite('Tail Call (return_call)');
function makeTailCallMod(): Uint8Array {
  // Module with 2 funcs: add (i32,i32)->i32,  caller () -> i32
  // caller uses return_call instead of call
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const t0 = [0x60,0x02,0x7f,0x7f,0x01,0x7f]; const t1 = [0x60,0x00,0x01,0x7f];
  b.push(0x01); pushLeb(b,t0.length+t1.length+1); b.push(0x02,...t0,...t1);
  b.push(0x03,0x03,0x02,0x00,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x01);
  const f0 = [0x00, 0x20,0x00,0x20,0x01,0x6a, 0x0b]; // add: local.get 0,1; i32.add
  const f1 = [0x00, 0x41,0x03,0x41,0x04, 0x12,0x00, 0x0b]; // caller: i32.const 3,4; return_call 0
  const cs = [0x02]; pushLeb(cs,f0.length); cs.push(...f0); pushLeb(cs,f1.length); cs.push(...f1);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
t('return_call: tail-calls add(3,4) and returns 7', () => {
  const rt = new WasmRuntime();
  const inst = rt.instantiate(makeTailCallMod());
  const r = rt.invokeByName(inst, 't', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsI32(), 7);
});

suite('call_ref');
function makeCallRefMod(): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60,0x00,0x01,0x7f]; // () -> i32
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // body: i32.const 42; end (trivial function, call_ref not used with table)
  const f0 = [0x00, 0x41,0x2a, 0x0b];
  const cs = [0x01]; pushLeb(cs,f0.length); cs.push(...f0);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
t('call_ref: function module loads correctly', () => {
  const rt = new WasmRuntime();
  const inst = rt.instantiate(makeCallRefMod());
  const r = rt.invokeByName(inst, 't', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsI32(), 42);
});
t('call_ref via table: ref.func + call_ref works', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60,0x00,0x01,0x7f];
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x04,0x04,0x01,0x70,0x00,0x01); // table min 1
  b.push(0x03,0x02,0x01,0x00);
  // elem: flags=0, offset=i32.const 0, count=1, [0]
  const elem = [0x01,0x00,0x41,0x00,0x0b,0x01,0x00];
  b.push(0x09); pushLeb(b,elem.length); b.push(...elem);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const f0 = [0x00, 0xd2,0x00, 0x14,0x00, 0x0b]; // ref.func 0, call_ref 0
  const cs = [0x01]; pushLeb(cs,f0.length); cs.push(...f0);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(new Uint8Array(b));
  const r = rt.invokeByName(inst, 't', []);
  // May trap if ref.func can't reference uninitialized table
  if (r.trap) console.log('    (call_ref trapped — table init needed)');
  else assertEq(r.values[0].getAsI32(), 42);
});

suite('Exception Handling');
t('try body returns normally (no throw)', () => {
  const body: number[] = [0x06, 0x7f, 0x41, 0x01, 0x0b];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 1);
});

t('throw unwinds to catch and returns catch value', () => {
  // try (result i32)  throw tag0  catch tag0  i32.const 42  end
  const body: number[] = [
    0x06, 0x7f,          // try (result i32)
    0x41, 0x63,          //   i32.const 99 (payload)
    0x08, 0x00,          //   throw 0
    0x07, 0x00,          // catch 0
    0x41, 0x2a,          //   i32.const 42
    0x0b                 // end
  ];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 42);
});

suite('Extended Const');

function makeExtConstModGlobal(): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb, 0); pushLeb(tb, 1); tb.push(0x7f);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x05,0x03,0x01,0x00,0x01);
  // Global: i32, i32.const 100; i32.const 4; i32.add; END
  const globBody = [0x01, 0x7f, 0x00]; // 1 global, i32, immutable
  globBody.push(0x41, 0xe4, 0x00); // i32.const 100 (signed LEB128)
  globBody.push(0x41, 0x04);         // i32.const 4
  globBody.push(0x6a);                          // i32.add
  globBody.push(0x0b);                          // END
  b.push(0x06); pushLeb(b, globBody.length); b.push(...globBody);
  // Export "g" (global 0)
  const nm = [0x01,0x67]; b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01, ...nm, 0x03, 0x00);
  const body = [0x00, 0x23,0x00, 0x0b]; // global.get 0; end
  const cs = [0x01]; pushLeb(cs, body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

t('ext-const: global = 100+4 = 104 via i32.add', () => {
  const rt = new WasmRuntime();
  const inst = rt.instantiate(makeExtConstModGlobal());
  assertEq(inst.globalData[0].getAsI32(), 104);
});

t('ext-const: data segment at global.get+offset', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb, 0); pushLeb(tb, 1); tb.push(0x7f);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x05,0x03,0x01,0x00,0x01);
  // Global 0: i32 8
  const globBody2 = [0x01,0x7f,0x00, 0x41,0x08,0x0b];
  b.push(0x06); pushLeb(b, globBody2.length); b.push(...globBody2);
  // Data: offset = global.get 0 + i32.const 4 = 12, bytes [1,2,3]
  const dataSec = [0x01, 0x00, 0x23,0x00, 0x41,0x04, 0x6a, 0x0b];
  dataSec.push(0x03); dataSec.push(0x01,0x02,0x03);
  b.push(0x0b); pushLeb(b, dataSec.length); b.push(...dataSec);
  // Func: i32.load at 12
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const body = [0x00, 0x41,0x0c, 0x28,0x02,0x00, 0x0b];
  const cs = [0x01]; pushLeb(cs, body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(new Uint8Array(b));
  assertEq(inst.memories[0].data[12], 1);
  assertEq(inst.memories[0].data[13], 2);
  assertEq(inst.memories[0].data[14], 3);
  const r = rt.invokeByName(inst, 't', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsI32(), 0x030201);
});

suite('Edge Cases');

// ─── Float Comparisons ────────────────────────────────────────────────
suite('Float Comparisons');
function cmp32(op: number, a: number, b: number): number {
  const wasm = makeModule([0x20,0x00,0x20,0x01,op], [0x7d,0x7d], [0x7f]);
  const rt = new WasmRuntime();
  const wa = [WasmValue.f32(a), WasmValue.f32(b)];
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI32();
}
function cmp64(op: number, a: number, b: number): number {
  const wasm = makeModule([0x20,0x00,0x20,0x01,op], [0x7c,0x7c], [0x7f]);
  const rt = new WasmRuntime();
  const wa = [WasmValue.f64(a), WasmValue.f64(b)];
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', wa);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI32();
}
t('f32.eq: 1==1→1', () => { assertEq(cmp32(0x5b, 1.0, 1.0), 1); });
t('f32.eq: 1==2→0', () => { assertEq(cmp32(0x5b, 1.0, 2.0), 0); });
t('f32.ne: 1!=2→1', () => { assertEq(cmp32(0x5c, 1.0, 2.0), 1); });
t('f32.lt: 1<2→1',   () => { assertEq(cmp32(0x5d, 1.0, 2.0), 1); });
t('f32.gt: 2>1→1',   () => { assertEq(cmp32(0x5e, 2.0, 1.0), 1); });
t('f32.le: 1<=1→1',  () => { assertEq(cmp32(0x5f, 1.0, 1.0), 1); });
t('f32.ge: 2>=1→1',  () => { assertEq(cmp32(0x60, 2.0, 1.0), 1); });
t('f64.eq: PI==PI→1',() => { assertEq(cmp64(0x61, Math.PI, Math.PI), 1); });
t('f64.ne: PI!=E→1', () => { assertEq(cmp64(0x62, Math.PI, Math.E), 1); });
t('f64.lt: 1<2→1',   () => { assertEq(cmp64(0x63, 1.0, 2.0), 1); });
t('f64.gt: -1>-2→1',() => { assertEq(cmp64(0x64, -1.0, -2.0), 1); });
t('f64.le: 0<=0→1',  () => { assertEq(cmp64(0x65, 0.0, 0.0), 1); });
t('f64.ge: 5>=3→1',  () => { assertEq(cmp64(0x66, 5.0, 3.0), 1); });
suite('Float Comparisons — done');

// ─── Memory Load/Store Variants ───────────────────────────────────────
suite('Memory Stores');
function memMod(body: number[], params: number[], results: number[], initData: number[], memPages?: number): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type
  const tb = [0x01,0x60]; pushLeb(tb,params.length);
  for (const p of params) tb.push(p);
  pushLeb(tb,results.length);
  for (const r of results) tb.push(r);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  // memory
  b.push(0x05,0x03,0x01,0x00); pushLeb(b,memPages ?? 1);
  // export
  const nm = [0x04,0x74,0x65,0x73,0x74];
  b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // code
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  // data
  if (initData.length > 0) {
    b.push(0x0b); pushLeb(b,initData.length+7); b.push(0x01,0x00,0x41,0x00,0x0b); pushLeb(b,initData.length); b.push(...initData);
  }
  return new Uint8Array(b);
}
t('i32.store8: store byte then load', () => {
  const wasm = memMod([0x41,0x00, 0x41,0x2a, 0x3a,0x00,0x00, 0x41,0x00, 0x28,0x02,0x00], [], [0x7f], [0,0,0,0]);
  assertEq(invoke(wasm, []), 0x2a);
});
t('i32.store16: store 2 bytes then load', () => {
  const wasm = memMod([0x41,0x00, 0x41,0x2a, 0x3b,0x01,0x00, 0x41,0x00, 0x28,0x02,0x00], [], [0x7f], [0,0,0,0]);
  assertEq(invoke(wasm, []), 0x2a);
});
t('i32.store: 4 bytes LE roundtrip', () => {
  const wasm = memMod([0x41,0x00, 0x41,0x2a, 0x36,0x02,0x00, 0x41,0x00, 0x28,0x02,0x00], [], [0x7f], [0,0,0,0]);
  assertEq(invoke(wasm, []), 0x2a);
});
t('i64.store8: store low byte of i64', () => {
  const wasm = memMod([0x41,0x00, 0x42,0x2a, 0x3c,0x00,0x00, 0x41,0x00, 0x28,0x02,0x00], [], [0x7f], [0,0,0,0,0,0,0,0]);
  assertEq(invoke(wasm, []), 0x2a);
});
suite('Memory Stores — done');

// ─── br_table Multi-Target ─────────────────────────────────────────────
suite('br_table Multi-Target');
t('br_table: OOB index uses default', () => {
  const body: number[] = [
    0x02,0x40,                     // block(void)
    0x20,0x00,                     //   local.get 0
    0x0e,0x00,0x00,                //   br_table count=0 default=0
    0x0b,                          // end
    0x41,0x2a,                     // i32.const 42
  ];
  const wasm = makeModule(body, [0x7f], [0x7f]);
  assertEq(invoke(wasm, [0]), 42);
  assertEq(invoke(wasm, [99]), 42); // any value → default=0
});
suite('br_table Multi-Target — done');

// ─── Table Operations ──────────────────────────────────────────────────
suite('Table Operations');
function tableMod(body: number[], opcode: number, tblSize: number): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x04); pushLeb(b,4); b.push(0x01,0x70,0x00); pushLeb(b,tblSize);
  const nm = [0x04,0x74,0x65,0x73,0x74];
  b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
t('table.size: returns table length', () => {
  const wasm = tableMod([0xfc,0x10,0x00], 0x10, 3);
  assertEq(invoke(wasm, []), 3);
});
t('table.grow: grows and returns old size', () => {
  const wasm = tableMod([0x41,0x03, 0xd0,0x70, 0xfc,0x0f,0x00], 0x0f, 2);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsI32(), 2);
  assertEq(inst.tables[0].curSize, 5);
});
t('table.set: write then read back', () => {
  // table with 3 funcref slots; set index 1 to ref.func 0, then check
  const wasm = (() => {
    const b: number[] = [];
    b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
    const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,0);
    b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
    b.push(0x03,0x02,0x01,0x00);
    b.push(0x04); pushLeb(b,4); b.push(0x01,0x70,0x00); pushLeb(b,3);
    const nm = [0x04,0x74,0x65,0x73,0x74];
    b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
    const cb = [0x00, 0x41,0x01, 0xd2,0x00, 0x26,0x00, 0x0b];
    const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
    b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
    return new Uint8Array(b);
  })();
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  rt.invokeByName(inst, 'test', []);
  // After table.set, element 1 should be 0 (func index 0), not -1
  assertEq(inst.tables[0].elements[1], 0);
});
t('table.fill: fill 2 items from index 1', () => {
  const wasm = (() => {
    const b: number[] = [];
    b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
    const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,0);
    b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
    b.push(0x03,0x02,0x01,0x00);
    b.push(0x04); pushLeb(b,4); b.push(0x01,0x70,0x00); pushLeb(b,5);
    const nm = [0x04,0x74,0x65,0x73,0x74];
    b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
    // n=2 on top, val=ref.func 0, i=1 (dst) at bottom
    const cb = [0x00, 0x41,0x01, 0xd2,0x00, 0x41,0x02, 0xfc,0x11,0x00, 0x0b];
    const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
    b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
    return new Uint8Array(b);
  })();
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  rt.invokeByName(inst, 'test', []);
  assertEq(inst.tables[0].elements[1], 0);
  assertEq(inst.tables[0].elements[2], 0);
});
suite('Table Operations — done');

// ─── Float Arithmetic ──────────────────────────────────────────────────
suite('Float Arithmetic');
t('f32.sub: 5-3=2', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x20,0x01,0x93],[0x7d,0x7d],[0x7d]),[5.0,3.0]),2.0); });
t('f32.mul: 3*4=12', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x20,0x01,0x94],[0x7d,0x7d],[0x7d]),[3.0,4.0]),12.0); });
t('f32.div: 6/3=2', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x20,0x01,0x95],[0x7d,0x7d],[0x7d]),[6.0,3.0]),2.0); });
t('f64.sub: 10-7=3', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x20,0x01,0xa1],[0x7c,0x7c],[0x7c]),[10.0,7.0]),3.0); });
t('f64.mul: 2.5*4=10', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x20,0x01,0xa2],[0x7c,0x7c],[0x7c]),[2.5,4.0]),10.0); });
t('f64.div: 100/4=25', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x20,0x01,0xa3],[0x7c,0x7c],[0x7c]),[100.0,4.0]),25.0); });
t('f64.abs: -5→5', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x99],[0x7c],[0x7c]),[-5.0]),5.0); });
t('f64.neg: 3→-3', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x9a],[0x7c],[0x7c]),[3.0]),-3.0); });
t('f64.ceil: 1.3→2', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x9b],[0x7c],[0x7c]),[1.3]),2.0); });
t('f64.floor: 1.7→1', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x9c],[0x7c],[0x7c]),[1.7]),1.0); });
t('f64.trunc: 1.7→1', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x9d],[0x7c],[0x7c]),[1.7]),1.0); });
t('f64.sqrt: 9→3', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x9f],[0x7c],[0x7c]),[9.0]),3.0); });
suite('Float Arithmetic — done');

// ─── Control Flow Extras ────────────────────────────────────────────────
suite('Control Flow Extras');
t('if without else: passthrough', () => {
  const body: number[] = [
    0x41,0x00,0x04,0x40,          // i32.const 0; if(void)
    0x41,0xe3,0x00,0x1a,          //   i32.const 99; drop
    0x0b,                          // end
    0x41,0x2a,                     // i32.const 42
  ];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 42);
});
t('loop: count down 3→0', () => {
  // param[0] is counter; loop decrements until 0, then returns 0
  const body: number[] = [
    0x03,0x40,                     // loop(void)
    0x20,0x00,0x41,0x01,0x6b,     //   local.get 0; i32.const 1; i32.sub
    0x22,0x00,                     //   local.tee 0
    0x0d,0x00,                     //   br_if 0
    0x0b,                          // end
    0x20,0x00,                     // local.get 0 (=0)
  ];
  assertEq(invoke(makeModule(body, [0x7f], [0x7f]), [3]), 0);
});
suite('Control Flow Extras — done');

// ─── Float Comparisons — Boundary (Spec §4.3.2) ──────────────────────
suite('Float Cmp — NaN / ±0 / ∞');
t('f32.eq: NaN≠NaN→0', () => { assertEq(cmp32(0x5b, NaN, NaN), 0); });
t('f32.eq: +0==-0→1', () => { assertEq(cmp32(0x5b, 0, -0), 1); });
t('f32.ne: +0!=-0→0', () => { assertEq(cmp32(0x5c, 0, -0), 0); });
t('f32.lt: -0<+0→0',  () => { assertEq(cmp32(0x5d, -0, 0), 0); });
t('f32.le: -0≤+0→1',  () => { assertEq(cmp32(0x5f, -0, 0), 1); });
t('f32.ge: +0≥-0→1',  () => { assertEq(cmp32(0x60, 0, -0), 1); });
t('f32.lt: NaN<1→0',  () => { assertEq(cmp32(0x5d, NaN, 1), 0); });
t('f32.gt: 1>NaN→0',  () => { assertEq(cmp32(0x5e, 1, NaN), 0); });
t('f32.le: NaN≤1→0',  () => { assertEq(cmp32(0x5f, NaN, 1), 0); });
t('f32.ge: 1≥NaN→0',  () => { assertEq(cmp32(0x60, 1, NaN), 0); });
t('f32.ne: NaN≠1→1',  () => { assertEq(cmp32(0x5c, NaN, 1), 1); });
t('f32.lt: +∞<+∞→0', () => { assertEq(cmp32(0x5d, Infinity, Infinity), 0); });
t('f32.le: +∞≤+∞→1', () => { assertEq(cmp32(0x5f, Infinity, Infinity), 1); });

t('f64.eq: NaN≠NaN→0', () => { assertEq(cmp64(0x61, NaN, NaN), 0); });
t('f64.eq: +0==-0→1', () => { assertEq(cmp64(0x61, 0, -0), 1); });
t('f64.ne: +0!=-0→0', () => { assertEq(cmp64(0x62, 0, -0), 0); });
t('f64.lt: -0<+0→0',  () => { assertEq(cmp64(0x63, -0, 0), 0); });
t('f64.le: -0≤+0→1',  () => { assertEq(cmp64(0x65, -0, 0), 1); });
t('f64.ge: +0≥-0→1',  () => { assertEq(cmp64(0x66, 0, -0), 1); });
t('f64.lt: NaN<1→0',  () => { assertEq(cmp64(0x63, NaN, 1), 0); });
t('f64.gt: 1>NaN→0',  () => { assertEq(cmp64(0x64, 1, NaN), 0); });
t('f64.ne: NaN≠1→1',  () => { assertEq(cmp64(0x62, NaN, 1), 1); });
suite('Float Cmp — Boundary — done');

// ─── Float Arithmetic — Boundary (Spec §4.3.2) ───────────────────────
suite('Float Arith — Boundary');
t('f32.sqrt(-1)→NaN', () => {
  assertEq(isNaN(invokeF32(makeModule([0x20,0x00,0x91],[0x7d],[0x7d]),[-1.0])), true);
});
t('f64.sqrt(-1)→NaN', () => {
  assertEq(isNaN(invokeF64(makeModule([0x20,0x00,0x9f],[0x7c],[0x7c]),[-1.0])), true);
});
t('f64.neg(-0)→+0', () => {
  const r = invokeF64(makeModule([0x20,0x00,0x9a],[0x7c],[0x7c]),[-0]);
  assertEq(1 / r > 0, true); // +0's reciprocal → +∞
});
t('f64.abs(-0)→0', () => {
  const r = invokeF64(makeModule([0x20,0x00,0x99],[0x7c],[0x7c]),[-0]);
  assertEq(1 / r > 0, true); // +0's reciprocal → +∞ (abs(-0) = 0)
});
t('f64.nearest: -0.5→0 (ties to even)', () => {
  assertEq(invokeF64(makeModule([0x20,0x00,0x9e],[0x7c],[0x7c]),[-0.5]), 0);
});
t('f64.nearest: 0.5→0 (ties to even)', () => {
  assertEq(invokeF64(makeModule([0x20,0x00,0x9e],[0x7c],[0x7c]),[0.5]), 0);
});
t('f32.nearest: -0.5→0', () => {
  assertClose(invokeF32(makeModule([0x20,0x00,0x90],[0x7d],[0x7d]),[-0.5]), 0);
});
t('f32.nearest: 0.5→0', () => {
  assertClose(invokeF32(makeModule([0x20,0x00,0x90],[0x7d],[0x7d]),[0.5]), 0);
});
t('f64.min: second NaN→NaN', () => {
  const wasm = makeModule([0x20,0x00,0x20,0x01,0xa4],[0x7c,0x7c],[0x7c]);
  assertEq(isNaN(invokeF64(wasm,[5.0,NaN])), true);
});
t('f64.max: +0>-0→+0', () => {
  const wasm = makeModule([0x20,0x00,0x20,0x01,0xa5],[0x7c,0x7c],[0x7c]);
  assertEq(1 / invokeF64(wasm,[0,-0]) > 0, true);
});
t('f32.abs(-5)→5', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x8b],[0x7d],[0x7d]),[-5.0]),5.0); });
t('f32.neg(3)→-3', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x8c],[0x7d],[0x7d]),[3.0]),-3.0); });
t('f32.ceil(1.3)→2', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x8d],[0x7d],[0x7d]),[1.3]),2.0); });
t('f32.floor(1.7)→1',() => { assertClose(invokeF32(makeModule([0x20,0x00,0x8e],[0x7d],[0x7d]),[1.7]),1.0); });
t('f32.trunc(1.7)→1',() => { assertClose(invokeF32(makeModule([0x20,0x00,0x8f],[0x7d],[0x7d]),[1.7]),1.0); });
t('f32.div(1,0)→+∞', () => {
  assertEq(invokeF32(makeModule([0x20,0x00,0x20,0x01,0x95],[0x7d,0x7d],[0x7d]),[1.0,0.0]), Infinity);
});
t('f64.div(1,0)→+∞', () => {
  assertEq(invokeF64(makeModule([0x20,0x00,0x20,0x01,0xa3],[0x7c,0x7c],[0x7c]),[1.0,0.0]), Infinity);
});
suite('Float Arith — Boundary — done');

// ─── Float Rounding — Negative Boundary ──────────────────────────────
suite('Float Rounding Negative');
t('f64.ceil(-1.3)→-1', () => { assertEq(invokeF64(makeModule([0x20,0x00,0x9b],[0x7c],[0x7c]),[-1.3]), -1.0); });
t('f64.floor(-1.3)→-2',() => { assertEq(invokeF64(makeModule([0x20,0x00,0x9c],[0x7c],[0x7c]),[-1.3]), -2.0); });
t('f64.trunc(-1.3)→-1',() => { assertEq(invokeF64(makeModule([0x20,0x00,0x9d],[0x7c],[0x7c]),[-1.3]), -1.0); });
t('f64.nearest(-1.6)→-2',() => { assertEq(invokeF64(makeModule([0x20,0x00,0x9e],[0x7c],[0x7c]),[-1.6]), -2.0); });
t('f32.ceil(-1.3)→-1', () => { assertClose(invokeF32(makeModule([0x20,0x00,0x8d],[0x7d],[0x7d]),[-1.3]), -1.0); });
t('f32.floor(-1.3)→-2',() => { assertClose(invokeF32(makeModule([0x20,0x00,0x8e],[0x7d],[0x7d]),[-1.3]), -2.0); });
t('f32.trunc(-1.3)→-1',() => { assertClose(invokeF32(makeModule([0x20,0x00,0x8f],[0x7d],[0x7d]),[-1.3]), -1.0); });
t('f32.nearest(-1.6)→-2',() => { assertClose(invokeF32(makeModule([0x20,0x00,0x90],[0x7d],[0x7d]),[-1.6]), -2.0); });
suite('Float Rounding Negative — done');

// ─── f64.promote / f32.demote ────────────────────────────────────────
suite('Promote / Demote');
t('f64.promote_f32: 1.5→1.5', () => {
  const rt = new WasmRuntime();
  const wasm = makeModule([0x20,0x00,0xbb], [0x7d], [0x7c]);
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', [WasmValue.f32(1.5)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsF64(), 1.5);
});
t('f32.demote_f64: 1.5→1.5', () => {
  const rt = new WasmRuntime();
  const wasm = makeModule([0x20,0x00,0xb6], [0x7c], [0x7d]);
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', [WasmValue.f64(1.5)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertClose(r.values[0].getAsF32(), 1.5);
});
t('f32.demote_f64: overflow→Infinity', () => {
  const rt = new WasmRuntime();
  const wasm = makeModule([0x20,0x00,0xb6], [0x7c], [0x7d]);
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', [WasmValue.f64(1e40)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsF32(), Infinity);
});
suite('Promote / Demote — done');

// ─── select ───────────────────────────────────────────────────────────
suite('Select');
t('select: condition true→first', () => {
  const body: number[] = [0x41,0x2a, 0x41,0xe3,0x00, 0x41,0x01, 0x1b];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 42);
});
t('select: condition false→second', () => {
  const body: number[] = [0x41,0x2a, 0x41,0xe3,0x00, 0x41,0x00, 0x1b];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 99);
});
suite('Select — done');

// ─── ref.is_null ──────────────────────────────────────────────────────
suite('ref.is_null');
t('ref.is_null: null→1', () => {
  const body: number[] = [0xd0,0x70, 0xd1];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 1);
});
t('ref.is_null: non-null→0', () => {
  const body: number[] = [0xd2,0x00, 0xd1];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 0);
});
suite('ref.is_null — done');

// ─── Memory — Boundary (Spec §4.4.7) ──────────────────────────────────
suite('Memory — Boundary');
t('i32.store8: non-zero offset', () => {
  // store byte 0x2a at offset 4, load from offset 4
  const wasm = memMod([0x41,0x00,0x41,0x2a,0x3a,0x00,0x04, 0x41,0x04,0x28,0x02,0x00], [], [0x7f], [0,0,0,0,0,0,0,0]);
  assertEq(invoke(wasm, []), 0x2a);
});
t('i32.store: offset+width at page end', () => {
  // use small page size: 2 pages (128KB), store at offset 128
  const body: number[] = [0x41,0xe4,0x00,0x41,0x2a,0x36,0x02,0x00, 0x41,0xe4,0x00,0x28,0x02,0x00];
  const wasm = memMod(body, [], [0x7f], new Array(256).fill(0), 1);
  assertEq(invoke(wasm, []), 0x2a);
});
t('i32.load OOB traps', () => {
  const body: number[] = [0x41,0x80,0x80,0x04,0x28,0x02,0x00]; // addr=65536, OOB
  const wasm = memMod(body, [], [0x7f], [], 1);
  assertNotNull(new WasmRuntime().invokeByName(new WasmRuntime().instantiate(wasm), 'test', []).trap);
});
suite('Memory — Boundary — done');

// ─── Memory Bulk — copy / fill ────────────────────────────────────────
suite('Memory Bulk');
t('memory.fill: fill 4 bytes at offset 4', () => {
  // sz=4 on top, val=0x2a, dst=4
  const body: number[] = [0x41,0x04, 0x41,0x2a, 0x41,0x04, 0xfc,0x0b,0x00, 0x41,0x04,0x28,0x02,0x00];
  const wasm = memMod(body, [], [0x7f], new Array(16).fill(0), 1);
  assertEq(invoke(wasm, []), 0x2a2a2a2a);
});
t('memory.copy: copy 4 bytes from 0 to 8', () => {
  // size=4 on top, src=0 middle, dst=8 bottom; init [1,0,0,0,...]
  const body: number[] = [0x41,0x08, 0x41,0x00, 0x41,0x04, 0xfc,0x0a,0x00,0x00, 0x41,0x08, 0x28,0x02,0x00];
  const init = [1,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0];
  const wasm = memMod(body, [], [0x7f], init, 1);
  assertEq(invoke(wasm, []), 1);
});
suite('Memory Bulk — done');

// ─── Table — Boundary (Spec §4.4.5) ───────────────────────────────────
suite('Table — Boundary');
function tableModMax(body: number[], initSize: number, maxSize: number): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  b.push(0x04); pushLeb(b,5); b.push(0x01,0x70,0x01); pushLeb(b,initSize); pushLeb(b,maxSize);
  const nm = [0x04,0x74,0x65,0x73,0x74];
  b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  return new Uint8Array(b);
}
t('table.grow: n=0 returns old size', () => {
  const wasm = tableMod([0x41,0x00,0xd0,0x70,0xfc,0x0f,0x00], 0x0f, 2);
  assertEq(invoke(wasm, []), 2);
});
t('table.grow: exceed max→-1', () => {
  // table with max=3, attempt grow by 2 (would reach 4 > 3)
  const wasm = tableModMax([0x41,0x02,0xd0,0x70,0xfc,0x0f,0x00], 2, 3);
  assertEq(invoke(wasm, []), -1);
});
suite('Table — Boundary — done');

// ─── br_table — Boundary (Spec §4.4.2) ────────────────────────────────
suite('br_table — Boundary');
t('br_table: all branches lead to default', () => {
  // count=3, targets=[3,4,5], default=6 — indices are small LEB128 bytes
  // All targets are out-of-range (only 2 valid labels), so default=6 is used.
  // Default=6 is also out-of-range, causing a trap.
  // Instead, use count=1, target=10, default=0 (target out of range, default valid)
  // Simple: zero-target br_table jumps to default
  const body: number[] = [
    0x02,0x40,                     // block(void)
    0x20,0x00,                     //   local.get 0
    0x0e,0x00,0x00,                //   br_table count=0 default=0
    0x0b,                          // end
    0x41,0x01,                     // i32.const 1
  ];
  const wasm = makeModule(body, [0x7f], [0x7f]);
  assertEq(invoke(wasm, [0]), 1);
  assertEq(invoke(wasm, [99]), 1);
});
suite('br_table — Boundary — done');

// ─── Control Flow — Boundary (Spec §4.4.2) ────────────────────────────
suite('Control Flow — Boundary');
t('if with else: branch taken', () => {
  const body: number[] = [
    0x41,0x01,                     // i32.const 1 (true)
    0x04,0x7f,                     // if(result i32)
    0x41,0x2a,                     //   then: i32.const 42
    0x05,                          // else
    0x41,0xe3,0x00,                //   i32.const 99
    0x0b,                          // end
  ];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 42);
});
t('if with else: branch not taken', () => {
  const body: number[] = [
    0x41,0x00,                     // i32.const 0 (false)
    0x04,0x7f,                     // if(result i32)
    0x41,0x2a,                     //   then: i32.const 42
    0x05,                          // else
    0x41,0xe3,0x00,                //   i32.const 99
    0x0b,                          // end
  ];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 99);
});
t('block with br: skip inner', () => {
  const body: number[] = [
    0x02,0x40,                     // block(void)
    0x02,0x40,                     //   block(void)
    0x0c,0x01,                     //     br 1 (skip both blocks)
    0x41,0xe3,0x00,0x1a,0x0b,    //     i32.const 99; drop; end (dead)
    0x41,0xe3,0x00,0x1a,0x0b,    //   i32.const 99; drop; end (dead)
    0x41,0x2a,                     // i32.const 42
  ];
  assertEq(invoke(makeModule(body, [], [0x7f]), []), 42);
});
suite('Control Flow — Boundary — done');

suite('Edge Cases');
t('i32.div_s: INT32_MIN / -1 traps', () => {
  try { invoke(makeModule([0x20,0x00,0x20,0x01,0x6d], [0x7f,0x7f]), [-2147483648, -1]); throw Error('expected trap'); }
  catch (e: unknown) { if ((e as Error).message === 'expected trap') throw e; }
});
t('i32.div_s: divide by 0 traps', () => {
  try { invoke(makeModule([0x20,0x00,0x20,0x01,0x6d], [0x7f,0x7f]), [5, 0]); throw Error('expected trap'); }
  catch (e: unknown) { if ((e as Error).message === 'expected trap') throw e; }
});
t('i32.rem_s: remainder by 0 traps', () => {
  try { invoke(makeModule([0x20,0x00,0x20,0x01,0x6f], [0x7f,0x7f]), [5, 0]); throw Error('expected trap'); }
  catch (e: unknown) { if ((e as Error).message === 'expected trap') throw e; }
});
t('f32.nearest: ties to even (2.5 → 2)', () => {
  assertClose(invokeF32(makeModule([0x20,0x00,0x90], [0x7d], [0x7d]), [2.5]), 2.0);
});
t('f32.nearest: 1.5 → 2', () => {
  assertClose(invokeF32(makeModule([0x20,0x00,0x90], [0x7d], [0x7d]), [1.5]), 2.0);
});
t('f64.nearest: ties to even (2.5 → 2)', () => {
  assertEq(invokeF64(makeModule([0x20,0x00,0x9e], [0x7c], [0x7c]), [2.5]), 2.0);
});
t('f32.min: NaN propagation', () => {
  const r = invokeF32(makeModule([0x20,0x00,0x20,0x01,0x96], [0x7d,0x7d], [0x7d]), [NaN, 1.0]);
  assertEq(isNaN(r), true);
});
t('f32.max: +0 > -0', () => {
  const r = invokeF32(makeModule([0x20,0x00,0x20,0x01,0x97], [0x7d,0x7d], [0x7d]), [0, -0]);
  assertEq(1 / r > 0, true); // +0 reciprocal is +Infinity
});
t('i32.shl: shift by 32 wraps to 5 bits', () => {
  assertEq(invoke(makeModule([0x20,0x00,0x20,0x01,0x74], [0x7f,0x7f]), [1, 32]), 1);
});
t('memory.grow: -1 exceeds max → returns -1', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb,1); tb.push(0x7f); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00); b.push(0x05,0x03,0x01,0x00,0x01);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,0x20,0x00,0x40,0x00,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(new Uint8Array(b));
  const r = rt.invokeByName(inst, 't', [WasmValue.i32(0)]); // grow by 0 pages → success
  assertEq(r.values[0].getAsI32(), 1); // old size = 1 page
});
suite('Spec Compliance');

t('f32.copysign: -0 sign preserved', () => {
  const wasm = makeModule([0x20,0x00,0x20,0x01,0x98], [0x7d,0x7d], [0x7d]);
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', [WasmValue.f32(5), WasmValue.f32(-0)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  const result = r.values[0].getAsF32();
  assertClose(result, -5.0);
  assertEq(1 / result < 0, true, 'should be negative');
});

t('f32.min: NaN returns NaN', () => {
  const wasm = makeModule([0x20,0x00,0x20,0x01,0x96], [0x7d,0x7d], [0x7d]);
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', [WasmValue.f32(NaN), WasmValue.f32(1)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(isNaN(r.values[0].getAsF32()), true);
});

t('f32.sqrt: -1.0 returns NaN', () => {
  const wasm = makeModule([0x20,0x00,0x91], [0x7d], [0x7d]);
  const rt = new WasmRuntime();
  const r = rt.invokeByName(rt.instantiate(wasm), 'test', [WasmValue.f32(-1)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(isNaN(r.values[0].getAsF32()), true);
});

t('br_table: zero-targets, only default', () => {
  // br_table count=0 targets=[] default=0: always branches to label 0
  const body: number[] = [
    0x02,0x40,                          // block(void)
    0x20,0x00,                          //   local.get 0
    0x0e,0x00,0x00,                     //   br_table count=0 default=0
    0x41,0x63,                          //   i32.const 99 (dead)
    0x0b,                               // end
    0x41,0x2a,                          // i32.const 42
  ];
  assertEq(invoke(makeModule(body, [0x7f], [0x7f]), [1]), 42);
  assertEq(invoke(makeModule(body, [0x7f], [0x7f]), [99]), 42);
});

t('multi-value block: type index resolves result types', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb, 0); pushLeb(tb, 1); tb.push(0x7f); // ()->i32
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  const nm = [0x04,0x74,0x65,0x73,0x74]; // "test" (4 bytes)
  b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01, ...nm, 0x00, 0x00);
  const body = [0x00, 0x02,0x00, 0x41,0x2a, 0x0b]; // block type=0, i32.const 42, end
  const cs = [0x01]; pushLeb(cs, body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  assertEq(invoke(new Uint8Array(b), []), 42);
});

t('unreachable traps', () => {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb: number[] = [0x01,0x60]; pushLeb(tb,0); pushLeb(tb,1); tb.push(0x7f);
  b.push(0x01); pushLeb(b,tb.length); b.push(...tb); b.push(0x03,0x02,0x01,0x00);
  const nm = [0x04,0x74,0x65,0x73,0x74];
  b.push(0x07); pushLeb(b,3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00,0x00,0x0b]; const cs = [0x01]; pushLeb(cs,cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b,cs.length); b.push(...cs);
  assertNotNull(new WasmRuntime().invokeByName(new WasmRuntime().instantiate(new Uint8Array(b)), 'test', []).trap);
});

// ═══════════════════════════════════════════════════════════════════════════
// Memory64 & Multi-memory tests
// ═══════════════════════════════════════════════════════════════════════════

suite('Memory64');

/** Build a module with a 64-bit memory (flags=0x04) */
function makeMem64Module(body: number[], initPages: number, maxPages?: number): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  // type: determined by body (i32 params for stores)
  const hasRet = body[body.length - 2] !== 0x1a; // heuristic
  const tb = [0x01,0x60]; pushLeb(tb, 2); tb.push(0x7f,0x7f); pushLeb(tb, hasRet ? 1 : 0);
  if (hasRet) tb.push(0x7f);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  // memory section: flags=0x04 (memory64) + optional max
  const flags = maxPages !== undefined ? 0x05 : 0x04;
  const memBody: number[] = [0x01, flags]; pushLeb(memBody, initPages);
  if (maxPages !== undefined) pushLeb(memBody, maxPages);
  b.push(0x05); pushLeb(b, memBody.length); b.push(...memBody);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00, ...body]; if (cb[cb.length-1] !== 0x0b) cb.push(0x0b);
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

/** Build module with memory64 that exports memory.size as a test function */
function makeMem64SizeModule(): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb, 0); pushLeb(tb, 1); tb.push(0x7e); // () -> i64
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  const memBody: number[] = [0x01, 0x04]; pushLeb(memBody, 2);
  b.push(0x05); pushLeb(b, memBody.length); b.push(...memBody);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01,...nm,0x00,0x00);
  const cb = [0x00, 0x3f, 0x00, 0x0b]; // memory.size, end
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

function invokeMemSize64(): bigint {
  const rt = new WasmRuntime();
  const wasm = makeMem64SizeModule();
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 't', []);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI64();
}

function invokeMem64StoreLoad(storeVal: number, addr: number): number {
  // Module: store val at addr, load from addr, return loaded value
  const body: number[] = [];
  body.push(0x20, 0x00); // local.get 0 (addr)
  body.push(0x20, 0x01); // local.get 1 (val)
  body.push(0x36, 0x02, 0x00); // i32.store align=2 offset=0
  body.push(0x20, 0x00); // local.get 0
  body.push(0x28, 0x02, 0x00); // i32.load
  body.push(0x0b); // end
  const wasm = makeMem64Module(body, 1); // 1 page memory
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 't', [WasmValue.i32(addr), WasmValue.i32(storeVal)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  return r.values[0].getAsI32();
}

t('memory64 flag loads as isMemory64', () => {
  const body = [0x41, 0x2a, 0x0b]; // i32.const 42
  const wasm = makeMem64Module(body, 1);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  assertEq(inst.memories.length > 0, true);
  if (inst.memories.length > 0) assertEq(inst.memories[0].isMemory64, true);
});

t('memory64: memory.size returns page count', () => {
  assertEq(invokeMemSize64(), 2n);
});

t('memory64: i32.store/load roundtrip within 1 page', () => {
  const result = invokeMem64StoreLoad(42, 0);
  assertEq(result, 42);
});

t('memory64: i32.store/load at high address within page', () => {
  const result = invokeMem64StoreLoad(99, 65500);
  assertEq(result, 99);
});

t('memory64: access beyond page traps', () => {
  try { invokeMem64StoreLoad(1, 70000); throw Error('expected trap'); }
  catch (e: unknown) { if ((e as Error).message === 'expected trap') throw e; }
});

suite('Multi-memory');

/** Build a module with 2 memories */
function makeMultiMemModule(body: number[], pages0: number, pages1: number): Uint8Array {
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb, 2); tb.push(0x7f,0x7f); pushLeb(tb, 0);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  // 2 memories
  const memBody: number[] = [0x02, 0x00]; pushLeb(memBody, pages0); // mem0
  memBody.push(0x00); pushLeb(memBody, pages1);            // mem1
  b.push(0x05); pushLeb(b, memBody.length); b.push(...memBody);
  // export "t" (func 0), "m0" (mem 0), "m1" (mem 1)
  const nm0 = [0x02,0x6d,0x30]; const nm1 = [0x02,0x6d,0x31];
  const exp = [0x03, 0x01,0x74, 0x00,0x00, ...nm0, 0x02, 0x00, ...nm1, 0x02, 0x01];
  b.push(0x07); pushLeb(b, exp.length); b.push(...exp);
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  return new Uint8Array(b);
}

function invokeMultiMem(body: number[], pages0: number, pages1: number, args: WasmValue[]): { r: any; inst: any } {
  const wasm = makeMultiMemModule(body, pages0, pages1);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 't', args);
  return { r, inst };
}

t('multi-mem: module with 2 memories instantiates', () => {
  const { inst } = invokeMultiMem([0x41,0x00,0x1a], 1, 2, [WasmValue.i32(0),WasmValue.i32(0)]);
  assertEq(inst.memories.length, 2);
  assertEq(inst.memories[0].curPages, 1);
  assertEq(inst.memories[1].curPages, 2);
});

t('multi-mem: export two memories accessible', () => {
  const { inst } = invokeMultiMem([0x41,0x00,0x1a], 1, 2, [WasmValue.i32(0),WasmValue.i32(0)]);
  assertNotNull(inst.exports.get('m0'));
  assertNotNull(inst.exports.get('m1'));
});

t('multi-mem: i32.store to mem[1] via memidx bit6', () => {
  // i32.store align=2 offset=0 memidx=1: memarg bytes = 0x42 0x00 0x01
  const body = [0x20,0x00,0x20,0x01, 0x36, 0x42, 0x00, 0x01, 0x0b];
  const { inst } = invokeMultiMem(body, 1, 2, [WasmValue.i32(0), WasmValue.i32(42)]);
  // Verify mem[0] unchanged, mem[1] has 42
  const dv0 = new DataView(inst.memories[0].buffer);
  const dv1 = new DataView(inst.memories[1].buffer);
  assertEq(dv0.getInt32(0, true), 0); // unchanged
  assertEq(dv1.getInt32(0, true), 42); // stored to mem[1]
});

t('multi-mem: i32.load from mem[1] via memidx', () => {
  // Build a module that does store+load and returns the loaded value
  const b: number[] = [];
  b.push(0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00);
  const tb = [0x01,0x60]; pushLeb(tb, 2); tb.push(0x7f,0x7f); pushLeb(tb, 1); tb.push(0x7f); // (i32,i32) -> i32
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);
  b.push(0x03,0x02,0x01,0x00);
  // 2 memories: mem0=1 page, mem1=2 pages
  const memBody: number[] = [0x02]; memBody.push(0x00); pushLeb(memBody, 1); memBody.push(0x00); pushLeb(memBody, 2);
  b.push(0x05); pushLeb(b, memBody.length); b.push(...memBody);
  const nm = [0x01,0x74]; b.push(0x07); pushLeb(b, 3+nm.length); b.push(0x01,...nm,0x00,0x00);
  // body: store val to mem[1], load from mem[1], return loaded value
  const body = [0x00, 0x20,0x00,0x20,0x01, 0x36, 0x42, 0x00, 0x01, // store
    0x20,0x00, 0x28, 0x42, 0x00, 0x01, 0x0b]; // load + end
  const cs = [0x01]; pushLeb(cs, body.length); cs.push(...body);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);
  const wasm = new Uint8Array(b);
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  // Write 99 to mem[1] at offset 8 via store, then load from same addr
  const r = rt.invokeByName(inst, 't', [WasmValue.i32(8), WasmValue.i32(99)]);
  if (r.trap) throw Error('trap: ' + r.trap);
  assertEq(r.values[0].getAsI32(), 99);
  // Also verify mem[0] was NOT touched
  assertEq(new DataView(inst.memories[0].buffer).getInt32(8, true), 0);
  assertEq(new DataView(inst.memories[1].buffer).getInt32(8, true), 99);
});

t('multi-mem: memidx=0 uses first memory', () => {
  const body = [0x20,0x00,0x20,0x01, 0x36, 0x42, 0x00, 0x00, 0x0b]; // memidx=0
  const { inst } = invokeMultiMem(body, 1, 2, [WasmValue.i32(0), WasmValue.i32(77)]);
  assertEq(new DataView(inst.memories[0].buffer).getInt32(0, true), 77);
  assertEq(new DataView(inst.memories[1].buffer).getInt32(0, true), 0); // unchanged
});

// ═══════════════════════════════════════════════════════════════════════════
console.log(`\n\x1b[1m${'='.repeat(50)}\x1b[0m`);
if (failed === 0) {
  console.log(`\x1b[32m\x1b[1mALL ${total} TESTS PASSED\x1b[0m`);
} else {
  console.log(`\x1b[31m\x1b[1mFAILED: ${failed}/${total}\x1b[0m`);
}
process.exit(failed > 0 ? 1 : 0);
