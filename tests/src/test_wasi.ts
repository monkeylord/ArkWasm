/**
 * test_wasi.ts — WASI Preview 1 integration tests
 *
 * Tests the WasiProvider using DefaultWasiEnv (no platform dependencies).
 * Each test builds a minimal .wasm module that imports from
 * `wasi_snapshot_preview1` and exercises one or more WASI functions.
 */

import { WasmRuntime, WasmValue, HostTrap } from '../../build/WasmRuntime';
import { WasiProvider, WasiEnv, createDefaultWasiEnv } from '../../build/wasi/WasiProvider';

let pass = 0;
let fail = 0;

function assertEq(actual: number, expected: number, msg?: string): void {
  if (actual !== expected) {
    fail++;
    console.log(`  \x1b[31mFAIL\x1b[0m: ${msg} — expected ${expected} but got ${actual}`);
    return;
  }
  pass++;
}

function assertTrue(cond: boolean, msg?: string): void {
  if (!cond) { fail++; console.log(`  \x1b[31mFAIL\x1b[0m: ${msg}`); }
  else { pass++; }
}

function pushLeb(arr: number[], v: number): void {
  do { arr.push((v & 0x7F) | (v >= 128 ? 0x80 : 0)); v >>>= 7; } while (v > 0);
}

const MOD_WASI = 'wasi_snapshot_preview1';

function pushLeb64(arr: number[], v: bigint): void {
  let n = v;
  do {
    arr.push(Number((n & 0x7Fn) | (n >= 128n ? 0x80n : 0n)));
    n >>= 7n;
  } while (n > 0n);
}

// ── Module builders ─────────────────────────────────────────────────────

/** Build a WASM module with an import section and one function body. */
function makeImportModule(
  imports: Array<{ mod: string; name: string; params: number[]; results: number[] }>,
  body: number[], resultTypes: number[] = [0x7f],
): Uint8Array {
  const b: number[] = [];
  b.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

  // Type section: collect unique signatures
  function makeSig(params: number[], results: number[]): number[] {
    const s: number[] = [0x60];
    pushLeb(s, params.length); for (const p of params) s.push(p);
    pushLeb(s, results.length); for (const r of results) s.push(r);
    return s;
  }
  const typeSigs: number[][] = [];
  const impTypeIdx: number[] = [];
  for (const imp of imports) {
    const sig = makeSig(imp.params, imp.results);
    let found = -1;
    for (let i = 0; i < typeSigs.length; i++) {
      if (JSON.stringify(typeSigs[i]) === JSON.stringify(sig)) { found = i; break; }
    }
    if (found < 0) { typeSigs.push(sig); impTypeIdx.push(typeSigs.length - 1); }
    else { impTypeIdx.push(found); }
  }
  const localSig = makeSig([], resultTypes);
  typeSigs.push(localSig);
  const localTypeIdx = typeSigs.length - 1;

  // Write type section
  const tb: number[] = [];
  pushLeb(tb, typeSigs.length);
  for (const s of typeSigs) tb.push(...s);
  b.push(0x01); pushLeb(b, tb.length); b.push(...tb);

  // Import section
  if (imports.length > 0) {
    const impData: number[] = [];
    pushLeb(impData, imports.length);
    for (let i = 0; i < imports.length; i++) {
      const imp = imports[i];
      pushLeb(impData, imp.mod.length);
      for (const c of imp.mod) impData.push(c.charCodeAt(0));
      pushLeb(impData, imp.name.length);
      for (const c of imp.name) impData.push(c.charCodeAt(0));
      impData.push(0x00); // kind = function
      pushLeb(impData, impTypeIdx[i]); // type index
    }
    b.push(0x02); pushLeb(b, impData.length); b.push(...impData);
  }

  // Function section
  b.push(0x03, 0x02, 0x01); pushLeb(b, localTypeIdx);

  // Memory section
  b.push(0x05, 0x03, 0x01, 0x00, 0x01);

  // Export section — export local function (index = imports.length)
  const nm = [0x04, 0x74, 0x65, 0x73, 0x74];
  b.push(0x07); pushLeb(b, 3 + nm.length); b.push(0x01, ...nm, 0x00); pushLeb(b, imports.length);

  // Code section
  const cb = [0x00, ...body, 0x0b];
  const cs = [0x01]; pushLeb(cs, cb.length); cs.push(...cb);
  b.push(0x0a); pushLeb(b, cs.length); b.push(...cs);

  return new Uint8Array(b);
}



