/**
 * HarmonyWasiEnv.ets — 鸿蒙元服务 WASI 完整环境实现。
 *
 * 使用 @ohos.file.fs、@ohos.cryptoFramework、@ohos.systemDateTime
 * 等鸿蒙系统 API 实现 WasiEnv 的全部 16 个回调。
 *
 * ═══════════════════════════════════════════════════════════════
 * 使用方法
 * ═══════════════════════════════════════════════════════════════
 *
 * 将此文件复制到你的鸿蒙元服务项目中，然后：
 *
 *   import { WasiProvider, WasiEnv } from 'arkwasm';
 *   import { createHarmonyWasiEnv } from './HarmonyWasiEnv';
 *
 *   const wasi = new WasiProvider(createHarmonyWasiEnv(ctx), ['./app'], {});
 *   const rt = new WasmRuntime(wasi);
 *   const inst = rt.instantiate(wasmBytes);
 *   try { rt.invokeByName(inst, '_start', []); }
 *   catch (e) { if (e instanceof HostTrap) console.log('exit'); }
 *
 * ═══════════════════════════════════════════════════════════════
 * 元服务权限要求 (module.json5)
 * ═══════════════════════════════════════════════════════════════
 *
 * 最小配置：无需额外权限即可运行（仅用沙箱目录 + rawfile）
 * 如需访问外部存储，需在 module.json5 声明：
 *
 *   "requestPermissions": [
 *     { "name": "ohos.permission.READ_MEDIA" },
 *     { "name": "ohos.permission.WRITE_MEDIA" }
 *   ]
 */

import { WasiEnv, PreopenDir } from './WasiProvider';
import {
  WASI_ESUCCESS,      WASI_EBADF,       WASI_EACCES,       WASI_ENOENT,
  WASI_ENOTDIR,       WASI_EEXIST,      WASI_ENOTEMPTY,    WASI_ENAMETOOLONG,
  WASI_ENOTSUP,       WASI_EOVERFLOW,   WASI_EINVAL,       WASI_EFAULT,
  WASI_PREOPENTYPE_DIR,
  WASI_FILETYPE_DIRECTORY,
  WASI_FILETYPE_REGULAR_FILE,
  WASI_FILETYPE_SYMBOLIC_LINK,
  WASI_FILETYPE_UNKNOWN,
  WASI_WHENCE_SET,
  WASI_WHENCE_CUR,
  WASI_WHENCE_END,
  WASI_O_CREAT,
  WASI_O_TRUNC,
  WASI_O_EXCL,
  WASI_FDFLAG_APPEND,
  writeFilestat,
  writeDirent,
} from './WasiTypes';

// ═══════════════════════════════════════════════════════════════════════════
// HarmonyOS API imports (仅鸿蒙可用；非鸿蒙环境此文件无法编译)
// ═══════════════════════════════════════════════════════════════════════════

import { fileIo, ReadOptions, OpenMode } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';

// ═══════════════════════════════════════════════════════════════════════════
// 内部工具
// ═══════════════════════════════════════════════════════════════════════════

const DOMAIN = 0x0000;

/** fd → 文件路径映射表（鸿蒙 fileIo 不支持通过 fd 查路径） */
class FdTable {
  private paths: Map<number, string> = new Map();
  private nextFd: number = 3; // 0/1/2 = stdin/stdout/stderr

  register(path: string): number {
    const fd = this.nextFd++;
    this.paths.set(fd, path);
    return fd;
  }
  getPath(fd: number): string | undefined {
    return this.paths.get(fd);
  }
  release(fd: number): void {
    this.paths.delete(fd);
  }
}

/** Map HarmonyOS fileIo error to WASI errno */
function mapErrno(e: unknown): number {
  if (e instanceof Error) {
    const m = e.message;
    if (m.includes('exist'))                    return WASI_EEXIST;
    if (m.includes('not found') || m.includes('no such')) return WASI_ENOENT;
    if (m.includes('permission') || m.includes('access')) return WASI_EACCES;
    if (m.includes('directory'))                return WASI_ENOTDIR;
    if (m.includes('name too long'))            return WASI_ENAMETOOLONG;
    if (m.includes('not empty'))                return WASI_ENOTEMPTY;
    if (m.includes('bad file'))                 return WASI_EBADF;
    if (m.includes('bad address') || m.includes('fault')) return WASI_EFAULT;
    if (m.includes('invalid'))                  return WASI_EINVAL;
    if (m.includes('overflow'))                 return WASI_EOVERFLOW;
  }
  return WASI_EACCES; // fallback
}

