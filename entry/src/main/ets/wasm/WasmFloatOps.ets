/**
 * WasmFloatOps.ets — IEEE 754 floating-point operations for WebAssembly.
 *
 * WebAssembly's floating-point semantics require specific behaviors for:
 *   - NaN canonicalization (NaNs must be "canonical NaN")
 *   - Division and truncation with exact Wasm semantics
 *   - Minimum/maximum with NaN propagation rules
 *   - Sign operations (copysign, abs, neg)
 *   - Integer conversion (trunc_s / trunc_u) with saturation
 *
 * All operations use IEEE 754 single (f32) and double (f64) precision.
 */

// ============================================================================
// NaN utilities
// ============================================================================

const F32_CANONICAL_NAN: number = 0x7fc00000; // canonical NaN for f32
const F64_CANONICAL_NAN_HI: number = 0x7FF80000; // high 32 bits of canonical f64 NaN
const F64_CANONICAL_NAN_LO: number = 0x00000000; // low 32 bits

/**
 * Returns true if the float32 value is NaN.
 */
export function isF32NaN(v: number): boolean {
  return v !== v; // NaN !== NaN
}

/**
 * Returns true if the float64 value is NaN.
 */
export function isF64NaN(v: number): boolean {
  return v !== v;
}

/**
 * Canonicalize NaN for f32 (using Math.fround).
 */
export function f32CanonicalNaN(): number {
  const buf = new ArrayBuffer(4);
  new DataView(buf).setUint32(0, F32_CANONICAL_NAN, true);
  return new DataView(buf).getFloat32(0, true);
}

/**
 * Canonicalize NaN for f64.
 */
export function f64CanonicalNaN(): number {
  const buf = new ArrayBuffer(8);
  new DataView(buf).setUint32(0, F64_CANONICAL_NAN_LO, true);
  new DataView(buf).setUint32(4, F64_CANONICAL_NAN_HI, true);
  return new DataView(buf).getFloat64(0, true);
}

/**
 * Force canonical NaN if `v` is NaN.
 * Any NaN is converted to canonical NaN.
 */
export function canonicalF32NaN(v: number): number {
  if (isF32NaN(v)) {
    return f32CanonicalNaN();
  }
  return v;
}

export function canonicalF64NaN(v: number): number {
  if (isF64NaN(v)) {
    return f64CanonicalNaN();
  }
  return v;
}

// ============================================================================
// I32 bitwise operations for float reinterpretation
// ============================================================================

/**
 * Reinterpret f32 bits as i32.
 */
export function f32ToI32(v: number): number {
  const buf = new ArrayBuffer(4);
  new DataView(buf).setFloat32(0, v, true);
  return new DataView(buf).getInt32(0, true);
}

/**
 * Reinterpret i32 bits as f32.
 */
export function i32ToF32(v: number): number {
  const buf = new ArrayBuffer(4);
  new DataView(buf).setInt32(0, v, true);
  return new DataView(buf).getFloat32(0, true);
}

/**
 * Reinterpret f64 bits as i64 (bigint).
 */
export function f64ToI64(v: number): bigint {
  const buf = new ArrayBuffer(8);
  new DataView(buf).setFloat64(0, v, true);
  const lo = new DataView(buf).getUint32(0, true);
  const hi = new DataView(buf).getUint32(4, true);
  return (BigInt(hi) << 32n) | BigInt(lo);
}

/**
 * Reinterpret i64 (bigint) bits as f64.
 */
export function i64ToF64(v: bigint): number {
  const buf = new ArrayBuffer(8);
  const lo = Number(v & 0xFFFFFFFFn);
  const hi = Number((v >> 32n) & 0xFFFFFFFFn);
  new DataView(buf).setUint32(0, lo, true);
  new DataView(buf).setUint32(4, hi, true);
  return new DataView(buf).getFloat64(0, true);
}

// ============================================================================
// F32 specific operations
// ============================================================================

export function f32Abs(v: number): number {
  return Math.abs(v);
}

export function f32Neg(v: number): number {
  return -v;
}

export function f32Ceil(v: number): number {
  return Math.fround(Math.ceil(v));
}

export function f32Floor(v: number): number {
  return Math.fround(Math.floor(v));
}

export function f32Trunc(v: number): number {
  return Math.fround(Math.trunc(v));
}

