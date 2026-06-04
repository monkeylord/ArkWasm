# ArkWASM — 需求规格说明书

> 目标：计算机本科毕业生可在 1 小时内理解项目全貌、定位 Bug、扩展功能。

---

## 目录

1. 项目概述
2. 栈式虚拟机模型
3. 模块详解
4. 关键算法
5. 执行流程
6. Host Import 体系
7. 构建与测试体系
8. 错误处理
9. 排错指南
10. 扩展开发
11. 已知 Bug 与修复历史
12. 与 Wasm 规范已知差异
13. 附录

---

## 1. 项目概述

### 1.1 是什么

ArkWASM 是一个纯 TypeScript 实现的 WebAssembly 解释器。加载 `.wasm` 二进制文件，逐条解释执行。不依赖 C/C++ 原生代码，完全在 JavaScript 引擎中运行。

### 1.2 规模

| 指标 | 值 |
|------|-----|
| 源文件 | 9 个 `.ets` |
| 测试用例 | 263 |
| 外部依赖 | `tsx` (仅开发时) |
| 运行时依赖 | 无 |
| 指令覆盖 | 200+ (含全部 MVP + 大部分提案) |

### 1.3 文件列表

| 文件 | 职责 | 行数 |
|------|------|------|
| `WasmOpcode.ets` | 554 条指令定义 + 元数据表 | ~1040 |
| `WasmTypes.ets` | 值类型常量 / 所有数据结构 | ~610 |
| `WasmInterpreter.ets` | 解释器引擎 (switch dispatch) | ~2100 |
| `WasmLoader.ets` | `.wasm` 二进制解析器 | ~550 |
| `WasmFloatOps.ets` | IEEE754 / I32 / I64 算术 | ~710 |
| `WasmRuntime.ets` | 实例化 + 调用 API | ~240 |
| `WasmByteReader.ets` | 顺序二进制读取 | ~110 |
| `WasmLeb128.ets` | LEB128 编解码 | ~90 |
| `WasiProvider.ets` | WASI preview1 实现 | ~220 |
| `Index.ets` | 桶导出 | ~22 |

---

## 2. 栈式虚拟机模型

### 2.1 运行时组件

```
stack[]       操作数栈      ← push / pop WasmValue
ctrlStk[]     控制栈        ← block/loop/if/函数帧
locs[]        局部变量      ← 参数 + local 声明
code + ip     字节码 + 指令指针
memory        ArrayBuffer   ← DataView 读写
globals[]     全局变量
tables[]      函数引用表    ← call_indirect
```

### 2.2 WasmValue

```typescript
class WasmValue {
  type: number;       // 0x7F(i32) 0x7E(i64) 0x7D(f32) 0x7C(f64)
  i32Val: number;     // 32 位有符号
  i64Val: bigint;     // 64 位
  f32Val: number;     // 32 位浮点
  f64Val: number;     // 64 位浮点
  refVal: number;     // 函数引用索引 (-1 = null)
}
```

所有字段同时存在，`type` 指示有效字段。测试中传参时需同时填充 `i32Val` 避免跨类型读取返回 0。

### 2.3 .wasm 二进制结构

```
Magic:   \0 a s m  (4 bytes)
Version: 1          (4 bytes)

Section[] = [id:byte][size:u32][payload]

ID 1  Type       functype: 0x60 params[] results[]
ID 2  Import     module + field + kind + type_desc
ID 3  Function   type_index[]
ID 4  Table      elemtype + limits
ID 5  Memory     limits (pages)
ID 6  Global     type + mut + init_expr + END(0x0B)
ID 7  Export     name + kind + index
ID 8  Start      func_idx
ID 9  Elem       flags + func_index[]
ID 10 Code       func_body[]: local_decls + bytecode
ID 11 Data       flags + init_expr + bytes[]
```

Section 的 `size` 字段**仅计 payload 字节数**（不含 id 和 size 自身）。export section 的 size = `1(count) + namelen + name + 1(kind) + 1(index)`。

---

## 3. 模块详解

### 3.1 WasmOpcode — 指令集