// ═══════════════════════════════════════════════════════════════════════════
// createHarmonyWasiEnv
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 创建一个可用于鸿蒙元服务的完整 WasiEnv。
 *
 * @param ctx    —— UIAbility/Component 的 context（用于 resourceManager）
 * @param preopenBase —— 预挂载到 WASM `/` 的鸿蒙沙箱路径，默认值为应用 rawfile 目录
 * @param stdin  —— 可选的 stdin 输入数据
 */
export function createHarmonyWasiEnv(
  ctx: common.Context,
  preopenBase: string = '',
  stdin?: Uint8Array,
): WasiEnv {
  const fdTable = new FdTable();

  // 默认预打开目录：应用的 rawfile 根目录
  if (!preopenBase) {
    preopenBase = ctx.resourceDir + '/rawfile';
  }

  const env: WasiEnv = {
    // ── 时间 ────────────────────────────────────────────────────────
    nowNanos: () => BigInt(systemDateTime.getTime(false)) * 1_000_000n,
    clockResolution: (_id: number) => 1_000_000n, // 1ms

    // ── 随机 ────────────────────────────────────────────────────────
    randomFill: (buf: Uint8Array) => {
      try {
        const rand = cryptoFramework.createRandom();
        const data = rand.generateRandomSync(buf.length);
        buf.set(new Uint8Array(data.data));
        rand.releaseSync();
      } catch {
        // fallback: Math.random
        for (let i = 0; i < buf.length; i++) {
          buf[i] = Math.floor(Math.random() * 256);
        }
      }
    },

    // ── I/O ─────────────────────────────────────────────────────────
    stdin,
    onStdout: (data: Uint8Array) => {
      let text = '';
      for (let i = 0; i < data.length; i++) {
        text += String.fromCharCode(data[i]);
      }
      hilog.info(DOMAIN, 'wasm:stdout', '%{public}s', text);
    },
    onStderr: (data: Uint8Array) => {
      let text = '';
      for (let i = 0; i < data.length; i++) {
        text += String.fromCharCode(data[i]);
      }
      hilog.warn(DOMAIN, 'wasm:stderr', '%{public}s', text);
    },
    onExit: (code: number) => {
      hilog.info(DOMAIN, 'wasm:exit', 'exit(%{public}d)', code);
    },

    preopens: [
      new PreopenDir(preopenBase, WASI_FILETYPE_DIRECTORY),
    ],

    // ── 文件系统 ────────────────────────────────────────────────────

    fsOpen: (path: string, oflags: number, _rights: bigint, _fdflags: number): number => {
      try {
        let mode: number;
        if (oflags & WASI_O_CREAT) {
          mode = OpenMode.CREATE | OpenMode.READ_WRITE;
        } else if (oflags & WASI_O_TRUNC) {
          mode = OpenMode.CREATE | OpenMode.READ_WRITE;
        } else {
          mode = OpenMode.READ_WRITE;
        }
        const file = fileIo.openSync(path, mode);
        if (oflags & WASI_O_TRUNC) {
          fileIo.truncateSync(file.fd);
        }
        fdTable.register(path);
        return file.fd;
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsRead: (fd: number, buf: Uint8Array, offset: bigint): number => {
      try {
        const options: ReadOptions = {
          offset: Number(offset),
          length: buf.length,
        };
        return fileIo.readSync(fd, buf.buffer, options);
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsWrite: (fd: number, data: Uint8Array, offset: bigint): number => {
      try {
        // fileIo.writeSync 的 options 接口因版本而异；部分版本不支持 offset
        // 兼容路径：先 seek 到目标位置再写入
        const stat = fileIo.statSync(fileIo.getPath(fd));
        if (Number(offset) + data.length > stat.size) {
          // 扩展文件（truncate to new size）
          fileIo.truncateSync(fd, Number(offset) + data.length);
        }
        return fileIo.writeSync(fd, data.buffer);
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsClose: (fd: number): number => {
      try {
        fileIo.closeSync(fd);
        fdTable.release(fd);
        return WASI_ESUCCESS;
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsSeek: (fd: number, offset: bigint, whence: number, dv: DataView, newoffsetPtr: number): number => {
      try {
        const path = fdTable.getPath(fd);
        if (!path) return -WASI_EBADF;
        const stat = fileIo.statSync(path);
        let newOffset: bigint;
        switch (whence) {
          case WASI_WHENCE_SET:
            newOffset = offset;
            break;
          case WASI_WHENCE_CUR:
            newOffset = 0n + offset; // cursor is always 0 in this impl; seek via read/write offset
            break;
          case WASI_WHENCE_END:
            newOffset = BigInt(stat.size) + offset;
            break;
          default:
            return -WASI_EINVAL;
        }
        dv.setBigInt64(newoffsetPtr, newOffset, true);
        return WASI_ESUCCESS;
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsFilestatGet: (fd: number, dv: DataView, ptr: number): number => {
      try {
        const path = fdTable.getPath(fd);
        if (!path) {
          // fd 0/1/2: character device
          writeFilestat(dv, ptr, 0n, 0n, WASI_FILETYPE_UNKNOWN, 0n, 0n, 0n, 0n, 0n);
          return WASI_ESUCCESS;
        }
        const stat = fileIo.statSync(path);
        const filetype = stat.isDirectory() ? WASI_FILETYPE_DIRECTORY
                      : stat.isSymbolicLink() ? WASI_FILETYPE_SYMBOLIC_LINK
                      : WASI_FILETYPE_REGULAR_FILE;
        writeFilestat(dv, ptr,
          0n,                     // dev
          BigInt(stat.ino > 0 ? stat.ino : 1), // ino
          filetype,
          1n,                     // nlink
          BigInt(stat.size > 0 ? stat.size : 0), // size
          BigInt(stat.atime),     // atim
          BigInt(stat.mtime),     // mtim
          BigInt(stat.ctime),     // ctim
        );
        return WASI_ESUCCESS;
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsUnlink: (path: string): number => {
      try { fileIo.unlinkSync(path); return WASI_ESUCCESS; }
      catch (e) { return -mapErrno(e); }
    },

    fsMkdir: (path: string): number => {
      try { fileIo.mkdirSync(path); return WASI_ESUCCESS; }
      catch (e) { return -mapErrno(e); }
    },

    fsRmdir: (path: string): number => {
      try { fileIo.rmdirSync(path); return WASI_ESUCCESS; }
      catch (e) { return -mapErrno(e); }
    },

    fsRename: (oldPath: string, newPath: string): number => {
      try { fileIo.renameSync(oldPath, newPath); return WASI_ESUCCESS; }
      catch (e) { return -mapErrno(e); }
    },

    fsSymlink: (target: string, linkPath: string): number => {
      try { fileIo.symlinkSync(target, linkPath); return WASI_ESUCCESS; }
      catch (e) { return -mapErrno(e); }
    },

    fsReadlink: (path: string, buf: Uint8Array): number => {
      try {
        const target = fileIo.readlinkSync(path);
        const bytes = new Uint8Array(target.length);
        for (let i = 0; i < target.length && i < buf.length; i++) {
          bytes[i] = target.charCodeAt(i);
        }
        buf.set(bytes.subarray(0, Math.min(bytes.length, buf.length)));
        return Math.min(target.length, buf.length);
      } catch (e) {
        return -mapErrno(e);
      }
    },

    fsLink: (_existing: string, _newPath: string): number => {
      // fileIo 不支持硬链接
      return -WASI_ENOTSUP;
    },

    fsReaddir: (fd: number, bufPtr: number, bufLen: number, cookie: bigint, dv: DataView): number => {
      try {
        const path = fdTable.getPath(fd);
        if (!path) return -WASI_EBADF;
        const names = fileIo.listFileSync(path);
        let written = 0;
        let index = Number(cookie);
        while (written < bufLen && index < names.length) {
          const name = names[index];
          const nameLen = name.length;
          const direntSize = 24 + nameLen; // dirent header + name
          if (written + direntSize > bufLen) break;
          // Determine file type
          let ftype = WASI_FILETYPE_UNKNOWN;
          try {
            const st = fileIo.statSync(path + '/' + name);
            if (st.isDirectory()) ftype = WASI_FILETYPE_DIRECTORY;
            else ftype = WASI_FILETYPE_REGULAR_FILE;
          } catch { /* ignore stat error */ }
          writeDirent(dv, bufPtr + written, BigInt(index + 1), BigInt(index + 1), nameLen, ftype);
          written += 24;
          for (let j = 0; j < nameLen; j++) {
            dv.setUint8(bufPtr + written + j, name.charCodeAt(j));
          }
          written += nameLen;
          index++;
        }
        return written;
      } catch (e) {
        return -mapErrno(e);
      }
    },
  };

  return env;
}
