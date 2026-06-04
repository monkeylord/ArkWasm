/**
 * WasmLoader.ets — WebAssembly binary format loader (lightweight).
 *
 * Parses .wasm binary modules: validates the module structure,
 * decodes all sections, builds the WasmModule data structure.
 *
 * Based on WAMR's wasm_loader.c but simplified for the interpreter-only
 * ArkTS runtime — skips full type-checking validation, trusts the
 * Wasm binary to be well-formed (relies on test-driven verification).
 */

import { ByteReader } from './WasmByteReader';
import { Leb128 } from './WasmLeb128';
import {
  WasmModule,
  WasmFunction,
  WasmGlobal,
  WasmTable,
  WasmMemory,
  WasmImport,
  WasmExport,
  WasmTableSeg,
  WasmDataSeg,
  FuncType,
  WasmValue,
  BlockAddr,
  VALUE_TYPE_I32,
  VALUE_TYPE_I64,
  VALUE_TYPE_F32,
  VALUE_TYPE_F64,
  VALUE_TYPE_V128,
  VALUE_TYPE_FUNCREF,
  VALUE_TYPE_EXTERNREF,
  VALUE_TYPE_VOID,
  valueTypeCellNum,
  WASM_MAGIC_NUMBER,
  WASM_CURRENT_VERSION,
  SECTION_TYPE_TYPE,
  SECTION_TYPE_IMPORT,
  SECTION_TYPE_FUNC,
  SECTION_TYPE_TABLE,
  SECTION_TYPE_MEMORY,
  SECTION_TYPE_GLOBAL,
  SECTION_TYPE_EXPORT,
  SECTION_TYPE_START,
  SECTION_TYPE_ELEM,
  SECTION_TYPE_CODE,
  SECTION_TYPE_DATA,
  SECTION_TYPE_DATACOUNT,
  IMPORT_KIND_FUNC,
  IMPORT_KIND_TABLE,
  IMPORT_KIND_MEMORY,
  IMPORT_KIND_GLOBAL,
  EXPORT_KIND_FUNC,
  EXPORT_KIND_TABLE,
  EXPORT_KIND_MEMORY,
  EXPORT_KIND_GLOBAL,
  PosRef,
} from './WasmTypes';

export class WasmLoader {
  private reader: ByteReader = new ByteReader(new Uint8Array(0));
  private module: WasmModule = new WasmModule();

  /**
   * Load a Wasm module from raw bytes.
   */
  load(data: Uint8Array): WasmModule {
    this.reader = new ByteReader(data);
    this.module = new WasmModule();

    this.readHeader();
    this.readSections();

    this.computeCounts();
    return this.module;
  }

  /**
   * Load a Wasm module from a specific offset (for multi-module scenarios).
   */
  loadFrom(data: Uint8Array, offset: number): WasmModule {
    return this.load(data.subarray(offset));
  }

  // ==========================================================================
  // Header
  // ==========================================================================
  private readHeader(): void {
    const magic = this.reader.readU32LE();
    if (magic !== WASM_MAGIC_NUMBER) {
      throw new Error(`Invalid Wasm magic: 0x${magic.toString(16)}`);
    }
    const version = this.reader.readU32LE();
    if (version !== WASM_CURRENT_VERSION) {
      throw new Error(`Unsupported Wasm version: ${version}`);
    }
  }

  // ==========================================================================
  // Sections
  // ==========================================================================
  private readSections(): void {
    while (this.reader.hasMore) {
      const sectionId = this.reader.readU8();
      const sectionSize = this.reader.readU32();
      const sectionStart = this.reader.pos;
      const sectionEnd = this.reader.pos + sectionSize;

      switch (sectionId) {
        case SECTION_TYPE_TYPE:
          this.readTypeSection();
          break;
        case SECTION_TYPE_IMPORT:
          this.readImportSection();
          break;
        case SECTION_TYPE_FUNC:
          this.readFuncSection();
          break;
        case SECTION_TYPE_TABLE:
          this.readTableSection();
          break;
        case SECTION_TYPE_MEMORY:
          this.readMemorySection();
          break;
        case SECTION_TYPE_GLOBAL:
          this.readGlobalSection();
          break;
        case SECTION_TYPE_EXPORT:
          this.readExportSection();
          break;
        case SECTION_TYPE_START:
          this.readStartSection();
          break;
        case SECTION_TYPE_ELEM:
          this.readElemSection();
          break;
        case SECTION_TYPE_CODE:
          this.readCodeSection(sectionSize);
          break;
        case SECTION_TYPE_DATA:
          this.readDataSection();
          break;
        case SECTION_TYPE_DATACOUNT:
          this.readDataCountSection();
          break;
        default:
          // Custom or unknown section — skip
          break;
      }

      // Ensure we consumed the declared section size
      if (this.reader.pos > sectionEnd) {
        throw new Error(`Section ${sectionId} overread: ${this.reader.pos} > ${sectionEnd}`);
      }
      this.reader.pos = sectionEnd;
    }
  }