console.log('\x1b[36mWASI — args / environ\x1b[0m');

// ── args_sizes_get ──────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider(undefined, ['hello', 'world']));
  // Build module: call args_sizes_get, read from buffers
  // params=(), results=i32
  const imports = [
    { mod: MOD_WASI, name: 'args_sizes_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x10, 0x10,0x00,  // i32.const 0, i32.const 16, call 0
    0x1a,                              // drop errno
    0x41,0x00, 0x28,0x02,0x00,        // i32.load (argc)
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: args_sizes_get — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 2, 'args_sizes_get: argc=2');
})();

// ── args_get ────────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider(undefined, ['abc']));
  const imports = [
    { mod: MOD_WASI, name: 'args_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  // Write the first argv offset pointer to memory at 0, then read the string
  const body = [
    0x41,0x10, 0x41,0x20, 0x10,0x00,  // i32.const 16, i32.const 32, call 0 (args_get)
    0x1a,                              // drop errno
    0x41,0x10, 0x28,0x02,0x00,        // i32.load 16 (argv[0] = offset)
    0x28,0x02,0x00,                    // i32.load from that offset → first 4 bytes of "abc"
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: args_get — trap: ' + r.trap); return; }
  // First 4 bytes of "abc" + null → 0x00636261 = 6513249 (LE: 'a','b','c',0)
  assertEq(r.values[0].getAsI32(), 0x00636261, 'args_get: first 4 bytes');
})();

// ── environ_sizes_get ──────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider(undefined, [], { HOME: '/data' }));
  const imports = [
    { mod: MOD_WASI, name: 'environ_sizes_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x10, 0x10,0x00, 0x1a,
    0x41,0x00, 0x28,0x02,0x00,  // i32.load — count
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: environ_sizes_get — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 1, 'environ_sizes_get: count=1');
})();

// ── environ_get ────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider(undefined, [], { KEY: 'value' }));
  const imports = [
    { mod: MOD_WASI, name: 'environ_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x10, 0x41,0x30, 0x10,0x00, 0x1a,
    0x41,0x10, 0x28,0x02,0x00,  // i32.load (env[0] offset)
    0x28,0x02,0x00,              // "KEY="
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: environ_get — trap: ' + r.trap); return; }
  // "KEY=" = 0x3D59454B
  assertEq(r.values[0].getAsI32(), 0x3D59454B, 'environ_get: KEY= prefix');
})();

// ═══════════════════════════════════════════════════════════════════════════

console.log('\x1b[36mWASI — clock / random\x1b[0m');

// ── clock_time_get ─────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'clock_time_get', params: [0x7f,0x7c,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x42,0x00, 0x41,0x10, 0x10,0x00,  // clock_time_get(0, 0, 16)
    0x1a,                                           // drop errno
    0x41,0x10, 0x29,0x03,0x00,                     // i64.load
  ];
  const wasm = makeImportModule(imports, body, [0x7e]);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: clock_time_get — trap: ' + r.trap); return; }
  assertTrue(r.values[0].getAsI64() >= 0n, 'clock_time_get: returns non-negative');
})();

// ── clock_res_get ──────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'clock_res_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x10, 0x10,0x00,  // clock_res_get(0, 16)
    0x1a,                              // drop errno
    0x41,0x10, 0x29,0x03,0x00,        // i64.load
  ];
  const wasm = makeImportModule(imports, body, [0x7e]);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: clock_res_get — trap: ' + r.trap); return; }
  assertTrue(r.values[0].getAsI64() > 0n, 'clock_res_get: returns positive resolution');
})();

// ── random_get ─────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'random_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x04, 0x10,0x00, 0x1a,
    0x41,0x00, 0x28,0x02,0x00,  // i32.load
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: random_get — trap: ' + r.trap); return; }
  assertTrue(r.values[0].getAsI32() !== 0, 'random_get: non-zero');
})();

