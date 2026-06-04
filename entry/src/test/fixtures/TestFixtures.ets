/**
 * test fixtures — hand-crafted minimal .wasm byte arrays for testing.
 * Each fixture is a complete, valid .wasm module that exports a "test" function.
 */

// ============================================================================
// Helper to build a minimal Wasm module with a function that returns an i32
// ============================================================================

function buildModule(body: number[]): Uint8Array {
  const bytes: number[] = [];

  // Magic number
  bytes.push(0x00, 0x61, 0x73, 0x6d);
  // Version
  bytes.push(0x01, 0x00, 0x00, 0x00);

  // ── Type section: single type (func: () -> i32) ──────────────────────────
  const typeBytes = [0x01, 0x60, 0x00, 0x01, 0x7f]; // 1 type: () -> i32
  // Section wrapper
  bytes.push(0x01); // section id
  pushLebU32(bytes, typeBytes.length);
  bytes.push(...typeBytes);

  // ── Function section: 1 function using type 0 ────────────────────────────
  const funcBytes = [0x01, 0x00]; // 1 func, type index 0
  bytes.push(0x03); // section id
  pushLebU32(bytes, funcBytes.length);
  bytes.push(...funcBytes);

  // ── Export section: export "test" (func 0) ───────────────────────────────
  const name = [0x04, 0x74, 0x65, 0x73, 0x74]; // "test"
  const exportBytes = [0x01, ...name, 0x00, 0x00]; // 1 export, name, kind=func, idx=0
  bytes.push(0x07); // section id
  pushLebU32(bytes, exportBytes.length);
  bytes.push(...exportBytes);

  // ── Code section: 1 function body ────────────────────────────────────────
  // body: 0 locals, <instructions>, 0x0B (end)
  const codeBody = [0x00, ...body, 0x0B]; // 0 local decls, bytecode, END
  const codeBytes = [0x01]; // 1 function
  pushLebU32(codeBytes, codeBody.length);
  codeBytes.push(...codeBody);

  bytes.push(0x0a); // section id
  pushLebU32(bytes, codeBytes.length);
  bytes.push(...codeBytes);

  return new Uint8Array(bytes);
}

/**
 * Build a module with params and results.
 */
function buildModuleWithParams(params: number[], results: number[], body: number[]): Uint8Array {
  const bytes: number[] = [];

  bytes.push(0x00, 0x61, 0x73, 0x6d);
  bytes.push(0x01, 0x00, 0x00, 0x00);

  // Type section: func(params...) -> results...
  const typeBytes: number[] = [0x01, 0x60];
  pushLebU32(typeBytes, params.length);
  typeBytes.push(...params);
  pushLebU32(typeBytes, results.length);
  typeBytes.push(...results);

  bytes.push(0x01);
  pushLebU32(bytes, typeBytes.length);
  bytes.push(...typeBytes);

  // Function section
  bytes.push(0x03);
  bytes.push(0x02, 0x01, 0x00); // 1 func, type 0

  // Export section
  const name = [0x04, 0x74, 0x65, 0x73, 0x74];
  const expSec = [0x01, ...name, 0x00, 0x00];
  bytes.push(0x07);
  pushLebU32(bytes, expSec.length);
  bytes.push(...expSec);

  // Code section
  const codeBody = [0x00, ...body, 0x0B];
  const codeSec = [0x01];
  pushLebU32(codeSec, codeBody.length);
  codeSec.push(...codeBody);

  bytes.push(0x0a);
  pushLebU32(bytes, codeSec.length);
  bytes.push(...codeSec);

  return new Uint8Array(bytes);
}

function pushLebU32(buf: number[], v: number): void {
  while (v >= 0x80) {
    buf.push((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  buf.push(v & 0x7f);
}

// ============================================================================
// Fixtures
// ============================================================================

/** i32.const 42 */
export const I32_CONST = buildModule([0x41, 0x2a]); // i32.const 42

/** i32.add */
export const I32_ADD = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x6a] // local.get 0, local.get 1, i32.add
);

/** i32.sub */
export const I32_SUB = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x6b] // local.get 0, local.get 1, i32.sub
);

/** i32.mul */
export const I32_MUL = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x6c]
);

/** i32.div_s */
export const I32_DIV_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x6d]
);

/** i32.div_u */
export const I32_DIV_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x6e]
);

/** i32.rem_s */
export const I32_REM_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x6f]
);

/** i32.rem_u */
export const I32_REM_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x70]
);

/** i32.and */
export const I32_AND = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x71]
);