5 个 enum + `OPCODE_TABLE` (OpcodeInfo[])：

```
WasmOp        (~176 条, 单字节)
GcExtOp       (~70 条, prefix 0xFB)
MiscExtOp     (18 条,  prefix 0xFC)
SimdExtOp     (~230 条, prefix 0xFD)
AtomicExtOp   (~60 条,  prefix 0xFE)
```

每条 OpcodeInfo 包含 name, category, stackIn, stackOut, hasImmediate。VMP 分析直接使用。

### 3.2 WasmLeb128 — LEB128

每字节低 7 位存数据，bit7 = continuation flag。

```typescript
readU32(data, pos)  // 无符号
readI32(data, pos)  // 有符号, bit6 为符号位
readI64(data, pos)  // BigInt, 最多 10 字节
```

**⚠️ 符号陷阱**：0x63 作为 signed LEB128 = -29（不是 99）。bit6=1 时触发符号扩展。值 ≥ 64 需双字节编码：`99 = 0xE3 0x00`。

### 3.3 WasmLoader — 解析器

`load(data)` → 验证 magic/version → 循环读取 section → `computeCounts()` 关联 typeIndex。

轻量验证：检查结构正确性，不做完整类型推导。依赖测试覆盖保证正确性。

### 3.4 WasmInterpreter — 解释器

```
executeLoop():
  while !halted && ip < code.length:
    op = code[ip++]
    switch(op) { ... 170+ cases }
```

**指令实现模式**：

| 类别 | 模式 | 示例 |
|------|------|------|
| 常量 | readImm + push | i32.const |
| 一元 | pop → op → push | i32.clz |
| 二元 | pop2 → op → push | i32.add |
| 比较 | pop2 → cmp → push i32(0\|1) | i32.eq |
| 控制流 | 操作 ctrlStk + ip | block/br |
| 内存 | DataView 读写 | i32.load/store |
| 调用 | save/restore state | call |

### 3.5 WasmFloatOps — 算术

**I32**：`|0` 截断为 32 位有符号，`>>>0` 为无符号。

```typescript
i32Add(a,b) { return ((a|0)+(b|0))|0; }
i32DivU(a,b) { return Math.trunc((a>>>0)/(b>>>0))>>>0; }
```

**I64**：BigInt 运算后 `& I64_MASK` 模拟 64 位环绕。

```typescript
const I64_MASK = 0xFFFFFFFFFFFFFFFFn;
i64Add(a,b) { return (a+b) & I64_MASK; }
```

**⚠️ 陷阱**：JS `>>` 是算术右移（保持符号），`>>>` 是逻辑右移（补 0）。Wasm `i32.shr_s` 用 `>>`，`i32.shr_u` 用 `>>>`。

### 3.6 WasmRuntime — API

```typescript
instantiate(wasmBytes):
  module = loader.load()
  创建 memory(table(global 实例
  加载 data/elem segments
  创建 funcInstances
  构建 exports Map

invokeByName(inst, name, args):
  funcIdx = inst.exports.get(name).index
  return interpreter.invoke(inst, funcIdx, args)
```

### 3.7 build.mjs — 构建脚本

```
node build.mjs test  →  transpile(.ets→.ts) to build/
node build.mjs dist  →  transpile to dist/ets/ + esbuild bundle to dist/web/ + self-contained HTML
node build.mjs       →  both
```

**transpile 步骤**：
1. 复制 .ets → .ts
2. `const enum` → `enum` (esbuild 兼容)
3. 修复重复 export (WasmFloatOps)
4. 修复 re-export 路径 (Index)

**bundle 步骤**：esbuild 处理 .ets (as .ts)，resolve 插件添加无后缀 import 的 .ets 查找。

---

## 4. 关键算法

### 4.1 Block Type 解析

`0x7F` (i32) 读为 signed LEB128 = `-1`。`-1 & 0xFF = 0xFF` ≠ 0x7F。正确算法：

```
readBlockType():
  bt = readI32(code)     // signed
  if bt == -64 → []      // 0x40 = void
  if bt >= 0  → [bt]     // type_index
  return [bt + 128]      // -1+128=127=i32 ✓
```

