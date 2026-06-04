/**
 * WasmRuntime.ets — High-level WebAssembly runtime API.
 *
 * Handles:
 *   - Module instantiation (memory, table, global, function instances)
 *   - Data/element segment initialization
 *   - Export resolution
 *   - Function invocation
 *
 * This is the API layer users interact with.
 */

import {
  WasmModule,
  WasmModuleInstance,
  WasmFunction,
  WasmFunctionInstance,
  WasmMemoryInstance,
  WasmTableInstance,
  WasmValue,
  WasmMemory,
  WasmTable,
  HostFunction,
  VALUE_TYPE_I32,
  VALUE_TYPE_I64,
  VALUE_TYPE_F32,
  VALUE_TYPE_F64,
  VALUE_TYPE_FUNCREF,
  VALUE_TYPE_EXTERNREF,
  IMPORT_KIND_FUNC,
  IMPORT_KIND_TABLE,
  IMPORT_KIND_MEMORY,
  IMPORT_KIND_GLOBAL,
  PosRef,
} from './WasmTypes';

import { WasmLoader } from './WasmLoader';
import { WasmInterpreter, InterpResult } from './WasmInterpreter';
import { Leb128 } from './WasmLeb128';

// ============================================================================
// Import provider interface
// ============================================================================
export interface ImportProvider {
  getFunction(moduleName: string, fieldName: string): HostFunction | null;
  getMemory(moduleName: string, fieldName: string): WasmMemoryInstance | null;
  getTable(moduleName: string, fieldName: string): WasmTableInstance | null;
  getGlobal(moduleName: string, fieldName: string): WasmValue | null;
}

export class DefaultImportProvider implements ImportProvider {
  getFunction(_m: string, _f: string): HostFunction | null { return null; }
  getMemory(_m: string, _f: string): WasmMemoryInstance | null { return null; }
  getTable(_m: string, _f: string): WasmTableInstance | null { return null; }
  getGlobal(_m: string, _f: string): WasmValue | null { return null; }
}

// ============================================================================
// Runtime class
// ============================================================================
export class WasmRuntime {
  private loader: WasmLoader;
  private interpreter: WasmInterpreter;
  private importProvider: ImportProvider;

  constructor(importProvider?: ImportProvider) {
    this.loader = new WasmLoader();
    this.interpreter = new WasmInterpreter();
    this.importProvider = importProvider ?? new DefaultImportProvider();
  }

  /**
   * Load and instantiate a Wasm module from raw bytes.
   * Returns the module instance ready for function calls.
   */
  instantiate(data: Uint8Array): WasmModuleInstance {
    const module = this.loader.load(data);
    return this.instantiateModule(module);
  }