/** i32.or */
export const I32_OR = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x72]
);

/** i32.xor */
export const I32_XOR = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x73]
);

/** i32.shl */
export const I32_SHL = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x74]
);

/** i32.shr_s */
export const I32_SHR_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x75]
);

/** i32.shr_u */
export const I32_SHR_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x76]
);

/** i32.rotl */
export const I32_ROTL = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x77]
);

/** i32.rotr */
export const I32_ROTR = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x78]
);

/** i32.clz */
export const I32_CLZ = buildModuleWithParams(
  [0x7f], [0x7f],
  [0x20, 0x00, 0x67]
);

/** i32.ctz */
export const I32_CTZ = buildModuleWithParams(
  [0x7f], [0x7f],
  [0x20, 0x00, 0x68]
);

/** i32.popcnt */
export const I32_POPCNT = buildModuleWithParams(
  [0x7f], [0x7f],
  [0x20, 0x00, 0x69]
);

/** i32.eqz */
export const I32_EQZ = buildModuleWithParams(
  [0x7f], [0x7f],
  [0x20, 0x00, 0x45]
);

/** i32.eq */
export const I32_EQ = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x46]
);

/** i32.ne */
export const I32_NE = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x47]
);

/** i32.lt_s */
export const I32_LT_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x48]
);

/** i32.lt_u */
export const I32_LT_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x49]
);

/** i32.gt_s */
export const I32_GT_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x4a]
);

/** i32.gt_u */
export const I32_GT_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x4b]
);

/** i32.le_s */
export const I32_LE_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x4c]
);

/** i32.le_u */
export const I32_LE_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x4d]
);

/** i32.ge_s */
export const I32_GE_S = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x4e]
);

/** i32.ge_u */
export const I32_GE_U = buildModuleWithParams(
  [0x7f, 0x7f], [0x7f],
  [0x20, 0x00, 0x20, 0x01, 0x4f]
);

/** f32.add */
export const F32_ADD = buildModuleWithParams(
  [0x7d, 0x7d], [0x7d],
  [0x20, 0x00, 0x20, 0x01, 0x92]
);

/** f64.add */
export const F64_ADD = buildModuleWithParams(
  [0x7c, 0x7c], [0x7c],
  [0x20, 0x00, 0x20, 0x01, 0xa0]
);

/** f32.const */
export const F32_CONST = buildModule(
  [0x43, 0x00, 0x00, 0x80, 0x3f] // f32.const 1.0 (little-endian IEEE 754)
);

/** f64.const */
export const F64_CONST = buildModule(
  [0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f] // f64.const 1.0
);

/** i64.const 42 */
export const I64_CONST = buildModuleWithParams(
  [], [0x7e],
  [0x42, 0x2a] // i64.const 42
);

/** i64.add */
export const I64_ADD = buildModuleWithParams(
  [0x7e, 0x7e], [0x7e],
  [0x20, 0x00, 0x20, 0x01, 0x7c] // local.get 0, local.get 1, i64.add
);

/** i64.sub */
export const I64_SUB = buildModuleWithParams(
  [0x7e, 0x7e], [0x7e],
  [0x20, 0x00, 0x20, 0x01, 0x7d]
);

/** i64.mul */
export const I64_MUL = buildModuleWithParams(
  [0x7e, 0x7e], [0x7e],
  [0x20, 0x00, 0x20, 0x01, 0x7e]
);

/** i32_extend8_s */
export const I32_EXTEND8_S = buildModuleWithParams(
  [0x7f], [0x7f],
  [0x20, 0x00, 0xc0]
);

/** i32_extend16_s */
export const I32_EXTEND16_S = buildModuleWithParams(
  [0x7f], [0x7f],
  [0x20, 0x00, 0xc1]
);

// ============================================================================
// Memory test fixtures — module with exported memory
// ============================================================================

/**
 * Module with memory export and a store function.
 * Memory: 1 page (64KB). Export "mem" (memory 0), "store" (func 0).
 */