### 4.2 分支 (doBranchN)

```
doBranchN(ti):
  tf = ctrlStk[ti]
  // 1. 保存结果值
  for i in 0..resultCount:
    results[i] = stack[stack.length - resultCount + i]
  // 2. 截断栈（仅缩短）
  if tf.stackHeight < stack.length:
    stack.length = tf.stackHeight
  // 3. 推回
  push all results
  // 4. 弹出帧
  while ctrlStk.length > ti + 1: ctrlStk.pop()
  // 5. 跳转
  if tf.isLoop: ip = startIp
  else if tf == FUNCTION: halted = true
  else: ip = endIp
```

**⚠️ `stack.length = th` 无条件赋值会扩展数组产生 undefined。必须加 `if (th < stack.length)`。**

### 4.3 字节码扫描 (scanForEnd / findElseBefore)

Wasm 无显式跳转偏移量。用括号匹配扫描，**必须跳过各指令的操作数字节**，否则 LEB128 操作数中的字节值（如 0x02=BLOCK、0x03=LOOP）会破坏深度计数。

```
scanForEnd():
  depth = 1; pos = ip
  while pos < code.length:
    op = code[pos++]
    if op in {BLOCK,LOOP,IF}: depth++
    elif op == END:
      depth--
      if depth == 0: return pos
    else: pos = skipImmediate(pos)  // 跳过操作数
```

`skipImmediate` 覆盖所有带操作数的指令：LEB128 (常量/局部变量/分支/调用)、memarg (内存操作)、br_table (多目标)、f32.const (4 字节)、f64.const (8 字节)、前缀 opcode (0xFC/0xFD/0xFE)。

### 4.4 函数调用 (callInline)

状态保存/恢复模式，非原生调用栈：

```
callInline(fi, args):
  saved = {stack, ctrlStk, locs, code, ip}
  stack=[]; ctrlStk=[]; locs=[args..., zeros...]
  executeLoop()
  results = stack.pop
  restore(saved)
  return results
```

---

## 5. 执行流程

### 5.1 加载到调用

```
instantiate(wasmBytes)
  └─ load(data) → readHeader → readSections → computeCounts
  └─ 创建 mem/table/global → load segments → 构建 exports

invokeByName(inst, "add", args)
  └─ interpreter.invoke(fidx, args)
      └─ callFunction → init stack/ctrlStk/locs → executeLoop → collect results
```

### 5.2 单指令：i32.add 3 + 4

```
op=0x6A → dispatch:
  b = stack.pop().getAsI32()  // 4
  a = stack.pop().getAsI32()  // 3
  stack.push(WasmValue.i32((a+b)|0))  // 7
```

### 5.3 单指令：br_if 0

```
op=0x0D → handleBrIf:
  depth = readLebU32()        // 0
  cond  = popI32()            // 弹出条件值
  if cond ≠ 0:
    doBranch(depth)           // 跳转到目标标签
// 条件为 0 时 fall-through
```

---

## 6. Host Import 体系

### 7.1 架构

ArkWASM 支持宿主函数注入（Host Import），允许 Wasm 模块调用 JavaScript 实现的函数。三个调用路径均支持：

```
Wasm → call $import → handleCall() → fi.isImport? → hostFunc(args, memory) → push results
Wasm → call_indirect → handleCallIndirect() → fi.isImport? → hostFunc(args, memory) → push results
API → invoke() → callFunction() → fi.isImport? → hostFunc(args, memory) → return results
```

### 7.2 类型定义

```typescript
type HostFunction = (
  args: WasmValue[],                       // Wasm 传来的参数
  memory: WasmMemoryInstance | null        // 线性内存引用（无内存时为 null）
) => WasmValue[];                          // 返回给 Wasm 的值

interface ImportProvider {
  getFunction(module: string, field: string): HostFunction | null;
  getMemory(module: string, field: string): WasmMemoryInstance | null;
  getTable(module: string, field: string): WasmTableInstance | null;
  getGlobal(module: string, field: string): WasmValue | null;
}
```

