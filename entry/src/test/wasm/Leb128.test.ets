/**
 * Leb128.test.ets — Tests for LEB128 encoding/decoding
 */
import { describe, it, expect } from '@ohos/hypium/index';
import { Leb128 } from '../ets/wasm/WasmLeb128';

export default function testSuite() {
  describe('Leb128', () => {

    describe('readU32', () => {
      it('should decode 0', () => {
        const data = new Uint8Array([0x00]);
        const pos = { v: 0 };
        expect(Leb128.readU32(data, pos)).assertEqual(0);
        expect(pos.v).assertEqual(1);
      });

      it('should decode single-byte max', () => {
        const data = new Uint8Array([0x7f]);
        const pos = { v: 0 };
        expect(Leb128.readU32(data, pos)).assertEqual(127);
      });

      it('should decode multi-byte value 128', () => {
        const data = new Uint8Array([0x80, 0x01]);
        const pos = { v: 0 };
        expect(Leb128.readU32(data, pos)).assertEqual(128);
        expect(pos.v).assertEqual(2);
      });

      it('should decode 624485', () => {
        const data = new Uint8Array([0xe5, 0x8e, 0x26]);
        const pos = { v: 0 };
        expect(Leb128.readU32(data, pos)).assertEqual(624485);
      });

      it('should decode 0xFFFFFFFF (max u32)', () => {
        const data = new Uint8Array([0xff, 0xff, 0xff, 0xff, 0x0f]);
        const pos = { v: 0 };
        expect(Leb128.readU32(data, pos)).assertEqual(0xFFFFFFFF);
      });

      it('should throw on too-long encoding', () => {
        const data = new Uint8Array([0x80, 0x80, 0x80, 0x80, 0x80, 0x01]);
        const pos = { v: 0 };
        expect(() => Leb128.readU32(data, pos)).assertThrowsError();
      });
    });

    describe('readI32', () => {
      it('should decode 0', () => {
        const data = new Uint8Array([0x00]);
        const pos = { v: 0 };
        expect(Leb128.readI32(data, pos)).assertEqual(0);
      });

      it('should decode 1', () => {
        const data = new Uint8Array([0x01]);
        expect(Leb128.readI32(data, { v: 0 })).assertEqual(1);
      });

      it('should decode -1', () => {
        const data = new Uint8Array([0x7f]);
        expect(Leb128.readI32(data, { v: 0 })).assertEqual(-1);
      });

      it('should decode -2', () => {
        const data = new Uint8Array([0x7e]);
        expect(Leb128.readI32(data, { v: 0 })).assertEqual(-2);
      });

      it('should decode -128', () => {
        const data = new Uint8Array([0x80, 0x7f]);
        expect(Leb128.readI32(data, { v: 0 })).assertEqual(-128);
      });

      it('should decode 128', () => {
        const data = new Uint8Array([0x80, 0x01]);
        expect(Leb128.readI32(data, { v: 0 })).assertEqual(128);
      });

      it('should decode -624485', () => {
        const data = new Uint8Array([0x9b, 0xf1, 0x59]);
        expect(Leb128.readI32(data, { v: 0 })).assertEqual(-624485);
      });
    });

    describe('readI64', () => {
      it('should decode 0n', () => {
        const data = new Uint8Array([0x00]);
        expect(Leb128.readI64(data, { v: 0 })).assertEqual(0n);
      });

      it('should decode 42n', () => {
        const data = new Uint8Array([0x2a]);
        expect(Leb128.readI64(data, { v: 0 })).assertEqual(42n);
      });

      it('should decode -1n', () => {
        const data = new Uint8Array([0x7f]);
        expect(Leb128.readI64(data, { v: 0 })).assertEqual(-1n);
      });

      it('should decode large positive', () => {
        const data = new Uint8Array([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]);
        // This is a large 64-bit value
        const result = Leb128.readI64(data, { v: 0 });
        expect(result).assertEqual(BigInt('9223372036854775808'));
      });
    });

    describe('encodeU32', () => {
      it('should encode 0', () => {
        const bytes = Leb128.encodeU32(0);
        expect(bytes.length).assertEqual(1);
        expect(bytes[0]).assertEqual(0);
      });

      it('should encode 127', () => {
        const bytes = Leb128.encodeU32(127);
        expect(bytes[0]).assertEqual(0x7f);
      });

      it('should encode 128 as two bytes', () => {
        const bytes = Leb128.encodeU32(128);
        expect(bytes.length).assertEqual(2);
        expect(bytes[0]).assertEqual(0x80);
        expect(bytes[1]).assertEqual(0x01);
      });

      it('should round-trip correctly', () => {
        for (const v of [0, 1, 42, 127, 128, 255, 1000, 100000, 0xFFFFFFFF]) {
          const encoded = Leb128.encodeU32(v);
          const decoded = Leb128.readU32(encoded, { v: 0 });
          expect(decoded).assertEqual(v);
        }
      });
    });

    describe('encodeI32', () => {
      it('should round-trip correctly', () => {
        for (const v of [0, 1, -1, 42, -42, 127, -128, 1000, -1000, 0x7FFFFFFF]) {
          const encoded = Leb128.encodeI32(v);
          const decoded = Leb128.readI32(encoded, { v: 0 });
          expect(decoded).assertEqual(v);
        }
      });
    });
  });
}
