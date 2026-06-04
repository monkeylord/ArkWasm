/**
 * WasmLeb128.ets — LEB128 (Little-Endian Base-128) codec for reading
 * variable-length integers from Wasm binary streams.
 *
 * LEB128 is used extensively in WebAssembly for:
 *   - Integer constants (i32.const, i64.const)
 *   - Local/global/function indices
 *   - Branch depth operands
 *   - Memory offsets and limits
 *   - Section sizes and counts
 */
import { PosRef } from './WasmTypes';

export class Leb128 {
  static readU32(data: Uint8Array, pos: PosRef): number {
    let result: number = 0;
    let shift: number = 0;
    let byte: number;
    // Max 5 bytes for u32 LEB128
    for (let i = 0; i < 5; i++) {
      byte = data[pos.v++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) {
        return result >>> 0; // ensure unsigned
      }
      shift += 7;
    }
    throw new Error('LEB128: u32 too long');
  }

  /**
   * Read a signed LEB128-encoded 32-bit integer.
   */
  static readI32(data: Uint8Array, pos: PosRef): number {
    let result: number = 0;
    let shift: number = 0;
    let byte: number;
    for (let i = 0; i < 5; i++) {
      byte = data[pos.v++];
      result |= (byte & 0x7f) << shift;
      shift += 7;
      if ((byte & 0x80) === 0) {
        // Sign extend
        if (shift < 32 && (byte & 0x40) !== 0) {
          result |= -(1 << shift);
        }
        return result;
      }
    }
    throw new Error('LEB128: i32 too long');
  }

  /**
   * Read a signed LEB128-encoded 64-bit integer as bigint.
   */
  static readI64(data: Uint8Array, pos: PosRef): bigint {
    let result: bigint = 0n;
    let shift: bigint = 0n;
    let byte: number;
    for (let i = 0; i < 10; i++) {
      byte = data[pos.v++];
      result |= BigInt(byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) {
        // Sign extend
        if (shift < 64n && (byte & 0x40) !== 0) {
          const signMask: bigint = -(1n << (shift + 7n));
          result |= signMask;
        }
        return result;
      }
      shift += 7n;
    }
    throw new Error('LEB128: i64 too long');
  }

  /**
   * Read an unsigned LEB128-encoded 64-bit integer as bigint.
   * Used for memory64 offsets/sizes.
   */
  static readU64(data: Uint8Array, pos: PosRef): bigint {
    let result: bigint = 0n;
    let shift: bigint = 0n;
    let byte: number;
    for (let i = 0; i < 10; i++) {
      byte = data[pos.v++];
      result |= BigInt(byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) {
        return result;
      }
      shift += 7n;
    }
    throw new Error('LEB128: u64 too long');
  }

  /**
   * Read a signed LEB128-encoded 33-bit integer.
   * Returns as number. Used for certain extended fields.
   */
  static readI33(data: Uint8Array, pos: PosRef): number {
    let result: number = 0;
    let shift: number = 0;
    let byte: number;
    for (let i = 0; i < 5; i++) {
      byte = data[pos.v++];
      result |= (byte & 0x7f) << shift;
      shift += 7;
      if ((byte & 0x80) === 0) {
        // sign extend bit 32 if needed
        if (shift > 32 && (byte & 0x40) !== 0) {
          result |= ~((1 << shift) - 1);
        } else if (shift === 35 && (byte & 0x40) !== 0) {
          result |= ~((1 << shift) - 1);
        }
        return result;
      }
    }
    throw new Error('LEB128: i33 too long');
  }

  /**
   * Encode a 32-bit unsigned integer to LEB128 bytes.
   */
  static encodeU32(value: number): Uint8Array {
    const bytes: number[] = [];
    let v: number = value >>> 0;
    while (v >= 0x80) {
      bytes.push((v & 0x7f) | 0x80);
      v >>>= 7;
    }
    bytes.push(v & 0x7f);
    return new Uint8Array(bytes);
  }

  /**
   * Encode a 32-bit signed integer to LEB128 bytes.
   */
  static encodeI32(value: number): Uint8Array {
    const bytes: number[] = [];
    let more: boolean = true;
    let v: number = value;
    while (more) {
      let byte: number = v & 0x7f;
      v >>= 7;
      if ((v === 0 && (byte & 0x40) === 0) ||
        (v === -1 && (byte & 0x40) !== 0)) {
        more = false;
      } else {
        byte |= 0x80;
      }
      bytes.push(byte);
    }
    return new Uint8Array(bytes);
  }

  /**
   * Peek at the next LEB128-encoded u32 without advancing.
   */
  static peekU32(data: Uint8Array, pos: number): number {
    const p: PosRef = new PosRef(pos);
    const result = Leb128.readU32(data, p);
    return result;
  }
}