### 7.3 WasmFunctionInstance 扩展

```typescript
class WasmFunctionInstance {
  isImport: boolean;
  hostFunc: HostFunction | null;  // null → 调用时 trap
}
```

### 7.4 HostTrap 异常

```typescript
class HostTrap extends Error {}

// 抛 HostTrap → 解释器捕获，转为 InterpResult { trap: message }
// 抛其他异常 → 穿透到调用方
```

### 7.5 WASI Provider

`WasiProvider` 实现 `ImportProvider`，覆盖 WASI preview1 协议的 12 个核心函数。

每个 WASI 函数通过 `_wasm_<name>` 方法实现，`getFunction` 自动将 `wasi_snapshot_preview1` 模块的函数名映射到对应方法。

```
WasiProvider.getFunction("wasi_snapshot_preview1", "fd_write")
  → this._wasm_fd_write(args, mem)
```

### 7.6 调用流程

```
instantiateModule():
  for each import func in module.imports:
    hostFn = importProvider.getFunction(module, field)
    fi = new WasmFunctionInstance(...)
    fi.isImport = true
    fi.hostFunc = hostFn   // null if unresolved

callHostInline(fi):          // handleCall / handleCallIndirect
  ft = types[fi.typeIndex]
  args = pop from stack      // 按类型签名逆序弹出
  try:
    results = fi.hostFunc(args, memory)
    push results to stack
  catch HostTrap:
    trap(message)

callHost(fi, args):          // callFunction (invoke entry)
  try:
    results = fi.hostFunc(args, memory)
    return { values: results, trap: null }
  catch HostTrap:
    return { values: [], trap: message }
```

---

## 6.1 WASI 支持 (可选模块)

### 6.1.1 架构

WASI 通过 `ImportProvider` 接口注入，与核心 WASM 完全解耦。`WasiProvider` 位于 `wasm/wasi/` 子目录，不 import 任何平台 API，通过 `WasiEnv` 回调接口获取平台能力。

```
┌─ WASM 核心 (不变) ────────────────────────────────┐
│  WasmRuntime ──importProvider──→ ImportProvider    │
└────────────────────────────────────────────────────┘
                                ↑
┌─ WASI (可选) ─────────────────────────────────────┐
│  WasiProvider implements ImportProvider            │
│    ├─ WasiEnv 接口 (16 个回调)                     │
│    ├─ ~85 个 _wasm_* 函数                         │
│    └─ 依赖 WasiTypes 常量                          │
└────────────────────────────────────────────────────┘
                                ↑
┌─ 鸿蒙 App (注入平台能力) ─────────────────────────┐
│  @ohos.file.fs → fsOpen/fsRead/fsClose             │
│  systemDateTime → nowNanos                         │
│  cryptoFramework → randomFill                      │
│  hilog → onStdout/onStderr                         │
└────────────────────────────────────────────────────┘
```

### 6.1.2 WasiEnv 接口

```typescript
interface WasiEnv {
  nowNanos: () => bigint;
  clockResolution: (id: number) => bigint;
  randomFill: (buf: Uint8Array) => void;

  stdin?: Uint8Array;
  onStdout?: (data: Uint8Array) => void;
  onStderr?: (data: Uint8Array) => void;
  onExit?: (code: number) => void;

  preopens?: Array<{ path: string }>;
  fsOpen?: (path, oflags, rights, fdflags) => number;
  fsRead?: (fd, buf, offset) => number;
  fsWrite?: (fd, data, offset) => number;
  fsClose?: (fd) => number;
  fsSeek?: (fd, offset, whence, dv, ptr) => number;
  fsFilestatGet?: (fd, dv, ptr) => number;
  fsUnlink / fsMkdir / fsRmdir / fsRename: (path...) => number;
  fsSymlink / fsReadlink / fsLink / fsReaddir: (...);
}
```

### 6.1.3 函数实现状态

