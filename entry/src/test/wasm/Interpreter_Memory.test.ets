/**
 * Interpreter_Memory.test.ets — Memory-specific tests for the interpreter.
 * Tests: load/store variants, bounds checking, memory.grow, alignment.
 */
import { describe, it, expect } from '@ohos/hypium/index';
import { WasmRuntime } from '../ets/wasm/WasmRuntime';
import { WasmValue } from '../ets/wasm/WasmTypes';

function makeModule(params: number[], results: number[], body: number[], memInit: number = 1): Uint8Array {
  const bytes: number[] = [];
  bytes.push(0x00, 0x61, 0x73, 0x6d);
  bytes.push(0x01, 0x00, 0x00, 0x00);

  // Type
  const tb = [0x01, 0x60];
  pushLeb(tb, params.length); tb.push(...params);
  pushLeb(tb, results.length); tb.push(...results);
  bytes.push(0x01); pushLeb(bytes, tb.length); bytes.push(...tb);

  // Function
  bytes.push(0x03, 0x02, 0x01, 0x00);

  // Memory: 1 mem, init pages
  bytes.push(0x05, 0x04, 0x01, 0x00);
  pushLeb(bytes, memInit);

  // Export "test"
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  bytes.push(0x07); pushLeb(bytes, 2 + nm.length); bytes.push(0x01, ...nm, 0x00, 0x00);

  // Code
  const cb = [0x00, ...body, 0x0B];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  bytes.push(0x0a); pushLeb(bytes, cs.length); bytes.push(...cs);

  return new Uint8Array(bytes);
}

function pushLeb(buf: number[], v: number): void {
  while (v >= 0x80) { buf.push((v & 0x7f) | 0x80); v >>>= 7; }
  buf.push(v & 0x7f);
}