// ═══════════════════════════════════════════════════════════════════════════

console.log('\x1b[36mWASI — proc / sched\x1b[0m');

// ── proc_exit ───────────────────────────────────────────────────────────
(function () {
  let exited = false;
  const env: WasiEnv = { ...createDefaultWasiEnv(), onExit: (_c) => { exited = true; } };
  const rt = new WasmRuntime(new WasiProvider(env));
  const imports = [
    { mod: MOD_WASI, name: 'proc_exit', params: [0x7f], results: [] },
  ];
  const body = [0x41,0x00, 0x10,0x00, 0x41,0x2a]; // call proc_exit(0), then 42 (dead)
  const wasm = makeImportModule(imports, body, [0x7f]);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  assertTrue(r.trap !== null, 'proc_exit: produces trap');
})();

// ── sched_yield ────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'sched_yield', params: [], results: [0x7f] },
  ];
  const body = [0x10,0x00]; // call 0
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: sched_yield — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 0, 'sched_yield: returns SUCCESS');
})();

// ═══════════════════════════════════════════════════════════════════════════

console.log('\x1b[36mWASI — fd_read / fd_write\x1b[0m');

// ── fd_write stdout ────────────────────────────────────────────────────
(function () {
  let captured: string = '';
  const env: WasiEnv = {
    ...createDefaultWasiEnv(),
    onStdout: (data) => { captured += String.fromCharCode(...data); },
  };
  const rt = new WasmRuntime(new WasiProvider(env));
  const imports = [
    { mod: MOD_WASI, name: 'fd_write', params: [0x7f,0x7f,0x7f,0x7f], results: [0x7f] },
  ];
  // Write "Hi\0" via iovec
  const body = [
    0x41,0x00, 0x41,0x20, 0x36,0x02,0x00,  // store ptr=32 at addr 0
    0x41,0x04, 0x41,0x03, 0x36,0x02,0x00,  // store len=3 at addr 4
    0x41,0x20, 0x41,0x30, 0x3a,0x00,0x00,  // store8 '0' at addr 32
    0x41,0x21, 0x41,0x31, 0x3a,0x00,0x00,  // store8 '1' at addr 33
    0x41,0x22, 0x41,0x32, 0x3a,0x00,0x00,  // store8 '2' at addr 34
    0x41,0x01, 0x41,0x00, 0x41,0x01, 0x41,0x10, 0x10,0x00, // fd_write(1,0,1,16)
    0x1a,
    0x41,0x10, 0x28,0x02,0x00,  // nwritten
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_write — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 3, 'fd_write: nwritten=3');
  assertEq(captured, '012', 'fd_write: captured stdout');
})();

// ── fd_read stdin ──────────────────────────────────────────────────────
(function () {
  const env: WasiEnv = {
    ...createDefaultWasiEnv(),
    stdin: new Uint8Array([0x41, 0x42, 0x43]), // "ABC"
  };
  const rt = new WasmRuntime(new WasiProvider(env));
  const imports = [
    { mod: MOD_WASI, name: 'fd_read', params: [0x7f,0x7f,0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x20, 0x36,0x02,0x00, // store ptr=32 at addr 0
    0x41,0x04, 0x41,0x03, 0x36,0x02,0x00, // store len=3 at addr 4
    0x41,0x00, 0x41,0x00, 0x41,0x01, 0x41,0x10, 0x10,0x00, // fd_read(0,0,1,16)
    0x1a,
    0x41,0x20, 0x2d,0x00,0x00,  // load 1st byte
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_read — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 0x41, 'fd_read: reads 0x41');
})();

// ── fd_read EOF ────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_read', params: [0x7f,0x7f,0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x20, 0x36,0x02,0x00,
    0x41,0x04, 0x41,0x03, 0x36,0x02,0x00,
    0x41,0x00, 0x41,0x00, 0x41,0x01, 0x41,0x10, 0x10,0x00,
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_read EOF — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 0, 'fd_read EOF: returns SUCCESS');
})();