| 分类 | 数量 | 实现方式 |
|------|:----:|----------|
| args/environ/proc/sched/clock/random | 12 | 纯算法或 WasiEnv 回调 |
| fd 核心 (read/write/close/seek/tell/fdstat/prestat) | 11 | WasiEnv I/O 回调 |
| fd 扩展 (pread/pwrite/advise/sync/renumber/readdir/filestat) | 12 | 部分 stub (ENOSYS/NOTSUP) |
| path 完整 (10) | 10 | WasiEnv fs* 回调 |
| poll_oneoff | 1 | stub |
| sock 完整 (43) | 43 | 全部 ENOSYS |

### 6.1.4 测试

`tests/src/test_wasi.ts` — 22 测试，覆盖 args, environ, clock, random, proc_exit, sched_yield, fd_read, fd_write, fd_close, fd_seek, fd_tell, fd_fdstat_get, fd_prestat, poll_oneoff, errno 返回值。

---

## 7. 构建与测试体系

### 7.1 构建链

```
.ets 源 → build.mjs test → build/*.ts → tsx test_all.ts → 263 PASS

.ets 源 → build.mjs dist → dist/ets/*.ts    (鸿蒙)
                         → dist/web/*.mjs    (Web)
                         → dist/web/arktest.html (自包含, 双击即用)
```

### 7.2 测试套件

| 套件 | 用例 | 覆盖 |
|------|------|------|
| Leb128 | 12 | u32/i32/i64 编解码边界 |
| WasmLoader | 6 | 模块解析/错误检测 |
| Constants | 4 | i32/i64/f32/f64.const |
| I32 Arithmetic | 20 | 全部算术/位运算/移位/旋转 |
| I32 Bit Count | 7 | clz/ctz/popcnt |
| I32 Comparisons | 10 | 全部比较 (s/u) |
| I64 Arithmetic | 12 | add/sub/mul/bit/shift/rot/clz/eqz |
| Floating Point | 8 | f32/f64 算术 |
| Float Comparisons | 34 | §4.3.2: 全部 cmp + NaN/±0/∞ 边界 |
| Float Rounding | 8 | ceil/floor/trunc/nearest 负值 |
| Float Arith Boundary | 17 | sqrt(-1), neg(-0), abs(-0), nearest, min/max NaN/±0, div/0 |
| Promote/Demote | 3 | f64.promote_f32, f32.demote_f64/overflow |
| Select / ref.is_null | 4 | §4.4.4 / §4.3.3 |
| Sign Extension | 7 | 全部 5 条 + i64 验证 |
| I64↔Float Conversions | 7 | 全部 8 条 i64↔float |
| Saturating Trunc | 6 | i32/i64 全部饱和截断 |
| Reinterpretations | 2 | f32↔i32, f64↔i64 |
| Reference Ops | 3 | ref.null/is_null/eq/br |
| Control Flow | 16 | block/br/br_if/if-else/return/drop/select/loop/br_table |
| Function Calls | 1 | call(add) |
| Tail Call | 1 | return_call |
| call_ref | 2 | 直接 + 表调用 |
| Exception Handling | 2 | try/end, throw→catch |
| Memory Ops | 10 | store/load 变体 + 偏移 + 页边界 + OOB |
| Memory Bulk | 2 | memory.copy/fill |
| Table Operations | 6 | size/grow/edge/set/fill |
| SIMD | 3 | v128.const, i32x4.splat, v128.or |
| Atomics | 2 | fence, rmw.add |
| Edge Cases | 10 | div/0, INT_MIN/-1, nearest, min/max, shift, br_table |
| Misc Extensions | 2 | trunc_sat |
| Traps | 1 | unreachable |
| **Core total** | **263** | |
| WASI | 22 | args, environ, clock, random, fd, errno |
| WAMR fixtures | 23 | app4_m1, i64 regression, mem pages |
| WAMR malformed | 50 | fuzz + GitHub PoC 全部正确拒绝 |
| WAMR regression | 19 | mem OOB, div/0, unreachable, float |
| Host Import | 9 | i32/i64/f32 调用, memory 传递, HostTrap |
| Feature verification | 34 | 10 组 Proposal 逐一验证 |
| **Grand total** | **420** | |

