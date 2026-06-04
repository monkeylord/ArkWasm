/**
 * WasmTypes.ets — Core type definitions for the ArkWAMR runtime.
 * Mirrors WAMR's wasm.h value types, section IDs, and structural constants.
 */

/** Mutable position reference used by LEB128 readers. */
export class PosRef {
  v: number = 0;
  constructor(v: number) { this.v = v; }
}

/** Memory argument (align + offset + memidx). */
export class MemArg {
  align: number = 0;
  offset: number = 0;
  memidx: number = 0;
  constructor(align: number = 0, offset: number = 0, memidx: number = 0) {
    this.align = align;
    this.offset = offset;
    this.memidx = memidx;
  }
}

/** Decoded LEB128 result (value + new position). */
export class DecodedLeb {
  val: number = 0;
  pos: number = 0;
  constructor(val: number, pos: number) { this.val = val; this.pos = pos; }
}

// ============================================================================
// Value Type Constants (wasm.h:21-84)
// ============================================================================
export const VALUE_TYPE_I32: number = 0x7f;
export const VALUE_TYPE_I64: number = 0x7e;
export const VALUE_TYPE_F32: number = 0x7d;
export const VALUE_TYPE_F64: number = 0x7c;
export const VALUE_TYPE_V128: number = 0x7b;
export const VALUE_TYPE_FUNCREF: number = 0x70;
export const VALUE_TYPE_EXTERNREF: number = 0x6f;
export const VALUE_TYPE_VOID: number = 0x40;
export const VALUE_TYPE_ANY: number = 0x42;

export const PACKED_TYPE_I8: number = 0x78;
export const PACKED_TYPE_I16: number = 0x77;

// Reference type constants
export const REF_TYPE_NULLFUNCREF: number = 0x73;
export const REF_TYPE_NULLEXTERNREF: number = 0x72;
export const REF_TYPE_NULLREF: number = 0x71;
export const REF_TYPE_FUNCREF: number = 0x70;
export const REF_TYPE_EXTERNREF: number = 0x6f;
export const REF_TYPE_ANYREF: number = 0x6e;
export const REF_TYPE_EQREF: number = 0x6d;
export const REF_TYPE_I31REF: number = 0x6c;
export const REF_TYPE_STRUCTREF: number = 0x6b;
export const REF_TYPE_ARRAYREF: number = 0x6a;
export const REF_TYPE_HT_NON_NULLABLE: number = 0x64;
export const REF_TYPE_HT_NULLABLE: number = 0x63;
export const REF_TYPE_STRINGREF: number = 0x67;
export const REF_TYPE_STRINGVIEWWTF8: number = 0x66;
export const REF_TYPE_STRINGVIEWWTF16: number = 0x62;
export const REF_TYPE_STRINGVIEWITER: number = 0x61;

// Heap type constants
export const HEAP_TYPE_NOFUNC: number = -0x0d;
export const HEAP_TYPE_NOEXTERN: number = -0x0e;
export const HEAP_TYPE_NONE: number = -0x0f;
export const HEAP_TYPE_FUNC: number = -0x10;
export const HEAP_TYPE_EXTERN: number = -0x11;
export const HEAP_TYPE_ANY: number = -0x12;
export const HEAP_TYPE_EQ: number = -0x13;
export const HEAP_TYPE_I31: number = -0x14;
export const HEAP_TYPE_STRUCT: number = -0x15;
export const HEAP_TYPE_ARRAY: number = -0x16;
export const HEAP_TYPE_STRINGREF: number = -0x19;
export const HEAP_TYPE_STRINGVIEWWTF8: number = -0x1a;
export const HEAP_TYPE_STRINGVIEWWTF16: number = -0x1e;
export const HEAP_TYPE_STRINGVIEWITER: number = -0x1f;

// ============================================================================
// Section IDs (wasm.h:158-176)
// ============================================================================
export const SECTION_TYPE_USER: number = 0;
export const SECTION_TYPE_TYPE: number = 1;
export const SECTION_TYPE_IMPORT: number = 2;
export const SECTION_TYPE_FUNC: number = 3;
export const SECTION_TYPE_TABLE: number = 4;
export const SECTION_TYPE_MEMORY: number = 5;
export const SECTION_TYPE_GLOBAL: number = 6;
export const SECTION_TYPE_EXPORT: number = 7;
export const SECTION_TYPE_START: number = 8;
export const SECTION_TYPE_ELEM: number = 9;
export const SECTION_TYPE_CODE: number = 10;
export const SECTION_TYPE_DATA: number = 11;
export const SECTION_TYPE_DATACOUNT: number = 12;
export const SECTION_TYPE_TAG: number = 13;
export const SECTION_TYPE_STRINGREF: number = 14;

