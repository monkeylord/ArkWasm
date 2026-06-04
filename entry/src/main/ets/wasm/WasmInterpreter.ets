/**
 * WasmInterpreter.ets — Stack-based WebAssembly interpreter engine.
 *
 * Implements the complete Wasm MVP instruction set (~170 opcodes) plus
 * extended misc opcodes using a switch-based dispatch loop.
 *
 * Architecture mirrors WAMR's wasm_interp_classic.c:
 *   - Value stack (WasmValue[]) for operands
 *   - Control stack (CtrlFrame[]) for block/loop/if management
 *   - Linear memory via WasmMemoryInstance
 *   - Function calls via frame stack
 */

import {
  WasmValue,
  WasmModule,
  WasmModuleInstance,
  WasmFunction,
  WasmFunctionInstance,
  WasmMemoryInstance,
  WasmTableInstance,
  WasmInterpFrame,
  BranchBlock,
  HostTrap,
  FuncType,
  VALUE_TYPE_I32,
  VALUE_TYPE_I64,
  VALUE_TYPE_F32,
  VALUE_TYPE_F64,
  VALUE_TYPE_V128,
  VALUE_TYPE_FUNCREF,
  VALUE_TYPE_EXTERNREF,
  VALUE_TYPE_VOID,
  valueTypeCellNum,
  LABEL_TYPE_BLOCK,
  LABEL_TYPE_LOOP,
  LABEL_TYPE_IF,
  LABEL_TYPE_FUNCTION,
  LABEL_TYPE_TRY,
  LABEL_TYPE_CATCH,
  LABEL_TYPE_CATCH_ALL,
} from './WasmTypes';
import { PosRef, MemArg, DecodedLeb } from './WasmTypes';
import { WasmOp, GcExtOp, MiscExtOp, SimdExtOp, AtomicExtOp, isPrefixOpcode } from './WasmOpcode';
import { Leb128 } from './WasmLeb128';

import * as F from './WasmFloatOps';

// ============================================================================
// Result type for function calls
// ============================================================================
export interface InterpResult {
  values: WasmValue[];
  trap: string | null; // null = success, string = trap message
}

// ============================================================================
// Control Frame (label stack entry)
// ============================================================================
class CtrlFrame {
  public labelType: number;
  public startIp: number;  // block/loop/if start in bytecode
  public endIp: number;    // end position in bytecode
  public elseIp: number;   // else position (0 for block/loop)
  public stackHeight: number; // stack height when entering
  public resultTypes: number[]; // block result types
  public isLoop: boolean;

  constructor(
    lt: number, start: number, end: number, elseP: number,
    sh: number, results: number[], loop: boolean
  ) {
    this.labelType = lt;
    this.startIp = start;
    this.endIp = end;
    this.elseIp = elseP;
    this.stackHeight = sh;
    this.resultTypes = results;
    this.isLoop = loop;
  }
}

// ============================================================================
// Interpreter Engine
// ============================================================================
export class WasmInterpreter {
  // State
  private moduleInst: WasmModuleInstance = new WasmModuleInstance(new WasmModule());
  private stack: WasmValue[] = [];       // value stack
  private ctrlStack: CtrlFrame[] = [];    // control/label stack
  private frameStk: WasmInterpFrame[] = []; // call frame stack
  private locs: WasmValue[] = [];        // locals of current frame
  private halted: boolean = false;
  private trapMsg: string | null = null;

  // Currently executing function's bytecode
  private code: Uint8Array = new Uint8Array(0);
  private ip: number = 0;

  // Quick references
  private memory: WasmMemoryInstance | null = null;
  private globals: WasmValue[] = [];
  private tables: WasmTableInstance[] = [];
  private funcInsts: WasmFunctionInstance[] = [];
  private types: FuncType[] = [];

  /**
   * Invoke a function by index in the module instance.
   */
  invoke(moduleInst: WasmModuleInstance, funcIdx: number, args: WasmValue[]): InterpResult {
    this.moduleInst = moduleInst;
    this.memory = moduleInst.memories.length > 0 ? moduleInst.memories[0] : null;
    this.globals = moduleInst.globalData;
    this.tables = moduleInst.tables;
    this.funcInsts = moduleInst.funcInstances;
    this.types = moduleInst.module.types;

    const fi = this.funcInsts[funcIdx];
    if (!fi) {
      return { values: [], trap: `function index ${funcIdx} out of bounds` };
    }

    return this.callFunction(fi, args, null);
  }

  /**
   * Invoke by export name.
   */
  invokeByName(moduleInst: WasmModuleInstance, name: string, args: WasmValue[]): InterpResult {
    const exp = moduleInst.exports.get(name);
    if (!exp || exp.kind !== 0) {
      return { values: [], trap: `export '${name}' not found` };
    }
    return this.invoke(moduleInst, exp.index, args);
  }

  // ==========================================================================
  // Function Call Entry
  // ==========================================================================
  private callFunction(
    funcInst: WasmFunctionInstance,
    args: WasmValue[],
    prevFrame: WasmInterpFrame | null
  ): InterpResult {
    const func = funcInst.funcDesc;
    const typeIdx = func.typeIndex;
    const ft = this.types[typeIdx];

    // Check arg count
    if (args.length !== ft.paramTypes.length) {
      return { values: [], trap: `arg count mismatch: expected ${ft.paramTypes.length}, got ${args.length}` };
    }

    // If import function — dispatch to host callback
    if (funcInst.isImport) {
      return this.callHost(funcInst, args);
    }

    // Setup execution
    this.stack = [];
    this.ctrlStack = [];
    this.locs = [];
    this.halted = false;
    this.trapMsg = null;
    this.code = func.code;
    this.ip = 0;

    // Copy params to locals
    for (let i = 0; i < args.length; i++) {
      this.locs.push(args[i]);
    }
    // Init non-param locals to 0
    for (let i = args.length; i < func.paramCount + func.localTypes.length; i++) {
      this.locs.push(WasmValue.i32(0));
    }

    // Push function frame onto control stack
    const results: number[] = ft.resultTypes;
    this.ctrlStack.push(new CtrlFrame(
      LABEL_TYPE_FUNCTION, 0, this.code.length, 0,
      this.stack.length, results, false
    ));

    // Execute
    try {
      this.executeLoop();
    } catch (e) {
      if (e instanceof Error) {
        return { values: [], trap: e.message };
      }
      return { values: [], trap: String(e) };
    }

    if (this.trapMsg) {
      return { values: [], trap: this.trapMsg };
    }

    // Collect results
    const resultValues: WasmValue[] = [];
    for (let i = 0; i < results.length; i++) {
      const idx = this.stack.length - results.length + i;
      if (idx >= 0 && idx < this.stack.length) {
        resultValues.push(this.stack[idx].copy());
      }
    }

    return { values: resultValues, trap: null };
  }

  // ==========================================================================
  // Main Execution Loop
  // ==========================================================================
  private executeLoop(): void {
    while (!this.halted && this.ip < this.code.length) {
      const opcode = this.code[this.ip++];
      this.dispatch(opcode);
    }
  }