// ── fd_read EBADF ──────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_read', params: [0x7f,0x7f,0x7f,0x7f], results: [0x7f] },
  ];
  const body = [0x41,0x63, 0x41,0x10, 0x41,0x01, 0x41,0x20, 0x10,0x00]; // fd=99
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_read EBADF — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 8, 'fd_read EBADF: returns 8 (errno)');
})();

// ═══════════════════════════════════════════════════════════════════════════

console.log('\x1b[36mWASI — fd extras\x1b[0m');

// ── fd_close ────────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_close', params: [0x7f], results: [0x7f] },
  ];
  const body = [0x41,0x00, 0x10,0x00]; // fd_close(0)
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_close — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 0, 'fd_close(0): SUCCESS');
})();

// ── fd_fdstat_get ──────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_fdstat_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x01, 0x41,0x10, 0x10,0x00,  // fd_fdstat_get(1, 16)
    0x1a,
    0x41,0x10, 0x2d,0x00,0x00,        // filetype
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_fdstat_get — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 2, 'fd_fdstat_get: filetype=CHARACTER_DEVICE');
})();

// ── fd_tell ─────────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_tell', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x41,0x10, 0x10,0x00, 0x1a,
    0x41,0x10, 0x29,0x03,0x00,  // i64.load offset
  ];
  const wasm = makeImportModule(imports, body, [0x7e]);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_tell — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI64(), 0n, 'fd_tell: initial offset 0');
})();

// ── fd_seek ────────────────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_seek', params: [0x7f,0x7c,0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x00, 0x42,0x0a, 0x41,0x00, 0x41,0x20, 0x10,0x00, // seek(0, 10, SET, 32)
    0x1a,
    0x41,0x20, 0x29,0x03,0x00,  // new offset
  ];
  const wasm = makeImportModule(imports, body, [0x7e]);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_seek — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI64(), 10n, 'fd_seek SET 10: offset=10');
})();

// ── prestat / dir_name ─────────────────────────────────────────────────
(function () {
  const env: WasiEnv = {
    ...createDefaultWasiEnv(),
    preopens: [{ path: '/data', filetype: 3 }],
  };
  const rt = new WasmRuntime(new WasiProvider(env));
  const imports = [
    { mod: MOD_WASI, name: 'fd_prestat_get', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [
    0x41,0x03, 0x41,0x10, 0x10,0x00, // fd_prestat_get(3, 16)
  ];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_prestat_get — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 0, 'fd_prestat_get(3): SUCCESS');
})();

// ── poll_oneoff stub ───────────────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'poll_oneoff', params: [0x7f,0x7f,0x7f,0x7f], results: [0x7f] },
  ];
  const body = [0x41,0x00, 0x41,0x10, 0x41,0x00, 0x41,0x20, 0x10,0x00];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: poll_oneoff — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 0, 'poll_oneoff: SUCCESS (stub)');
})();

// ── errno EBADF via fd_fdstat_set_flags ────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_fdstat_set_flags', params: [0x7f,0x7f], results: [0x7f] },
  ];
  const body = [0x41,0x00, 0x41,0x00, 0x10,0x00];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: set_flags — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 58, 'fd_fdstat_set_flags: ENOTSUP');
})();

// ── errno ENOSYS via fd_advise ─────────────────────────────────────────
(function () {
  const rt = new WasmRuntime(new WasiProvider());
  const imports = [
    { mod: MOD_WASI, name: 'fd_advise', params: [0x7f,0x7c,0x7c,0x7f], results: [0x7f] },
  ];
  const body = [0x41,0x00, 0x42,0x00, 0x42,0x00, 0x41,0x00, 0x10,0x00];
  const wasm = makeImportModule(imports, body);
  const inst = rt.instantiate(wasm);
  const r = rt.invokeByName(inst, 'test', []);
  if (r.trap) { fail++; console.log('  \x1b[31mFAIL\x1b[0m: fd_advise — trap: ' + r.trap); return; }
  assertEq(r.values[0].getAsI32(), 58, 'fd_advise: ENOTSUP');
})();

// ═══════════════════════════════════════════════════════════════════════════

console.log(`\n\x1b[32m\x1b[1mWASI ${pass + fail} tests: ${pass} PASS, ${fail} FAIL\x1b[0m\n`);
if (fail > 0) process.exit(1);