// ============================================================================
// Import/Export Kinds (wasm.h:184-198)
// ============================================================================
export const IMPORT_KIND_FUNC: number = 0;
export const IMPORT_KIND_TABLE: number = 1;
export const IMPORT_KIND_MEMORY: number = 2;
export const IMPORT_KIND_GLOBAL: number = 3;
export const IMPORT_KIND_TAG: number = 4;

export const EXPORT_KIND_FUNC: number = 0;
export const EXPORT_KIND_TABLE: number = 1;
export const EXPORT_KIND_MEMORY: number = 2;
export const EXPORT_KIND_GLOBAL: number = 3;
export const EXPORT_KIND_TAG: number = 4;

// ============================================================================
// Label Types (wasm.h:200-208)
// ============================================================================
export const LABEL_TYPE_BLOCK: number = 0;
export const LABEL_TYPE_LOOP: number = 1;
export const LABEL_TYPE_IF: number = 2;
export const LABEL_TYPE_FUNCTION: number = 3;
export const LABEL_TYPE_TRY: number = 4;
export const LABEL_TYPE_CATCH: number = 5;
export const LABEL_TYPE_CATCH_ALL: number = 6;

// ============================================================================
// Memory constants (wasm.h:109-120)
// ============================================================================
export const DEFAULT_NUM_BYTES_PER_PAGE: number = 65536;
export const DEFAULT_MAX_PAGES: number = 65536;

export const WASM_MAGIC_NUMBER: number = 0x6d736100;
export const WASM_CURRENT_VERSION: number = 1;

// ============================================================================
// Value Types Enum (for type checking)
// ============================================================================
export const enum ValType {
  I32 = 0x7f,
  I64 = 0x7e,
  F32 = 0x7d,
  F64 = 0x7c,
  V128 = 0x7b,
  Funcref = 0x70,
  Externref = 0x6f,
  Void = 0x40,
}

export function valTypeToString(vt: number): string {
  const map: Record<number, string> = {
    0x7f: 'i32', 0x7e: 'i64', 0x7d: 'f32', 0x7c: 'f64',
    0x7b: 'v128', 0x70: 'funcref', 0x6f: 'externref', 0x40: 'void'
  };
  return map[vt] ?? `unknown(0x${vt.toString(16)})`;
}

export function isValueType(vt: number): boolean {
  return vt === VALUE_TYPE_I32 || vt === VALUE_TYPE_I64 ||
    vt === VALUE_TYPE_F32 || vt === VALUE_TYPE_F64 ||
    vt === VALUE_TYPE_V128;
}

export function valueTypeCellNum(vt: number): number {
  if (vt === VALUE_TYPE_I64 || vt === VALUE_TYPE_F64) {
    return 2;
  }
  if (vt === VALUE_TYPE_V128) {
    return 4;
  }
  return 1;
}

// ============================================================================
// WasmValue — tagged union for all Wasm value types
// ============================================================================
export class WasmValue {
  public type: number;

  // Storage fields
  public i32Val: number = 0;
  public i64Val: bigint = 0n;
  public f32Val: number = 0;
  public f64Val: number = 0;
  public v128Val: Uint8Array = new Uint8Array(16);
  public refVal: number = -1; // ref index (funcref/externref)

  constructor(type: number) {
    this.type = type;
  }