export function f32Nearest(v: number): number {
  // Wasm spec: round ties to even (banker's rounding), not Math.round's half-up
  const r = Math.fround(v);
  const floor = Math.floor(r);
  const frac = r - floor;
  if (frac > 0.5) { return Math.fround(floor + 1); }
  if (frac < 0.5) { return Math.fround(floor); }
  // tie: round to even
  return Math.fround(floor % 2 === 0 ? floor : floor + 1);
}

export function f32Sqrt(v: number): number {
  return Math.fround(Math.sqrt(v));
}

export function f32Add(a: number, b: number): number {
  return Math.fround(a + b);
}

export function f32Sub(a: number, b: number): number {
  return Math.fround(a - b);
}

export function f32Mul(a: number, b: number): number {
  return Math.fround(a * b);
}

export function f32Div(a: number, b: number): number {
  return Math.fround(a / b);
}

export function f32Min(a: number, b: number): number {
  // Wasm spec: if either is NaN, return an input NaN (not freshly canonicalized)
  if (isF32NaN(a)) { return a; }
  if (isF32NaN(b)) { return b; }
  // Wasm min: if either is -0 or +0, return -0
  if (a === 0 && b === 0) {
    return (1 / a < 0 || 1 / b < 0) ? -0 : 0;
  }
  return Math.min(a, b);
}

export function f32Max(a: number, b: number): number {
  // Wasm spec: NaN propagation
  if (isF32NaN(a)) { return a; }
  if (isF32NaN(b)) { return b; }
  // Wasm max: if either is -0 or +0, return +0
  if (a === 0 && b === 0) {
    return (1 / a > 0 || 1 / b > 0) ? 0 : -0;
  }
  return Math.max(a, b);
}

export function f32Copysign(a: number, b: number): number {
  // Wasm spec: return a with the sign of b. Don't use Math.sign (returns 0/-0).
  const absA = Math.abs(a);
  return (b < 0 || (1 / b === -Infinity)) ? -absA : absA;
}

export function f32Eq(a: number, b: number): number {
  return (a === b) ? 1 : 0;
}

export function f32Ne(a: number, b: number): number {
  return (a !== b) ? 1 : 0;
}

export function f32Lt(a: number, b: number): number {
  return (a < b) ? 1 : 0;
}

export function f32Gt(a: number, b: number): number {
  return (a > b) ? 1 : 0;
}

export function f32Le(a: number, b: number): number {
  return (a <= b) ? 1 : 0;
}

export function f32Ge(a: number, b: number): number {
  return (a >= b) ? 1 : 0;
}

export function f64Eq(a: number, b: number): number { return (a === b) ? 1 : 0; }
export function f64Ne(a: number, b: number): number { return (a !== b) ? 1 : 0; }
export function f64Lt(a: number, b: number): number { return (a < b) ? 1 : 0; }
export function f64Gt(a: number, b: number): number { return (a > b) ? 1 : 0; }
export function f64Le(a: number, b: number): number { return (a <= b) ? 1 : 0; }
export function f64Ge(a: number, b: number): number { return (a >= b) ? 1 : 0; }

// ============================================================================
// F64 specific operations
// ============================================================================

export function f64Abs(v: number): number { return Math.abs(v); }
export function f64Neg(v: number): number { return -v; }
export function f64Ceil(v: number): number { return Math.ceil(v); }
export function f64Floor(v: number): number { return Math.floor(v); }
export function f64Trunc(v: number): number { return Math.trunc(v); }
export function f64Nearest(v: number): number {
  const floor = Math.floor(v);
  const frac = v - floor;
  if (frac > 0.5) { return floor + 1; }
  if (frac < 0.5) { return floor; }
  return floor % 2 === 0 ? floor : floor + 1;
}
export function f64Sqrt(v: number): number { return Math.sqrt(v); }
export function f64Add(a: number, b: number): number { return a + b; }
export function f64Sub(a: number, b: number): number { return a - b; }
export function f64Mul(a: number, b: number): number { return a * b; }
export function f64Div(a: number, b: number): number { return a / b; }

export function f64Min(a: number, b: number): number {
  if (isF64NaN(a)) { return a; }
  if (isF64NaN(b)) { return b; }
  if (a === 0 && b === 0) {
    return (1 / a < 0 || 1 / b < 0) ? -0 : 0;
  }
  return Math.min(a, b);
}

