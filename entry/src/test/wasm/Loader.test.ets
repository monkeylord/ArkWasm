/**
 * Loader.test.ets — Tests for the Wasm binary loader
 */
import { describe, it, expect } from '@ohos/hypium/index';
import { WasmLoader } from '../ets/wasm/WasmLoader';
import { WasmModule } from '../ets/wasm/WasmTypes';

export default function testSuite() {
  describe('WasmLoader', () => {

    /**
     * Minimal valid Wasm module: empty function returning nothing.
     */
    const EMPTY_MODULE: Uint8Array = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d,  // magic
      0x01, 0x00, 0x00, 0x00,  // version
      // Type section: () -> ()
      0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
      // Function section: 1 func, type 0
      0x03, 0x02, 0x01, 0x00,
      // Code section: 1 func, empty body (0 locals, end)
      0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    ]);

    /**
     * Module with an exported function.
     */
    const EXPORT_MODULE: Uint8Array = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d,
      0x01, 0x00, 0x00, 0x00,
      // Type: () -> i32
      0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
      // Function: 1 func, type 0
      0x03, 0x02, 0x01, 0x00,
      // Export: "hello" (func 0)
      0x07, 0x09, 0x01, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00,
      // Code: i32.const 42, end
      0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
    ]);

    /**
     * Module with memory and table.
     */
    const MEM_TABLE_MODULE: Uint8Array = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d,
      0x01, 0x00, 0x00, 0x00,
      // Type: () -> i32
      0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
      // Function
      0x03, 0x02, 0x01, 0x00,
      // Table: 1 table, funcref, min 10
      0x04, 0x04, 0x01, 0x70, 0x00, 0x0a,
      // Memory: 1 memory, min 1 page
      0x05, 0x03, 0x01, 0x00, 0x01,
      // Code
      0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    ]);

    it('should load a minimal valid module', () => {
      const loader = new WasmLoader();
      const module = loader.load(EMPTY_MODULE);
      expect(module).assertNotNull();
      expect(module.types.length).assertEqual(1);
      expect(module.functions.length).assertEqual(1);
      expect(module.funcDescs.length).assertEqual(1);
    });

    it('should reject invalid magic number', () => {
      const loader = new WasmLoader();
      const invalidMagic = new Uint8Array([
        0x00, 0x61, 0x73, 0x6e, // wrong magic
        0x01, 0x00, 0x00, 0x00,
      ]);
      expect(() => loader.load(invalidMagic)).assertThrowsError();
    });

    it('should reject invalid version', () => {
      const loader = new WasmLoader();
      const invalidVersion = new Uint8Array([
        0x00, 0x61, 0x73, 0x6d,
        0x02, 0x00, 0x00, 0x00, // version 2
      ]);
      expect(() => loader.load(invalidVersion)).assertThrowsError();
    });

    it('should parse type section correctly', () => {
      const loader = new WasmLoader();
      const module = loader.load(EMPTY_MODULE);
      expect(module.types[0].paramTypes.length).assertEqual(0);
      expect(module.types[0].resultTypes.length).assertEqual(0);
    });

    it('should parse type section with params and results', () => {
      const loader = new WasmLoader();
      const module = loader.load(EXPORT_MODULE);
      expect(module.types[0].paramTypes.length).assertEqual(0);
      expect(module.types[0].resultTypes.length).assertEqual(1);
      expect(module.types[0].resultTypes[0]).assertEqual(0x7f); // i32
    });

    it('should parse export section', () => {
      const loader = new WasmLoader();
      const module = loader.load(EXPORT_MODULE);
      expect(module.exports.length).assertEqual(1);
      expect(module.exports[0].name).assertEqual('hello');
      expect(module.exports[0].kind).assertEqual(0); // func
      expect(module.exports[0].index).assertEqual(0);
    });

    it('should parse function section', () => {
      const loader = new WasmLoader();
      const module = loader.load(EXPORT_MODULE);
      expect(module.functions.length).assertEqual(1);
      expect(module.functions[0]).assertEqual(0); // type index 0
    });

    it('should parse code section with bytecode', () => {
      const loader = new WasmLoader();
      const module = loader.load(EXPORT_MODULE);
      expect(module.funcDescs.length).assertEqual(1);
      const func = module.funcDescs[0];
      expect(func.localTypes.length).assertEqual(0);
      expect(func.code.length).assertEqual(2); // i32.const 42, end
      expect(func.code[0]).assertEqual(0x41); // i32.const
    });

    it('should parse memory section', () => {
      const loader = new WasmLoader();
      const module = loader.load(MEM_TABLE_MODULE);
      expect(module.memories.length).assertEqual(1);
      expect(module.memories[0].initPages).assertEqual(1);
    });

    it('should parse table section', () => {
      const loader = new WasmLoader();
      const module = loader.load(MEM_TABLE_MODULE);
      expect(module.tables.length).assertEqual(1);
      expect(module.tables[0].initSize).assertEqual(10);
      expect(module.tables[0].elemType).assertEqual(0x70); // funcref
    });

    it('should compute import and function counts', () => {
      const loader = new WasmLoader();
      const module = loader.load(EMPTY_MODULE);
      expect(module.importFuncCount).assertEqual(0);
      expect(module.totalFuncCount).assertEqual(1);
      expect(module.funcDescs[0].typeIndex).assertEqual(0);
    });
  });
}