  static i32(v: number): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_I32);
    wv.i32Val = v | 0;
    return wv;
  }

  static i64(v: bigint): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_I64);
    wv.i64Val = v;
    wv.i32Val = Number(v & 0xFFFFFFFFn);
    return wv;
  }

  static f32(v: number): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_F32);
    wv.f32Val = v;
    return wv;
  }

  static f64(v: number): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_F64);
    wv.f64Val = v;
    return wv;
  }

  static funcref(idx: number): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_FUNCREF);
    wv.refVal = idx;
    return wv;
  }

  static externref(idx: number): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_EXTERNREF);
    wv.refVal = idx;
    return wv;
  }

  static v128(data: Uint8Array): WasmValue {
    const wv = new WasmValue(VALUE_TYPE_V128);
    wv.v128Val = data;
    return wv;
  }

  getAsI32(): number { return this.i32Val; }
  getAsI64(): bigint { return this.i64Val; }
  getAsF32(): number { return this.f32Val; }
  getAsF64(): number { return this.f64Val; }
  getAsV128(): Uint8Array { return this.v128Val; }
  getAsRef(): number { return this.refVal; }

  copy(): WasmValue {
    const wv = new WasmValue(this.type);
    wv.i32Val = this.i32Val;
    wv.i64Val = this.i64Val;
    wv.f32Val = this.f32Val;
    wv.f64Val = this.f64Val;
    wv.v128Val = new Uint8Array(this.v128Val);
    wv.refVal = this.refVal;
    return wv;
  }

  toString(): string {
    switch (this.type) {
      case VALUE_TYPE_I32: return `i32(${this.i32Val})`;
      case VALUE_TYPE_I64: return `i64(${this.i64Val})`;
      case VALUE_TYPE_F32: return `f32(${this.f32Val})`;
      case VALUE_TYPE_F64: return `f64(${this.f64Val})`;
      case VALUE_TYPE_FUNCREF: return `funcref(${this.refVal})`;
      case VALUE_TYPE_EXTERNREF: return `externref(${this.refVal})`;
      default: return `unknown_type(${this.type})`;
    }
  }

  equals(other: WasmValue): boolean {
    if (this.type !== other.type) {
      return false;
    }
    switch (this.type) {
      case VALUE_TYPE_I32: return this.i32Val === other.i32Val;
      case VALUE_TYPE_I64: return this.i64Val === other.i64Val;
      case VALUE_TYPE_F32: return this.f32Val === other.f32Val;
      case VALUE_TYPE_F64: return this.f64Val === other.f64Val;
      case VALUE_TYPE_FUNCREF:
      case VALUE_TYPE_EXTERNREF:
        return this.refVal === other.refVal;
      default: return false;
    }
  }
}

// ============================================================================
// FuncType — function signature
// ============================================================================
export class FuncType {
  public paramTypes: number[] = [];
  public resultTypes: number[] = [];
  public paramCellNum: number = 0;
  public retCellNum: number = 0;

  computeCells(): void {
    this.paramCellNum = 0;
    for (const pt of this.paramTypes) {
      this.paramCellNum += valueTypeCellNum(pt);
    }
    this.retCellNum = 0;
    for (const rt of this.resultTypes) {
      this.retCellNum += valueTypeCellNum(rt);
    }
  }
}

// ============================================================================
// BlockType — block signature (void, single value type, or type index)
// ============================================================================
export class BlockType {
  public isVoid: boolean = true;
  public valueType: number = 0; // non-void block
  public typeIndex: number = -1; // multi-value block (Wasm GC)

  static createVoid(): BlockType {
    return new BlockType();
  }

  static createValue(vt: number): BlockType {
    const bt = new BlockType();
    bt.isVoid = false;
    bt.valueType = vt;
    bt.typeIndex = -1;
    return bt;
  }

  static createTypeIndex(ti: number): BlockType {
    const bt = new BlockType();
    bt.isVoid = false;
    bt.typeIndex = ti;
    return bt;
  }

  getResultCount(types: FuncType[]): number {
    if (this.isVoid) {
      return 0;
    }
    if (this.typeIndex >= 0 && this.typeIndex < types.length) {
      return types[this.typeIndex].resultTypes.length;
    }
    return 1; // single value type
  }
}

// ============================================================================
// Memory/Optional memory index flags
// ============================================================================
export const OPT_MEMIDX_FLAG: number = 0x40;
export const MAX_PAGE_COUNT_FLAG: number = 0x01;
export const SHARED_MEMORY_FLAG: number = 0x02;
export const MEMORY64_FLAG: number = 0x04;
export const TABLE_INIT_EXPR_FLAG: number = 0x40;