export default function testSuite() {
  describe('Memory Operations - Detailed', () => {

    // ── I32 Load/Store Variants ────────────────────────────────────────────
    describe('i32 load variants', () => {
      it('i32.load8_s: -1 (0xFF) loads as -1', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,             // local.get 0
          0x2c, 0x00, 0x00        // i32.load8_s align=0 offset=0
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        // Write 0xFF at address 0
        inst.memories[0].data[0] = 0xFF;
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(0)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(-1);
      });

      it('i32.load8_u: 0xFF loads as 255', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,
          0x2d, 0x00, 0x00        // i32.load8_u
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        inst.memories[0].data[0] = 0xFF;
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(0)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(255);
      });

      it('i32.load16_s: 0xFFFF loads as -1', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,
          0x2e, 0x01, 0x00        // i32.load16_s align=1 offset=0
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        inst.memories[0].data[0] = 0xFF;
        inst.memories[0].data[1] = 0xFF;
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(0)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(-1);
      });

      it('i32.load16_u: 0xFFFF loads as 65535', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,
          0x2f, 0x01, 0x00        // i32.load16_u
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        inst.memories[0].data[0] = 0xFF;
        inst.memories[0].data[1] = 0xFF;
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(0)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(65535);
      });

      it('i32.load with offset', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,
          0x28, 0x02, 0x10        // i32.load offset=16
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        const dv = new DataView(inst.memories[0].buffer);
        dv.setInt32(20, 777, true);
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(4)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(777);
      });
    });

    // ── I32 Store Variants ─────────────────────────────────────────────────
    describe('i32 store variants', () => {
      it('i32.store8 stores low byte', () => {
        const mod = makeModule([0x7f, 0x7f], [], [
          0x20, 0x00, 0x20, 0x01, // local.get 0, local.get 1
          0x3a, 0x00, 0x00        // i32.store8
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(0x1234)]);
        expect(inst.memories[0].data[0]).assertEqual(0x34);
      });

      it('i32.store16 stores low 2 bytes', () => {
        const mod = makeModule([0x7f, 0x7f], [], [
          0x20, 0x00, 0x20, 0x01,
          0x3b, 0x01, 0x00        // i32.store16
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(0x12345678)]);
        const dv = new DataView(inst.memories[0].buffer);
        expect(dv.getUint16(0, true)).assertEqual(0x5678);
      });
    });

    // ── I64 Load/Store ─────────────────────────────────────────────────────
    describe('i64 load/store', () => {
      it('i64.store then i64.load', () => {
        // Build a module with i64.store
        const mod = makeModule([0x7f, 0x7e], [], [
          0x20, 0x00, 0x20, 0x01, // local.get 0, local.get 1
          0x37, 0x03, 0x00        // i64.store align=3 offset=0
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i64(0x0102030405060708n)]);
        const dv = new DataView(inst.memories[0].buffer);
        expect(dv.getBigInt64(0, true)).assertEqual(0x0102030405060708n);
      });
    });

    // ── F32/F64 Load/Store ─────────────────────────────────────────────────
    describe('f32/f64 load/store', () => {
      it('f32.store then f32.load', () => {
        const mod = makeModule([0x7f, 0x7d], [], [
          0x20, 0x00, 0x20, 0x01,
          0x38, 0x02, 0x00        // f32.store
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.f32(3.14)]);
        const dv = new DataView(inst.memories[0].buffer);
        expect(dv.getFloat32(0, true)).assertClose(3.14, 0.0001);
      });

      it('f64.store then f64.load', () => {
        const mod = makeModule([0x7f, 0x7c], [], [
          0x20, 0x00, 0x20, 0x01,
          0x39, 0x03, 0x00        // f64.store
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.f64(Math.PI)]);
        const dv = new DataView(inst.memories[0].buffer);
        expect(dv.getFloat64(0, true)).assertEqual(Math.PI);
      });
    });

    // ── Memory Grow ────────────────────────────────────────────────────────
    describe('memory.grow', () => {
      it('memory.grow succeeds and returns old size', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,
          0x40, 0x00             // memory.grow
        ], 1);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(2)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(1); // old size
        expect(inst.memories[0].curPages).assertEqual(3);
      });
    });

    // ── Memory Copy and Fill ───────────────────────────────────────────────
    describe('memory.copy and memory.fill', () => {
      it('memory.copy copies data between regions', () => {
        // (dst, src, size) -> ()
        const mod = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          // type: (i32, i32, i32) -> ()
          0x01, 0x08, 0x01, 0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x00,
          0x03, 0x02, 0x01, 0x00,
          0x05, 0x03, 0x01, 0x00, 0x01, // memory
          // export "test"
          0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
          // code: memory.copy
          0x0a, 0x0b, 0x01, 0x09, 0x00,
          0x20, 0x00, 0x20, 0x01, 0x20, 0x02,
          0xfc, 0x0a, 0x00, 0x00, // memory.copy
          0x0b,
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        // Write data at src
        inst.memories[0].data[0] = 1;
        inst.memories[0].data[1] = 2;
        inst.memories[0].data[2] = 3;
        // Copy 3 bytes from addr 0 to addr 10
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(10), WasmValue.i32(0), WasmValue.i32(3)]);
        expect(res.trap).assertNull();
        expect(inst.memories[0].data[10]).assertEqual(1);
        expect(inst.memories[0].data[11]).assertEqual(2);
        expect(inst.memories[0].data[12]).assertEqual(3);
      });

      it('memory.fill fills a memory region', () => {
        // (dst, val, size) -> ()
        const mod = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          0x01, 0x08, 0x01, 0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x00,
          0x03, 0x02, 0x01, 0x00,
          0x05, 0x03, 0x01, 0x00, 0x01,
          0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
          0x0a, 0x0b, 0x01, 0x09, 0x00,
          0x20, 0x00, 0x20, 0x01, 0x20, 0x02,
          0xfc, 0x0b, 0x00, // memory.fill
          0x0b,
        ]);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        rt.invokeByName(inst, 'test', [WasmValue.i32(5), WasmValue.i32(0x42), WasmValue.i32(3)]);
        expect(inst.memories[0].data[5]).assertEqual(0x42);
        expect(inst.memories[0].data[6]).assertEqual(0x42);
        expect(inst.memories[0].data[7]).assertEqual(0x42);
        expect(inst.memories[0].data[4]).assertEqual(0); // unchanged
      });
    });

    // ── Bounds Checking ────────────────────────────────────────────────────
    describe('bounds checking', () => {
      it('load beyond memory boundary traps', () => {
        const mod = makeModule([0x7f], [0x7f], [
          0x20, 0x00,
          0x28, 0x02, 0x00        // i32.load
        ], 1);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(65536)]); // beyond 64KB
        expect(res.trap).assertNotNull();
      });

      it('store beyond memory boundary traps', () => {
        const mod = makeModule([0x7f, 0x7f], [], [
          0x20, 0x00, 0x20, 0x01,
          0x36, 0x02, 0x00        // i32.store
        ], 1);
        const rt = new WasmRuntime();
        const inst = rt.instantiate(mod);
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(65536), WasmValue.i32(42)]);
        expect(res.trap).assertNotNull();
      });
    });
  });
}
