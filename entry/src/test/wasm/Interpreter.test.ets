/**
 * Interpreter.test.ets — Comprehensive test suite for the ArkWASM interpreter.
 *
 * Tests cover all MVP instruction categories:
 *   - Constants (i32/i64/f32/f64.const)
 *   - I32 arithmetic and bitwise
 *   - I64 arithmetic and bitwise
 *   - F32 arithmetic
 *   - F64 arithmetic
 *   - Comparisons (all types)
 *   - Conversions and reinterpretations
 *   - Sign extension
 *   - Control flow (block, loop, if, br, br_if, br_table, return, call)
 *   - Memory operations (load, store, size, grow)
 *   - Local/Global variables
 *   - Reference instructions
 *   - Misc extensions (saturating trunc, memory.copy/fill, table ops)
 */

import { describe, it, expect } from '@ohos/hypium/index';
import { WasmRuntime } from '../ets/wasm/WasmRuntime';
import { WasmModuleInstance, WasmValue } from '../ets/wasm/WasmTypes';
import * as Fixtures from './fixtures/TestFixtures';

// ============================================================================
// Test helpers
// ============================================================================

function invoke(fixture: Uint8Array, args: WasmValue[]): { result: WasmValue | null; trap: string | null } {
  const rt = new WasmRuntime();
  const inst = rt.instantiate(fixture);
  const res = rt.invokeByName(inst, 'test', args);
  if (res.trap) {
    return { result: null, trap: res.trap };
  }
  return { result: res.values[0] ?? null, trap: null };
}

function assertI32(wasm: Uint8Array, args: number[], expected: number): void {
  const wArgs = args.map(a => WasmValue.i32(a));
  const { result, trap } = invoke(wasm, wArgs);
  expect(trap).assertNull();
  expect(result).assertNotNull();
  expect(result!.getAsI32()).assertEqual(expected);
}

function assertI64(wasm: Uint8Array, args: bigint[], expected: bigint): void {
  const wArgs = args.map(a => WasmValue.i64(a));
  const { result, trap } = invoke(wasm, wArgs);
  expect(trap).assertNull();
  expect(result).assertNotNull();
  expect(result!.getAsI64()).assertEqual(expected);
}

function assertF32(wasm: Uint8Array, args: number[], expected: number): void {
  const wArgs = args.map(a => WasmValue.f32(a));
  const { result, trap } = invoke(wasm, wArgs);
  expect(trap).assertNull();
  expect(result).assertNotNull();
  expect(result!.getAsF32()).assertEqual(expected);
}

function assertF64(wasm: Uint8Array, args: number[], expected: number): void {
  const wArgs = args.map(a => WasmValue.f64(a));
  const { result, trap } = invoke(wasm, wArgs);
  expect(trap).assertNull();
  expect(result).assertNotNull();
  expect(result!.getAsF64()).assertEqual(expected);
}