// ============================================================================
// Function representation
// ============================================================================
export class WasmFunction {
  public typeIndex: number = 0;
  public localTypes: number[] = [];
  public localCount: number = 0;
  public paramCount: number = 0;
  public paramCellNum: number = 0;
  public localCellNum: number = 0;
  public retCellNum: number = 0;
  public code: Uint8Array = new Uint8Array(0);
  public codeOffset: number = 0; // offset within the combined code section
  public codeSize: number = 0;
}

// ============================================================================
// Global
// ============================================================================
export class WasmGlobal {
  public type: number = 0;
  public mutable: boolean = false;
  public initExprType: number = 0;
  public initValue: WasmValue | null = null;     // simple init: known at parse time
  public initExprBytes: Uint8Array | null = null; // extended: raw bytecode for runtime eval
}

// ============================================================================
// Table
// ============================================================================
export class WasmTable {
  public elemType: number = 0;
  public limitsFlags: number = 0;
  public initSize: number = 0;
  public maxSize: number = 0;
}

// ============================================================================
// Memory
// ============================================================================
export class WasmMemory {
  public limitsFlags: number = 0;
  public initPages: number = 0;
  public maxPages: number = 0;
  public isMemory64: boolean = false;
}

// ============================================================================
// Import
// ============================================================================
export class WasmImport {
  public moduleName: string = '';
  public fieldName: string = '';
  public kind: number = 0;
  public typeIndex: number = 0; // func
  public tableType: WasmTable | null = null;
  public memoryType: WasmMemory | null = null;
  public globalType: number = 0;
  public globalMutable: boolean = false;
}

// ============================================================================
// Export
// ============================================================================
export class WasmExport {
  public name: string = '';
  public kind: number = 0;
  public index: number = 0;
}

// ============================================================================
// Table Segment
// ============================================================================
export class WasmTableSeg {
  public tableIndex: number = 0;
  public elemType: number = 0;
  public initExprType: number = 0;
  public initValue: WasmValue | null = null;
  public initExprBytes: Uint8Array | null = null; // extended const expression
  public funcIndices: number[] = [];
}

// ============================================================================
// Data Segment
// ============================================================================
export class WasmDataSeg {
  public memoryIndex: number = 0;
  public initExprType: number = 0;
  public initValue: WasmValue | null = null;
  public initExprBytes: Uint8Array | null = null; // extended const expression
  public data: Uint8Array = new Uint8Array(0);
}

// ============================================================================
// Block Address — for branch targets
// ============================================================================
export class BlockAddr {
  public startAddr: number = 0;
  public elseAddr: number = 0;
  public endAddr: number = 0;
}

// ============================================================================
// Branch Block — label stack entry
// ============================================================================
export class BranchBlock {
  public labelType: number = 0;
  public beginAddr: number = 0;
  public targetAddr: number = 0;
  public frameSp: number = 0; // stack pointer when entering block
  public cellNum: number = 0; // number of cell results
  public elseAddr: number = 0;
  public endAddr: number = 0;

  constructor(lt: number, begin: number, target: number, sp: number, cn: number) {
    this.labelType = lt;
    this.beginAddr = begin;
    this.targetAddr = target;
    this.frameSp = sp;
    this.cellNum = cn;
  }
}

// ============================================================================
// Module structure
// ============================================================================
export class WasmModule {
  public types: FuncType[] = [];
  public imports: WasmImport[] = [];
  public functions: number[] = []; // type indices
  public tables: WasmTable[] = [];
  public memories: WasmMemory[] = [];
  public globals: WasmGlobal[] = [];
  public exports: WasmExport[] = [];
  public startFuncIdx: number = -1;
  public tableSegs: WasmTableSeg[] = [];
  public dataSegs: WasmDataSeg[] = [];
  public codeSection: Uint8Array = new Uint8Array(0);
  public funcDescs: WasmFunction[] = [];
  public dataCount: number = 0;

  // Computed counts
  public importFuncCount: number = 0;
  public importTableCount: number = 0;
  public importMemoryCount: number = 0;
  public importGlobalCount: number = 0;
  public totalFuncCount: number = 0;
}

// ============================================================================
// Module Instance — runtime instance
// ============================================================================
export class WasmModuleInstance {
  public module: WasmModule;
  public memories: WasmMemoryInstance[] = [];
  public tables: WasmTableInstance[] = [];
  public globalData: WasmValue[] = [];
  public funcInstances: WasmFunctionInstance[] = [];
  public exports: Map<string, WasmExport> = new Map();
  public startFuncIdx: number = -1;
  public dataSegments: WasmDataSeg[] = [];   // for memory.init / data.drop
  public elemSegments: WasmTableSeg[] = [];   // for table.init / elem.drop

