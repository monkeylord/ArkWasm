/**
 * wasm/Index.ets — Barrel export for the ArkWASM module
 */
export { WasmOp, GcExtOp, MiscExtOp, SimdExtOp, AtomicExtOp, OPCODE_TABLE, OPCODE_MAP, OpcodeCategory } from './WasmOpcode';
export type { OpcodeInfo } from './WasmOpcode';
export {
  WasmValue, WasmModule, WasmModuleInstance,
  WasmFunction, WasmFunctionInstance,
  WasmMemoryInstance, WasmTableInstance,
  WasmMemory, WasmTable, WasmGlobal,
  WasmImport, WasmExport, WasmDataSeg, WasmTableSeg,
  FuncType, BlockType, BlockAddr, BranchBlock, WasmInterpFrame,
  VALUE_TYPE_I32, VALUE_TYPE_I64, VALUE_TYPE_F32, VALUE_TYPE_F64,
  VALUE_TYPE_V128, VALUE_TYPE_FUNCREF, VALUE_TYPE_EXTERNREF,
  VALUE_TYPE_VOID, valueTypeCellNum,
  HostTrap
} from './WasmTypes';
export type { HostFunction } from './WasmTypes';
export { WasmLoader } from './WasmLoader';
export { WasmRuntime, DefaultImportProvider } from './WasmRuntime';
export type { ImportProvider } from './WasmRuntime';
export { WasmInterpreter } from './WasmInterpreter';
export type { InterpResult } from './WasmInterpreter';
export { Leb128 } from './WasmLeb128';
export { WasiProvider, createDefaultWasiEnv } from './wasi/WasiProvider';
export type { WasiEnv } from './wasi/WasiProvider';