### 7.3 添加测试

```typescript
t('i32.add 3+4=7', () => {
  // body = [local.get 0, local.get 1, i32.add]
  const wasm = makeModule([0x20,0x00,0x20,0x01,0x6a], [0x7f,0x7f]);
  assertEq(invoke(wasm, [3, 4]), 7);
});
```

`makeModule(body, params?, results?)` 按参数构建最小模块。`invoke` 返回 i32，`invokeI64` 返回 bigint，`invokeF32/F64` 返回浮点。

---

## 8. 错误处理

### 7.1 三层体系

```
Layer 3 — Loader:   magic mismatch / section overread → throw Error
Layer 2 — Runtime:  unreachable / div-by-0 / bounds → trap(msg)
Layer 1 — API:      InterpResult { values, trap }
```

### 7.2 trap 实现

```typescript
trap(msg) {
  this.trapMsg = msg;
  this.halted = true;
  throw new Error(msg);    // 跳出嵌套调用栈
}
// callFunction 中:
try { executeLoop(); }
catch(e) { if (e instanceof Error) trapMsg = e.message; }
if (trapMsg) return { values: [], trap: trapMsg };
```

---

## 9. 排错指南

### 8.1 "section overread"

Section size 与实际 payload 字节数不匹配。常见原因是 export section 的 name 长度计算错误。

### 8.2 "Cannot read properties of undefined"

| 原因 | 位置 | 修复 |
|------|------|------|
| `stack.length = th` 扩展栈 | doBranchN | `if (th < stack.length)` |
| block type 解析 | readBlockType | `bt + 128` |
| readLebI32 不更新 ip | 3 个方法 | `p={v:ip}; r=read(data,p); ip=p.v` |

### 8.3 readLeb* 不更新 ip

`{ v: this.ip }` 创建临时对象。`readI32` 修改了 `v` 但调用方未回写 `this.ip`。

```typescript
// 错误
readLebI32() { return Leb128.readI32(this.code, { v: this.ip }); }

// 正确
readLebI32() {
  const p = { v: this.ip };
  const r = Leb128.readI32(this.code, p);
  this.ip = p.v;
  return r;
}
```

此 bug 导致所有带立即数的指令读错操作数，后续字节被误当作新指令执行。

### 8.4 LEB128 符号误判

`0x63` 作为 signed LEB128 = -29。值 99 的正确编码是 `0xE3 0x00`。

### 8.5 双重导出

`export function i64Add` 在函数声明处已导出，底部 `export { i64Add, ... }` 导致 esbuild 报错。修复：删除底部 export block。

---

## 10. 扩展开发

### 9.1 添加新指令

1. 操作码已定义在 `WasmOpcode.ets`
2. 在 `WasmFloatOps.ets` 实现纯函数
3. 在 `WasmInterpreter.ets` → `dispatch()` 添加 case
4. 在 `test_all.ts` 添加测试
5. `npm test`

### 9.2 扩展解释器状态

修改 `callInline` 中的 save/restore 覆盖新字段。修改 `invoke` 中的初始化。

### 9.3 支持 Host Import

在 `WasmRuntime` 添加 `importProvider`，在 `WasmInterpreter.handleCall` 中判断 `isImport` 时调用 provider 而非 trap。

---

## 11. 已知 Bug 与修复历史