  constructor(mod: WasmModule) {
    this.module = mod;
  }
}

// ============================================================================
// Memory Instance
// ============================================================================
export class WasmMemoryInstance {
  public memoryType: WasmMemory;
  public buffer: ArrayBuffer;
  public data: Uint8Array;
  public curPages: number;
  public maxPages: number;
  public isMemory64: boolean;

  constructor(memType: WasmMemory) {
    this.memoryType = memType;
    this.curPages = memType.initPages;
    this.maxPages = memType.maxPages;
    this.isMemory64 = memType.isMemory64;
    this.buffer = new ArrayBuffer(memType.initPages * DEFAULT_NUM_BYTES_PER_PAGE);
    this.data = new Uint8Array(this.buffer);
  }

  get dataSize(): number {
    return this.curPages * DEFAULT_NUM_BYTES_PER_PAGE;
  }

  grow(pages: number): number {
    const oldPages = this.curPages;
    const newPages = oldPages + pages;
    if (newPages > this.maxPages && this.maxPages > 0) {
      return -1;
    }
    if (newPages > DEFAULT_MAX_PAGES) {
      return -1;
    }
    const newBuffer = new ArrayBuffer(newPages * DEFAULT_NUM_BYTES_PER_PAGE);
    const newData = new Uint8Array(newBuffer);
    newData.set(this.data);
    this.buffer = newBuffer;
    this.data = newData;
    this.curPages = newPages;
    return oldPages;
  }
}

// ============================================================================
// Table Instance
// ============================================================================
export class WasmTableInstance {
  public tableType: WasmTable;
  public elements: number[] = []; // func indices or ref indices
  public curSize: number;
  public maxSize: number;

  constructor(tblType: WasmTable) {
    this.tableType = tblType;
    this.curSize = tblType.initSize;
    this.maxSize = tblType.maxSize;
    this.elements = new Array<number>(this.curSize);
    for (let i = 0; i < this.curSize; i++) {
      this.elements[i] = -1; // NULL_REF
    }
  }

  grow(delta: number, initVal: number): number {
    const oldSize = this.curSize;
    const newSize = oldSize + delta;
    if (this.maxSize > 0 && newSize > this.maxSize) {
      return -1;
    }
    for (let i = oldSize; i < newSize; i++) {
      this.elements.push(initVal);
    }
    this.curSize = newSize;
    return oldSize;
  }
}

// ============================================================================
// Function Instance
// ============================================================================
/**
 * Host function callback: receives Wasm arguments + linear memory reference,
 * returns Wasm result values. Throwing HostTrap signals proc_exit or similar
 * expected termination.
 */
export type HostFunction = (args: WasmValue[], memory: WasmMemoryInstance | null) => WasmValue[];

export class HostTrap extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'HostTrap';
  }
}

export class WasmFunctionInstance {
  public funcDesc: WasmFunction;
  public moduleInstance: WasmModuleInstance;
  public isImport: boolean = false;
  public hostFunc: HostFunction | null = null;  // non-null for resolved host imports

  constructor(fd: WasmFunction, mi: WasmModuleInstance) {
    this.funcDesc = fd;
    this.moduleInstance = mi;
  }
}

// ============================================================================
// Interpreter-specific: Call Frame
// ============================================================================
export class WasmInterpFrame {
  public prevFrame: WasmInterpFrame | null = null;
  public funcInst: WasmFunctionInstance;
  public ip: number = 0; // instruction pointer (index into bytecode)
  public sp: number = 0; // stack pointer (index into value stack)
  public csp: number = 0; // control stack pointer (index into label stack)
  public lp: number = 0; // local pointer (index into value stack where locals start)
  public retSp: number = 0; // return stack pointer
  public cellNum: number = 0; // total cells for this frame
  public refMap: Map<number, number> = new Map(); // offset -> type mapping for GC

  constructor(fi: WasmFunctionInstance, prev: WasmInterpFrame | null) {
    this.funcInst = fi;
    this.prevFrame = prev;
  }
}