export function f64Max(a: number, b: number): number {
  if (isF64NaN(a)) { return a; }
  if (isF64NaN(b)) { return b; }
  if (a === 0 && b === 0) {
    return (1 / a > 0 || 1 / b > 0) ? 0 : -0;
  }
  return Math.max(a, b);
}

export function f64Copysign(a: number, b: number): number {
  const absA = Math.abs(a);
  return (b < 0 || (1 / b === -Infinity)) ? -absA : absA;
}

// ============================================================================
// I32 bitwise operations
// ============================================================================

export function i32Clz(v: number): number {
  v = v | 0;
  if (v === 0) return 32;
  let n: number = 0;
  if ((v & 0xFFFF0000) === 0) { n += 16; v <<= 16; }
  if ((v & 0xFF000000) === 0) { n += 8; v <<= 8; }
  if ((v & 0xF0000000) === 0) { n += 4; v <<= 4; }
  if ((v & 0xC0000000) === 0) { n += 2; v <<= 2; }
  if ((v & 0x80000000) === 0) { n += 1; }
  return n;
}

export function i32Ctz(v: number): number {
  v = v | 0;
  if (v === 0) {
    return 32;
  }
  // count trailing zeros
  let count = 0;
  while ((v & 1) === 0) {
    v >>>= 1;
    count++;
  }
  return count;
}

export function i32Popcnt(v: number): number {
  v = v | 0;
  v = v - ((v >>> 1) & 0x55555555);
  v = (v & 0x33333333) + ((v >>> 2) & 0x33333333);
  v = (v + (v >>> 4)) & 0x0F0F0F0F;
  v = v * 0x01010101 >>> 24;
  return v;
}

export function i32Add(a: number, b: number): number { return ((a | 0) + (b | 0)) | 0; }
export function i32Sub(a: number, b: number): number { return ((a | 0) - (b | 0)) | 0; }
export function i32Mul(a: number, b: number): number { return Math.imul(a, b); }

export function i32DivS(a: number, b: number): number {
  a = a | 0; b = b | 0;
  if (b === 0) { throw new Error('integer divide by zero'); }
  // Wasm spec: INT32_MIN / -1 must trap (integer overflow)
  if (a === -2147483648 && b === -1) { throw new Error('integer overflow'); }
  return Math.trunc(a / b) | 0;
}

export function i32DivU(a: number, b: number): number {
  a = a >>> 0; b = b >>> 0;
  if (b === 0) { throw new Error('integer divide by zero'); }
  return Math.trunc(a / b) >>> 0;
}

export function i32RemS(a: number, b: number): number {
  a = a | 0; b = b | 0;
  if (b === 0) { throw new Error('integer remainder by zero'); }
  return (a % b) | 0;
}

export function i32RemU(a: number, b: number): number {
  a = a >>> 0; b = b >>> 0;
  if (b === 0) { throw new Error('integer remainder by zero'); }
  return (a % b) >>> 0;
}

export function i32And(a: number, b: number): number { return (a & b) | 0; }
export function i32Or(a: number, b: number): number { return (a | b) | 0; }
export function i32Xor(a: number, b: number): number { return (a ^ b) | 0; }
export function i32Shl(a: number, b: number): number { return (a << (b & 0x1f)) | 0; }
export function i32ShrS(a: number, b: number): number { return (a >> (b & 0x1f)) | 0; }
export function i32ShrU(a: number, b: number): number { return (a >>> (b & 0x1f)) >>> 0; }

export function i32Rotl(a: number, b: number): number {
  b = b & 0x1f;
  a = a >>> 0;
  return ((a << b) | (a >>> (32 - b))) >>> 0;
}

export function i32Rotr(a: number, b: number): number {
  b = b & 0x1f;
  a = a >>> 0;
  return ((a >>> b) | (a << (32 - b))) >>> 0;
}