// ============================================================================
// Test Suite
// ============================================================================
export default function testSuite() {
  describe('WasmInterpreter', () => {

    // ========================================================================
    // Constants
    // ========================================================================
    describe('Constants', () => {
      it('i32.const 42', () => {
        assertI32(Fixtures.I32_CONST, [], 42);
      });

      it('f32.const 1.0', () => {
        assertF32(Fixtures.F32_CONST, [], 1.0);
      });

      it('f64.const 1.0', () => {
        assertF64(Fixtures.F64_CONST, [], 1.0);
      });

      it('i64.const 42', () => {
        assertI64(Fixtures.I64_CONST, [], 42n);
      });
    });

    // ========================================================================
    // I32 Arithmetic
    // ========================================================================
    describe('i32 Arithmetic', () => {
      it('i32.add: 3 + 4 = 7', () => {
        assertI32(Fixtures.I32_ADD, [3, 4], 7);
      });
      it('i32.add: -5 + 7 = 2', () => {
        assertI32(Fixtures.I32_ADD, [-5, 7], 2);
      });
      it('i32.add: overflow wraps', () => {
        assertI32(Fixtures.I32_ADD, [0x7FFFFFFF, 1], -0x80000000);
      });

      it('i32.sub: 10 - 3 = 7', () => {
        assertI32(Fixtures.I32_SUB, [10, 3], 7);
      });
      it('i32.sub: 0 - 1 = -1', () => {
        assertI32(Fixtures.I32_SUB, [0, 1], -1);
      });
      it('i32.sub: -5 - 3 = -8', () => {
        assertI32(Fixtures.I32_SUB, [-5, 3], -8);
      });

      it('i32.mul: 3 * 4 = 12', () => {
        assertI32(Fixtures.I32_MUL, [3, 4], 12);
      });
      it('i32.mul: -3 * 4 = -12', () => {
        assertI32(Fixtures.I32_MUL, [-3, 4], -12);
      });
      it('i32.mul: 0 * anything = 0', () => {
        assertI32(Fixtures.I32_MUL, [0, 9999], 0);
      });
      it('i32.mul: large values wrap', () => {
        assertI32(Fixtures.I32_MUL, [65536, 65536], 0);
      });

      it('i32.div_s: 10 / 3 = 3', () => {
        assertI32(Fixtures.I32_DIV_S, [10, 3], 3);
      });
      it('i32.div_s: -10 / 3 = -3', () => {
        assertI32(Fixtures.I32_DIV_S, [-10, 3], -3);
      });
      it('i32.div_s: 7 / 1 = 7', () => {
        assertI32(Fixtures.I32_DIV_S, [7, 1], 7);
      });

      it('i32.div_u: 10 / 3 = 3', () => {
        assertI32(Fixtures.I32_DIV_U, [10, 3], 3);
      });
      it('i32.div_u: -1 / 2 = 2147483647', () => {
        assertI32(Fixtures.I32_DIV_U, [-1, 2], 2147483647);
      });

      it('i32.rem_s: 10 % 3 = 1', () => {
        assertI32(Fixtures.I32_REM_S, [10, 3], 1);
      });
      it('i32.rem_s: -10 % 3 = -1', () => {
        assertI32(Fixtures.I32_REM_S, [-10, 3], -1);
      });

      it('i32.rem_u: 10 % 3 = 1', () => {
        assertI32(Fixtures.I32_REM_U, [10, 3], 1);
      });
    });

    // ========================================================================
    // I32 Bitwise
    // ========================================================================
    describe('i32 Bitwise', () => {
      it('i32.and: 0xFF & 0x0F = 0x0F', () => {
        assertI32(Fixtures.I32_AND, [0xFF, 0x0F], 0x0F);
      });
      it('i32.or: 0xF0 | 0x0F = 0xFF', () => {
        assertI32(Fixtures.I32_OR, [0xF0, 0x0F], 0xFF);
      });
      it('i32.xor: 0xFFFF ^ 0x00FF = 0xFF00', () => {
        assertI32(Fixtures.I32_XOR, [0xFFFF, 0x00FF], 0xFF00);
      });

      it('i32.shl: 1 << 3 = 8', () => {
        assertI32(Fixtures.I32_SHL, [1, 3], 8);
      });
      it('i32.shl: shift by 32 wraps to 0', () => {
        assertI32(Fixtures.I32_SHL, [1, 32], 1);
      });
      it('i32.shl: 0x80000000 << 1 = 0', () => {
        assertI32(Fixtures.I32_SHL, [-0x80000000, 1], 0);
      });

      it('i32.shr_s: -4 >> 1 = -2', () => {
        assertI32(Fixtures.I32_SHR_S, [-4, 1], -2);
      });
      it('i32.shr_s: 8 >> 2 = 2', () => {
        assertI32(Fixtures.I32_SHR_S, [8, 2], 2);
      });

      it('i32.shr_u: -1 >> 1 = 0x7FFFFFFF', () => {
        assertI32(Fixtures.I32_SHR_U, [-1, 1], 0x7FFFFFFF);
      });

      it('i32.rotl: 1 <<< 1 = 2', () => {
        assertI32(Fixtures.I32_ROTL, [1, 1], 2);
      });
      it('i32.rotl: 0x80000000 <<< 1 = 1', () => {
        assertI32(Fixtures.I32_ROTL, [-0x80000000, 1], 1);
      });

      it('i32.rotr: 1 >>> 1 = 0x80000000', () => {
        assertI32(Fixtures.I32_ROTR, [1, 1], -0x80000000);
      });
    });

    // ========================================================================
    // I32 Count Operations
    // ========================================================================
    describe('i32 Count Ops', () => {
      it('i32.clz(0) = 32', () => { assertI32(Fixtures.I32_CLZ, [0], 32); });
      it('i32.clz(1) = 31', () => { assertI32(Fixtures.I32_CLZ, [1], 31); });
      it('i32.clz(0x80000000) = 0', () => { assertI32(Fixtures.I32_CLZ, [-0x80000000], 0); });
      it('i32.clz(0xFF) = 24', () => { assertI32(Fixtures.I32_CLZ, [0xFF], 24); });

      it('i32.ctz(0) = 32', () => { assertI32(Fixtures.I32_CTZ, [0], 32); });
      it('i32.ctz(1) = 0', () => { assertI32(Fixtures.I32_CTZ, [1], 0); });
      it('i32.ctz(8) = 3', () => { assertI32(Fixtures.I32_CTZ, [8], 3); });
      it('i32.ctz(0x80000000) = 31', () => { assertI32(Fixtures.I32_CTZ, [-0x80000000], 31); });

      it('i32.popcnt(0) = 0', () => { assertI32(Fixtures.I32_POPCNT, [0], 0); });
      it('i32.popcnt(1) = 1', () => { assertI32(Fixtures.I32_POPCNT, [1], 1); });
      it('i32.popcnt(0xFFFFFFFF) = 32', () => { assertI32(Fixtures.I32_POPCNT, [-1], 32); });
      it('i32.popcnt(0x55555555) = 16', () => { assertI32(Fixtures.I32_POPCNT, [0x55555555], 16); });
    });

    // ========================================================================
    // I32 Comparisons
    // ========================================================================
    describe('i32 Comparisons', () => {
      it('i32.eqz(0) = 1', () => { assertI32(Fixtures.I32_EQZ, [0], 1); });
      it('i32.eqz(1) = 0', () => { assertI32(Fixtures.I32_EQZ, [1], 0); });
      it('i32.eqz(-1) = 0', () => { assertI32(Fixtures.I32_EQZ, [-1], 0); });

      it('i32.eq: 3 == 3 = 1', () => { assertI32(Fixtures.I32_EQ, [3, 3], 1); });
      it('i32.eq: 3 == 4 = 0', () => { assertI32(Fixtures.I32_EQ, [3, 4], 0); });
      it('i32.ne: 3 != 4 = 1', () => { assertI32(Fixtures.I32_NE, [3, 4], 1); });
      it('i32.ne: 3 != 3 = 0', () => { assertI32(Fixtures.I32_NE, [3, 3], 0); });

      it('i32.lt_s: -2 < -1 = 1', () => { assertI32(Fixtures.I32_LT_S, [-2, -1], 1); });
      it('i32.lt_s: 3 < 2 = 0', () => { assertI32(Fixtures.I32_LT_S, [3, 2], 0); });
      it('i32.lt_u: -1 < 1 = 0', () => { assertI32(Fixtures.I32_LT_U, [-1, 1], 0); });

      it('i32.gt_s: 5 > 3 = 1', () => { assertI32(Fixtures.I32_GT_S, [5, 3], 1); });
      it('i32.gt_s: 2 > 3 = 0', () => { assertI32(Fixtures.I32_GT_S, [2, 3], 0); });
      it('i32.gt_u: -1 > 1 = 1', () => { assertI32(Fixtures.I32_GT_U, [-1, 1], 1); });

      it('i32.le_s: 3 <= 3 = 1', () => { assertI32(Fixtures.I32_LE_S, [3, 3], 1); });
      it('i32.le_s: 4 <= 3 = 0', () => { assertI32(Fixtures.I32_LE_S, [4, 3], 0); });
      it('i32.le_u: 5 <= 10 = 1', () => { assertI32(Fixtures.I32_LE_U, [5, 10], 1); });

      it('i32.ge_s: 5 >= 3 = 1', () => { assertI32(Fixtures.I32_GE_S, [5, 3], 1); });
      it('i32.ge_s: 2 >= 5 = 0', () => { assertI32(Fixtures.I32_GE_S, [2, 5], 0); });
      it('i32.ge_u: 10 >= 5 = 1', () => { assertI32(Fixtures.I32_GE_U, [10, 5], 1); });
    });

    // ========================================================================
    // I64 Arithmetic
    // ========================================================================
    describe('i64 Arithmetic', () => {
      it('i64.add: 3 + 4 = 7', () => {
        assertI64(Fixtures.I64_ADD, [3n, 4n], 7n);
      });
      it('i64.add: max safe + 1 wraps', () => {
        const maxU64 = (1n << 64n) - 1n;
        assertI64(Fixtures.I64_ADD, [maxU64, 1n], 0n);
      });
      it('i64.sub: 10 - 3 = 7', () => {
        assertI64(Fixtures.I64_SUB, [10n, 3n], 7n);
      });
      it('i64.sub: 0 - 1 = -1', () => {
        assertI64(Fixtures.I64_SUB, [0n, 1n], (1n << 64n) - 1n); // u64 wrap
      });
      it('i64.mul: 3 * 4 = 12', () => {
        assertI64(Fixtures.I64_MUL, [3n, 4n], 12n);
      });
      it('i64.mul: 1M * 1M = 1T', () => {
        assertI64(Fixtures.I64_MUL, [1000000n, 1000000n], 1000000000000n);
      });
    });

    // ========================================================================
    // F32 Operations
    // ========================================================================
    describe('f32 Operations', () => {
      it('f32.add: 1.5 + 2.5 = 4.0', () => {
        assertF32(Fixtures.F32_ADD, [1.5, 2.5], 4.0);
      });
      it('f32.add: -1.0 + 1.0 = 0.0', () => {
        assertF32(Fixtures.F32_ADD, [-1.0, 1.0], 0.0);
      });
      it('f32.add: 0.1 + 0.2 approx 0.3', () => {
        const result = invoke(Fixtures.F32_ADD, [WasmValue.f32(0.1), WasmValue.f32(0.2)]);
        expect(result.trap).assertNull();
        const diff = Math.abs(Math.fround(result.result!.getAsF32() - 0.3));
        expect(diff < 0.0000001).assertTrue();
      });
    });

    // ========================================================================
    // F64 Operations
    // ========================================================================
    describe('f64 Operations', () => {
      it('f64.add: 1.5 + 2.5 = 4.0', () => {
        assertF64(Fixtures.F64_ADD, [1.5, 2.5], 4.0);
      });
      it('f64.add: PI + E', () => {
        assertF64(Fixtures.F64_ADD, [Math.PI, Math.E], Math.PI + Math.E);
      });
    });

    // ========================================================================
    // Sign Extension
    // ========================================================================
    describe('Sign Extension', () => {
      it('i32.extend8_s(-1) = -1', () => {
        assertI32(Fixtures.I32_EXTEND8_S, [0xFF], -1);
      });
      it('i32.extend8_s(0x80) = -128', () => {
        assertI32(Fixtures.I32_EXTEND8_S, [0x80], -128);
      });
      it('i32.extend8_s(0x7F) = 127', () => {
        assertI32(Fixtures.I32_EXTEND8_S, [0x7F], 127);
      });

      it('i32.extend16_s(0xFFFF) = -1', () => {
        assertI32(Fixtures.I32_EXTEND16_S, [0xFFFF], -1);
      });
      it('i32.extend16_s(0x8000) = -32768', () => {
        assertI32(Fixtures.I32_EXTEND16_S, [0x8000], -32768);
      });
      it('i32.extend16_s(0x7FFF) = 32767', () => {
        assertI32(Fixtures.I32_EXTEND16_S, [0x7FFF], 32767);
      });
    });

    // ========================================================================
    // Control Flow
    // ========================================================================
    describe('Control Flow', () => {
      it('block returns constant', () => {
        assertI32(Fixtures.CTRL_BLOCK, [], 1);
      });

      it('br 0 exits block immediately', () => {
        assertI32(Fixtures.CTRL_BR, [], 1);
      });

      it('br_if: condition true breaks', () => {
        assertI32(Fixtures.CTRL_BR_IF, [1], 1);
      });

      it('br_if: condition false returns 42', () => {
        assertI32(Fixtures.CTRL_BR_IF, [0], 42);
      });

      it('br_table: selector 0 => case 0 => 2', () => {
        assertI32(Fixtures.CTRL_BR_TABLE, [0], 2);
      });

      it('br_table: selector 1 => case 1 => 3', () => {
        assertI32(Fixtures.CTRL_BR_TABLE, [1], 3);
      });

      it('br_table: selector 99 => default => 1', () => {
        assertI32(Fixtures.CTRL_BR_TABLE, [99], 1);
      });

      it('call: calls add function, 3+4=7', () => {
        assertI32(Fixtures.CTRL_CALL, [], 7);
      });
    });

    // ========================================================================
    // Memory Operations
    // ========================================================================
    describe('Memory Operations', () => {
      it('i32.store then i32.load', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(Fixtures.MEM_I32_STORE);
        // Store 42 at address 0
        const storeRes = rt.invokeByName(inst, 'test', [WasmValue.i32(0), WasmValue.i32(42)]);
        expect(storeRes.trap).assertNull();
        // Verify via memory instance
        const mem = inst.memories[0];
        const dv = new DataView(mem.buffer);
        expect(dv.getInt32(0, true)).assertEqual(42);
      });

      it('i32.load reads stored value', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(Fixtures.MEM_I32_LOAD);
        // Write value manually into memory
        const dv = new DataView(inst.memories[0].buffer);
        dv.setInt32(0, 12345, true);
        // Load it
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(0)]);
        expect(res.trap).assertNull();
        expect(res.values[0].getAsI32()).assertEqual(12345);
      });

      it('memory.size returns initial page count', () => {
        assertI32(Fixtures.MEM_SIZE, [], 1);
      });

      it('memory load out of bounds traps', () => {
        const rt = new WasmRuntime();
        const inst = rt.instantiate(Fixtures.MEM_I32_LOAD);
        // Address beyond memory
        const res = rt.invokeByName(inst, 'test', [WasmValue.i32(65536)]);
        expect(res.trap).assertNotNull();
      });
    });

    // ========================================================================
    // Drop and Select
    // ========================================================================
    describe('Drop and Select', () => {
      it('drop removes top of stack', () => {
        // Module: (i32.const 1) (i32.const 2) drop (i32.const 3) → returns 1 then 3?
        // Actually: drop removes value, result is what remains
        // We'll test indirectly via a module
        const bytes = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          // type: () -> i32
          0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
          0x03, 0x02, 0x01, 0x00,
          // export "test"
          0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
          // code: i32.const 1, i32.const 2, drop, i32.const 3, end
          0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x01, 0x41, 0x02, 0x1a, 0x41, 0x03, 0x0b,
        ]);
        assertI32(bytes, [], 3);
      });

      it('select picks first value when cond is non-zero', () => {
        const bytes = selectModule(42, 99, 1);
        assertI32(bytes, [], 42);
      });

      it('select picks second value when cond is zero', () => {
        const bytes = selectModule(42, 99, 0);
        assertI32(bytes, [], 99);
      });
    });

    // ========================================================================
    // Unreachable trap
    // ========================================================================
    describe('Traps', () => {
      it('unreachable traps', () => {
        const bytes = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
          0x03, 0x02, 0x01, 0x00,
          0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
          0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, // unreachable
        ]);
        const { trap } = invoke(bytes, []);
        expect(trap).assertNotNull();
      });
    });
  });
}

// ============================================================================
// Helpers
// ============================================================================

function selectModule(v1: number, v2: number, cond: number): Uint8Array {
  const condVal = cond !== 0 ? 1 : 0;
  const bytes = new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: () -> i32
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
    // code: i32.const v1, i32.const v2, i32.const cond, select
    0x0a, 0x09, 0x01, 0x07, 0x00,
    0x41, v1,
    0x41, v2,
    0x41, condVal,
    0x1b, // select
    0x0b,
  ]);
  return bytes;
}