  /**
   * Instantiate a pre-loaded module.
   */
  instantiateModule(module: WasmModule): WasmModuleInstance {
    const inst = new WasmModuleInstance(module);

    // ── Create memory instances ─────────────────────────────────────────────
    for (let i = 0; i < module.imports.length; i++) {
      const imp = module.imports[i];
      if (imp.kind === IMPORT_KIND_MEMORY) {
        const ext = this.importProvider.getMemory(imp.moduleName, imp.fieldName);
        if (ext) {
          inst.memories.push(ext);
        } else {
          inst.memories.push(new WasmMemoryInstance(imp.memoryType!));
        }
      }
    }
    for (const memType of module.memories) {
      inst.memories.push(new WasmMemoryInstance(memType));
    }

    // ── Create table instances ──────────────────────────────────────────────
    for (let i = 0; i < module.imports.length; i++) {
      const imp = module.imports[i];
      if (imp.kind === IMPORT_KIND_TABLE) {
        const ext = this.importProvider.getTable(imp.moduleName, imp.fieldName);
        if (ext) {
          inst.tables.push(ext);
        } else {
          inst.tables.push(new WasmTableInstance(imp.tableType!));
        }
      }
    }
    for (const tblType of module.tables) {
      inst.tables.push(new WasmTableInstance(tblType));
    }

    // ── Create global instances ─────────────────────────────────────────────
    let importGlobalIdx = 0;
    for (const imp of module.imports) {
      if (imp.kind === IMPORT_KIND_GLOBAL) {
        const ext = this.importProvider.getGlobal(imp.moduleName, imp.fieldName);
        if (ext) {
          inst.globalData.push(ext);
        } else {
          inst.globalData.push(WasmValue.i32(0));
        }
        importGlobalIdx++;
      }
    }
    for (const g of module.globals) {
      if (g.initExprBytes) {
        // Extended constant expression — evaluate with access to globals
        inst.globalData.push(this.evaluateInitExpr(g.initExprBytes, inst.globalData));
      } else if (g.initValue) {
        inst.globalData.push(g.initValue.copy());
      } else {
        inst.globalData.push(WasmValue.i32(0));
      }
    }

    // ── Create function instances ───────────────────────────────────────────
    let importFuncIdx = 0;
    for (const imp of module.imports) {
      if (imp.kind === IMPORT_KIND_FUNC) {
        const hostFn = this.importProvider.getFunction(imp.moduleName, imp.fieldName);
        const funcDesc = new WasmFunction();
        funcDesc.code = new Uint8Array([0x00, 0x0B]); // unreachable + end (backup)
        funcDesc.typeIndex = imp.typeIndex;
        funcDesc.paramCount = 0;
        const fi = new WasmFunctionInstance(funcDesc, inst);
        fi.isImport = true;
        fi.hostFunc = hostFn;  // null if unresolved — will trap on call
        inst.funcInstances.push(fi);
        importFuncIdx++;
      }
    }
    for (let i = 0; i < module.funcDescs.length; i++) {
      const func = module.funcDescs[i];
      const funcIdx = module.importFuncCount + i;
      func.typeIndex = module.functions[i];
      // Set param/ret info
      if (func.typeIndex < module.types.length) {
        const ft = module.types[func.typeIndex];
        func.paramCount = ft.paramTypes.length;
        func.paramCellNum = ft.paramCellNum;
        func.retCellNum = ft.retCellNum;
      }
      const fi = new WasmFunctionInstance(func, inst);
      inst.funcInstances.push(fi);
    }

    // ── Initialize element segments (tables) ────────────────────────────────
    for (const seg of module.tableSegs) {
      if (seg.tableIndex >= 0) {
        let offset = 0;
        if (seg.initExprBytes) {
          const val = this.evaluateInitExpr(seg.initExprBytes, inst.globalData);
          if (val.type === VALUE_TYPE_I32) offset = val.getAsI32();
        } else if (seg.initValue && seg.initValue.type === VALUE_TYPE_I32) {
          offset = seg.initValue.getAsI32();
        }
        const table = inst.tables[seg.tableIndex];
        if (table) {
          for (let i = 0; i < seg.funcIndices.length; i++) {
            const funcIdx = seg.funcIndices[i];
            const targetPos = offset + i;
            if (targetPos < table.elements.length) {
              table.elements[targetPos] = funcIdx;
            }
          }
        }
      }
    }

    // ── Initialize data segments ────────────────────────────────────────────
    for (const seg of module.dataSegs) {
      if (seg.memoryIndex >= 0 && seg.memoryIndex < inst.memories.length) {
        let offset = 0;
        if (seg.initExprBytes) {
          const val = this.evaluateInitExpr(seg.initExprBytes, inst.globalData);
          if (val.type === VALUE_TYPE_I32) offset = val.getAsI32();
        } else if (seg.initValue && seg.initValue.type === VALUE_TYPE_I32) {
          offset = seg.initValue.getAsI32();
        }
        const mem = inst.memories[seg.memoryIndex];
        if (mem && offset + seg.data.length <= mem.dataSize) {
          mem.data.set(seg.data, offset);
        }
      }
    }

    // ── Build exports map ───────────────────────────────────────────────────
    for (const exp of module.exports) {
      inst.exports.set(exp.name, exp);
    }

    // ── Set start function ──────────────────────────────────────────────────
    inst.startFuncIdx = module.startFuncIdx;
    inst.dataSegments = module.dataSegs;
    inst.elemSegments = module.tableSegs;

    return inst;
  }