export function i32Eqz(a: number): number { return (a | 0) === 0 ? 1 : 0; }
export function i32Eq(a: number, b: number): number { return (a | 0) === (b | 0) ? 1 : 0; }
export function i32Ne(a: number, b: number): number { return (a | 0) !== (b | 0) ? 1 : 0; }
export function i32LtS(a: number, b: number): number { return (a | 0) < (b | 0) ? 1 : 0; }
export function i32LtU(a: number, b: number): number { return (a >>> 0) < (b >>> 0) ? 1 : 0; }
export function i32GtS(a: number, b: number): number { return (a | 0) > (b | 0) ? 1 : 0; }
export function i32GtU(a: number, b: number): number { return (a >>> 0) > (b >>> 0) ? 1 : 0; }
export function i32LeS(a: number, b: number): number { return (a | 0) <= (b | 0) ? 1 : 0; }
export function i32LeU(a: number, b: number): number { return (a >>> 0) <= (b >>> 0) ? 1 : 0; }
export function i32GeS(a: number, b: number): number { return (a | 0) >= (b | 0) ? 1 : 0; }
export function i32GeU(a: number, b: number): number { return (a >>> 0) >= (b >>> 0) ? 1 : 0; }

// ============================================================================
// I64 bitwise operations (bigint)
// ============================================================================

const I64_MASK: bigint = 0xFFFFFFFFFFFFFFFFn;
const I64_SIGN_BIT: bigint = 0x8000000000000000n;
const I64_U32_MASK: bigint = 0xFFFFFFFFn;

export function i64And(a: bigint, b: bigint): bigint { return a & b; }
export function i64Or(a: bigint, b: bigint): bigint { return a | b; }
export function i64Xor(a: bigint, b: bigint): bigint { return a ^ b; }
function i64Wrap(v: bigint): bigint { return v & I64_MASK; }
function i64SignExtend(v: bigint): bigint {
  if (v & I64_SIGN_BIT) {
    return v | ~I64_MASK;
  }
  return v & I64_MASK;
}

export function i64Clz(v: bigint): number {
  v = i64Wrap(v);
  if (v === 0n) { return 64; }
  let count = 0;
  let mask = BigInt(1) << BigInt(63);
  while ((v & mask) === 0n) {
    count++;
    v <<= 1n;
  }
  return count;
}

export function i64Ctz(v: bigint): number {
  v = i64Wrap(v);
  if (v === 0n) { return 64; }
  let count = 0;
  while ((v & 1n) === 0n) {
    v >>= 1n;
    count++;
  }
  return count;
}

export function i64Popcnt(v: bigint): number {
  v = i64Wrap(v);
  let count = 0;
  while (v !== 0n) {
    count += Number(v & 1n);
    v >>= 1n;
  }
  return count;
}

export function i64Add(a: bigint, b: bigint): bigint { return i64Wrap(a + b); }
export function i64Sub(a: bigint, b: bigint): bigint { return i64Wrap(a - b); }
export function i64Mul(a: bigint, b: bigint): bigint { return i64Wrap(a * b); }

export function i64DivS(a: bigint, b: bigint): bigint {
  a = i64SignExtend(a);
  b = i64SignExtend(b);
  if (b === 0n) { throw new Error('i64 divide by zero'); }
  if (a === (1n << 63n) && b === -1n) { throw new Error('i64 overflow'); }
  return i64Wrap(a / b);
}

export function i64DivU(a: bigint, b: bigint): bigint {
  a = i64Wrap(a); b = i64Wrap(b);
  if (b === 0n) { throw new Error('i64 divide by zero'); }
  return a / b;
}

export function i64RemS(a: bigint, b: bigint): bigint {
  a = i64SignExtend(a);
  b = i64SignExtend(b);
  if (b === 0n) { throw new Error('i64 remainder by zero'); }
  return i64SignExtend(a % b);
}

export function i64RemU(a: bigint, b: bigint): bigint {
  a = i64Wrap(a); b = i64Wrap(b);
  if (b === 0n) { throw new Error('i64 remainder by zero'); }
  return a % b;
}

export function i64Shl(a: bigint, b: bigint): bigint { return i64Wrap(i64Wrap(a) << (b & 63n)); }
export function i64ShrS(a: bigint, b: bigint): bigint {
  return i64SignExtend(a) >> (b & 63n);
}
export function i64ShrU(a: bigint, b: bigint): bigint {
  return i64Wrap(a) >> (b & 63n);
}

