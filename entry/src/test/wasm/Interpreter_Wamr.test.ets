/**
 * Interpreter_Wamr.test.ets — Tests using real WAMR test wasm modules.
 * Verifies that ArkWASM produces results matching WAMR's interpreter.
 */
import { describe, it, expect } from '@ohos/hypium/index';
import { WasmRuntime } from '../ets/wasm/WasmRuntime';
import { WasmValue } from '../ets/wasm/WasmTypes';
import {
  WAMR_APP3,
  WAMR_APP4_M1,
  WAMR_APP4_M2,
} from './fixtures/WamrFixtures';

export default function testSuite() {
  describe('WAMR Test Modules', () => {

    // ── app4/m1.wasm: Provider module ──────────────────────────────────────
    describe('app4/m1: Provider Module', () => {
      it('exports function f1: returns i32 1', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP4_M1);
        const res = rt.invokeByName(inst, 'f1', []);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(1);
      });

      it('exports memory m1: 1 page, 2 max', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP4_M1);
        expect(inst.memories.length).assertEqual(1);
        expect(inst.memories[0].curPages).assertEqual(1);
        expect(inst.memories[0].maxPages).assertEqual(2);
      });

      it('exports table t1: funcref, size 0', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP4_M1);
        expect(inst.tables.length).assertEqual(1);
        expect(inst.tables[0].curSize).assertEqual(0);
      });

      it('exports global g1: i32 = 1', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP4_M1);
        expect(inst.globalData.length).assertEqual(1);
        expect(inst.globalData[0].getAsI32()).assertEqual(1);
      });
    });

    // ── app4/m2.wasm: Consumer module with imports ─────────────────────────
    describe('app4/m2: Consumer Module', () => {
      it('loads module with imports (placeholders ok)', () => {
        // m2 imports from m1 — placeholders are created for missing imports
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP4_M2);
        expect(inst.funcInstances.length).assertEqual(3); // 0-2 (import f1, table 0 function, f2, f3)
      });
    });

    // ── app3: Minimal module — null_pointer and my_sqrt ────────────────────
    describe('app3: Minimal Module', () => {
      it('null_pointer returns 0', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP3);
        // null_pointer is export index 2, type () -> i32
        const res = rt.invokeByName(inst, 'null_pointer', []);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(0);
      });

      it('my_sqrt(3, 4) = 25 (x*x + y*y)', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP3);
        // my_sqrt(3, 4) = 3*3 + 4*4 = 25
        const res = rt.invokeByName(inst, 'my_sqrt', [WasmValue.i32(3), WasmValue.i32(4)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(25);
      });

      it('my_sqrt(0, 0) = 0', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP3);
        const res = rt.invokeByName(inst, 'my_sqrt', [WasmValue.i32(0), WasmValue.i32(0)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(0);
      });

      it('my_sqrt(5, 12) = 169', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP3);
        const res = rt.invokeByName(inst, 'my_sqrt', [WasmValue.i32(5), WasmValue.i32(12)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(169);
      });

      it('on_init is a nop (empty function)', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(WAMR_APP3);
        const res = rt.invokeByName(inst, 'on_init', []);
        expect(res.trap).assertNull();
        expect(res.values.length).assertEqual(0);
      });
    });
  });
}
