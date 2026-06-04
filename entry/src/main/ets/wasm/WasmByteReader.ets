/**
 * WasmByteReader.ets — Sequential byte reader for parsing Wasm binary format.
 * Provides read methods for all WebAssembly binary primitives (u8, u16, u32,
 * u64, f32, f64, vectors, names, and LEB128-encoded integers).
 */

import { Leb128 } from './WasmLeb128';
import { PosRef, MemArg } from './WasmTypes';

export class ByteReader {
  public data: Uint8Array;
  public pos: number = 0; // mutable position for LEB128 compat

  private view: DataView;

  constructor(data: Uint8Array, pos: number = 0) {
    this.data = data;
    this.pos = pos;
    this.view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  }

  get remaining(): number {
    return this.data.length - this.pos;
  }

  get length(): number {
    return this.data.length;
  }

  get hasMore(): boolean {
    return this.pos < this.data.length;
  }

  /** Read single byte */
  readU8(): number {
    if (this.pos >= this.data.length) {
      throw new Error('ByteReader: unexpected end of data');
    }
    return this.data[this.pos++];
  }

  /** Read little-endian uint16 */
  readU16LE(): number {
    if (this.pos + 2 > this.data.length) {
      throw new Error('ByteReader: unexpected end of data (u16)');
    }
    const v = this.view.getUint16(this.pos, true);
    this.pos += 2;
    return v;
  }

  /** Read little-endian uint32 */
  readU32LE(): number {
    if (this.pos + 4 > this.data.length) {
      throw new Error('ByteReader: unexpected end of data (u32)');
    }
    const v = this.view.getUint32(this.pos, true);
    this.pos += 4;
    return v;
  }

  /** Read little-endian float32 */
  readF32LE(): number {
    if (this.pos + 4 > this.data.length) {
      throw new Error('ByteReader: unexpected end of data (f32)');
    }
    const v = this.view.getFloat32(this.pos, true);
    this.pos += 4;
    return v;
  }

  /** Read little-endian float64 */
  readF64LE(): number {
    if (this.pos + 8 > this.data.length) {
      throw new Error('ByteReader: unexpected end of data (f64)');
    }
    const v = this.view.getFloat64(this.pos, true);
    this.pos += 8;
    return v;
  }

  /** Read little-endian uint64 as bigint */
  readU64LE(): bigint {
    if (this.pos + 8 > this.data.length) {
      throw new Error('ByteReader: unexpected end of data (u64)');
    }
    const lo = this.view.getUint32(this.pos, true);
    const hi = this.view.getUint32(this.pos + 4, true);
    this.pos += 8;
    return (BigInt(hi) << 32n) | BigInt(lo);
  }

  /** Read LEB128 unsigned 32-bit */
  readU32(): number {
    const posRef: PosRef = new PosRef(this.pos);
    const result = Leb128.readU32(this.data, posRef);
    this.pos = posRef.v;
    return result;
  }

  /** Read LEB128 signed 32-bit */
  readI32(): number {
    const posRef: PosRef = new PosRef(this.pos);
    const result = Leb128.readI32(this.data, posRef);
    this.pos = posRef.v;
    return result;
  }

  /** Read LEB128 signed 64-bit */
  readI64(): bigint {
    const posRef: PosRef = new PosRef(this.pos);
    const result = Leb128.readI64(this.data, posRef);
    this.pos = posRef.v;
    return result;
  }

  /** Read LEB128 unsigned 64-bit (used for memory64 page counts) */
  readU64(): bigint {
    const posRef: PosRef = new PosRef(this.pos);
    const result = Leb128.readU64(this.data, posRef);
    this.pos = posRef.v;
    return result;
  }

  /** Read a length-prefixed name (u32 length + UTF-8 bytes) */
  readName(): string {
    const len = this.readU32();
    if (this.pos + len > this.data.length) {
      throw new Error('ByteReader: name exceeds data boundary');
    }
    const bytes = this.data.subarray(this.pos, this.pos + len);
    this.pos += len;
    // Manual UTF-8 decode (ArkTS compatible — no TextDecoder)
    let result: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const b0: number = bytes[i++];
      let cp: number;
      if (b0 < 0x80) {
        cp = b0;
      } else if ((b0 & 0xe0) === 0xc0 && i < bytes.length) {
        cp = ((b0 & 0x1f) << 6) | (bytes[i++] & 0x3f);
      } else if ((b0 & 0xf0) === 0xe0 && i + 1 < bytes.length) {
        cp = ((b0 & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      } else if ((b0 & 0xf8) === 0xf0 && i + 2 < bytes.length) {
        cp = ((b0 & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      } else {
        cp = 0xfffd; // replacement char
      }
      result += String.fromCharCode(cp);
    }
    return result;
  }

  /** Read `count` bytes as Uint8Array */
  readBytes(count: number): Uint8Array {
    if (this.pos + count > this.data.length) {
      throw new Error('ByteReader: readBytes exceeds data boundary');
    }
    const bytes = this.data.slice(this.pos, this.pos + count);
    this.pos += count;
    return bytes;
  }

  /** Read a length-prefixed byte vector */
  readByteVec(): Uint8Array {
    const len = this.readU32();
    return this.readBytes(len);
  }

  /** Read the memarg: alignment (LEB u32) + offset (LEB u32) */
  readMemArg(): MemArg {
    const result: MemArg = new MemArg();
    result.align = this.readU32();
    result.offset = this.readU32();
    return result;
  }

  /** Peek at the next byte without consuming */
  peek(): number {
    if (this.pos >= this.data.length) {
      return -1;
    }
    return this.data[this.pos];
  }

  /** Skip n bytes */
  skip(n: number): void {
    if (this.pos + n > this.data.length) {
      throw new Error('ByteReader: skip exceeds data boundary');
    }
    this.pos += n;
  }

  /** Clone a sub-reader at a specific position */
  subReader(start: number, length: number): ByteReader {
    return new ByteReader(this.data.subarray(start, start + length));
  }

  /** Create a reader from a specific position */
  static from(data: Uint8Array, start: number = 0): ByteReader {
    return new ByteReader(data, start);
  }
}