export function i64Eqz(a: bigint): number { return i64Wrap(a) === 0n ? 1 : 0; }
export function i64Eq(a: bigint, b: bigint): number { return i64Wrap(a) === i64Wrap(b) ? 1 : 0; }
export function i64Ne(a: bigint, b: bigint): number { return i64Wrap(a) !== i64Wrap(b) ? 1 : 0; }
export function i64LtS(a: bigint, b: bigint): number { return i64SignExtend(a) < i64SignExtend(b) ? 1 : 0; }
export function i64LtU(a: bigint, b: bigint): number { return i64Wrap(a) < i64Wrap(b) ? 1 : 0; }
export function i64GtS(a: bigint, b: bigint): number { return i64SignExtend(a) > i64SignExtend(b) ? 1 : 0; }
export function i64GtU(a: bigint, b: bigint): number { return i64Wrap(a) > i64Wrap(b) ? 1 : 0; }
export function i64LeS(a: bigint, b: bigint): number { return i64SignExtend(a) <= i64SignExtend(b) ? 1 : 0; }
export function i64LeU(a: bigint, b: bigint): number { return i64Wrap(a) <= i64Wrap(b) ? 1 : 0; }
export function i64GeS(a: bigint, b: bigint): number { return i64SignExtend(a) >= i64SignExtend(b) ? 1 : 0; }
export function i64GeU(a: bigint, b: bigint): number { return i64Wrap(a) >= i64Wrap(b) ? 1 : 0; }

export function i64Rotl(a: bigint, b: bigint): bigint {
  b = b & 63n;
  a = i64Wrap(a);
  return i64Wrap((a << b) | (a >> (64n - b)));
}

export function i64Rotr(a: bigint, b: bigint): bigint {
  b = b & 63n;
  a = i64Wrap(a);
  return i64Wrap((a >> b) | (a << (64n - b)));
}

// ============================================================================
// Conversions (between integer and float)
// ============================================================================

export function i32TruncSF32(v: number): number {
  if (isF32NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < -2147483648 || res > 2147483647) { throw new Error('integer overflow'); }
  return res | 0;
}

export function i32TruncUF32(v: number): number {
  if (isF32NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < 0 || res > 4294967295) { throw new Error('integer overflow'); }
  return res >>> 0;
}

export function i32TruncSF64(v: number): number {
  if (isF64NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < -2147483648 || res > 2147483647) { throw new Error('integer overflow'); }
  return res | 0;
}

export function i32TruncUF64(v: number): number {
  if (isF64NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < 0 || res > 4294967295) { throw new Error('integer overflow'); }
  return res >>> 0;
}

export function i32TruncSatSF32(v: number): number {
  if (isF32NaN(v)) { return 0; }
  const res = Math.trunc(v);
  if (res < -2147483648) { return -2147483648; }
  if (res > 2147483647) { return 2147483647; }
  return res | 0;
}

export function i32TruncSatUF32(v: number): number {
  if (isF32NaN(v)) { return 0; }
  const res = Math.trunc(v);
  if (res < 0) { return 0; }
  if (res > 4294967295) { return 4294967295 >>> 0; }
  return res >>> 0;
}

export function i32TruncSatSF64(v: number): number {
  if (isF64NaN(v)) { return 0; }
  const res = Math.trunc(v);
  if (res < -2147483648) { return -2147483648; }
  if (res > 2147483647) { return 2147483647; }
  return res | 0;
}

export function i32TruncSatUF64(v: number): number {
  if (isF64NaN(v)) { return 0; }
  const res = Math.trunc(v);
  if (res < 0) { return 0; }
  if (res > 4294967295) { return 4294967295 >>> 0; }
  return res >>> 0;
}

// ============================================================================
// I64 Saturating Truncation (Misc 0xFC prefix)
// ============================================================================

const I64_S_MIN: bigint = -9223372036854775808n;
const I64_U_MAX: bigint = 18446744073709551615n;

export function i64TruncSatSF32(v: number): bigint {
  if (isF32NaN(v)) { return 0n; }
  const res = Math.trunc(v);
  if (res < -9223372036854775808) { return I64_S_MIN; }
  if (res > 9223372036854775807) { return 9223372036854775807n; }
  return BigInt.asIntN(64, BigInt(Math.trunc(v)));
}