| Bug | 表现 | 修复 |
|-----|------|------|
| `readLebI32` 不更新 `this.ip` | 所有带立即数的指令乱序 | `p = {v: ip}; r = read(data, p); ip = p.v` |
| `readInitExpr` 相同问题 | 全局变量/segment 解析错误 | 同上 |
| `stack.length = th` 无条件赋值 | 栈扩展产生 undefined | `if (th < stack.length)` |
| `f32Nearest` 用 `Math.round` | tie 舍入 2.5→3 应为 2 | ties-to-even |
| `f32 min/max` ±0 用 `Math.sign` | `Math.sign(±0)=±0` 非 ±1 | `1/a > 0` |
| `f32Copysign`/`f64Copysign` 用 `Math.sign` | `copysign(5,-0)=0` 应为 -5 | `Object.is(b,-0) \|\| b<0` |
| `f32/f64 min/max` NaN 返回 canonical NaN | 应返回输入 NaN | `if(isNaN(a)) return a` |
| `i32DivS` INT_MIN/-1 不 trap | 返回 INT_MIN | `throw Error()` |
| `scanForCatch` 返回 pos 而非 pos-1 | throw 跳到 catch 后 | `return pos - 1` |
| `br_table` 解析顺序 default→count | 规范要求 count→targets→default | 改解析顺序 |
| `readBlockType` type index 直接返回 | 多值块类型不解析 functype | 查 `types[bt].resultTypes` |
| `i64Add` 等双重 export | esbuild 编译失败 | 删除底部 re-export block |
| `WasmValue.i64()` 未设 `i32Val` | i64.store8 写入 0 而非正确值 | `wv.i32Val = Number(v & 0xFFFFFFFFn)` |
| `handleIf() false + else` 未推 IF 帧 | `if/else` false 分支调用 `handleElse` 时 trap | false 分支有 else 时也推 IF 帧 |
| `scanForEnd` 不跳过指令操作数 | br_table 的 LEB128 字节 (0x02=BLOCK) 破坏深度计数 | 新增 `skipImmediate` 正确跳过各指令操作数 |

## 12. 与 Wasm 规范已知差异

| 差异 | 说明 |
|------|------|
| Memory64 load/store 使用 32-bit 地址 | 多数指令仍走 i32 路径；64-bit 地址完整实现中 |
| GC 全部返回 trap | 未实现垃圾回收堆 |
| 无完整类型验证 | 轻量 loader 不做签名检查，信任输入 |
| 内存初始/最大页数无验证 | 不检查 initPages > maxPages |
| scanForEnd 不识别罕见前缀指令 | 0xFB/0xFD 某些子指令操作数跳过可能不精确 |

---

## 13. 附录

### 12.1 术语

| 术语 | 含义 |
|------|------|
| WAMR | WebAssembly Micro Runtime (C 实现) |
| MVP | Minimum Viable Product (核心指令集) |
| LEB128 | Little-Endian Base-128 变长编码 |
| Trap | Wasm 运行时异常 |
| CtrlFrame | 控制栈条目 (labelType + stackHeight + endIp + isLoop) |
| Section | .wasm 文件的段 (id + size + payload) |

### 12.2 最小 .wasm 模块

```
00 61 73 6D 01 00 00 00     magic + version
01 05 01 60 00 01 7F         type: () → i32
03 02 01 00                  func: 1, type 0
07 08 01 04 74 65 73 74 00 00  export "test" func 0
0A 06 01 04 00 41 2A 0B     code: i32.const 42, end
```

### 12.3 命令速查

```bash
npm test              # build:test + run
npm run build:test    # only test build
npm run build:dist    # only dist
npm run build         # full build

# 调试
npx tsx -e "import { VALUE_TYPE_I32 } from './build/WasmTypes.ts'; console.log(VALUE_TYPE_I32);"

# WAT → .wasm
wat2wasm add.wat -o add.wasm
```

### 12.4 文件对照

| 源 (.ets) | 制品 (.ts) | JS 测试对应 |
|-----------|-----------|------------|
| WasmTypes.ets | build/WasmTypes.ts | 类型和常量 |
| WasmOpcode.ets | build/WasmOpcode.ts | 操作码枚举 |
| WasmLeb128.ets | build/WasmLeb128.ts | LEB128 |
| WasmFloatOps.ets | build/WasmFloatOps.ts | 算术运算 |
| WasmLoader.ets | build/WasmLoader.ts | 加载器 |
| WasmInterpreter.ets | build/WasmInterpreter.ts | 解释器 |
| WasmRuntime.ets | build/WasmRuntime.ts | 运行时 |
| WasmByteReader.ets | build/WasmByteReader.ts | 字节读取 |
| Index.ets | build/Index.ts | 导出桶 |