export function buildMemoryModule(body: number[]): Uint8Array {
  const bytes: number[] = [];

  bytes.push(0x00, 0x61, 0x73, 0x6d);
  bytes.push(0x01, 0x00, 0x00, 0x00);

  // Type: (i32, i32) -> ()
  const typeBytes: number[] = [0x01, 0x60];
  pushLebU32(typeBytes, 2);
  typeBytes.push(0x7f, 0x7f); // i32, i32
  pushLebU32(typeBytes, 0);
  bytes.push(0x01);
  pushLebU32(bytes, typeBytes.length);
  bytes.push(...typeBytes);

  // Function section
  bytes.push(0x03, 0x02, 0x01, 0x00);

  // Memory section: 1 memory, 1 page initial
  bytes.push(0x05, 0x03, 0x01, 0x00, 0x01); // 1 mem, flags=0, init=1

  // Export section: export "test" (func 0), export "mem" (memory 0)
  const nameTest = [0x04, 0x74, 0x65, 0x73, 0x74]; // "test"
  const nameMem = [0x03, 0x6d, 0x65, 0x6d]; // "mem"
  const expSec = [
    0x02, // 2 exports
    ...nameTest, 0x00, 0x00, // func 0
    ...nameMem, 0x02, 0x00   // memory 0
  ];
  bytes.push(0x07);
  pushLebU32(bytes, expSec.length);
  bytes.push(...expSec);

  // Code section
  const codeBody = [0x00, ...body, 0x0B];
  const codeSec = [0x01];
  pushLebU32(codeSec, codeBody.length);
  codeSec.push(...codeBody);

  bytes.push(0x0a);
  pushLebU32(bytes, codeSec.length);
  bytes.push(...codeSec);

  return new Uint8Array(bytes);
}

// store(addr, value): i32.store
// local.get 0 (addr), local.get 1 (value), i32.store (align=2, offset=0)
export const MEM_I32_STORE = buildMemoryModule([
  0x20, 0x00, 0x20, 0x01,
  0x36, 0x02, 0x00 // i32.store align=2 offset=0
]);

// load(addr): i32 -> i32
// local.get 0, i32.load
const memLoadBytes: number[] = [0x01, 0x60];
pushLebU32(memLoadBytes, 1); memLoadBytes.push(0x7f);
pushLebU32(memLoadBytes, 1); memLoadBytes.push(0x7f);

function buildMemLoadModule(): Uint8Array {
  const bytes: number[] = [];
  bytes.push(0x00, 0x61, 0x73, 0x6d);
  bytes.push(0x01, 0x00, 0x00, 0x00);
  bytes.push(0x01);
  pushLebU32(bytes, memLoadBytes.length);
  bytes.push(...memLoadBytes);
  bytes.push(0x03, 0x02, 0x01, 0x00);
  bytes.push(0x05, 0x03, 0x01, 0x00, 0x01);
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  const es = [0x01, ...nm, 0x00, 0x00];
  bytes.push(0x07);
  pushLebU32(bytes, es.length);
  bytes.push(...es);
  const cb = [0x00, 0x20, 0x00, 0x28, 0x02, 0x00, 0x0B]; // local.get 0, i32.load, end
  const cs = [0x01];
  pushLebU32(cs, cb.length);
  cs.push(...cb);
  bytes.push(0x0a);
  pushLebU32(bytes, cs.length);
  bytes.push(...cs);
  return new Uint8Array(bytes);
}
export const MEM_I32_LOAD = buildMemLoadModule();

// ============================================================================
// Control flow fixtures
// ============================================================================

/** Block returning constant (block $l (result i32) (i32.const 1)) */
export const CTRL_BLOCK = buildModuleWithParams(
  [], [0x7f],
  [0x02, 0x40, 0x41, 0x01, 0x0B] // block (result i32) i32.const 1 end
);

/** Loop that sums to 10 */
export const CTRL_LOOP_SUM = buildModuleWithParams(
  [], [0x7f],
  [
    0x41, 0x00,       // i32.const 0  (accumulator)
    0x41, 0x00,       // i32.const 0  (counter)
    0x03, 0x40,       // loop (block)
    0x41, 0x0a,       //   i32.const 10
    0x21, 0x02,       //   local.set 2 (limit)
    0x20, 0x01,       //   local.get 1 (counter)
    0x41, 0x0a,       //   i32.const 10
    0x48,             //   i32.lt_s
    0x04, 0x40,       //   if
    0x20, 0x00,       //     local.get 0 (accum)
    0x20, 0x01,       //     local.get 1 (counter)
    0x6a,             //     i32.add
    0x21, 0x00,       //     local.set 0 (accum)
    0x20, 0x01,       //     local.get 1
    0x41, 0x01,       //     i32.const 1
    0x6a,             //     i32.add
    0x21, 0x01,       //     local.set 1 (counter)
    0x0c, 0x00,       //     br 0 (continue loop)
    0x0B,             //   end (if)
    0x0B,             // end (loop)
    0x41, 0x00,       // i32.const 0
    0x20, 0x01,       // local.get 1
    0x21, 0x01,       // local.set 1
    0x20, 0x00        // local.get 0 (result)
  ]
);