  // ==========================================================================
  // Type Section (1)
  // ==========================================================================
  private readTypeSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const form = this.reader.readU8();
      if (form !== 0x60) {
        throw new Error(`Unknown type form: 0x${form.toString(16)}`);
      }
      const ft = new FuncType();

      // Parameters
      const paramCount = this.reader.readU32();
      for (let j = 0; j < paramCount; j++) {
        ft.paramTypes.push(this.reader.readU8());
      }

      // Results
      const resultCount = this.reader.readU32();
      for (let j = 0; j < resultCount; j++) {
        ft.resultTypes.push(this.reader.readU8());
      }

      ft.computeCells();
      this.module.types.push(ft);
    }
  }

  // ==========================================================================
  // Import Section (2)
  // ==========================================================================
  private readImportSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const imp = new WasmImport();
      imp.moduleName = this.reader.readName();
      imp.fieldName = this.reader.readName();
      imp.kind = this.reader.readU8();

      switch (imp.kind) {
        case IMPORT_KIND_FUNC:
          imp.typeIndex = this.reader.readU32();
          this.module.importFuncCount++;
          break;
        case IMPORT_KIND_TABLE:
          imp.tableType = this.readTableType();
          this.module.importTableCount++;
          break;
        case IMPORT_KIND_MEMORY:
          imp.memoryType = this.readMemoryType();
          this.module.importMemoryCount++;
          break;
        case IMPORT_KIND_GLOBAL:
          imp.globalType = this.reader.readU8();
          imp.globalMutable = this.reader.readU8() !== 0;
          this.module.importGlobalCount++;
          break;
        default:
          throw new Error(`Unknown import kind: ${imp.kind}`);
      }

      this.module.imports.push(imp);
    }
  }

  // ==========================================================================
  // Function Section (3)
  // ==========================================================================
  private readFuncSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const typeIdx = this.reader.readU32();
      this.module.functions.push(typeIdx);
    }
  }

  // ==========================================================================
  // Table Section (4)
  // ==========================================================================
  private readTableSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      this.module.tables.push(this.readTableType());
    }
  }

  private readTableType(): WasmTable {
    const t = new WasmTable();
    t.elemType = this.reader.readU8();

    // Handle init_expr flag for Wasm GC (0x40 0x00 prefix)
    if (t.elemType === 0x40) {
      this.reader.readU8(); // skip 0x00
      t.elemType = this.reader.readU8();
    }

    t.limitsFlags = this.reader.readU8();
    t.initSize = this.reader.readU32();
    if ((t.limitsFlags & 0x01) !== 0) {
      t.maxSize = this.reader.readU32();
    }
    return t;
  }

  // ==========================================================================
  // Memory Section (5)
  // ==========================================================================
  private readMemorySection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      this.module.memories.push(this.readMemoryType());
    }
  }

  private readMemoryType(): WasmMemory {
    const m = new WasmMemory();
    m.limitsFlags = this.reader.readU8();
    m.isMemory64 = (m.limitsFlags & 0x04) !== 0;
    if (m.isMemory64) {
      m.initPages = Number(this.reader.readU64()); // u64 → number (pages)
      if ((m.limitsFlags & 0x01) !== 0) {
        m.maxPages = Number(this.reader.readU64());
      }
    } else {
      m.initPages = this.reader.readU32();
      if ((m.limitsFlags & 0x01) !== 0) {
        m.maxPages = this.reader.readU32();
      }
    }
    return m;
  }

  // ==========================================================================
  // Global Section (6)
  // ==========================================================================
  private readGlobalSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const g = new WasmGlobal();
      g.type = this.reader.readU8();
      g.mutable = this.reader.readU8() !== 0;
      this.parseInitExpr(g);
      this.module.globals.push(g);
    }
  }

  /**
   * Parse an init expression (up to END opcode 0x0B).
   * For simple single-instruction expressions, evaluates immediately.
   * For extended expressions (global.get + binary ops), stores raw bytes.
   */
  private parseInitExpr(target: WasmGlobal | WasmDataSeg | WasmTableSeg): void {
    const startPos = this.reader.pos;
    let exprStart = startPos;
    let simpleValue: WasmValue | null = null;

    while (true) {
      const op = this.reader.readU8();
      if (op === 0x0B) { // END
        break;
      }
      switch (op) {
        case 0x41: { // i32.const
          const p: PosRef = new PosRef(this.reader.pos);
          const v = Leb128.readI32(this.reader.data, p);
          this.reader.pos = p.v;
          simpleValue = WasmValue.i32(v);
          break;
        }
        case 0x42: { // i64.const
          const p: PosRef = new PosRef(this.reader.pos);
          const v = Leb128.readI64(this.reader.data, p);
          this.reader.pos = p.v;
          simpleValue = WasmValue.i64(v);
          break;
        }
        case 0x43: // f32.const
          simpleValue = WasmValue.f32(this.reader.readF32LE());
          break;
        case 0x44: // f64.const
          simpleValue = WasmValue.f64(this.reader.readF64LE());
          break;
        case 0x23: // global.get — extended: defer to runtime eval
          this.reader.readU32();
          simpleValue = null; // can't compute now
          break;
        case 0xD0: // ref.null
          this.reader.readU32();
          simpleValue = new WasmValue(VALUE_TYPE_FUNCREF);
          simpleValue!.refVal = -1;
          break;
        case 0xD2: { // ref.func
          const fi = this.reader.readU32();
          simpleValue = new WasmValue(VALUE_TYPE_FUNCREF);
          simpleValue!.refVal = fi;
          break;
        }
        case 0x6A: case 0x6B: case 0x6C: // i32.add/sub/mul
        case 0x7C: case 0x7D: case 0x7E: // i64.add/sub/mul
          // Extended const: binary op → defer to runtime eval
          simpleValue = null;
          break;
        default:
          throw new Error(`Unknown init expr op: 0x${op.toString(16)}`);
      }
    }

    const endPos = this.reader.pos;
    const exprLen = endPos - startPos;

    if (simpleValue !== null && exprLen <= 3) {
      // Simple single-instruction: use computed value
      target.initExprType = this.reader.data[startPos];
      target.initValue = simpleValue;
      target.initExprBytes = null;
    } else {
      // Extended expression: store raw bytes for runtime evaluation
      target.initExprType = 0;
      target.initValue = null;
      target.initExprBytes = this.reader.data.slice(startPos, endPos);
    }
  }

  private readInitExpr(op: number): WasmValue {
    // NOTE: LEB128 reads need explicit pos writeback because
    // Leb128.readI32/U32/I64 only updates the passed-in {v} object.
    // Direct reader reads (readF32LE, readF64LE) auto-advance this.reader.pos.
    switch (op) {
      case 0x41: { // i32.const
        const p: PosRef = new PosRef(this.reader.pos);
        const r = WasmValue.i32(Leb128.readI32(this.reader.data, p));
        this.reader.pos = p.v;
        return r;
      }
      case 0x42: { // i64.const
        const p: PosRef = new PosRef(this.reader.pos);
        const r = WasmValue.i64(Leb128.readI64(this.reader.data, p));
        this.reader.pos = p.v;
        return r;
      }
      case 0x43: // f32.const — auto-advances this.reader.pos
        return WasmValue.f32(this.reader.readF32LE());
      case 0x44: // f64.const — auto-advances this.reader.pos
        return WasmValue.f64(this.reader.readF64LE());
      case 0x23: { // global.get
        const p: PosRef = new PosRef(this.reader.pos);
        const idx = Leb128.readU32(this.reader.data, p);
        this.reader.pos = p.v;
        return WasmValue.i32(idx);
      }
      case 0xD0: { // ref.null
        const p: PosRef = new PosRef(this.reader.pos);
        Leb128.readU32(this.reader.data, p);
        this.reader.pos = p.v;
        return new WasmValue(VALUE_TYPE_FUNCREF);
      }
      default:
        throw new Error(`Unknown init expr op: 0x${op.toString(16)}`);
    }
  }

  // ==========================================================================
  // Export Section (7)
  // ==========================================================================
  private readExportSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const exp = new WasmExport();
      exp.name = this.reader.readName();
      exp.kind = this.reader.readU8();
      exp.index = this.reader.readU32();
      this.module.exports.push(exp);
    }
  }

  // ==========================================================================
  // Start Section (8)
  // ==========================================================================
  private readStartSection(): void {
    this.module.startFuncIdx = this.reader.readU32();
  }

  // ==========================================================================
  // Element Section (9)
  // ==========================================================================
  private readElemSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const seg = new WasmTableSeg();

      const flags = this.reader.readU32();

      if (flags === 0) {
        // Active, table 0, funcs only
        seg.tableIndex = 0;
        this.parseInitExpr(seg);
      } else if (flags === 1) {
        // Passive, elem type
        seg.elemType = this.reader.readU8();
        seg.tableIndex = -1;
      } else if (flags === 2) {
        // Active with table index
        seg.tableIndex = this.reader.readU32();
        this.parseInitExpr(seg);
        seg.elemType = this.reader.readU8(); // always 0x00 (funcref) for flag 2
      } else if (flags === 3) {
        // Declared element type
        seg.elemType = this.reader.readU8();
        seg.tableIndex = -1;
      } else if (flags === 4) {
        // Active, table, expr
        seg.tableIndex = 0;
        this.parseInitExpr(seg);
      } else if (flags === 5) {
        // Active, table idx, ref type, expr
        seg.elemType = this.reader.readU8();
        seg.tableIndex = this.reader.readU32();
        this.parseInitExpr(seg);
      } else if (flags === 6) {
        // Active, table, ref type, expr
        seg.tableIndex = this.reader.readU32();
        seg.elemType = this.reader.readU8();
        this.parseInitExpr(seg);
      } else if (flags === 7) {
        // Declared, ref type
        seg.elemType = this.reader.readU8();
        seg.tableIndex = -1;
      }

      // Read func indices
      const funcCount = this.reader.readU32();
      for (let j = 0; j < funcCount; j++) {
        seg.funcIndices.push(this.reader.readU32());
      }

      this.module.tableSegs.push(seg);
    }
  }

  // ==========================================================================
  // Code Section (10) — decode function bodies
  // ==========================================================================
  private readCodeSection(sectionSize: number): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const funcSize = this.reader.readU32();
      const funcStart = this.reader.pos;

      const func = this.readFunctionBody(funcSize);

      if (this.reader.pos > funcStart + funcSize) {
        throw new Error(`Function body overread: ${this.reader.pos} > ${funcStart + funcSize}`);
      }
      this.reader.pos = funcStart + funcSize;

      this.module.funcDescs.push(func);
    }
  }

  private readFunctionBody(bodySize: number): WasmFunction {
    const func = new WasmFunction();
    const bodyStart = this.reader.pos;

    // Local declarations
    const localDeclCount = this.reader.readU32();
    for (let i = 0; i < localDeclCount; i++) {
      const count = this.reader.readU32();
      const type = this.reader.readU8();
      for (let j = 0; j < count; j++) {
        func.localTypes.push(type);
      }
    }

    const codeStart = this.reader.pos;
    const codeSize = bodySize - (codeStart - bodyStart);

    // Read and store the bytecode
    func.code = this.reader.data.slice(codeStart, codeStart + codeSize);

    // Quick validation: check for END opcode at the end
    if (codeSize > 0 && func.code[codeSize - 1] !== 0x0B) {
      // Not necessarily an error for malformed modules, but flag it
      // Lightweight loader: trust the binary
    }

    this.reader.pos = codeStart + codeSize;
    return func;
  }

  // ==========================================================================
  // Data Section (11)
  // ==========================================================================
  private readDataSection(): void {
    const count = this.reader.readU32();
    for (let i = 0; i < count; i++) {
      const seg = new WasmDataSeg();
      const flags = this.reader.readU32();

      if (flags === 0) {
        seg.memoryIndex = 0;
        this.parseInitExpr(seg);
      } else if (flags === 1) {
        seg.memoryIndex = -1;
      } else if (flags === 2) {
        seg.memoryIndex = this.reader.readU32();
        this.parseInitExpr(seg);
      }

      seg.data = this.reader.readByteVec();
      this.module.dataSegs.push(seg);
    }
  }

  // ==========================================================================
  // Data Count Section (12)
  // ==========================================================================
  private readDataCountSection(): void {
    this.module.dataCount = this.reader.readU32();
  }

  // ==========================================================================
  // Post-load computations
  // ==========================================================================
  private computeCounts(): void {
    const mod = this.module;
    const totalFuncs = mod.importFuncCount + mod.functions.length;
    mod.totalFuncCount = totalFuncs;

    // Set type indices and local info for each function
    for (let i = 0; i < mod.funcDescs.length; i++) {
      const func = mod.funcDescs[i];
      const funcIdx = mod.importFuncCount + i;
      func.typeIndex = mod.functions[i];

      // Get type info
      if (func.typeIndex < mod.types.length) {
        const ft = mod.types[func.typeIndex];
        func.paramCount = ft.paramTypes.length;
        func.paramCellNum = ft.paramCellNum;
        func.retCellNum = ft.retCellNum;
      }
    }
  }
}