export function i64TruncSatUF32(v: number): bigint {
  if (isF32NaN(v)) { return 0n; }
  const res = Math.trunc(v);
  if (res < 0) { return 0n; }
  if (res > 18446744073709551615) { return I64_U_MAX; }
  return BigInt.asUintN(64, BigInt(Math.trunc(v)));
}

export function i64TruncSatSF64(v: number): bigint {
  if (isF64NaN(v)) { return 0n; }
  const res = Math.trunc(v);
  if (res < -9223372036854775808) { return I64_S_MIN; }
  if (res > 9223372036854775807) { return 9223372036854775807n; }
  return BigInt.asIntN(64, BigInt(Math.trunc(v)));
}

export function i64TruncSatUF64(v: number): bigint {
  if (isF64NaN(v)) { return 0n; }
  const res = Math.trunc(v);
  if (res < 0) { return 0n; }
  if (res > 18446744073709551615) { return I64_U_MAX; }
  return BigInt.asUintN(64, BigInt(Math.trunc(v)));
}

// ============================================================================
// I64↔Float conversions
// ============================================================================

export function i64TruncSF32(v: number): bigint {
  if (isF32NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < -9223372036854775808 || res > 9223372036854775807) {
    throw new Error('integer overflow');
  }
  return BigInt.asIntN(64, BigInt(Math.trunc(v)));
}

export function i64TruncUF32(v: number): bigint {
  if (isF32NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < 0 || res > 18446744073709551615) {
    throw new Error('integer overflow');
  }
  return BigInt.asUintN(64, BigInt(Math.trunc(v)));
}

export function i64TruncSF64(v: number): bigint {
  if (isF64NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < -9223372036854775808 || res > 9223372036854775807) {
    throw new Error('integer overflow');
  }
  return BigInt.asIntN(64, BigInt(Math.trunc(v)));
}

export function i64TruncUF64(v: number): bigint {
  if (isF64NaN(v)) { throw new Error('invalid conversion to integer'); }
  const res = Math.trunc(v);
  if (res < 0 || res > 18446744073709551615) {
    throw new Error('integer overflow');
  }
  return BigInt.asUintN(64, BigInt(Math.trunc(v)));
}

export function f32ConvertSI64(v: bigint): number {
  return Math.fround(Number(BigInt.asIntN(64, v)));
}

export function f32ConvertUI64(v: bigint): number {
  return Math.fround(Number(v & I64_MASK));
}

export function f64ConvertSI64(v: bigint): number {
  return Number(BigInt.asIntN(64, v));
}

export function f64ConvertUI64(v: bigint): number {
  return Number(v & I64_MASK);
}

export function i64ExtendSI32(v: number): bigint {
  return BigInt.asIntN(64, BigInt(v | 0));
}

export function i64ExtendUI32(v: number): bigint {
  return BigInt.asUintN(64, BigInt(v >>> 0));
}

export function i32WrapI64(v: bigint): number {
  return Number(v & I64_U32_MASK) | 0;
}

export function f32ConvertSI32(v: number): number {
  return Math.fround(v | 0);
}

export function f32ConvertUI32(v: number): number {
  return Math.fround(v >>> 0);
}

export function f64ConvertSI32(v: number): number {
  return v | 0;
}

export function f64ConvertUI32(v: number): number {
  return v >>> 0;
}

export function f64PromoteF32(v: number): number {
  return v;
}

export function f32DemoteF64(v: number): number {
  return Math.fround(v);
}

// ============================================================================
// Sign extension (post-MVP)
// ============================================================================

export function i32Extend8S(v: number): number {
  return (v << 24) >> 24;
}

export function i32Extend16S(v: number): number {
  return (v << 16) >> 16;
}

export function i64Extend8S(v: bigint): bigint {
  return BigInt.asIntN(64, (v & 0xFFn) | ((v & 0x80n) !== 0n ? ~0xFFn : 0n));
}

export function i64Extend16S(v: bigint): bigint {
  return BigInt.asIntN(64, (v & 0xFFFFn) | ((v & 0x8000n) !== 0n ? ~0xFFFFn : 0n));
}

export function i64Extend32S(v: bigint): bigint {
  return BigInt.asIntN(64, (v & 0xFFFFFFFFn) | ((v & 0x80000000n) !== 0n ? ~0xFFFFFFFFn : 0n));
}

// ============================================================================
// Aggregate exports for easy access
// (End of WasmFloatOps)