  /**
   * Invoke a function by index.
   */
  invoke(inst: WasmModuleInstance, funcIdx: number, args: WasmValue[]): InterpResult {
    return this.interpreter.invoke(inst, funcIdx, args);
  }

  /**
   * Invoke a function by export name.
   */
  invokeByName(inst: WasmModuleInstance, name: string, args: WasmValue[]): InterpResult {
    return this.interpreter.invokeByName(inst, name, args);
  }

  /**
   * Evaluate an extended constant init expression at instantiation time.
   * Supports: i32/i64/f32/f64.const, global.get, i32/i64.add/sub/mul.
   */
  private evaluateInitExpr(bytes: Uint8Array, globals: WasmValue[]): WasmValue {
    const stack: WasmValue[] = [];
    let pos = 0;
    while (pos < bytes.length) {
      const op = bytes[pos++];
      if (op === 0x0B) { break; } // END
      switch (op) {
        case 0x41: { // i32.const
          const p: PosRef = new PosRef(pos);
          const v = Leb128.readI32(bytes, p);
          pos = p.v;
          stack.push(WasmValue.i32(v));
          break;
        }
        case 0x42: { // i64.const
          const p: PosRef = new PosRef(pos);
          const v = Leb128.readI64(bytes, p);
          pos = p.v;
          stack.push(WasmValue.i64(v));
          break;
        }
        case 0x43: { // f32.const
          const v = new DataView(bytes.buffer, bytes.byteOffset + pos, 4).getFloat32(0, true);
          pos += 4;
          stack.push(WasmValue.f32(v));
          break;
        }
        case 0x44: { // f64.const
          const v = new DataView(bytes.buffer, bytes.byteOffset + pos, 8).getFloat64(0, true);
          pos += 8;
          stack.push(WasmValue.f64(v));
          break;
        }
        case 0x23: { // global.get
          const p: PosRef = new PosRef(pos);
          const idx = Leb128.readU32(bytes, p);
          pos = p.v;
          if (idx < globals.length) {
            stack.push(globals[idx].copy());
          } else {
            stack.push(WasmValue.i32(0));
          }
          break;
        }
        case 0x6A: { // i32.add
          const b = stack.pop()!.getAsI32();
          const a = stack.pop()!.getAsI32();
          stack.push(WasmValue.i32((a + b) | 0));
          break;
        }
        case 0x6B: { // i32.sub
          const b = stack.pop()!.getAsI32();
          const a = stack.pop()!.getAsI32();
          stack.push(WasmValue.i32((a - b) | 0));
          break;
        }
        case 0x6C: { // i32.mul
          const b = stack.pop()!.getAsI32();
          const a = stack.pop()!.getAsI32();
          stack.push(WasmValue.i32(Math.imul(a, b)));
          break;
        }
        case 0x7C: { // i64.add
          const b = stack.pop()!.getAsI64();
          const a = stack.pop()!.getAsI64();
          stack.push(WasmValue.i64((a + b) & 0xFFFFFFFFFFFFFFFFn));
          break;
        }
        case 0x7D: { // i64.sub
          const b = stack.pop()!.getAsI64();
          const a = stack.pop()!.getAsI64();
          stack.push(WasmValue.i64((a - b) & 0xFFFFFFFFFFFFFFFFn));
          break;
        }
        case 0x7E: { // i64.mul
          const b = stack.pop()!.getAsI64();
          const a = stack.pop()!.getAsI64();
          stack.push(WasmValue.i64((a * b) & 0xFFFFFFFFFFFFFFFFn));
          break;
        }
      }
    }
    if (stack.length === 0) {
      return WasmValue.i32(0);
    }
    return stack[stack.length - 1];
  }

  /**
   * Run the start function if one exists.
   */
  runStart(inst: WasmModuleInstance): InterpResult {
    if (inst.startFuncIdx >= 0) {
      return this.interpreter.invoke(inst, inst.startFuncIdx, []);
    }
    return { values: [], trap: null };
  }
}