/** br 0 (shortest loop) */
export const CTRL_BR = buildModuleWithParams(
  [], [0x7f],
  [
    0x41, 0x01,       // i32.const 1
    0x02, 0x40,       // block
    0x0c, 0x00,       //   br 0
    0x0B,             // end
  ]
);

/** br_if (br if condition) */
export const CTRL_BR_IF = buildModuleWithParams(
  [0x7f], [0x7f],
  [
    0x20, 0x00,       // local.get 0 (flag)
    0x02, 0x40,       // block
    0x0d, 0x00,       //   br_if 0 (break if flag)
    0x41, 0x2a,       //   i32.const 42 (only if no break)
    0x0B,             // end
  ]
);

/** br_table switch */
export const CTRL_BR_TABLE = buildModuleWithParams(
  [0x7f], [0x7f],
  [
    0x20, 0x00,        // local.get 0 (selector)
    0x02, 0x40,        // block (label 0)
    0x02, 0x40,        //   block (label 1)
    0x02, 0x40,        //     block (label 2)
    0x20, 0x00,        //
    0x0e, 0x02,        //     br_table 2 (default)
    0x00, 0x01,        //       [0, 1]
    0x0B,              //     end (label 2)
    0x41, 0x03,        //     i32.const 3 (case 1)
    0x0C, 0x01,        //     br 1
    0x0B,              //   end (label 1)
    0x41, 0x02,        //   i32.const 2 (case 0)
    0x0C, 0x01,        //   br 1
    0x0B,              // end (label 0)
    0x41, 0x01,        // i32.const 1 (default case)
  ]
);

/** call another function */
export const CTRL_CALL = (() => {
  const bytes: number[] = [];
  bytes.push(0x00, 0x61, 0x73, 0x6d);
  bytes.push(0x01, 0x00, 0x00, 0x00);

  // Types: [0] () -> i32, [1] (i32, i32) -> i32
  const t0 = [0x60, 0x00, 0x01, 0x7f]; // () -> i32
  const t1 = [0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f]; // (i32,i32) -> i32
  const ts = [0x02, ...t0, ...t1];
  bytes.push(0x01);
  pushLebU32(bytes, ts.length);
  bytes.push(...ts);

  // Functions: func 0 = type 1 (add), func 1 = type 0 (caller)
  bytes.push(0x03, 0x03, 0x02, 0x01, 0x00);

  // Export: "test" = func 1 (caller)
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  bytes.push(0x07);
  pushLebU32(bytes, 2 + nm.length);
  bytes.push(0x01, ...nm, 0x00, 0x01); // 1 export, name, func, idx=1

  // Code: func 0 (add), func 1 (call)
  const f0 = [0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0B]; // local.get 0,1; i32.add; end
  const f1 = [0x00, 0x41, 0x03, 0x41, 0x04, 0x10, 0x00, 0x0B]; // i32.const 3,4; call 0; end
  const codeSec = [0x02];
  pushLebU32(codeSec, f0.length); codeSec.push(...f0);
  pushLebU32(codeSec, f1.length); codeSec.push(...f1);

  bytes.push(0x0a);
  pushLebU32(bytes, codeSec.length);
  bytes.push(...codeSec);

  return new Uint8Array(bytes);
})();

// ============================================================================
// Memory Size and Grow fixtures
// ============================================================================

/** memory.size — returns current memory size in pages */
export const MEM_SIZE = (() => {
  const bytes: number[] = [];
  bytes.push(0x00, 0x61, 0x73, 0x6d);
  bytes.push(0x01, 0x00, 0x00, 0x00);
  const ts = [0x01, 0x60, 0x00, 0x01, 0x7f];
  bytes.push(0x01); pushLebU32(bytes, ts.length); bytes.push(...ts);
  bytes.push(0x03, 0x02, 0x01, 0x00);
  bytes.push(0x05, 0x03, 0x01, 0x00, 0x01); // 1 page
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  bytes.push(0x07); pushLebU32(bytes, 2 + nm.length);
  bytes.push(0x01, ...nm, 0x00, 0x00);
  const cb = [0x00, 0x3f, 0x00, 0x0B]; // memory.size, end
  const cs = [0x01]; pushLebU32(cs, cb.length); cs.push(...cb);
  bytes.push(0x0a); pushLebU32(bytes, cs.length); bytes.push(...cs);
  return new Uint8Array(bytes);
})();