  // ==========================================================================
  // Dispatch
  // ==========================================================================
  private dispatch(opcode: number): void {
    switch (opcode) {
      // ── Control ─────────────────────────────────────────────────────
      case WasmOp.UNREACHABLE:         this.trap('unreachable'); return;
      case WasmOp.NOP:                 return;
      case WasmOp.BLOCK:               this.handleBlock(); return;
      case WasmOp.LOOP:                this.handleLoop(); return;
      case WasmOp.IF:                  this.handleIf(); return;
      case WasmOp.ELSE:                this.handleElse(); return;
      case WasmOp.END:                 this.handleEnd(); return;
      case WasmOp.BR:                  this.handleBr(); return;
      case WasmOp.BR_IF:               this.handleBrIf(); return;
      case WasmOp.BR_TABLE:            this.handleBrTable(); return;
      case WasmOp.RETURN:              this.handleReturn(); return;
      case WasmOp.CALL:                this.handleCall(); return;
      case WasmOp.CALL_INDIRECT:       this.handleCallIndirect(); return;
      case WasmOp.RETURN_CALL:         this.handleReturnCall(); return;
      case WasmOp.RETURN_CALL_INDIRECT:this.handleReturnCallIndirect(); return;
      case WasmOp.CALL_REF:            this.handleCallRef(); return;
      case WasmOp.RETURN_CALL_REF:     this.handleReturnCallRef(); return;
      case WasmOp.TRY:                 this.handleTry(); return;
      case WasmOp.CATCH:               this.handleCatch(); return;
      case WasmOp.CATCH_ALL:           this.handleCatchAll(); return;
      case WasmOp.THROW:               this.handleThrow(); return;
      case WasmOp.RETHROW:             this.handleRethrow(); return;
      case WasmOp.DELEGATE:            this.handleDelegate(); return;

      // ── Parametric ──────────────────────────────────────────────────
      case WasmOp.DROP:                this.stack.pop()!; return;
      case WasmOp.SELECT:              this.handleSelect(false); return;
      case WasmOp.SELECT_T:            this.handleSelect(true); return;

      // ── Variable ────────────────────────────────────────────────────
      case WasmOp.GET_LOCAL:           this.handleGetLocal(); return;
      case WasmOp.SET_LOCAL:           this.handleSetLocal(); return;
      case WasmOp.TEE_LOCAL:           this.handleTeeLocal(); return;
      case WasmOp.GET_GLOBAL:          this.handleGetGlobal(); return;
      case WasmOp.SET_GLOBAL:          this.handleSetGlobal(); return;
      case WasmOp.TABLE_GET:           this.handleTableGet(); return;
      case WasmOp.TABLE_SET:           this.handleTableSet(); return;

      // ── Memory ──────────────────────────────────────────────────────
      case WasmOp.I32_LOAD:            this.memLoadI32(4, true); return;
      case WasmOp.I64_LOAD:            this.memLoadI64(8, true); return;
      case WasmOp.F32_LOAD:            this.memLoadF32(); return;
      case WasmOp.F64_LOAD:            this.memLoadF64(); return;
      case WasmOp.I32_LOAD8_S:         this.memLoadI32(1, true); return;
      case WasmOp.I32_LOAD8_U:         this.memLoadI32(1, false); return;
      case WasmOp.I32_LOAD16_S:        this.memLoadI32(2, true); return;
      case WasmOp.I32_LOAD16_U:        this.memLoadI32(2, false); return;
      case WasmOp.I64_LOAD8_S:         this.memLoadI64(1, true); return;
      case WasmOp.I64_LOAD8_U:         this.memLoadI64(1, false); return;
      case WasmOp.I64_LOAD16_S:        this.memLoadI64(2, true); return;
      case WasmOp.I64_LOAD16_U:        this.memLoadI64(2, false); return;
      case WasmOp.I64_LOAD32_S:        this.memLoadI64(4, true); return;
      case WasmOp.I64_LOAD32_U:        this.memLoadI64(4, false); return;
      case WasmOp.I32_STORE:           this.memStore(4); return;
      case WasmOp.I64_STORE:           this.memStore(8); return;
      case WasmOp.F32_STORE:           this.memStore(4); return;
      case WasmOp.F64_STORE:           this.memStore(8); return;
      case WasmOp.I32_STORE8:          this.memStore(1); return;
      case WasmOp.I32_STORE16:         this.memStore(2); return;
      case WasmOp.I64_STORE8:          this.memStore(1); return;
      case WasmOp.I64_STORE16:         this.memStore(2); return;
      case WasmOp.I64_STORE32:         this.memStore(4); return;
      case WasmOp.MEMORY_SIZE:         this.handleMemorySize(); return;
      case WasmOp.MEMORY_GROW:         this.handleMemoryGrow(); return;

      // ── Constants ───────────────────────────────────────────────────
      case WasmOp.I32_CONST:           this.pushI32(this.readLebI32()); return;
      case WasmOp.I64_CONST:           this.pushI64(this.readLebI64()); return;
      case WasmOp.F32_CONST:           this.pushF32(this.readF32()); return;
      case WasmOp.F64_CONST:           this.pushF64(this.readF64()); return;

      // ── I32 Compare ─────────────────────────────────────────────────
      case WasmOp.I32_EQZ:             this.pushI32(F.i32Eqz(this.popI32())); return;
      case WasmOp.I32_EQ:              { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Eq(a, b)); return; }
      case WasmOp.I32_NE:              { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Ne(a, b)); return; }
      case WasmOp.I32_LT_S:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32LtS(a, b)); return; }
      case WasmOp.I32_LT_U:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32LtU(a, b)); return; }
      case WasmOp.I32_GT_S:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32GtS(a, b)); return; }
      case WasmOp.I32_GT_U:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32GtU(a, b)); return; }
      case WasmOp.I32_LE_S:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32LeS(a, b)); return; }
      case WasmOp.I32_LE_U:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32LeU(a, b)); return; }
      case WasmOp.I32_GE_S:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32GeS(a, b)); return; }
      case WasmOp.I32_GE_U:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32GeU(a, b)); return; }

      // ── I64 Compare ─────────────────────────────────────────────────
      case WasmOp.I64_EQZ:             this.pushI32(F.i64Eqz(this.popI64())); return;
      case WasmOp.I64_EQ:              { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64Eq(a, b)); return; }
      case WasmOp.I64_NE:              { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64Ne(a, b)); return; }
      case WasmOp.I64_LT_S:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64LtS(a, b)); return; }
      case WasmOp.I64_LT_U:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64LtU(a, b)); return; }
      case WasmOp.I64_GT_S:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64GtS(a, b)); return; }
      case WasmOp.I64_GT_U:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64GtU(a, b)); return; }
      case WasmOp.I64_LE_S:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64LeS(a, b)); return; }
      case WasmOp.I64_LE_U:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64LeU(a, b)); return; }
      case WasmOp.I64_GE_S:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64GeS(a, b)); return; }
      case WasmOp.I64_GE_U:            { const b = this.popI64(), a = this.popI64(); this.pushI32(F.i64GeU(a, b)); return; }

      // ── F32 Compare ─────────────────────────────────────────────────
      case WasmOp.F32_EQ:              { const b = this.popF32(), a = this.popF32(); this.pushI32(F.f32Eq(a, b)); return; }
      case WasmOp.F32_NE:              { const b = this.popF32(), a = this.popF32(); this.pushI32(F.f32Ne(a, b)); return; }
      case WasmOp.F32_LT:              { const b = this.popF32(), a = this.popF32(); this.pushI32(F.f32Lt(a, b)); return; }
      case WasmOp.F32_GT:              { const b = this.popF32(), a = this.popF32(); this.pushI32(F.f32Gt(a, b)); return; }
      case WasmOp.F32_LE:              { const b = this.popF32(), a = this.popF32(); this.pushI32(F.f32Le(a, b)); return; }
      case WasmOp.F32_GE:              { const b = this.popF32(), a = this.popF32(); this.pushI32(F.f32Ge(a, b)); return; }

      // ── F64 Compare ─────────────────────────────────────────────────
      case WasmOp.F64_EQ:              { const b = this.popF64(), a = this.popF64(); this.pushI32(F.f64Eq(a, b)); return; }
      case WasmOp.F64_NE:              { const b = this.popF64(), a = this.popF64(); this.pushI32(F.f64Ne(a, b)); return; }
      case WasmOp.F64_LT:              { const b = this.popF64(), a = this.popF64(); this.pushI32(F.f64Lt(a, b)); return; }
      case WasmOp.F64_GT:              { const b = this.popF64(), a = this.popF64(); this.pushI32(F.f64Gt(a, b)); return; }
      case WasmOp.F64_LE:              { const b = this.popF64(), a = this.popF64(); this.pushI32(F.f64Le(a, b)); return; }
      case WasmOp.F64_GE:              { const b = this.popF64(), a = this.popF64(); this.pushI32(F.f64Ge(a, b)); return; }

      // ── I32 Numeric ─────────────────────────────────────────────────
      case WasmOp.I32_CLZ:             this.pushI32(F.i32Clz(this.popI32())); return;
      case WasmOp.I32_CTZ:             this.pushI32(F.i32Ctz(this.popI32())); return;
      case WasmOp.I32_POPCNT:          this.pushI32(F.i32Popcnt(this.popI32())); return;
      case WasmOp.I32_ADD:             { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Add(a, b)); return; }
      case WasmOp.I32_SUB:             { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Sub(a, b)); return; }
      case WasmOp.I32_MUL:             { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Mul(a, b)); return; }
      case WasmOp.I32_DIV_S:           { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32DivS(a, b)); return; }
      case WasmOp.I32_DIV_U:           { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32DivU(a, b)); return; }
      case WasmOp.I32_REM_S:           { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32RemS(a, b)); return; }
      case WasmOp.I32_REM_U:           { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32RemU(a, b)); return; }
      case WasmOp.I32_AND:             { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32And(a, b)); return; }
      case WasmOp.I32_OR:              { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Or(a, b)); return; }
      case WasmOp.I32_XOR:             { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Xor(a, b)); return; }
      case WasmOp.I32_SHL:             { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Shl(a, b)); return; }
      case WasmOp.I32_SHR_S:           { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32ShrS(a, b)); return; }
      case WasmOp.I32_SHR_U:           { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32ShrU(a, b)); return; }
      case WasmOp.I32_ROTL:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Rotl(a, b)); return; }
      case WasmOp.I32_ROTR:            { const b = this.popI32(), a = this.popI32(); this.pushI32(F.i32Rotr(a, b)); return; }

      // ── I64 Numeric ─────────────────────────────────────────────────
      case WasmOp.I64_CLZ:             this.pushI64(BigInt(F.i64Clz(this.popI64()))); return;
      case WasmOp.I64_CTZ:             this.pushI32(F.i64Ctz(this.popI64())); return;
      case WasmOp.I64_POPCNT:          this.pushI32(F.i64Popcnt(this.popI64())); return;
      case WasmOp.I64_ADD:             { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Add(a, b)); return; }
      case WasmOp.I64_SUB:             { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Sub(a, b)); return; }
      case WasmOp.I64_MUL:             { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Mul(a, b)); return; }
      case WasmOp.I64_DIV_S:           { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64DivS(a, b)); return; }
      case WasmOp.I64_DIV_U:           { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64DivU(a, b)); return; }
      case WasmOp.I64_REM_S:           { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64RemS(a, b)); return; }
      case WasmOp.I64_REM_U:           { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64RemU(a, b)); return; }
      case WasmOp.I64_AND:             { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64And(a, b)); return; }
      case WasmOp.I64_OR:              { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Or(a, b)); return; }
      case WasmOp.I64_XOR:             { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Xor(a, b)); return; }
      case WasmOp.I64_SHL:             { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Shl(a, b)); return; }
      case WasmOp.I64_SHR_S:           { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64ShrS(a, b)); return; }
      case WasmOp.I64_SHR_U:           { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64ShrU(a, b)); return; }
      case WasmOp.I64_ROTL:            { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Rotl(a, b)); return; }
      case WasmOp.I64_ROTR:            { const b = this.popI64(), a = this.popI64(); this.pushI64(F.i64Rotr(a, b)); return; }

      // ── F32 Numeric ─────────────────────────────────────────────────
      case WasmOp.F32_ABS:             this.pushF32(F.f32Abs(this.popF32())); return;
      case WasmOp.F32_NEG:             this.pushF32(F.f32Neg(this.popF32())); return;
      case WasmOp.F32_CEIL:            this.pushF32(F.f32Ceil(this.popF32())); return;
      case WasmOp.F32_FLOOR:           this.pushF32(F.f32Floor(this.popF32())); return;
      case WasmOp.F32_TRUNC:           this.pushF32(F.f32Trunc(this.popF32())); return;
      case WasmOp.F32_NEAREST:         this.pushF32(F.f32Nearest(this.popF32())); return;
      case WasmOp.F32_SQRT:            this.pushF32(F.f32Sqrt(this.popF32())); return;
      case WasmOp.F32_ADD:             { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Add(a, b)); return; }
      case WasmOp.F32_SUB:             { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Sub(a, b)); return; }
      case WasmOp.F32_MUL:             { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Mul(a, b)); return; }
      case WasmOp.F32_DIV:             { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Div(a, b)); return; }
      case WasmOp.F32_MIN:             { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Min(a, b)); return; }
      case WasmOp.F32_MAX:             { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Max(a, b)); return; }
      case WasmOp.F32_COPYSIGN:        { const b = this.popF32(), a = this.popF32(); this.pushF32(F.f32Copysign(a, b)); return; }

      // ── F64 Numeric ─────────────────────────────────────────────────
      case WasmOp.F64_ABS:             this.pushF64(F.f64Abs(this.popF64())); return;
      case WasmOp.F64_NEG:             this.pushF64(F.f64Neg(this.popF64())); return;
      case WasmOp.F64_CEIL:            this.pushF64(F.f64Ceil(this.popF64())); return;
      case WasmOp.F64_FLOOR:           this.pushF64(F.f64Floor(this.popF64())); return;
      case WasmOp.F64_TRUNC:           this.pushF64(F.f64Trunc(this.popF64())); return;
      case WasmOp.F64_NEAREST:         this.pushF64(F.f64Nearest(this.popF64())); return;
      case WasmOp.F64_SQRT:            this.pushF64(F.f64Sqrt(this.popF64())); return;
      case WasmOp.F64_ADD:             { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Add(a, b)); return; }
      case WasmOp.F64_SUB:             { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Sub(a, b)); return; }
      case WasmOp.F64_MUL:             { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Mul(a, b)); return; }
      case WasmOp.F64_DIV:             { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Div(a, b)); return; }
      case WasmOp.F64_MIN:             { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Min(a, b)); return; }
      case WasmOp.F64_MAX:             { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Max(a, b)); return; }
      case WasmOp.F64_COPYSIGN:        { const b = this.popF64(), a = this.popF64(); this.pushF64(F.f64Copysign(a, b)); return; }

      // ── Conversion ──────────────────────────────────────────────────
      case WasmOp.I32_WRAP_I64:        this.pushI32(F.i32WrapI64(this.popI64())); return;
      case WasmOp.I32_TRUNC_S_F32:     this.pushI32(F.i32TruncSF32(this.popF32())); return;
      case WasmOp.I32_TRUNC_U_F32:     this.pushI32(F.i32TruncUF32(this.popF32())); return;
      case WasmOp.I32_TRUNC_S_F64:     this.pushI32(F.i32TruncSF64(this.popF64())); return;
      case WasmOp.I32_TRUNC_U_F64:     this.pushI32(F.i32TruncUF64(this.popF64())); return;
      case WasmOp.I64_EXTEND_S_I32:    this.pushI64(F.i64ExtendSI32(this.popI32())); return;
      case WasmOp.I64_EXTEND_U_I32:    this.pushI64(F.i64ExtendUI32(this.popI32())); return;
      case WasmOp.I64_TRUNC_S_F32:     this.pushI64(F.i64TruncSF32(this.popF32())); return;
      case WasmOp.I64_TRUNC_U_F32:     this.pushI64(F.i64TruncUF32(this.popF32())); return;
      case WasmOp.I64_TRUNC_S_F64:     this.pushI64(F.i64TruncSF64(this.popF64())); return;
      case WasmOp.I64_TRUNC_U_F64:     this.pushI64(F.i64TruncUF64(this.popF64())); return;
      case WasmOp.F32_CONVERT_S_I32:   this.pushF32(F.f32ConvertSI32(this.popI32())); return;
      case WasmOp.F32_CONVERT_U_I32:   this.pushF32(F.f32ConvertUI32(this.popI32())); return;
      case WasmOp.F32_CONVERT_S_I64:   this.pushF32(F.f32ConvertSI64(this.popI64())); return;
      case WasmOp.F32_CONVERT_U_I64:   this.pushF32(F.f32ConvertUI64(this.popI64())); return;
      case WasmOp.F32_DEMOTE_F64:      this.pushF32(F.f32DemoteF64(this.popF64())); return;
      case WasmOp.F64_CONVERT_S_I32:   this.pushF64(F.f64ConvertSI32(this.popI32())); return;
      case WasmOp.F64_CONVERT_U_I32:   this.pushF64(F.f64ConvertUI32(this.popI32())); return;
      case WasmOp.F64_CONVERT_S_I64:   this.pushF64(F.f64ConvertSI64(this.popI64())); return;
      case WasmOp.F64_CONVERT_U_I64:   this.pushF64(F.f64ConvertUI64(this.popI64())); return;
      case WasmOp.F64_PROMOTE_F32:     this.pushF64(F.f64PromoteF32(this.popF32())); return;

      // ── Reinterpret ─────────────────────────────────────────────────
      case WasmOp.I32_REINTERPRET_F32: this.pushI32(F.f32ToI32(this.popF32())); return;
      case WasmOp.I64_REINTERPRET_F64: this.pushI64(F.f64ToI64(this.popF64())); return;
      case WasmOp.F32_REINTERPRET_I32: this.pushF32(F.i32ToF32(this.popI32())); return;
      case WasmOp.F64_REINTERPRET_I64: this.pushF64(F.i64ToF64(this.popI64())); return;

      // ── Sign Extend ─────────────────────────────────────────────────
      case WasmOp.I32_EXTEND8_S:       this.pushI32(F.i32Extend8S(this.popI32())); return;
      case WasmOp.I32_EXTEND16_S:      this.pushI32(F.i32Extend16S(this.popI32())); return;
      case WasmOp.I64_EXTEND8_S:       this.pushI64(F.i64Extend8S(this.popI64())); return;
      case WasmOp.I64_EXTEND16_S:      this.pushI64(F.i64Extend16S(this.popI64())); return;
      case WasmOp.I64_EXTEND32_S:      this.pushI64(F.i64Extend32S(this.popI64())); return;

      // ── Reference ───────────────────────────────────────────────────
      case WasmOp.REF_NULL:            this.handleRefNull(); return;
      case WasmOp.REF_IS_NULL:         this.handleRefIsNull(); return;
      case WasmOp.REF_FUNC:            this.handleRefFunc(); return;
      case WasmOp.REF_EQ:              this.handleRefEq(); return;
      case WasmOp.REF_AS_NON_NULL:     this.handleRefAsNonNull(); return;
      case WasmOp.BR_ON_NULL:          this.handleBrOnNull(); return;
      case WasmOp.BR_ON_NON_NULL:      this.handleBrOnNonNull(); return;

      // ── Misc prefix ─────────────────────────────────────────────────
      case WasmOp.MISC_PREFIX:         this.dispatchMisc(); return;
      case WasmOp.GC_PREFIX:           this.dispatchGc(); return;
      case WasmOp.SIMD_PREFIX:         this.dispatchSimd(); return;
      case WasmOp.ATOMIC_PREFIX:       this.dispatchAtomic(); return;

      default:
        this.trap(`unknown opcode: 0x${opcode.toString(16).padStart(2, '0')}`);
    }
  }

  // ==========================================================================
  // Stack Helpers
  // ==========================================================================
  private pushI32(v: number): void { this.stack.push(WasmValue.i32(v)); }
  private pushI64(v: bigint): void { this.stack.push(WasmValue.i64(v)); }
  private pushF32(v: number): void { this.stack.push(WasmValue.f32(v)); }
  private pushF64(v: number): void { this.stack.push(WasmValue.f64(v)); }

  private popI32(): number { return this.stack.pop()!.getAsI32(); }
  private popI64(): bigint { return this.stack.pop()!.getAsI64(); }
  private popF32(): number { return this.stack.pop()!.getAsF32(); }
  private popF64(): number { return this.stack.pop()!.getAsF64(); }

  private trap(msg: string): void {
    this.trapMsg = msg;
    this.halted = true;
    throw new Error(msg);
  }

  private readLebI32(): number {
    const p: PosRef = new PosRef(this.ip);
    const result = Leb128.readI32(this.code, p);
    this.ip = p.v;
    return result;
  }

  private readLebI64(): bigint {
    const p: PosRef = new PosRef(this.ip);
    const result = Leb128.readI64(this.code, p);
    this.ip = p.v;
    return result;
  }

  private readLebU32(): number {
    const p: PosRef = new PosRef(this.ip);
    const result = Leb128.readU32(this.code, p);
    this.ip = p.v;
    return result;
  }

  private readF32(): number {
    const v = new DataView(this.code.buffer, this.code.byteOffset + this.ip, 4).getFloat32(0, true);
    this.ip += 4;
    return v;
  }

  private readF64(): number {
    const v = new DataView(this.code.buffer, this.code.byteOffset + this.ip, 8).getFloat64(0, true);
    this.ip += 8;
    return v;
  }

  // ==========================================================================
  // Control Flow Handlers
  // ==========================================================================

  private readBlockType(): number[] {
    const p: PosRef = new PosRef(this.ip);
    const bt = Leb128.readI32(this.code, p);
    this.ip = p.v;
    if (bt === -64) { // 0x40 = void
      return [];
    }
    if (bt >= 0) {
      // Type index: look up functype result types for multi-value blocks
      if (bt < this.types.length) {
        return this.types[bt].resultTypes.slice();
      }
      return [];
    }
    // bt < 0 and bt !== -64: value type — recover raw byte
    return [bt + 128];
  }

  private handleBlock(): void {
    const resultTypes = this.readBlockType();
    const startIp = this.ip;
    const endIp = this.scanForEnd();
    this.ctrlStack.push(new CtrlFrame(
      LABEL_TYPE_BLOCK, startIp, endIp, 0,
      this.stack.length, resultTypes, false
    ));
  }

  private handleLoop(): void {
    const resultTypes = this.readBlockType();
    const startIp = this.ip;
    const endIp = this.scanForEnd();
    this.ctrlStack.push(new CtrlFrame(
      LABEL_TYPE_LOOP, startIp, endIp, 0,
      this.stack.length, resultTypes, true
    ));
  }

  private handleIf(): void {
    const cond = this.popI32();
    const resultTypes = this.readBlockType();

    if (cond !== 0) {
      // True branch: enter the if body
      this.ctrlStack.push(new CtrlFrame(
        LABEL_TYPE_IF, this.ip, 0, 0,
        this.stack.length, resultTypes, false
      ));
      // Find else/end for proper block closing
      const endIp = this.scanForEnd();
      const elseIp = this.findElse();
      this.ctrlStack[this.ctrlStack.length - 1].endIp = endIp;
      this.ctrlStack[this.ctrlStack.length - 1].elseIp = elseIp;
    } else {
      // False branch: skip to else or end
      const endIp = this.scanForEnd();
      const elseIp = this.findElseBefore(endIp);
      if (elseIp > 0) {
        // There is an else branch — push IF frame and continue at else body
        this.ctrlStack.push(new CtrlFrame(
          LABEL_TYPE_IF, elseIp, 0, 0,
          this.stack.length, resultTypes, false
        ));
        this.ctrlStack[this.ctrlStack.length - 1].endIp = endIp;
        this.ctrlStack[this.ctrlStack.length - 1].elseIp = elseIp;
        this.ip = elseIp;
      } else {
        this.ip = endIp;
      }
    }
  }

  private handleElse(): void {
    const frame = this.ctrlStack[this.ctrlStack.length - 1];
    if (frame.labelType !== LABEL_TYPE_IF) {
      this.trap('else without if');
      return;
    }
    // Jump to end of if-else block
    this.ip = frame.endIp;
  }

  private handleEnd(): void {
    const frame = this.ctrlStack.pop()!;
    if (frame.labelType === LABEL_TYPE_FUNCTION) {
      // Return from function — keep results on stack
      this.halted = true;
      return;
    }
    // For block/loop/if: continue after the block
  }

  private handleBr(): void {
    const depth = this.readLebU32();
    this.doBranch(depth);
  }

  private handleBrIf(): void {
    const depth = this.readLebU32();
    const cond = this.popI32();
    if (cond !== 0) {
      this.doBranch(depth);
    }
  }

  /**
   * br_table: Wasm spec binary format = targets* default
   *   Opcode 0x0E → count(u32) → target[0]...target[count-1](u32) → default(u32)
   * (Old WAMR format was default first; this follows the current Wasm spec)
   */
  private handleBrTable(): void {
    const tableLen = this.readLebU32();

    // Build lookup table
    const table: number[] = [];
    for (let i = 0; i < tableLen; i++) {
      table.push(this.readLebU32());
    }

    const defaultDepth = this.readLebU32();

    const idx = this.popI32();
    const targetDepth = (idx >= 0 && idx < tableLen) ? table[idx] : defaultDepth;
    this.doBranch(targetDepth);
  }

  private handleReturn(): void {
    // Branch to function frame
    for (let i = this.ctrlStack.length - 1; i >= 0; i--) {
      if (this.ctrlStack[i].labelType === LABEL_TYPE_FUNCTION) {
        this.doBranchN(i);
        return;
      }
    }
    this.halted = true;
  }

  private doBranch(depth: number): void {
    const targetIdx = this.ctrlStack.length - 1 - depth;
    if (targetIdx < 0) {
      this.trap(`branch depth ${depth} out of bounds`);
      return;
    }
    this.doBranchN(targetIdx);
  }

  private doBranchN(targetIdx: number): void {
    const targetFrame = this.ctrlStack[targetIdx];
    const resultCount = targetFrame.resultTypes.length;
    const currentHeight = this.stack.length;
    const targetHeight = targetFrame.stackHeight;

    // Move result values
    const results: WasmValue[] = [];
    for (let i = 0; i < resultCount; i++) {
      results.push(this.stack[currentHeight - resultCount + i].copy());
    }

    // Unwind stack (only truncate, never extend)
    if (targetHeight < this.stack.length) {
      this.stack.length = targetHeight;
    }

    // Push results
    for (const r of results) {
      this.stack.push(r);
    }

    // Pop all control frames up to target
    while (this.ctrlStack.length > targetIdx + 1) {
      this.ctrlStack.pop();
    }

    // Jump to target
    if (targetFrame.isLoop) {
      this.ip = targetFrame.startIp;
    } else if (targetFrame.labelType === LABEL_TYPE_FUNCTION) {
      // Pop the function frame
      const funcFrame = this.ctrlStack[targetIdx];
      if (targetHeight < this.stack.length) {
        this.stack.length = targetHeight;
      }
      // Push results
      for (let i = 0; i < targetFrame.resultTypes.length; i++) {
        if (results.length > i) {
          this.stack.push(results[i]);
        }
      }
      this.ctrlStack.length = targetIdx; // remove function frame
      this.halted = true;
    } else {
      this.ip = targetFrame.endIp;
    }
  }

  // ==========================================================================
  // Function Call Handlers
  // ==========================================================================

  private handleCall(): void {
    const funcIdx = this.readLebU32();
    const fi = this.funcInsts[funcIdx];
    if (!fi) {
      this.trap(`function ${funcIdx} not found`);
      return;
    }

    if (fi.isImport) {
      this.callHostInline(fi);
      return;
    }

    const func = fi.funcDesc;
    const ft = this.types[func.typeIndex];

    // Get args from stack
    const argCount = ft.paramTypes.length;
    const args: WasmValue[] = [];
    for (let i = argCount - 1; i >= 0; i--) {
      args.unshift(this.stack.pop()!.copy());
    }

    // Call the function inline (recursive)
    const result = this.callFunctionInline(fi, args);
    if (result.trap) {
      this.trap(result.trap);
      return;
    }

    // Push results
    for (const r of result.values) {
      this.stack.push(r);
    }
  }

  private handleCallIndirect(): void {
    const typeIdx = this.readLebU32();
    const tableIdx = this.readLebU32(); // default 0

    if (tableIdx >= this.tables.length) {
      this.trap(`table ${tableIdx} not found`);
      return;
    }

    const table = this.tables[tableIdx];
    const elemIdx = this.popI32();

    if (elemIdx < 0 || elemIdx >= table.elements.length) {
      this.trap(`undefined element: table index ${elemIdx} out of bounds`);
      return;
    }

    const funcIdx = table.elements[elemIdx];
    if (funcIdx < 0 || funcIdx >= this.funcInsts.length) {
      this.trap(`uninitialized element`);
      return;
    }

    const fi = this.funcInsts[funcIdx];
    const func = fi.funcDesc;

    // Type check
    if (func.typeIndex !== typeIdx) {
      this.trap(`indirect call type mismatch`);
      return;
    }

    if (fi.isImport) {
      const ft = this.types[typeIdx];
      const args: WasmValue[] = [];
      for (let i = ft.paramTypes.length - 1; i >= 0; i--) {
        args.unshift(this.stack.pop()!.copy());
      }
      // Type-checked host call from table
      if (!fi.hostFunc) {
        this.trap(`host function not provided for import`);
        return;
      }
      try {
        const results = fi.hostFunc(args, this.memory);
        for (const r of results) {
          this.stack.push(r);
        }
      } catch (e) {
        if (e instanceof HostTrap) {
          this.trap(e.message);
        } else {
          throw e as Error;
        }
      }
      return;
    }

    const ft2 = this.types[typeIdx];
    const args2: WasmValue[] = [];
    for (let i = ft2.paramTypes.length - 1; i >= 0; i--) {
      args2.unshift(this.stack.pop()!.copy());
    }

    const result = this.callFunctionInline(fi, args2);
    if (result.trap) {
      this.trap(result.trap);
      return;
    }

    for (const r of result.values) {
      this.stack.push(r);
    }
  }

  /**
   * Inline function call (no new frame push — shared stack).
   * Saves and restores local state.
   */
  private callFunctionInline(fi: WasmFunctionInstance, args: WasmValue[]): InterpResult {
    // Save current state
    const savedStack = this.stack;
    const savedCtrl = this.ctrlStack;
    const savedLocs = this.locs;
    const savedCode = this.code;
    const savedIp = this.ip;

    this.stack = [];
    this.ctrlStack = [];
    this.locs = [];
    this.halted = false;
    this.trapMsg = null;
    this.code = fi.funcDesc.code;
    this.ip = 0;

    // Setup locals
    for (let i = 0; i < args.length; i++) {
      this.locs.push(args[i].copy());
    }
    for (let i = args.length; i < fi.funcDesc.paramCount + fi.funcDesc.localTypes.length; i++) {
      this.locs.push(WasmValue.i32(0));
    }

    const ft = this.types[fi.funcDesc.typeIndex];
    this.ctrlStack.push(new CtrlFrame(
      LABEL_TYPE_FUNCTION, 0, this.code.length, 0,
      0, ft.resultTypes, false
    ));

    try {
      this.executeLoop();
    } catch (e) {
      // Restore state
      this.stack = savedStack;
      this.ctrlStack = savedCtrl;
      this.locs = savedLocs;
      this.code = savedCode;
      this.ip = savedIp;
      if (e instanceof Error) {
        return { values: [], trap: e.message };
      }
      return { values: [], trap: String(e) };
    }

    // Collect results
    const results: WasmValue[] = [];
    for (let i = 0; i < ft.resultTypes.length; i++) {
      if (this.stack.length > 0) {
        results.push(this.stack.pop()!.copy());
      }
    }
    // Reverse to maintain order
    results.reverse();

    // Restore state
    this.stack = savedStack;
    this.ctrlStack = savedCtrl;
    this.locs = savedLocs;
    this.code = savedCode;
    this.ip = savedIp;

    return { values: results, trap: null };
  }

  // ═══════════════════════════════════════════════════════════════════════
  // TAIL CALL / CALL_REF / EXCEPTION HANDLERS
  // ═══════════════════════════════════════════════════════════════════════

  // ─── return_call: call function, then return from current frame ───

  private handleReturnCall(): void {
    const funcIdx = this.readLebU32();
    const fi = this.funcInsts[funcIdx];
    if (!fi) { this.trap(`function ${funcIdx} not found`); return; }
    if (fi.isImport) {
      this.callHostInline(fi);
      this.handleReturn();
      return;
    }
    const func = fi.funcDesc;
    const ft = this.types[func.typeIndex];
    const args: WasmValue[] = [];
    for (let i = ft.paramTypes.length - 1; i >= 0; i--) {
      args.unshift(this.stack.pop()!.copy());
    }
    const result = this.callFunctionInline(fi, args);
    if (result.trap) { this.trap(result.trap); return; }
    for (const r of result.values) this.stack.push(r);
    this.handleReturn();
  }

  private handleReturnCallIndirect(): void {
    const typeIdx = this.readLebU32();
    this.readLebU32(); // table idx
    const table = this.tables[0];
    const elemIdx = this.popI32();
    if (elemIdx < 0 || elemIdx >= table.elements.length) {
      this.trap('return_call_indirect: element out of bounds'); return;
    }
    const funcIdx = table.elements[elemIdx];
    if (funcIdx < 0 || funcIdx >= this.funcInsts.length) {
      this.trap('return_call_indirect: uninitialized element'); return;
    }
    const fi = this.funcInsts[funcIdx];
    if (fi.funcDesc.typeIndex !== typeIdx) {
      this.trap('return_call_indirect: type mismatch'); return;
    }
    if (fi.isImport) {
      this.callHostInline(fi);
      this.handleReturn();
      return;
    }
    const ft = this.types[typeIdx];
    const args: WasmValue[] = [];
    for (let i = ft.paramTypes.length - 1; i >= 0; i--) {
      args.unshift(this.stack.pop()!.copy());
    }
    const result = this.callFunctionInline(fi, args);
    if (result.trap) { this.trap(result.trap); return; }
    for (const r of result.values) this.stack.push(r);
    this.handleReturn();
  }

  // ─── call_ref: call function via reference ─────────────────────────

  private handleCallRef(): void {
    const typeIdx = this.readLebU32();
    const refVal = this.stack.pop()!;
    const funcIdx = refVal.getAsRef();
    if (funcIdx < 0 || funcIdx >= this.funcInsts.length) {
      this.trap('call_ref: null function reference'); return;
    }
    const fi = this.funcInsts[funcIdx];
    if (fi.funcDesc.typeIndex !== typeIdx) {
      this.trap('call_ref: type mismatch'); return;
    }
    const ft = this.types[typeIdx];
    const args: WasmValue[] = [];
    for (let i = ft.paramTypes.length - 1; i >= 0; i--) {
      args.unshift(this.stack.pop()!.copy());
    }
    if (fi.isImport) { this.callHostInline(fi); return; }
    const result = this.callFunctionInline(fi, args);
    if (result.trap) { this.trap(result.trap); return; }
    for (const r of result.values) this.stack.push(r);
  }

  private handleReturnCallRef(): void {
    this.handleCallRef();
    this.handleReturn();
  }

  // ─── try / catch / throw ───────────────────────────────────────────

  private handleTry(): void {
    const bt = this.readBlockType();
    const bodyStart = this.ip;
    const catchAddr = this.scanForCatch();
    this.ctrlStack.push(new CtrlFrame(
      LABEL_TYPE_TRY, bodyStart, 0, catchAddr,
      this.stack.length, bt, false
    ));
  }

  private handleCatch(): void {
    // Read tag index
    this.readLebU32();
    // Pop exception payload from stack (pushed by throw before unwinding)
    // The exception value is on top of the stack at this point
    this.stack.pop();
    // Execution continues in catch body — no further action needed
  }

  private handleCatchAll(): void {
    // Pop exception payload
    this.stack.pop();
  }

  /**
   * Throw: unwind to nearest TRY frame and jump to its catch handler.
   * The exception value is on the top of the operand stack.
   */
  private handleThrow(): void {
    this.readLebU32(); // tag index (unused for now)

    // Walk up ctrlStack to find nearest TRY frame
    for (let i = this.ctrlStack.length - 1; i >= 0; i--) {
      const frame = this.ctrlStack[i];
      if (frame.labelType === LABEL_TYPE_TRY) {
        // Save the exception value from stack top
        const exceptVal = this.stack.length > 0 ?
          this.stack[this.stack.length - 1].copy() : WasmValue.i32(0);

        // Truncate stack to TRY frame's height
        const th = frame.stackHeight;
        if (th < this.stack.length) {
          this.stack.length = th;
        }
        // Push exception value back
        this.stack.push(exceptVal);

        // Pop all ctrlStack frames above the TRY frame
        while (this.ctrlStack.length > i + 1) {
          this.ctrlStack.pop();
        }
        // Pop the TRY frame itself (catch will re-push if needed)
        this.ctrlStack.pop();

        // Jump to catch handler
        this.ip = frame.elseIp;
        return;
      }
      // Check function frame — uncaught
      if (frame.labelType === LABEL_TYPE_FUNCTION) {
        this.trap('uncaught exception');
        return;
      }
    }
    this.trap('uncaught exception');
  }

  private handleRethrow(): void {
    this.readLebU32(); // relative depth (unused for now)
    this.handleThrow();
  }

  private handleDelegate(): void {
    const depth = this.readLebU32();
    // Pop TRY frame — delegation means exceptions go to outer handler
    // Simplified: just pop the TRY frame
    if (this.ctrlStack.length > 0) {
      const frame = this.ctrlStack.pop()!;
      if (frame.labelType !== LABEL_TYPE_TRY) {
        this.ctrlStack.push(frame); // restore if not TRY
      }
    }
  }

  /**
   * Scan forward from current IP to find the next CATCH or CATCH_ALL
   * at the current try block level. Used by handleTry to record
   * the catch handler address for throw unwinding.
   */
  private scanForCatch(): number {
    let depth = 1;
    let pos = this.ip;
    while (pos < this.code.length) {
      const op = this.code[pos++];
      if (op === WasmOp.TRY || op === WasmOp.BLOCK ||
        op === WasmOp.LOOP || op === WasmOp.IF) {
        depth++;
      } else if (op === WasmOp.END) {
        depth--;
        if (depth === 0) return pos; // no catch found, return END
      } else if ((op === WasmOp.CATCH || op === WasmOp.CATCH_ALL)
        && depth === 1) {
        return pos - 1; // catch opcode address (pos++ already advanced)
      }
    }
    return this.code.length;
  }

  /**
   * Call a host function from the top-level invoke() path.
   * Pops no stack — receives args directly from the caller.
   */
  private callHost(fi: WasmFunctionInstance, args: WasmValue[]): InterpResult {
    if (!fi.hostFunc) {
      return { values: [], trap: `host function not provided for import` };
    }
    try {
      const results = fi.hostFunc(args, this.memory);
      return { values: results, trap: null };
    } catch (e) {
      if (e instanceof HostTrap) {
        return { values: [], trap: e.message };
      }
      throw e as Error;
    }
  }

  /**
   * Call a host function from within the bytecode (call / call_indirect).
   * Pops args from the operand stack, pushes results back.
   */
  private callHostInline(fi: WasmFunctionInstance): void {
    if (!fi.hostFunc) {
      this.trap(`host function not provided for import`);
      return;
    }
    const ft = this.types[fi.funcDesc.typeIndex];

    // Pop args
    const args: WasmValue[] = [];
    for (let i = ft.paramTypes.length - 1; i >= 0; i--) {
      args.unshift(this.stack.pop()!.copy());
    }

    // Call host
    try {
      const results = fi.hostFunc(args, this.memory);
      for (const r of results) {
        this.stack.push(r);
      }
    } catch (e) {
      if (e instanceof HostTrap) {
        this.trap(e.message);
      } else {
        throw e as Error;
      }
    }
  }

  // ==========================================================================
  // Variable Handlers
  // ==========================================================================

  private handleGetLocal(): void {
    const idx = this.readLebU32();
    if (idx < this.locs.length) {
      this.stack.push(this.locs[idx].copy());
    } else {
      this.trap(`local.get index ${idx} out of bounds`);
    }
  }

  private handleSetLocal(): void {
    const idx = this.readLebU32();
    if (idx < this.locs.length) {
      this.locs[idx] = this.stack.pop()!.copy();
    } else {
      this.trap(`local.set index ${idx} out of bounds`);
    }
  }

  private handleTeeLocal(): void {
    const idx = this.readLebU32();
    if (idx < this.locs.length) {
      const val = this.stack[this.stack.length - 1].copy();
      this.locs[idx] = val;
    } else {
      this.trap(`local.tee index ${idx} out of bounds`);
    }
  }

  private handleGetGlobal(): void {
    const idx = this.readLebU32();
    if (idx < this.globals.length) {
      this.stack.push(this.globals[idx].copy());
    } else {
      this.trap(`global.get index ${idx} out of bounds`);
    }
  }

  private handleSetGlobal(): void {
    const idx = this.readLebU32();
    if (idx < this.globals.length) {
      this.globals[idx] = this.stack.pop()!.copy();
    } else {
      this.trap(`global.set index ${idx} out of bounds`);
    }
  }

  private handleTableGet(): void {
    const tableIdx = this.readLebU32();
    if (tableIdx >= this.tables.length) {
      this.trap(`table.get: table ${tableIdx} not found`);
      return;
    }
    const idx = this.popI32();
    const table = this.tables[tableIdx];
    if (idx < 0 || idx >= table.elements.length) {
      this.trap(`table.get: index ${idx} out of bounds`);
      return;
    }
    this.pushI32(table.elements[idx]);
  }

  private handleTableSet(): void {
    const tableIdx = this.readLebU32();
    if (tableIdx >= this.tables.length) {
      this.trap(`table.set: table ${tableIdx} not found`);
      return;
    }
    const val = this.popI32();
    const idx = this.popI32();
    const table = this.tables[tableIdx];
    if (idx < 0 || idx >= table.elements.length) {
      this.trap(`table.set: index ${idx} out of bounds`);
      return;
    }
    table.elements[idx] = val;
  }

  // ==========================================================================
  // Memory Handlers
  // ==========================================================================

  private checkMem(): WasmMemoryInstance {
    if (!this.memory) {
      this.trap('memory not available');
    }
    return this.memory!;
  }

  /** Get memory by index (0=default). For multi-memory support. */
  private getMem(idx: number): WasmMemoryInstance {
    if (idx > 0 && this.moduleInst && this.moduleInst.memories.length > idx) {
      return this.moduleInst.memories[idx];
    }
    return this.checkMem();
  }

  private memLoadI32(width: number, signed: boolean): void {
    const memArg = this.readMemArg();
    const align = memArg.align;
    const offset = memArg.offset;
    const memidx = memArg.memidx;
    const mem = this.getMem(memidx);
    const addr = this.popI32();
    const effectiveAddr = (addr >>> 0) + offset;

    if (effectiveAddr + width > mem.dataSize) {
      this.trap(`memory load out of bounds: ${effectiveAddr}+${width} > ${mem.dataSize}`);
      return;
    }

    const dv = new DataView(mem.buffer);
    let result: number;
    switch (width) {
      case 1:
        result = signed ? dv.getInt8(effectiveAddr) : dv.getUint8(effectiveAddr);
        break;
      case 2:
        result = signed ? dv.getInt16(effectiveAddr, true) : dv.getUint16(effectiveAddr, true);
        break;
      case 4:
        result = signed ? dv.getInt32(effectiveAddr, true) : dv.getUint32(effectiveAddr, true);
        break;
      default:
        this.trap(`invalid load width: ${width}`);
        return;
    }
    this.pushI32(result);
  }

  private memLoadI64(width: number, signed: boolean): void {
    const memArg = this.readMemArg();
    const align = memArg.align;
    const offset = memArg.offset;
    const memidx = memArg.memidx;
    const mem = this.getMem(memidx);
    const addr = this.popI32();
    const effectiveAddr = (addr >>> 0) + offset;

    if (effectiveAddr + width > mem.dataSize) {
      this.trap(`memory load out of bounds: ${effectiveAddr}+${width} > ${mem.dataSize}`);
      return;
    }

    const dv = new DataView(mem.buffer);
    let result: bigint;
    switch (width) {
      case 1:
        result = signed ? BigInt(dv.getInt8(effectiveAddr)) : BigInt(dv.getUint8(effectiveAddr));
        break;
      case 2:
        result = signed ? BigInt(dv.getInt16(effectiveAddr, true)) : BigInt(dv.getUint16(effectiveAddr, true));
        break;
      case 4:
        result = signed ? BigInt(dv.getInt32(effectiveAddr, true)) : BigInt(dv.getUint32(effectiveAddr, true));
        break;
      case 8:
        result = dv.getBigInt64(effectiveAddr, true);
        break;
      default:
        this.trap(`invalid load64 width: ${width}`);
        return;
    }
    this.pushI64(result);
  }

  private memLoadF32(): void {
    const memArg = this.readMemArg();
    const align = memArg.align;
    const offset = memArg.offset;
    const memidx = memArg.memidx;
    const mem = this.getMem(memidx);
    const addr = this.popI32();
    const effectiveAddr = (addr >>> 0) + offset;
    if (effectiveAddr + 4 > mem.dataSize) {
      this.trap(`memory load out of bounds`);
      return;
    }
    this.pushF32(new DataView(mem.buffer).getFloat32(effectiveAddr, true));
  }

  private memLoadF64(): void {
    const memArg = this.readMemArg();
    const align = memArg.align;
    const offset = memArg.offset;
    const memidx = memArg.memidx;
    const mem = this.getMem(memidx);
    const addr = this.popI32();
    const effectiveAddr = (addr >>> 0) + offset;
    if (effectiveAddr + 8 > mem.dataSize) {
      this.trap(`memory load out of bounds`);
      return;
    }
    this.pushF64(new DataView(mem.buffer).getFloat64(effectiveAddr, true));
  }

  private memStore(width: number): void {
    const memArg = this.readMemArg();
    const align = memArg.align;
    const offset = memArg.offset;
    const memidx = memArg.memidx;
    const mem = this.getMem(memidx);
    const value = this.stack.pop()!;
    const addr = this.popI32();
    const effectiveAddr = (addr >>> 0) + offset;

    if (effectiveAddr + width > mem.dataSize) {
      this.trap(`memory store out of bounds`);
      return;
    }

    const dv = new DataView(mem.buffer);
    switch (width) {
      case 1:
        dv.setUint8(effectiveAddr, value.getAsI32() & 0xFF);
        break;
      case 2:
        dv.setUint16(effectiveAddr, value.getAsI32() & 0xFFFF, true);
        break;
      case 4:
        if (value.type === VALUE_TYPE_I32) {
          dv.setInt32(effectiveAddr, value.getAsI32(), true);
        } else {
          dv.setFloat32(effectiveAddr, value.getAsF32(), true);
        }
        break;
      case 8:
        if (value.type === VALUE_TYPE_I64) {
          dv.setBigInt64(effectiveAddr, value.getAsI64(), true);
        } else {
          dv.setFloat64(effectiveAddr, value.getAsF64(), true);
        }
        break;
    }
  }

  private readMemArg(): MemArg {
    const rawAlign = this.readLebU32();
    const rawOffset = this.readLebU32();
    const memidx = (rawAlign & 0x40) !== 0 ? this.readLebU32() : 0;
    return new MemArg(rawAlign & 0x3F, rawOffset, memidx);
  }

  private handleMemorySize(): void {
    const memidx = this.readLebU32();
    const mem = this.getMem(memidx);
    if (mem.isMemory64) {
      this.pushI64(BigInt(mem.curPages));
    } else {
      this.pushI32(mem.curPages);
    }
  }

  private handleMemoryGrow(): void {
    const memidx = this.readLebU32();
    const mem = this.getMem(memidx);
    if (mem.isMemory64) {
      const pages = Number(this.popI64());
      const prev = mem.grow(pages);
      this.pushI64(prev >= 0 ? BigInt(prev) : -1n);
    } else {
      const pages = this.popI32();
      const prev = mem.grow(pages);
      this.pushI32(prev);
    }
  }

  // ==========================================================================
  // Reference Handlers
  // ==========================================================================

  private handleRefNull(): void {
    const type = this.readLebU32();
    // Push null reference
    const ref = new WasmValue(VALUE_TYPE_FUNCREF);
    ref.refVal = -1;
    this.stack.push(ref);
  }

  private handleRefIsNull(): void {
    const val = this.stack.pop()!;
    this.pushI32(val.refVal === -1 ? 1 : 0);
  }

  private handleRefFunc(): void {
    const funcIdx = this.readLebU32();
    const ref = new WasmValue(VALUE_TYPE_FUNCREF);
    ref.refVal = funcIdx;
    this.stack.push(ref);
  }

  private handleRefEq(): void {
    const v2 = this.stack.pop()!;
    const v1 = this.stack.pop()!;
    this.pushI32(v1.refVal === v2.refVal ? 1 : 0);
  }

  private handleRefAsNonNull(): void {
    const val = this.stack.pop()!;
    if (val.refVal === -1) {
      this.trap('ref.as_non_null: null reference');
      return;
    }
    this.stack.push(val);
  }

  private handleBrOnNull(): void {
    const depth = this.readLebU32();
    const val = this.stack.pop()!;
    if (val.refVal === -1) {
      this.doBranch(depth);
    } else {
      this.stack.push(val);
    }
  }

  private handleBrOnNonNull(): void {
    const depth = this.readLebU32();
    const val = this.stack.pop()!;
    if (val.refVal !== -1) {
      this.doBranch(depth);
    } else {
      this.stack.push(val);
    }
  }

  // ==========================================================================
  // Select Handlers
  // ==========================================================================

  private handleSelect(typed: boolean): void {
    if (typed) {
      const typeCount = this.readLebU32();
      // For single type select: skip the type vector
    }
    const cond = this.popI32();
    const val2 = this.stack.pop()!;
    const val1 = this.stack.pop()!;
    this.stack.push(cond !== 0 ? val1 : val2);
  }

  // ==========================================================================
  // Misc prefix dispatch
  // ==========================================================================

  private dispatchMisc(): void {
    const subOp = this.readLebU32();
    switch (subOp) {
      case MiscExtOp.I32_TRUNC_SAT_S_F32: this.pushI32(F.i32TruncSatSF32(this.popF32())); return;
      case MiscExtOp.I32_TRUNC_SAT_U_F32: this.pushI32(F.i32TruncSatUF32(this.popF32())); return;
      case MiscExtOp.I32_TRUNC_SAT_S_F64: this.pushI32(F.i32TruncSatSF64(this.popF64())); return;
      case MiscExtOp.I32_TRUNC_SAT_U_F64: this.pushI32(F.i32TruncSatUF64(this.popF64())); return;
      case MiscExtOp.I64_TRUNC_SAT_S_F32: this.pushI64(F.i64TruncSatSF32(this.popF32())); return;
      case MiscExtOp.I64_TRUNC_SAT_U_F32: this.pushI64(F.i64TruncSatUF32(this.popF32())); return;
      case MiscExtOp.I64_TRUNC_SAT_S_F64: this.pushI64(F.i64TruncSatSF64(this.popF64())); return;
      case MiscExtOp.I64_TRUNC_SAT_U_F64: this.pushI64(F.i64TruncSatUF64(this.popF64())); return;
      case MiscExtOp.MEMORY_INIT:   this.handleMemoryInit(); return;
      case MiscExtOp.DATA_DROP:     this.handleDataDrop(); return;
      case MiscExtOp.MEMORY_COPY:   this.handleMemoryCopy(); return;
      case MiscExtOp.MEMORY_FILL:   this.handleMemoryFill(); return;
      case MiscExtOp.TABLE_INIT:    this.handleTableInit(); return;
      case MiscExtOp.ELEM_DROP:     this.handleElemDrop(); return;
      case MiscExtOp.TABLE_COPY:    this.handleTableCopy(); return;
      case MiscExtOp.TABLE_GROW:    this.handleTableGrow(); return;
      case MiscExtOp.TABLE_SIZE:    this.handleTableSize(); return;
      case MiscExtOp.TABLE_FILL:    this.handleTableFill(); return;
      default:
        this.trap(`unknown misc opcode: 0x${subOp.toString(16)}`);
    }
  }

  private handleMemoryCopy(): void {
    const dstIdx = this.readLebU32();
    const srcIdx = this.readLebU32();
    const size = this.popI32();
    const src = this.popI32();
    const dst = this.popI32();
    const dstMem = this.getMem(dstIdx);
    const srcMem = this.getMem(srcIdx);
    if (src + size > srcMem.dataSize || dst + size > dstMem.dataSize) {
      this.trap('memory.copy out of bounds');
      return;
    }
    if (dstMem === srcMem) {
      dstMem.data.copyWithin(dst, src, src + size);
    } else {
      dstMem.data.set(srcMem.data.subarray(src, src + size), dst);
    }
  }

  private handleMemoryFill(): void {
    const memidx = this.readLebU32();
    const size = this.popI32();
    const val = this.popI32();
    const dst = this.popI32();
    const mem = this.getMem(memidx);
    if (dst + size > mem.dataSize) {
      this.trap('memory.fill out of bounds');
      return;
    }
    mem.data.fill(val & 0xFF, dst, dst + size);
  }

  private handleTableGrow(): void {
    const tableIdx = this.readLebU32();
    if (tableIdx >= this.tables.length) {
      this.trap(`table.grow: table ${tableIdx} not found`);
      return;
    }
    const initVal = this.popI32();
    const delta = this.popI32();
    const table = this.tables[tableIdx];
    const prevSize = table.grow(delta, initVal);
    this.pushI32(prevSize >= 0 ? prevSize : -1);
  }

  private handleTableSize(): void {
    const tableIdx = this.readLebU32();
    if (tableIdx >= this.tables.length) {
      this.trap(`table.size: table ${tableIdx} not found`);
      return;
    }
    this.pushI32(this.tables[tableIdx].curSize);
  }

  // ─── memory.init / data.drop ──────────────────────────────────────────

  private handleMemoryInit(): void {
    const dataIdx = this.readLebU32();
    this.readLebU32();
    const size = this.popI32();
    const src = this.popI32();
    const dst = this.popI32();
    const mem = this.checkMem();
    if (!this.moduleInst) { this.trap('memory.init: no module instance'); return; }

    const segs = this.moduleInst.dataSegments;
    if (dataIdx >= segs.length) {
      this.trap('memory.init: data segment index out of bounds');
      return;
    }
    const seg = segs[dataIdx];
    if (!seg.data || seg.data.length === 0) {
      // dropped or empty segment
      if (size !== 0) this.trap('memory.init: dropped data segment');
      return;
    }
    if (src + size > seg.data.length) {
      this.trap('memory.init: source out of bounds');
      return;
    }
    if (dst + size > mem.dataSize) {
      this.trap('memory.init: destination out of bounds');
      return;
    }
    mem.data.set(seg.data.subarray(src, src + size), dst);
  }

  private handleDataDrop(): void {
    const dataIdx = this.readLebU32();
    const segs = this.moduleInst.dataSegments;
    if (dataIdx >= segs.length) {
      this.trap('data.drop: index out of bounds');
      return;
    }
    segs[dataIdx].data = new Uint8Array(0); // mark as dropped
  }

  // ─── table.init / elem.drop ───────────────────────────────────────────

  private handleTableInit(): void {
    const elemIdx = this.readLebU32(); // elem segment index
    this.readLebU32(); // table idx (default 0)
    const size = this.popI32();
    const src = this.popI32();
    const dst = this.popI32();
    const table = this.tables[0];

    const segs = this.moduleInst.elemSegments;
    if (elemIdx >= segs.length) {
      this.trap('table.init: elem segment index out of bounds');
      return;
    }
    const seg = segs[elemIdx];
    if (seg.funcIndices.length === 0) {
      if (size !== 0) this.trap('table.init: dropped elem segment');
      return;
    }
    if (src + size > seg.funcIndices.length) {
      this.trap('table.init: source out of bounds');
      return;
    }
    if (dst + size > table.elements.length) {
      this.trap('table.init: destination out of bounds');
      return;
    }
    for (let i = 0; i < size; i++) {
      table.elements[dst + i] = seg.funcIndices[src + i];
    }
  }

  private handleElemDrop(): void {
    const elemIdx = this.readLebU32();
    const segs = this.moduleInst.elemSegments;
    if (elemIdx >= segs.length) {
      this.trap('elem.drop: index out of bounds');
      return;
    }
    segs[elemIdx].funcIndices = []; // mark as dropped
  }

  // ─── table.copy / table.fill ──────────────────────────────────────────

  private handleTableCopy(): void {
    const dstIdx = this.readLebU32();
    const srcIdx = this.readLebU32();
    const size = this.popI32();
    const src = this.popI32();
    const dst = this.popI32();

    if (srcIdx >= this.tables.length || dstIdx >= this.tables.length) {
      this.trap('table.copy: table index out of bounds');
      return;
    }
    const srcTable = this.tables[srcIdx];
    const dstTable = this.tables[dstIdx];
    if (src + size > srcTable.elements.length || dst + size > dstTable.elements.length) {
      this.trap('table.copy: out of bounds');
      return;
    }
    for (let i = 0; i < size; i++) {
      dstTable.elements[dst + i] = srcTable.elements[src + i];
    }
  }

  private handleTableFill(): void {
    this.readLebU32(); // table idx
    const size = this.popI32();
    const val = this.popI32();
    const dst = this.popI32();
    const table = this.tables[0];
    if (dst + size > table.elements.length) {
      this.trap('table.fill: out of bounds');
      return;
    }
    for (let i = 0; i < size; i++) {
      table.elements[dst + i] = val;
    }
  }

  // ==========================================================================
  // Bytecode Scanning Helpers
  // ==========================================================================

  /**
   * Scan forward from current IP to find matching END for the current block.
   * This is a simple brace-matching scan through the bytecode.
   * Returns the position AFTER the END opcode.
   */
  /** Decode LEB128 u32 from offset; returns DecodedLeb with val and new pos. */
  private decodeLebAt(pos: number): DecodedLeb {
    let result = 0;
    let shift = 0;
    while (pos < this.code.length) {
      const b = this.code[pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) === 0) break;
      shift += 7;
    }
    return new DecodedLeb(result, pos);
  }
  /** Skip operands of current instruction; returns new pos */
  private skipImmediate(pos: number): number {
    const op = this.code[pos - 1];
    // LEB128-based opcodes (single LEB)
    if ((op >= 0x20 && op <= 0x24) || op === 0x0C || op === 0x0D ||
        op === 0x10 || op === 0x41 || op === 0x42 || op === 0x11) {
      return this.decodeLebAt(pos).pos;
    }
    // br_table: count + targets[] + default (all LEB)
    if (op === 0x0E) {
      const c = this.decodeLebAt(pos);
      pos = c.pos;
      for (let i = 0; i < c.val && pos < this.code.length; i++) {
        pos = this.decodeLebAt(pos).pos;
      }
      return this.decodeLebAt(pos).pos;
    }
    // Memory load/store: align byte + LEB offset
    if (op >= 0x28 && op <= 0x3F) {
      pos++; // align
      return this.decodeLebAt(pos).pos;
    }
    if (op === 0x43) return pos + 4;     // f32.const
    if (op === 0x44) return pos + 8;     // f64.const
    if (op === 0xD0) return pos + 1;     // ref.null (1-byte heap type)
    if (op === 0xD2 || op === 0xD4 || op === 0xD1) return this.decodeLebAt(pos).pos; // ref.func etc.
    // Prefix ops
    if (op === 0xFC || op === 0xFD || op === 0xFE) {
      pos = this.decodeLebAt(pos).pos;
      // Most sub-ops have a memarg or a tableidx LEB
      if (op === 0xFC) {
        // memory.copy/fill: 2 LEB (srcdst, dstsrc)
        const sub = this.code[pos - 2]; // approximate
        if (sub === 0x0A || sub === 0x0B) return this.decodeLebAt(this.decodeLebAt(pos).pos).pos;
        // data.drop / table.init: 2 LEB
        if (sub === 0x09 || sub === 0x0C) return this.decodeLebAt(this.decodeLebAt(pos).pos).pos;
        return this.decodeLebAt(pos).pos;
      }
      if (op === 0xFD || op === 0xFE) {
        // memarg: align + LEB offset
        pos++;
        return this.decodeLebAt(pos).pos;
      }
    }
    return pos;
  }

  private scanForEnd(): number {
    let depth = 1;
    let pos = this.ip;
    while (pos < this.code.length) {
      const op = this.code[pos++];
      switch (op) {
        case WasmOp.BLOCK:
        case WasmOp.LOOP:
        case WasmOp.IF:
          depth++;
          break;
        case WasmOp.END:
          depth--;
          if (depth === 0) return pos;
          break;
        default:
          pos = this.skipImmediate(pos);
          break;
      }
    }
    this.trap('unterminated block');
    return this.code.length;
  }

  /**
   * Scan for ELSE within the current IF block.
   */
  private findElse(): number {
    let depth = 1;
    let pos = this.ip;
    while (pos < this.code.length) {
      const op = this.code[pos++];
      switch (op) {
        case WasmOp.BLOCK:
        case WasmOp.LOOP:
        case WasmOp.IF:
          depth++;
          break;
        case WasmOp.END:
          depth--;
          if (depth === 0) { return 0; }
          break;
        case WasmOp.ELSE:
          if (depth === 1) { return pos; }
          break;
        default:
          pos = this.skipImmediate(pos);
          break;
      }
    }
    return 0;
  }

  /**
   * Skip over an IF block's false branch to else or end.
   */
  private skipIfBlock(): void {
    const endPos = this.scanForEnd();
    const elsePos = this.findElseBefore(endPos);
    if (elsePos > 0) {
      this.ip = elsePos;
    } else {
      this.ip = endPos;
    }
  }

  private findElseBefore(endPos: number): number {
    let depth = 1;
    let pos = this.ip;
    while (pos < endPos) {
      const op = this.code[pos++];
      switch (op) {
        case WasmOp.BLOCK:
        case WasmOp.LOOP:
        case WasmOp.IF:
          depth++;
          break;
        case WasmOp.END:
          depth--;
          if (depth === 0) { return 0; }
          break;
        case WasmOp.ELSE:
          if (depth === 1) { return pos; }
          break;
        default:
          pos = this.skipImmediate(pos);
          break;
      }
    }
    return 0;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SIMD PREFIX (0xFD) — v128 operations
  // ═══════════════════════════════════════════════════════════════════════

  private dispatchSimd(): void {
    const sub = this.code[this.ip++]; // single byte — all SIMD sub-opcodes < 256

    // v128 memory ops
    switch (sub) {
      case SimdExtOp.V128_LOAD:          this.simdLoad(0); return;
      case SimdExtOp.V128_LOAD8X8_S:     this.trap('SIMD v128.load8x8_s not impl'); return;
      case SimdExtOp.V128_LOAD8X8_U:     this.trap('SIMD v128.load8x8_u not impl'); return;
      case SimdExtOp.V128_LOAD16X4_S:    this.trap('SIMD v128.load16x4_s not impl'); return;
      case SimdExtOp.V128_LOAD16X4_U:    this.trap('SIMD v128.load16x4_u not impl'); return;
      case SimdExtOp.V128_LOAD32X2_S:    this.trap('SIMD v128.load32x2_s not impl'); return;
      case SimdExtOp.V128_LOAD32X2_U:    this.trap('SIMD v128.load32x2_u not impl'); return;
      case SimdExtOp.V128_LOAD8_SPLAT:   this.trap('SIMD v128.load8_splat not impl'); return;
      case SimdExtOp.V128_LOAD16_SPLAT:  this.trap('SIMD v128.load16_splat not impl'); return;
      case SimdExtOp.V128_LOAD32_SPLAT:  this.trap('SIMD v128.load32_splat not impl'); return;
      case SimdExtOp.V128_LOAD64_SPLAT:  this.trap('SIMD v128.load64_splat not impl'); return;
      case SimdExtOp.V128_STORE:         this.simdStore(); return;
      case SimdExtOp.V128_CONST:         this.simdConst(); return;

      // Basic integer arithmetic (i32x4 / i64x2)
      case SimdExtOp.I32X4_ADD:          this.simdBinOp('i32', 4, (a, b) => (a + b) | 0); return;
      case SimdExtOp.I32X4_SUB:          this.simdBinOp('i32', 4, (a, b) => (a - b) | 0); return;
      case SimdExtOp.I32X4_MUL:          this.simdBinOp('i32', 4, (a, b) => Math.imul(a, b)); return;
      case SimdExtOp.I64X2_ADD:          this.simdBinOpI64(2, (a, b) => a + b); return;
      case SimdExtOp.I64X2_SUB:          this.simdBinOpI64(2, (a, b) => a - b); return;

      // Bitwise
      case SimdExtOp.V128_AND:           this.simdBitwise((a, b) => a & b); return;
      case SimdExtOp.V128_OR:            this.simdBitwise((a, b) => a | b); return;
      case SimdExtOp.V128_XOR:           this.simdBitwise((a, b) => a ^ b); return;
      case SimdExtOp.V128_NOT:           this.simdUnary(v => ~v); return;

      // Splat (i8x16, i16x8, i32x4, i64x2)
      case SimdExtOp.I8X16_SPLAT:        this.simdSplat(1, 16); return;
      case SimdExtOp.I16X8_SPLAT:        this.simdSplat(2, 8); return;
      case SimdExtOp.I32X4_SPLAT:        this.simdSplat(4, 4); return;
      case SimdExtOp.I64X2_SPLAT:        this.simdSplat64(); return;

      default:
        this.trap(`SIMD op 0x${sub.toString(16)} not impl`);
    }
  }

  // v128.load: read 16 bytes from memory
  private simdLoad(align: number): void {
    const mem = this.checkMem();
    const ao = this.readMemArg();
    const addr = this.popI32();
    const ea = (addr >>> 0) + ao.offset;
    if (ea + 16 > mem.dataSize) { this.trap('v128.load out of bounds'); return; }
    const data = new Uint8Array(16);
    data.set(mem.data.subarray(ea, ea + 16));
    this.stack.push(WasmValue.v128(data));
  }

  // v128.store: write 16 bytes to memory
  private simdStore(): void {
    const mem = this.checkMem();
    const ao = this.readMemArg();
    const val = this.stack.pop()!;
    const addr = this.popI32();
    const ea = (addr >>> 0) + ao.offset;
    if (ea + 16 > mem.dataSize) { this.trap('v128.store out of bounds'); return; }
    mem.data.set(val.getAsV128(), ea);
  }

  // v128.const: read 16 bytes from bytecode as immediate
  private simdConst(): void {
    const data = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      data[i] = this.code[this.ip++];
    }
    this.stack.push(WasmValue.v128(data));
  }

  // Bitwise SIMD ops on entire v128
  private simdBitwise(op: (a: number, b: number) => number): void {
    const v2 = this.stack.pop()!;
    const v1 = this.stack.pop()!;
    const a = v1.getAsV128();
    const b = v2.getAsV128();
    const r = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      r[i] = op(a[i], b[i]) & 0xFF;
    }
    this.stack.push(WasmValue.v128(r));
  }

  private simdUnary(op: (a: number) => number): void {
    const v = this.stack.pop()!;
    const a = v.getAsV128();
    const r = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      r[i] = op(a[i]) & 0xFF;
    }
    this.stack.push(WasmValue.v128(r));
  }

  // Binary SIMD op on i32 lanes
  private simdBinOp(laneType: string, lanes: number,
    op: (a: number, b: number) => number): void {
    const v2 = this.stack.pop()!;
    const v1 = this.stack.pop()!;
    const a = new DataView(v1.getAsV128().buffer);
    const b = new DataView(v2.getAsV128().buffer);
    const r = new Uint8Array(16);
    const rv = new DataView(r.buffer);
    for (let i = 0; i < lanes; i++) {
      const av = a.getInt32(i * 4, true);
      const bv = b.getInt32(i * 4, true);
      rv.setInt32(i * 4, op(av, bv), true);
    }
    this.stack.push(WasmValue.v128(r));
  }

  private simdBinOpI64(lanes: number,
    op: (a: bigint, b: bigint) => bigint): void {
    const v2 = this.stack.pop()!;
    const v1 = this.stack.pop()!;
    const a = new DataView(v1.getAsV128().buffer);
    const b = new DataView(v2.getAsV128().buffer);
    const r = new Uint8Array(16);
    const rv = new DataView(r.buffer);
    for (let i = 0; i < lanes; i++) {
      const av = a.getBigInt64(i * 8, true);
      const bv = b.getBigInt64(i * 8, true);
      rv.setBigInt64(i * 8, (op(av, bv) & 0xFFFFFFFFFFFFFFFFn), true);
    }
    this.stack.push(WasmValue.v128(r));
  }

  // SIMD splat: replicate a scalar across v128
  private simdSplat(elemSize: number, count: number): void {
    const val = this.popI32();
    const data = new Uint8Array(16);
    const dv = new DataView(data.buffer);
    for (let i = 0; i < count; i++) {
      if (elemSize === 1) data[i] = val & 0xFF;
      else if (elemSize === 2) dv.setInt16(i * 2, val, true);
      else dv.setInt32(i * 4, val, true);
    }
    this.stack.push(WasmValue.v128(data));
  }

  private simdSplat64(): void {
    const val = this.popI64();
    const data = new Uint8Array(16);
    const dv = new DataView(data.buffer);
    dv.setBigInt64(0, val, true);
    dv.setBigInt64(8, val, true);
    this.stack.push(WasmValue.v128(data));
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GC PREFIX (0xFB) — Struct/Array/Ref operations
  // ═══════════════════════════════════════════════════════════════════════

  private dispatchGc(): void {
    const sub = this.code[this.ip++]; // single byte

    switch (sub) {
      // Struct operations
      case GcExtOp.STRUCT_NEW:          this.trap('GC struct.new not impl'); return;
      case GcExtOp.STRUCT_NEW_DEFAULT:  this.trap('GC struct.new_default not impl'); return;
      case GcExtOp.STRUCT_GET:          this.trap('GC struct.get not impl'); return;
      case GcExtOp.STRUCT_GET_S:        this.trap('GC struct.get_s not impl'); return;
      case GcExtOp.STRUCT_GET_U:        this.trap('GC struct.get_u not impl'); return;
      case GcExtOp.STRUCT_SET:          this.trap('GC struct.set not impl'); return;

      // Array operations
      case GcExtOp.ARRAY_NEW:           this.trap('GC array.new not impl'); return;
      case GcExtOp.ARRAY_NEW_DEFAULT:   this.trap('GC array.new_default not impl'); return;
      case GcExtOp.ARRAY_NEW_FIXED:     this.trap('GC array.new_fixed not impl'); return;
      case GcExtOp.ARRAY_GET:           this.trap('GC array.get not impl'); return;
      case GcExtOp.ARRAY_GET_S:         this.trap('GC array.get_s not impl'); return;
      case GcExtOp.ARRAY_GET_U:         this.trap('GC array.get_u not impl'); return;
      case GcExtOp.ARRAY_SET:           this.trap('GC array.set not impl'); return;
      case GcExtOp.ARRAY_LEN:           this.trap('GC array.len not impl'); return;

      // Ref operations
      case GcExtOp.REF_TEST:            this.trap('GC ref.test not impl'); return;
      case GcExtOp.REF_CAST:            this.trap('GC ref.cast not impl'); return;
      case GcExtOp.BR_ON_CAST:          this.trap('GC br_on_cast not impl'); return;
      case GcExtOp.BR_ON_CAST_FAIL:     this.trap('GC br_on_cast_fail not impl'); return;

      // Extern/Any conversions
      case GcExtOp.ANY_CONVERT_EXTERN:  this.trap('GC any.convert_extern not impl'); return;
      case GcExtOp.EXTERN_CONVERT_ANY:  this.trap('GC extern.convert_any not impl'); return;

      default:
        this.trap(`GC op 0x${sub.toString(16)} not impl`);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ATOMIC PREFIX (0xFE) — Single-threaded degradation
  // ═══════════════════════════════════════════════════════════════════════

  private dispatchAtomic(): void {
    const sub = this.code[this.ip++]; // single byte

    switch (sub) {
      // notify/wait/fence
      case AtomicExtOp.NOTIFY:    this.trap('atomic.notify not impl'); return;
      case AtomicExtOp.WAIT32:    this.trap('atomic.wait32 not impl'); return;
      case AtomicExtOp.WAIT64:    this.trap('atomic.wait64 not impl'); return;
      case AtomicExtOp.FENCE:     this.ip++; return; // skip reserved byte, nop

      // Atomic load → non-atomic load
      case AtomicExtOp.I32_LOAD:     this.memLoadI32(4, true); return;
      case AtomicExtOp.I64_LOAD:     this.memLoadI64(8, true); return;
      case AtomicExtOp.I32_LOAD8_U:  this.memLoadI32(1, false); return;
      case AtomicExtOp.I32_LOAD16_U: this.memLoadI32(2, false); return;
      case AtomicExtOp.I64_LOAD8_U:  this.memLoadI64(1, false); return;
      case AtomicExtOp.I64_LOAD16_U: this.memLoadI64(2, false); return;
      case AtomicExtOp.I64_LOAD32_U: this.memLoadI64(4, false); return;

      // Atomic store → non-atomic store
      case AtomicExtOp.I32_STORE:    this.memStore(4); return;
      case AtomicExtOp.I64_STORE:    this.memStore(8); return;
      case AtomicExtOp.I32_STORE8:   this.memStore(1); return;
      case AtomicExtOp.I32_STORE16:  this.memStore(2); return;
      case AtomicExtOp.I64_STORE8:   this.memStore(1); return;
      case AtomicExtOp.I64_STORE16:  this.memStore(2); return;
      case AtomicExtOp.I64_STORE32:  this.memStore(4); return;

      // Atomic RMW → non-atomic RMW (full-width)
      case AtomicExtOp.RMW_I32_ADD:     this.atomicRmwI32((a, b) => (a + b) | 0); return;
      case AtomicExtOp.RMW_I32_SUB:     this.atomicRmwI32((a, b) => (a - b) | 0); return;
      case AtomicExtOp.RMW_I32_AND:     this.atomicRmwI32((a, b) => a & b); return;
      case AtomicExtOp.RMW_I32_OR:      this.atomicRmwI32((a, b) => a | b); return;
      case AtomicExtOp.RMW_I32_XOR:     this.atomicRmwI32((a, b) => a ^ b); return;
      case AtomicExtOp.RMW_I32_XCHG:    this.atomicRmwI32((a, _b) => a); return;
      case AtomicExtOp.RMW_I32_CMPXCHG: this.trap('atomic.cmpxchg not impl'); return;

      case AtomicExtOp.RMW_I64_ADD:     this.atomicRmwI64((a, b) => a + b); return;
      case AtomicExtOp.RMW_I64_SUB:     this.atomicRmwI64((a, b) => a - b); return;
      case AtomicExtOp.RMW_I64_AND:     this.atomicRmwI64((a, b) => a & b); return;
      case AtomicExtOp.RMW_I64_OR:      this.atomicRmwI64((a, b) => a | b); return;
      case AtomicExtOp.RMW_I64_XOR:     this.atomicRmwI64((a, b) => a ^ b); return;
      case AtomicExtOp.RMW_I64_XCHG:    this.atomicRmwI64((a, _b) => a); return;
      case AtomicExtOp.RMW_I64_CMPXCHG: this.trap('atomic.cmpxchg not impl'); return;

      // Sub-word RMW (non-atomic degradation)
      case AtomicExtOp.RMW_I32_ADD8_U:  this.atomicRmwSubWord(1, (a, b) => (a + b) & 0xFF); return;
      case AtomicExtOp.RMW_I32_ADD16_U: this.atomicRmwSubWord(2, (a, b) => (a + b) & 0xFFFF); return;
      case AtomicExtOp.RMW_I64_ADD8_U:  this.atomicRmwSubWord(1, (a, b) => (a + b) & 0xFF); return;
      case AtomicExtOp.RMW_I64_ADD16_U: this.atomicRmwSubWord(2, (a, b) => (a + b) & 0xFFFF); return;
      case AtomicExtOp.RMW_I64_ADD32_U: this.atomicRmwSubWord(4, (a, b) => (a + b) >>> 0); return;

      case AtomicExtOp.RMW_I32_SUB8_U:  this.atomicRmwSubWord(1, (a, b) => (a - b) & 0xFF); return;
      case AtomicExtOp.RMW_I32_SUB16_U: this.atomicRmwSubWord(2, (a, b) => (a - b) & 0xFFFF); return;
      case AtomicExtOp.RMW_I64_SUB8_U:  this.atomicRmwSubWord(1, (a, b) => (a - b) & 0xFF); return;
      case AtomicExtOp.RMW_I64_SUB16_U: this.atomicRmwSubWord(2, (a, b) => (a - b) & 0xFFFF); return;
      case AtomicExtOp.RMW_I64_SUB32_U: this.atomicRmwSubWord(4, (a, b) => (a - b) >>> 0); return;

      case AtomicExtOp.RMW_I32_AND8_U:  this.atomicRmwSubWord(1, (a, b) => a & b); return;
      case AtomicExtOp.RMW_I32_AND16_U: this.atomicRmwSubWord(2, (a, b) => a & b); return;
      case AtomicExtOp.RMW_I64_AND8_U:  this.atomicRmwSubWord(1, (a, b) => a & b); return;
      case AtomicExtOp.RMW_I64_AND16_U: this.atomicRmwSubWord(2, (a, b) => a & b); return;
      case AtomicExtOp.RMW_I64_AND32_U: this.atomicRmwSubWord(4, (a, b) => a & b); return;

      case AtomicExtOp.RMW_I32_OR8_U:   this.atomicRmwSubWord(1, (a, b) => a | b); return;
      case AtomicExtOp.RMW_I32_OR16_U:  this.atomicRmwSubWord(2, (a, b) => a | b); return;
      case AtomicExtOp.RMW_I64_OR8_U:   this.atomicRmwSubWord(1, (a, b) => a | b); return;
      case AtomicExtOp.RMW_I64_OR16_U:  this.atomicRmwSubWord(2, (a, b) => a | b); return;
      case AtomicExtOp.RMW_I64_OR32_U:  this.atomicRmwSubWord(4, (a, b) => a | b); return;

      case AtomicExtOp.RMW_I32_XOR8_U:  this.atomicRmwSubWord(1, (a, b) => a ^ b); return;
      case AtomicExtOp.RMW_I32_XOR16_U: this.atomicRmwSubWord(2, (a, b) => a ^ b); return;
      case AtomicExtOp.RMW_I64_XOR8_U:  this.atomicRmwSubWord(1, (a, b) => a ^ b); return;
      case AtomicExtOp.RMW_I64_XOR16_U: this.atomicRmwSubWord(2, (a, b) => a ^ b); return;
      case AtomicExtOp.RMW_I64_XOR32_U: this.atomicRmwSubWord(4, (a, b) => a ^ b); return;

      default:
        this.trap(`atomic op 0x${sub.toString(16)} not impl`);
    }
  }

  /**
   * Atomic RMW on i32: load val from memory at addr, apply op(val, arg),
   * store result back, push OLD value.
   * In single-threaded mode, this is equivalent to non-atomic RMW.
   */
  private atomicRmwI32(op: (loaded: number, arg: number) => number): void {
    const mem = this.checkMem();
    const ao = this.readMemArg();
    const arg = this.popI32();
    const addr = this.popI32();
    const ea = (addr >>> 0) + ao.offset;
    if (ea + 4 > mem.dataSize) { this.trap('atomic RMW out of bounds'); return; }
    const dv = new DataView(mem.buffer);
    const loaded = dv.getInt32(ea, true);
    const result = op(loaded, arg);
    dv.setInt32(ea, result, true);
    this.pushI32(loaded);
  }

  private atomicRmwI64(op: (loaded: bigint, arg: bigint) => bigint): void {
    const mem = this.checkMem();
    const ao = this.readMemArg();
    const arg = this.popI64();
    const addr = this.popI32();
    const ea = (addr >>> 0) + ao.offset;
    if (ea + 8 > mem.dataSize) { this.trap('atomic RMW out of bounds'); return; }
    const dv = new DataView(mem.buffer);
    const loaded = dv.getBigInt64(ea, true);
    const result = op(loaded, arg) & 0xFFFFFFFFFFFFFFFFn;
    dv.setBigInt64(ea, result, true);
    this.pushI64(loaded);
  }

  /** Sub-word atomic RMW: byte/word/dword operations in single-threaded mode */
  private atomicRmwSubWord(width: number, op: (loaded: number, arg: number) => number): void {
    const mem = this.checkMem();
    const ao = this.readMemArg();
    const arg = this.popI32();
    const addr = this.popI32();
    const ea = (addr >>> 0) + ao.offset;
    if (ea + width > mem.dataSize) { this.trap('atomic RMW sub-word out of bounds'); return; }
    const dv = new DataView(mem.buffer);
    let loaded: number;
    if (width === 1) loaded = dv.getUint8(ea);
    else if (width === 2) loaded = dv.getUint16(ea, true);
    else loaded = dv.getUint32(ea, true);
    const result = op(loaded, arg);
    if (width === 1) dv.setUint8(ea, result & 0xFF);
    else if (width === 2) dv.setUint16(ea, result & 0xFFFF, true);
    else dv.setUint32(ea, result, true);
    this.pushI32(loaded);
  }
}
