# ArkWASM

> WebAssembly Micro Runtime 的纯 TypeScript/ArkTS 移植。  
> Interpreter-only · 263 测试 · 零原生依赖 · 浏览器 / 鸿蒙元服务

参考 [bytecodealliance/wasm-micro-runtime](https://github.com/bytecodealliance/wasm-micro-runtime) 经典解释器架构实现的鸿蒙元服务WASM运行时。

---

## 快速开始

```bash
cd arkwasm
npm install
npm test              # 构建 + 263 测试
npm run build:dist    # 生成制品 (ts + web + har)
```

制品产出 `dist/web/arktest.html` — 自包含 HTML，双击即用。

---

## 接入指南

### 浏览器

```html
<script type="module">
  import { WasmRuntime, WasmValue } from './dist/web/arkwasm.min.mjs';
  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasmBytes);
  const res = rt.invokeByName(inst, 'add', [
    WasmValue.i32(3), WasmValue.i32(4)
  ]);
  console.log(res.values[0].getAsI32()); // 7
</script>
```

### 鸿蒙元服务

**方式一：单文件 TS 引入**

将 `dist/ts/arkwasm.ts` 复制到项目：

```typescript
import { WasmRuntime, WasmValue } from './wasm/arkwasm';
```

**方式二：HAR 包引入**

```bash
ohpm install ../path/to/dist/arkwasm.har
```

```typescript
import { WasmRuntime, WasmValue } from 'arkwasm';
```

**方式三：从 rawfile 加载 .wasm**

```typescript
import { WasmRuntime, WasmValue } from '../wasm/Index';
import { common } from '@kit.AbilityKit';

// 在 UIAbility 或 Component 中：使用 this.context
// 在 HAR 库中：由调用方传入 context
function loadWasm(ctx: common.Context): void {
  const rm = ctx.resourceManager;
  const raw = await rm.getRawFileContent('module.wasm');
  const wasm = new Uint8Array(raw.buffer);

  const rt = new WasmRuntime();
  const inst = rt.instantiate(wasm);
  const res = rt.invokeByName(inst, 'main', []);

  // 线性内存读写
  const mem = inst.memories[0];
  new DataView(mem.buffer).setInt32(0, 42, true);
}
```

### 准备 .wasm

| 语言 | 命令 |
|------|------|
| C/C++ | `emcc code.c -o out.wasm -s STANDALONE_WASM --no-entry` |
| Rust | `cargo build --target wasm32-unknown-unknown` |
| WAT | `wat2wasm add.wat -o add.wasm` |

---

## 项目结构

```
arkwasm/
├── package.json
├── build.mjs                 # 构建脚本 (transpile + esbuild bundle)
├── tsconfig.json
├── .gitignore
│
├── entry/src/main/ets/wasm/  # 源代码 (10 个 .ets)
│   ├── WasmOpcode.ets         ★ 554 条指令集中定义
│   ├── WasmTypes.ets          值类型 + 数据结构
│   ├── WasmInterpreter.ets    解释器引擎 (switch dispatch)
│   ├── WasmLoader.ets         .wasm 二进制解析
│   ├── WasmFloatOps.ets       IEEE754 / I32 / I64 算术
│   ├── WasmRuntime.ets        运行时 API
│   ├── WasmByteReader.ets     字节读取
│   ├── WasmLeb128.ets         LEB128 编解码
│   ├── WasiProvider.ets       WASI preview1 实现
│   └── Index.ets              公共导出
│
├── tests/
│   ├── src/                   # 6 个测试文件
│   │   ├── test_all.ts        263 手写测试
│   │   ├── test_wasi.ts        22  WASI 测试
│   │   ├── test_wamr*.ts      WAMR 移植测试
│   │   ├── test_host_import.ts
│   │   └── test_features.ts   34 特性验证
│   ├── wamr-fixtures/         # 101 个 WAMR 原始 .wasm
│   └── arktest.template       # 浏览器测试模板
│
├── build/                     # 测试构建 (gitignored)
└── dist/                      # 制品 (gitignored)
    ├── ts/
    │   ├── arkwasm.ts          ← 单文件 TS (231 KB)
    │   └── arkwasm.d.ts        ← 类型声明
    ├── web/
    │   ├── arktest.html        ← 自包含 HTML (125 KB)
    │   ├── arkwasm.mjs         ← ESM (213 KB)
    │   └── arkwasm.min.mjs     ← ESM 压缩 (110 KB)
    └── arkwasm.har             ← HAR 包 (234 KB)
```

---

## API

```typescript
class WasmRuntime {
  instantiate(data: Uint8Array): WasmModuleInstance;
  invokeByName(inst, name: string, args: WasmValue[]): InterpResult;
  invoke(inst, funcIdx: number, args: WasmValue[]): InterpResult;
}

class WasmValue {
  static i32(v: number): WasmValue;
  static i64(v: bigint): WasmValue;
  static f32(v: number): WasmValue;
  static f64(v: number): WasmValue;
  getAsI32(): number;
  getAsI64(): bigint;
  getAsF32(): number;
  getAsF64(): number;
}

interface InterpResult {
  values: WasmValue[];    // trap 时为空
  trap: string | null;    // null = 成功
}
```

---

## Feature Support

对照 [WebAssembly.org Features](https://webassembly.org/features/)：

### Phase 5 — 已标准化

| Proposal | 状态 | 说明 |
|----------|------|------|
| **MVP (Core Spec)** | ✅ | 全部 i32/i64/f32/f64 运算、控制流、内存、调用 |
| **Sign Extension** | ✅ | i32.extend8_s/16_s, i64.extend8_s/16_s/32_s |
| **Non-trapping Float-to-Int** | ✅ | trunc_sat_s/u (i32/i64 × f32/f64) |
| **Bulk Memory** | ✅ | memory.copy/fill/init, data.drop, table.init/copy/fill/grow/size |
| **Reference Types** | ✅ | ref.null, ref.is_null, ref.func, ref.eq, br_on_null/non_null, ref.as_non_null |
| **Multi-value** | ✅ | block/if/else with result types |
| **Mutable Globals** | ✅ | import/export mutable globals |
| **BigInt ↔ i64** | ✅ | JS BigInt 与 Wasm i64 互操作 |
| **Tail Call** | ✅ | return_call, return_call_indirect |
| **Typed Function References** | ✅ | call_ref, return_call_ref (null 检查 + 类型校验) |
| **Exception Handling** | ✅ | try/catch/catch_all/throw/rethrow/delegate (throw→catch 完整栈展开) |
| **SIMD v128** | ⚠️ | load/store/const, i32x4/i64x2 add/sub/mul, v128 and/or/xor/not, splat (其余 ~180 条 trap) |
| **GC** | 🚫 | struct/array/i31/ref.cast/stringref 全部返回 trap |
| **Memory64** | ✅ | 64-bit 内存寻址（loader + 64-bit load/store + 63 项边界测试） |
| **Multi-memory** | ✅ | 多内存实例（memarg bit6 flag + memory index dispatch） |

### Phase 4+ — 部分支持

| Proposal | 状态 | 说明 |
|----------|------|------|
| **Threads / Atomics** | ✅ | 单线程模式：57 条全部降解为非原子操作（含 sub-word RMW） |
| **Extended Const** | ✅ | i32/i64.add/sub/mul in init expressions |

### Host Import

| 特性 | 状态 |
|------|------|
| ImportProvider 接口 | ✅ |
| host 函数调用 (i32/i64/f32/f64) | ✅ |
| host 读写 Wasm 内存 | ✅ |
| HostTrap 终止执行 | ✅ |
| WASI preview1 (12 函数) | ✅ |

---

## Host Import

```typescript
type HostFunction = (args: WasmValue[], memory: WasmMemoryInstance | null) => WasmValue[];

interface ImportProvider {
  getFunction(module: string, field: string): HostFunction | null;
  getMemory(module: string, field: string): WasmMemoryInstance | null;
  getTable(module: string, field: string): WasmTableInstance | null;
  getGlobal(module: string, field: string): WasmValue | null;
}
```

### 使用

```typescript
const provider: ImportProvider = {
  getFunction(mod, field) {
    if (mod === 'env' && field === 'add')
      return (args) => [WasmValue.i32(args[0].getAsI32() + args[1].getAsI32())];
    return null;
  },
  getMemory: () => null, getTable: () => null, getGlobal: () => null,
};
const rt = new WasmRuntime(provider);
const inst = rt.instantiate(wasmWithImports);
```

### HostTrap — 主动终止

```typescript
throw new HostTrap('wasi: exit(0)');  // → Wasm 执行终止
```

---

## WASI 支持

内置 `WasiProvider`，实现 WASI Preview 1 全部 85 个函数。通过 `WasiEnv` 回调接口解耦平台依赖，HAR 包零平台依赖。

### 环境兼容性

| WASI 模块 | 函数数 | 鸿蒙元服务 | 浏览器 | Node/TS |
|-----------|:----:|:--------:|:-----:|:-------:|
| args / environ | 4 | ✅ | ✅ | ✅ |
| proc / sched | 3 | ✅ | ✅ | ✅ |
| clock / random | 3 | ✅ | ✅ | ✅ |
| fd 核心 (read/write/close/seek/tell/fdstat/prestat) | 11 | ✅ | ✅ | ✅ |
| fd 扩展 (pread/pwrite/advise/sync/renumber/readdir/filestat) | 12 | ⚠️ 需 fs 回调 | ⚠️ stub | ⚠️ 需 fs 回调 |
| path 完整 (open/stat/readlink/mkdir/unlink/rename/symlink/link) | 10 | ✅ 通过 @ohos.file.fs | ⚠️ ENOSYS | ✅ 通过 node:fs |
| poll_oneoff | 1 | ⚠️ stub | ⚠️ stub | ⚠️ stub |
| sock 完整 (43) | 43 | 🟡 ENOSYS | ⚠️ ENOSYS | 🟡 ENOSYS |
| **全部** | **85** | **~58 有用** | **~22** | **~58 有用** |

### 使用

```typescript
import { WasiProvider } from 'arkwasm';

const wasi = new WasiProvider(undefined, ['./app', '--verbose'], { HOME: '/data' });
const rt = new WasmRuntime(wasi);
try { rt.invokeByName(rt.instantiate(wasiWasm), '_start', []); }
catch (e) { if (e instanceof HostTrap) console.log('exit'); }
```

### 各环境 WasmEnv 实现示例

#### 鸿蒙元服务（完整文件系统 + 随机数 + 时钟）

创建 `HarmonyWasiEnv.ets`，参考 [`entry/src/main/ets/wasm/wasi/HarmonyWasiEnv.ets`](entry/src/main/ets/wasm/wasi/HarmonyWasiEnv.ets)：

```typescript
import { WasiProvider } from 'arkwasm';
import { createHarmonyWasiEnv } from './HarmonyWasiEnv';
import { common } from '@kit.AbilityKit';

// 在 UIAbility / Component 中：
const ctx = getContext(this) as common.UIAbilityContext;
const wasi = new WasiProvider(createHarmonyWasiEnv(ctx), ['./app'], {});

const rt = new WasmRuntime(wasi);
const rm = ctx.resourceManager;
const raw = await rm.getRawFileContent('module.wasm');
const inst = rt.instantiate(new Uint8Array(raw.buffer));

try { rt.invokeByName(inst, '_start', []); }
catch (e) { if (e instanceof HostTrap) hilog.info(0, 'wasi', 'exit'); }
```

#### 浏览器（最小实现）

```typescript
import { WasmRuntime, WasiProvider, WasiEnv } from 'arkwasm';

const env: WasiEnv = {
  nowNanos: () => BigInt(performance.now() * 1e6),
  clockResolution: () => 1_000_000n,
  randomFill: (buf) => crypto.getRandomValues(buf),
  stdin: new Uint8Array(0),
  onStdout: (data) => { const s = String.fromCharCode(...data); console.log(s); },
  onStderr: (data) => { const s = String.fromCharCode(...data); console.warn(s); },
  preopens: [],
  // 浏览器无文件系统，path_open 等返回 ENOSYS
};

const wasi = new WasiProvider(env, ['./app']);
const rt = new WasmRuntime(wasi);
```

#### Node.js（完整文件系统）

```typescript
import { WasmRuntime, WasiProvider, WasiEnv } from 'arkwasm';
import { readFileSync, writeFileSync, openSync, closeSync, readSync,
         writeSync, mkdirSync, rmdirSync, unlinkSync, renameSync,
         readlinkSync, symlinkSync, statSync, readdirSync } from 'node:fs';
import { randomFillSync } from 'node:crypto';

const fds = new Map<number, string>();
const env: WasiEnv = {
  nowNanos: () => BigInt(Date.now()) * 1_000_000n,
  clockResolution: () => 1_000_000n,
  randomFill: (buf) => randomFillSync(buf),
  onStdout: (data) => process.stdout.write(data),
  onStderr: (data) => process.stderr.write(data),
  preopens: [{ path: '/', filetype: 3 }],
  fsOpen: (path) => {
    try { const fd = openSync(path, 'r+'); fds.set(fd, path); return fd; }
    catch { return -8/*EBADF*/; }
  },
  fsRead: (fd, buf, offset) => {
    try { return readSync(fd, buf, 0, buf.length, Number(offset)); }
    catch { return -8; }
  },
  fsClose: (fd) => { closeSync(fd); fds.delete(fd); return 0; },
  // ... 其余回调类推
};
```

---

## 命令

```bash
npm test              # 构建 + 263 测试
npm run build         # 完整构建
npm run build:test    # 仅测试构建
npm run build:dist    # 全部制品 (ts + web + har)
npm run build:ts      # 仅 TS 单文件
npm run build:har     # 仅 HAR 包
```
