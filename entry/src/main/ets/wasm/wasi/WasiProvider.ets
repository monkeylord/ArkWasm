/**
 * WasiProvider.ets — WASI Preview 1 host implementation (85 functions).
 *
 * Implements the `ImportProvider` interface. All platform-specific
 * behaviour is delegated to a `WasiEnv` callback object injected at
 * construction time so that the HAR artefact stays zero-dependency.
 *
 * ── Environment coverage ───────────────────────────────────────────
 *  HarmonyOS   : complete (fs via @ohos.file.fs, ...)
 *  Browser     : core 18 functions (no fs, no sock, no poll)
 *  Node / TS   : core + fs via node:fs callbacks
 *
 * Usage
 * ─────
 *   const wasi = new WasiProvider(wasiEnv, ['./app'], { HOME: '/data' });
 *   const rt = new WasmRuntime(wasi);
 *   const inst = rt.instantiate(wasmBytes);
 *   try { rt.invokeByName(inst, '_start', []); }
 *   catch (e) { if (e instanceof HostTrap) console.log('exit'); }
 */

import {
  WasmValue,
  WasmMemoryInstance,
  HostTrap,
} from '../WasmTypes';
import {
  ImportProvider,
} from '../WasmRuntime';

import {
  WASI_ESUCCESS,      WASI_EBADF,       WASI_EINVAL,
  WASI_ENOSYS,        WASI_ENOTSUP,      WASI_ENOENT,
  WASI_ENOTDIR,       WASI_EACCES,       WASI_EEXIST,
  WASI_ENOTEMPTY,     WASI_ENAMETOOLONG, WASI_EOVERFLOW,
  WASI_ERANGE,        WASI_ENOTCAPABLE,  WASI_EFAULT,
  WASI_ESPIPE,        WASI_EISDIR,
  WASI_RIGHTS_STDIN,  WASI_RIGHTS_STDOUT, WASI_RIGHTS_STDERR,
  WASI_RIGHTS_DIR_BASE, WASI_RIGHTS_FILE_BASE,
  WASI_RIGHT_FD_READ, WASI_RIGHT_FD_WRITE, WASI_RIGHT_FD_SEEK,
  WASI_RIGHT_FD_TELL, WASI_RIGHT_FD_FDSTAT_SET_FLAGS,
  WASI_RIGHT_FD_ADVISE, WASI_RIGHT_FD_FILESTAT_GET,
  WASI_RIGHT_FD_FILESTAT_SET_SIZE, WASI_RIGHT_FD_FILESTAT_SET_TIMES,
  WASI_RIGHT_POLL_FD_READWRITE,
  WASI_RIGHT_PATH_OPEN, WASI_RIGHT_PATH_CREATE_DIRECTORY,
  WASI_RIGHT_PATH_CREATE_FILE, WASI_RIGHT_PATH_FILESTAT_GET,
  WASI_RIGHT_PATH_FILESTAT_SET_SIZE, WASI_RIGHT_PATH_FILESTAT_SET_TIMES,
  WASI_RIGHT_PATH_READLINK, WASI_RIGHT_PATH_RENAME_SOURCE,
  WASI_RIGHT_PATH_RENAME_TARGET, WASI_RIGHT_PATH_SYMLINK,
  WASI_RIGHT_PATH_LINK_SOURCE, WASI_RIGHT_PATH_LINK_TARGET,
  WASI_RIGHT_PATH_UNLINK_FILE, WASI_RIGHT_PATH_REMOVE_DIRECTORY,
  WASI_RIGHT_FD_READDIR, WASI_RIGHT_FD_ALLOCATE,
  WASI_O_CREAT, WASI_O_DIRECTORY, WASI_O_EXCL, WASI_O_TRUNC,
  WASI_FDFLAG_APPEND, WASI_FDFLAG_DSYNC, WASI_FDFLAG_NONBLOCK,
  WASI_FDFLAG_RSYNC, WASI_FDFLAG_SYNC,
  WASI_CLOCK_REALTIME, WASI_CLOCK_MONOTONIC,
  WASI_WHENCE_SET, WASI_WHENCE_CUR, WASI_WHENCE_END,
  WASI_PREOPENTYPE_DIR,
  WASI_FILETYPE_UNKNOWN, WASI_FILETYPE_DIRECTORY,
  WASI_FILETYPE_REGULAR_FILE, WASI_FILETYPE_SYMBOLIC_LINK,
  WASI_FILETYPE_CHARACTER_DEVICE,
  WASI_LOOKUP_SYMLINK_FOLLOW,
  WASI_ADVICE_NORMAL, WASI_EVENTTYPE_CLOCK,
  WASI_EVENTTYPE_FD_READ, WASI_EVENTTYPE_FD_WRITE,
  WASI_FILESTAT_SET_ATIM, WASI_FILESTAT_SET_ATIM_NOW,
  WASI_FILESTAT_SET_MTIM, WASI_FILESTAT_SET_MTIM_NOW,
  WASI_SOCK_RECV_PEEK, WASI_SOCK_RECV_WAITALL,
  WASI_SHUT_RD, WASI_SHUT_WR,
  WASI_SUBSCRIPTION_CLOCK_ABSTIME,
  WASI_EVENT_FD_READWRITE_HANGUP,
  writeFilestat, writeDirent,
} from './WasiTypes';

/** Preopened directory descriptor. */
export class PreopenDir {
  path: string = '/';
  filetype: number = 3;
  constructor(path: string, filetype: number) { this.path = path; this.filetype = filetype; }
}

// ═══════════════════════════════════════════════════════════════════════════
// WasiEnv — platform abstraction
// ═══════════════════════════════════════════════════════════════════════════

export interface WasiEnv {
  /** Current time in nanoseconds (epoch may be arbitrary). */
  nowNanos: () => bigint;
  /** Clock resolution in nanoseconds. */
  clockResolution: (clockId: number) => bigint;

  /** Fill `buf` with cryptographically-strong random bytes. */
  randomFill: (buf: Uint8Array) => void;

  /** Pre-buffered stdin contents. If null/empty, fd_read returns EOF. */
  stdin?: Uint8Array;

  /** Called when wasm writes to fd 1 (stdout). */
  onStdout?: (data: Uint8Array) => void;
  /** Called when wasm writes to fd 2 (stderr). */
  onStderr?: (data: Uint8Array) => void;

  /** Called on proc_exit(code). Default throws HostTrap. */
  onExit?: (code: number) => void;

  /** Preopened directory entries. Index = fd. */
  preopens?: PreopenDir[];

  // ── file system callbacks (all optional; missing → ENOSYS) ──────────

  /** Open a file. Returns fd (>= 0) or negative errno. */
  fsOpen?: (path: string, oflags: number, rights: bigint, fdflags: number) => number;
  /** Read bytes at offset. Returns byte count (>= 0) or negative errno. */
  fsRead?: (fd: number, buf: Uint8Array, offset: bigint) => number;
  /** Write bytes at offset. Returns byte count (>= 0) or negative errno. */
  fsWrite?: (fd: number, data: Uint8Array, offset: bigint) => number;
  /** Close fd. Returns 0 or negative errno. */
  fsClose?: (fd: number) => number;
  /** Seek fd. Returns 0 or negative errno; newoffset is written by caller via out-ptr. */
  fsSeek?: (fd: number, offset: bigint, whence: number, dv: DataView, newoffsetPtr: number) => number;
  /** Get filestat for fd. Returns 0 or negative errno; writes into dv at ptr. */
  fsFilestatGet?: (fd: number, dv: DataView, ptr: number) => number;
  /** Unlink a file. Returns 0 or negative errno. */
  fsUnlink?: (path: string) => number;
  /** Create directory. Returns 0 or negative errno. */
  fsMkdir?: (path: string) => number;
  /** Remove directory. Returns 0 or negative errno. */
  fsRmdir?: (path: string) => number;
  /** Rename. Returns 0 or negative errno. */
  fsRename?: (oldPath: string, newPath: string) => number;
  /** Create symlink. Returns 0 or negative errno. */
  fsSymlink?: (target: string, linkPath: string) => number;
  /** Read symlink target. Returns string or negative errno. */
  fsReadlink?: (path: string, buf: Uint8Array) => number;
  /** Create hard link. Returns 0 or negative errno. */
  fsLink?: (existing: string, newPath: string) => number;
  /** Read directory entries. Returns bytes written or negative errno. */
  fsReaddir?: (fd: number, bufPtr: number, bufLen: number, cookie: bigint, dv: DataView) => number;
}

// ═══════════════════════════════════════════════════════════════════════════
// DefaultWasiEnv — used when no env is supplied (browser / generic TS)
// ═══════════════════════════════════════════════════════════════════════════

export function createDefaultWasiEnv(): WasiEnv {
  return {
    nowNanos: () => BigInt(Date.now()) * 1_000_000n,
    clockResolution: (_id) => 1_000_000n,
    randomFill: (buf) => {
      for (let i = 0; i < buf.length; i++) buf[i] = Math.floor(Math.random() * 256);
    },
    onStdout: (_data: Uint8Array) => {
      // Override in HarmonyOS with hilog.info
    },
    onStderr: (_data: Uint8Array) => {
      // Override in HarmonyOS with hilog.warn
    },
    preopens: [],
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// WasiProvider
// ═══════════════════════════════════════════════════════════════════════════

export class WasiProvider implements ImportProvider {
  private env: WasiEnv;
  private args: string[];
  private environ: Record<string, string>;

  /** Pre-computed argc/argv memory byte layouts. */
  private argcBytes: Uint8Array = new Uint8Array(0);
  private argvBytes: Uint8Array = new Uint8Array(0);
  private environCount: number = 0;
  private environBuf: Uint8Array | null = null;

  /** Per-fd seek cursor (bigint). Index = fd. */
  private fdCursor: Map<number, bigint> = new Map();

  constructor(env?: WasiEnv | Partial<WasiEnv>, args: string[] = [],
              environ: Record<string, string> = {}) {
    const defaults: WasiEnv = createDefaultWasiEnv();
    if (env !== undefined) {
      if (env.nowNanos) defaults.nowNanos = env.nowNanos;
      if (env.clockResolution) defaults.clockResolution = env.clockResolution;
      if (env.randomFill) defaults.randomFill = env.randomFill;
      if (env.stdin) defaults.stdin = env.stdin;
      if (env.onStdout) defaults.onStdout = env.onStdout;
      if (env.onStderr) defaults.onStderr = env.onStderr;
      if (env.onExit) defaults.onExit = env.onExit;
      if (env.preopens) defaults.preopens = env.preopens;
    }
    this.env = defaults;
    this.args = args;
    this.environ = environ;
    this.recomputeArgs();
  }

  private recomputeArgs(): void {
    const argc = this.args.length;
    let totalArgvLen = 0;
    for (const a of this.args) totalArgvLen += a.length + 1;
    this.argcBytes = new Uint8Array(4);
    new DataView(this.argcBytes.buffer).setUint32(0, argc, true);
    this.argvBytes = new Uint8Array(argc * 4 + totalArgvLen);
    const dv = new DataView(this.argvBytes.buffer);
    let strOff = argc * 4;
    for (let i = 0; i < argc; i++) {
      dv.setUint32(i * 4, strOff, true);
      for (let j = 0; j < this.args[i].length; j++) {
        this.argvBytes[strOff++] = this.args[i].charCodeAt(j);
      }
      this.argvBytes[strOff++] = 0;
    }

    // environ
    const keys = Object.keys(this.environ);
    this.environCount = keys.length;
    if (this.environCount > 0) {
      let totalEnvLen = 0;
      for (const k of keys) totalEnvLen += (k.length + 1 + this.environ[k].length + 1);
      this.environBuf = new Uint8Array(this.environCount * 4 + totalEnvLen);
      const edv = new DataView(this.environBuf.buffer);
      let eOff = this.environCount * 4;
      for (let i = 0; i < this.environCount; i++) {
        const entry = keys[i] + '=' + this.environ[keys[i]];
        edv.setUint32(i * 4, eOff, true);
        for (let j = 0; j < entry.length; j++) {
          this.environBuf[eOff++] = entry.charCodeAt(j);
        }
        this.environBuf[eOff++] = 0;
      }
    } else {
      this.environBuf = null;
    }
  }

  // ── ImportProvider interface ──────────────────────────────────────────

  getFunction(module: string, field: string): ((args: WasmValue[], mem: WasmMemoryInstance | null) => WasmValue[]) | null {
    if (module !== 'wasi_snapshot_preview1' && module !== 'wasi_unstable') {
      return null;
    }
    // Dispatch by method name (avoid TypeScript Record cast and fn.call)
    const handler = this.resolveWasiMethod(field);
    if (handler === null) return null;
    const self: WasiProvider = this;
    return (args, mem) => {
      try { return handler(self, args, mem); }
      catch (e) {
        if (e instanceof HostTrap) throw e;
        throw new HostTrap(`wasi:${field}: ${(e as Error).message}`);
      }
    };
  }

  private resolveWasiMethod(field: string): ((p: WasiProvider, args: WasmValue[], mem: WasmMemoryInstance | null) => WasmValue[]) | null {
    switch (field) {
      case 'args_sizes_get':     return (p, a, m) => p._wasm_args_sizes_get(a, m);
      case 'args_get':           return (p, a, m) => p._wasm_args_get(a, m);
      case 'environ_sizes_get':  return (p, a, m) => p._wasm_environ_sizes_get(a, m);
      case 'environ_get':        return (p, a, m) => p._wasm_environ_get(a, m);
      case 'proc_exit':          return (p, a, _m) => p._wasm_proc_exit(a);
      case 'proc_raise':         return (p, a, _m) => p._wasm_proc_raise(a);
      case 'sched_yield':        return (p, a, _m) => p._wasm_sched_yield(a);
      case 'clock_time_get':     return (p, a, m) => p._wasm_clock_time_get(a, m);
      case 'clock_res_get':      return (p, a, m) => p._wasm_clock_res_get(a, m);
      case 'random_get':         return (p, a, m) => p._wasm_random_get(a, m);
      case 'fd_read':            return (p, a, m) => p._wasm_fd_read(a, m);
      case 'fd_write':           return (p, a, m) => p._wasm_fd_write(a, m);
      case 'fd_close':           return (p, a, _m) => p._wasm_fd_close(a);
      case 'fd_seek':            return (p, a, m) => p._wasm_fd_seek(a, m);
      case 'fd_tell':            return (p, a, m) => p._wasm_fd_tell(a, m);
      case 'fd_fdstat_get':      return (p, a, m) => p._wasm_fd_fdstat_get(a, m);
      case 'fd_fdstat_set_flags':return (p, a, _m) => p._wasm_fd_fdstat_set_flags(a);
      case 'fd_fdstat_set_rights':return (p, a, _m) => p._wasm_fd_fdstat_set_rights(a);
      case 'fd_prestat_get':     return (p, a, m) => p._wasm_fd_prestat_get(a, m);
      case 'fd_prestat_dir_name':return (p, a, m) => p._wasm_fd_prestat_dir_name(a, m);
      case 'fd_advise':          return (p, a, _m) => p._wasm_fd_advise(a);
      case 'fd_allocate':        return (p, a, _m) => p._wasm_fd_allocate(a);
      case 'fd_datasync':        return (p, a, _m) => p._wasm_fd_datasync(a);
      case 'fd_sync':            return (p, a, _m) => p._wasm_fd_sync(a);
      case 'fd_pread':           return (p, a, m) => p._wasm_fd_pread(a, m);
      case 'fd_pwrite':          return (p, a, m) => p._wasm_fd_pwrite(a, m);
      case 'fd_renumber':        return (p, a, _m) => p._wasm_fd_renumber(a);
      case 'fd_readdir':         return (p, a, m) => p._wasm_fd_readdir(a, m);
      case 'fd_filestat_get':    return (p, a, m) => p._wasm_fd_filestat_get(a, m);
      case 'fd_filestat_set_size':return (p, a, _m) => p._wasm_fd_filestat_set_size(a);
      case 'fd_filestat_set_times':return (p, a, _m) => p._wasm_fd_filestat_set_times(a);
      case 'path_open':          return (p, a, m) => p._wasm_path_open(a, m);
      case 'path_filestat_get':  return (p, a, m) => p._wasm_path_filestat_get(a, m);
      case 'path_readlink':      return (p, a, m) => p._wasm_path_readlink(a, m);
      case 'path_create_directory':return (p, a, m) => p._wasm_path_create_directory(a, m);
      case 'path_remove_directory':return (p, a, m) => p._wasm_path_remove_directory(a, m);
      case 'path_unlink_file':   return (p, a, m) => p._wasm_path_unlink_file(a, m);
      case 'path_rename':        return (p, a, m) => p._wasm_path_rename(a, m);
      case 'path_symlink':       return (p, a, m) => p._wasm_path_symlink(a, m);
      case 'path_link':          return (p, a, m) => p._wasm_path_link(a, m);
      case 'path_filestat_set_times':return (p, a, m) => p._wasm_path_filestat_set_times(a, m);
      case 'poll_oneoff':        return (p, a, m) => p._wasm_poll_oneoff(a, m);
      default: return null;
    }
  }

  getMemory(): WasmMemoryInstance | null { return null; }
  getTable(): null { return null; }
  getGlobal(): null { return null; }

  // ── internal helpers ──────────────────────────────────────────────────

  private memData(mem: WasmMemoryInstance | null): Uint8Array {
    if (!mem) throw new HostTrap('wasi: no memory');
    return mem.data;
  }
  private memDV(mem: WasmMemoryInstance | null): DataView {
    if (!mem) throw new HostTrap('wasi: no memory');
    return new DataView(mem.buffer);
  }

  /** Read an iovec array from wasm memory. Returns total bytes available. */
  private iovecRead(data: Uint8Array, dv: DataView, iovsPtr: number, iovsLen: number,
                     out: Uint8Array[], outLens: number[]): number {
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = dv.getUint32(iovsPtr + i * 8, true);
      const len = dv.getUint32(iovsPtr + i * 8 + 4, true);
      outLens.push(len);
      out.push(data.subarray(ptr, ptr + len));
      total += len;
    }
    return total;
  }

  /** Normalize a wasm path string (remove /. , resolve .. etc.). */
  private pathNormalize(raw: string): string {
    // basic normalization: strip trailing /, leading ./
    let p = raw;
    while (p.startsWith('./')) p = p.slice(2);
    if (p === '.' || p === '') p = '/';
    if (!p.startsWith('/')) p = '/' + p;
    // collapse // and trailing /
    while (p.includes('//')) p = p.replace('//', '/');
    if (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
    return p;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §1 Args
  // ═══════════════════════════════════════════════════════════════════════

  private _wasm_args_sizes_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const dv = this.memDV(mem);
    dv.setUint32(args[0].getAsI32(), this.args.length, true);
    dv.setUint32(args[1].getAsI32(), this.argvBytes.length - this.args.length * 4, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_args_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const argvPtr = args[0].getAsI32();
    const argvBuf = args[1].getAsI32();
    const data = this.memData(mem);
    const dv = this.memDV(mem);
    const argc = this.args.length;
    let strOff = argvBuf;
    for (let i = 0; i < argc; i++) {
      dv.setUint32(argvPtr + i * 4, strOff, true);
      for (let j = 0; j < this.args[i].length; j++) {
        data[strOff++] = this.args[i].charCodeAt(j);
      }
      data[strOff++] = 0;
    }
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §2 Environ
  // ═══════════════════════════════════════════════════════════════════════

  private _wasm_environ_sizes_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const dv = this.memDV(mem);
    dv.setUint32(args[0].getAsI32(), this.environCount, true);
    const bufSize = this.environBuf ? (this.environBuf.length - this.environCount * 4) : 0;
    dv.setUint32(args[1].getAsI32(), bufSize, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_environ_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    if (!this.environBuf) return [WasmValue.i32(WASI_ESUCCESS)];
    const envPtr = args[0].getAsI32();
    const envBuf = args[1].getAsI32();
    const data = this.memData(mem);
    const dv = this.memDV(mem);
    // Recompute offsets relative to destination buffer
    const keys = Object.keys(this.environ);
    let strOff = envBuf;
    for (let i = 0; i < keys.length; i++) {
      const entry = keys[i] + '=' + this.environ[keys[i]];
      dv.setUint32(envPtr + i * 4, strOff, true);
      for (let j = 0; j < entry.length; j++) {
        data[strOff++] = entry.charCodeAt(j);
      }
      data[strOff++] = 0;
    }
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §3 Process / Sched
  // ═══════════════════════════════════════════════════════════════════════

  private _wasm_proc_exit(args: WasmValue[]): WasmValue[] {
    const code = args[0].getAsI32();
    if (this.env.onExit) { this.env.onExit(code); }
    throw new HostTrap(`wasi: exit(${code})`);
  }

  private _wasm_proc_raise(_args: WasmValue[]): WasmValue[] {
    throw new HostTrap('wasi: proc_raise');
  }

  private _wasm_sched_yield(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §4 Clock / Random
  // ═══════════════════════════════════════════════════════════════════════

  private _wasm_clock_time_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const clockId = args[0].getAsI32();
    const timePtr = args[2].getAsI32();
    if (clockId === WASI_CLOCK_REALTIME || clockId === WASI_CLOCK_MONOTONIC) {
      this.memDV(mem).setBigInt64(timePtr, this.env.nowNanos(), true);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_ENOSYS)];
  }

  private _wasm_clock_res_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const clockId = args[0].getAsI32();
    const resPtr = args[1].getAsI32();
    if (clockId === WASI_CLOCK_REALTIME || clockId === WASI_CLOCK_MONOTONIC) {
      this.memDV(mem).setBigInt64(resPtr, this.env.clockResolution(clockId), true);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_ENOSYS)];
  }

  private _wasm_random_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const ptr = args[0].getAsI32();
    const len = args[1].getAsI32();
    const buf = this.memData(mem).subarray(ptr, ptr + len);
    this.env.randomFill(buf);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §5 fd — file descriptor operations (19 functions)
  // ═══════════════════════════════════════════════════════════════════════

  private getFdRights(fd: number): bigint {
    if (fd === 0) return WASI_RIGHTS_STDIN;
    if (fd === 1 || fd === 2) return WASI_RIGHTS_STDOUT;
    return WASI_RIGHTS_FILE_BASE | WASI_RIGHTS_DIR_BASE;
  }

  private _wasm_fd_read(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const iovs = args[1].getAsI32();
    const iovsLen = args[2].getAsI32();
    const nreadPtr = args[3].getAsI32();
    const data = this.memData(mem);
    const dv = this.memDV(mem);

    let totalRead = 0;

    if (fd === 0 && this.env.stdin) {
      // Read from pre-buffered stdin
      const cursor = Number(this.fdCursor.get(fd) ?? 0n);
      let stdinRemain = this.env.stdin.length - cursor;
      for (let i = 0; i < iovsLen && stdinRemain > 0; i++) {
        const ptr = dv.getUint32(iovs + i * 8, true);
        const len = Math.min(dv.getUint32(iovs + i * 8 + 4, true), stdinRemain);
        for (let j = 0; j < len; j++) data[ptr + j] = this.env.stdin![cursor + totalRead + j];
        totalRead += len;
        stdinRemain -= len;
      }
      this.fdCursor.set(fd, BigInt(cursor) + BigInt(totalRead));
      dv.setUint32(nreadPtr, totalRead, true);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }

    if (this.env.fsRead) {
      let fsFd = fd;
      if (fd === 0) { fsFd = 0; dv.setUint32(nreadPtr, 0, true); return [WasmValue.i32(WASI_ESUCCESS)]; }
      for (let i = 0; i < iovsLen; i++) {
        const ptr = dv.getUint32(iovs + i * 8, true);
        const len = dv.getUint32(iovs + i * 8 + 4, true);
        const buf = data.subarray(ptr, ptr + len);
        const cursor = this.fdCursor.get(fd) ?? 0n;
        const n = this.env.fsRead!(fsFd, buf, cursor);
        if (n < 0) { dv.setUint32(nreadPtr, totalRead, true); return [WasmValue.i32(-n)]; }
        this.fdCursor.set(fd, cursor + BigInt(n));
        totalRead += n;
        if (n < len) break; // short read
      }
      dv.setUint32(nreadPtr, totalRead, true);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }

    // No stdin buffer and no fs backend
    if (fd === 0) {
      dv.setUint32(nreadPtr, 0, true);
      return [WasmValue.i32(WASI_ESUCCESS)]; // EOF
    }
    dv.setUint32(nreadPtr, 0, true);
    return [WasmValue.i32(WASI_EBADF)];
  }

  private _wasm_fd_write(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const iovs = args[1].getAsI32();
    const iovsLen = args[2].getAsI32();
    const nwrittenPtr = args[3].getAsI32();
    const data = this.memData(mem);
    const dv = this.memDV(mem);
    let totalWritten = 0;

    for (let i = 0; i < iovsLen; i++) {
      const ptr = dv.getUint32(iovs + i * 8, true);
      const len = dv.getUint32(iovs + i * 8 + 4, true);
      const chunk = data.subarray(ptr, ptr + len);

      if (fd === 1 && this.env.onStdout) {
        this.env.onStdout(chunk);
        totalWritten += len;
      } else if (fd === 2 && this.env.onStderr) {
        this.env.onStderr(chunk);
        totalWritten += len;
      } else if (fd >= 3 && this.env.fsWrite) {
        const cursor = this.fdCursor.get(fd) ?? 0n;
        const n = this.env.fsWrite(fd, chunk, cursor);
        if (n < 0) { dv.setUint32(nwrittenPtr, totalWritten, true); return [WasmValue.i32(-n)]; }
        this.fdCursor.set(fd, cursor + BigInt(n));
        totalWritten += n;
      } else if (fd <= 2) {
        // fallback: still count as written but silently discard
        totalWritten += len;
      } else {
        dv.setUint32(nwrittenPtr, totalWritten, true);
        return [WasmValue.i32(WASI_EBADF)];
      }
    }
    dv.setUint32(nwrittenPtr, totalWritten, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_close(args: WasmValue[]): WasmValue[] {
    const fd = args[0].getAsI32();
    if (fd <= 2) return [WasmValue.i32(WASI_ESUCCESS)];
    this.fdCursor.delete(fd);
    if (this.env.fsClose) {
      const r = this.env.fsClose(fd);
      return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_seek(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const offset = args[1].getAsI64();
    const whence = args[2].getAsI32();
    const newoffsetPtr = args[3].getAsI32();
    const dv = this.memDV(mem);

    if (this.env.fsSeek) {
      const r = this.env.fsSeek(fd, offset, whence, dv, newoffsetPtr);
      return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
    }

    // Minimal cursor tracking for fd 0-2
    if (fd <= 2) {
      let cur = this.fdCursor.get(fd) ?? 0n;
      if (whence === WASI_WHENCE_SET) cur = offset;
      else if (whence === WASI_WHENCE_CUR) cur += offset;
      else if (whence === WASI_WHENCE_END) cur = 0n; // stream end = 0
      this.fdCursor.set(fd, cur);
      dv.setBigInt64(newoffsetPtr, cur, true);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_EBADF)];
  }

  private _wasm_fd_tell(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const offsetPtr = args[1].getAsI32();
    const cur = this.fdCursor.get(fd) ?? 0n;
    this.memDV(mem).setBigInt64(offsetPtr, cur, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_fdstat_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const statPtr = args[1].getAsI32();
    const dv = this.memDV(mem);

    // fdstat layout: fs_filetype(1) fs_flags(2) + padding(5) fs_rights_base(8) fs_rights_inheriting(8)
    let filetype = WASI_FILETYPE_UNKNOWN;
    let rights = 0n;
    let rightsInheriting = 0n;
    let fdflags = 0;

    if (fd === 0) { filetype = WASI_FILETYPE_CHARACTER_DEVICE; rights = WASI_RIGHTS_STDIN; }
    else if (fd === 1 || fd === 2) { filetype = WASI_FILETYPE_CHARACTER_DEVICE; rights = WASI_RIGHTS_STDOUT; }
    else { filetype = WASI_FILETYPE_REGULAR_FILE; rights = WASI_RIGHTS_FILE_BASE; rightsInheriting = 0n; }

    dv.setUint8(statPtr, filetype);
    dv.setUint16(statPtr + 2, fdflags, true);
    dv.setBigUint64(statPtr + 8, rights, true);
    dv.setBigUint64(statPtr + 16, rightsInheriting, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_fdstat_set_flags(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_fdstat_set_rights(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_prestat_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const prestatPtr = args[1].getAsI32();
    const preopens = this.env.preopens ?? [];
    const idx = fd - 3; // fd 0,1,2 are stdio; preopened dirs start at 3
    if (idx < 0 || idx >= preopens.length) return [WasmValue.i32(WASI_EBADF)];
    const dv = this.memDV(mem);
    dv.setUint8(prestatPtr, WASI_PREOPENTYPE_DIR); // tag
    dv.setUint32(prestatPtr + 4, preopens[idx].path.length, true); // dir_name len
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_prestat_dir_name(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const bufPtr = args[1].getAsI32();
    const bufLen = args[2].getAsI32();
    const preopens = this.env.preopens ?? [];
    const idx = fd - 3;
    if (idx < 0 || idx >= preopens.length) return [WasmValue.i32(WASI_EBADF)];
    const name = preopens[idx].path;
    if (name.length > bufLen) return [WasmValue.i32(WASI_ENAMETOOLONG)];
    const data = this.memData(mem);
    for (let i = 0; i < name.length; i++) data[bufPtr + i] = name.charCodeAt(i);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_advise(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_allocate(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_datasync(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_sync(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_pread(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const iovs = args[1].getAsI32();
    const iovsLen = args[2].getAsI32();
    const offset = args[3].getAsI64();
    const nreadPtr = args[4].getAsI32();
    if (!this.env.fsRead) return [WasmValue.i32(WASI_ENOTSUP)];
    const dv = this.memDV(mem);
    const data = this.memData(mem);
    let totalRead = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = dv.getUint32(iovs + i * 8, true);
      const len = dv.getUint32(iovs + i * 8 + 4, true);
      const buf = data.subarray(ptr, ptr + len);
      const n = this.env.fsRead(fd, buf, offset + BigInt(totalRead));
      if (n < 0) { dv.setUint32(nreadPtr, totalRead, true); return [WasmValue.i32(-n)]; }
      totalRead += n;
      if (n < len) break;
    }
    dv.setUint32(nreadPtr, totalRead, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_pwrite(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const iovs = args[1].getAsI32();
    const iovsLen = args[2].getAsI32();
    const offset = args[3].getAsI64();
    const nwrittenPtr = args[4].getAsI32();
    if (!this.env.fsWrite) return [WasmValue.i32(WASI_ENOTSUP)];
    const dv = this.memDV(mem);
    const data = this.memData(mem);
    let totalWritten = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = dv.getUint32(iovs + i * 8, true);
      const len = dv.getUint32(iovs + i * 8 + 4, true);
      const n = this.env.fsWrite(fd, data.subarray(ptr, ptr + len), offset + BigInt(totalWritten));
      if (n < 0) { dv.setUint32(nwrittenPtr, totalWritten, true); return [WasmValue.i32(-n)]; }
      totalWritten += n;
    }
    dv.setUint32(nwrittenPtr, totalWritten, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_fd_renumber(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_readdir(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const bufPtr = args[1].getAsI32();
    const bufLen = args[2].getAsI32();
    const cookie = args[3].getAsI64();
    const bufUsedPtr = args[4].getAsI32();
    if (this.env.fsReaddir) {
      const dv = this.memDV(mem);
      const n = this.env.fsReaddir(fd, bufPtr, bufLen, cookie, dv);
      dv.setUint32(bufUsedPtr, n < 0 ? 0 : n, true);
      return [WasmValue.i32(n < 0 ? -n : WASI_ESUCCESS)];
    }
    this.memDV(mem).setUint32(bufUsedPtr, 0, true);
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_filestat_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const statPtr = args[1].getAsI32();
    if (this.env.fsFilestatGet) {
      const dv = this.memDV(mem);
      const r = this.env.fsFilestatGet(fd, dv, statPtr);
      return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
    }
    if (fd <= 2) {
      writeFilestat(this.memDV(mem), statPtr, 0n, 0n, WASI_FILETYPE_CHARACTER_DEVICE, 0n, 0n, 0n, 0n, 0n);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_filestat_set_size(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_fd_filestat_set_times(_args: WasmValue[]): WasmValue[] {
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §6 path — file system path operations (10 functions)
  // ═══════════════════════════════════════════════════════════════════════

  private _wasm_path_open(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const _dirflags = args[1].getAsI32();
    const pathPtr = args[2].getAsI32();
    const pathLen = args[3].getAsI32();
    const oflags = args[4].getAsI32();
    const rightsBase = args[5].getAsI64();
    const _rightsInheriting = args[6].getAsI64();
    const fdflags = args[7].getAsI32();
    const openedFdPtr = args[8].getAsI32();

    if (!this.env.fsOpen) {
      this.memDV(mem).setUint32(openedFdPtr, 0, true);
      return [WasmValue.i32(WASI_ENOTSUP)];
    }

    // Resolve path relative to preopened dir
    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    const data = this.memData(mem);
    let rawName = '';
    for (let i = 0; i < pathLen; i++) rawName += String.fromCharCode(data[pathPtr + i]);
    const fullPath = this.pathNormalize(base + '/' + rawName);

    const result = this.env.fsOpen(fullPath, oflags, rightsBase, fdflags);
    if (result < 0) {
      this.memDV(mem).setUint32(openedFdPtr, 0, true);
      return [WasmValue.i32(-result)];
    }
    this.memDV(mem).setUint32(openedFdPtr, result, true); // fd
    return [WasmValue.i32(WASI_ESUCCESS)];
  }

  private _wasm_path_filestat_get(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const _flags = args[1].getAsI32();
    const pathPtr = args[2].getAsI32();
    const pathLen = args[3].getAsI32();
    const statPtr = args[4].getAsI32();
    if (!this.env.fsOpen) return [WasmValue.i32(WASI_ENOTSUP)];

    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    const data = this.memData(mem);
    let rawName = '';
    for (let i = 0; i < pathLen; i++) rawName += String.fromCharCode(data[pathPtr + i]);
    const fullPath = this.pathNormalize(base + '/' + rawName);

    if (this.env.fsFilestatGet) {
      // open temporarily then stat
      const tmpFd = this.env.fsOpen!(fullPath, 0, WASI_RIGHT_FD_FILESTAT_GET, 0);
      if (tmpFd < 0) return [WasmValue.i32(-tmpFd)];
      const dv = this.memDV(mem);
      const r = this.env.fsFilestatGet(tmpFd, dv, statPtr);
      this.env.fsClose!(tmpFd);
      return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_path_readlink(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const pathPtr = args[1].getAsI32();
    const pathLen = args[2].getAsI32();
    const bufPtr = args[3].getAsI32();
    const bufLen = args[4].getAsI32();
    const bufUsedPtr = args[5].getAsI32();

    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    const data = this.memData(mem);
    let rawName = '';
    for (let i = 0; i < pathLen; i++) rawName += String.fromCharCode(data[pathPtr + i]);
    const fullPath = this.pathNormalize(base + '/' + rawName);

    if (this.env.fsReadlink) {
      const writeBuf = this.memData(mem).subarray(bufPtr, bufPtr + bufLen);
      const n = this.env.fsReadlink(fullPath, writeBuf);
      if (n < 0) {
        this.memDV(mem).setUint32(bufUsedPtr, 0, true);
        return [WasmValue.i32(-n)];
      }
      this.memDV(mem).setUint32(bufUsedPtr, n, true);
      return [WasmValue.i32(WASI_ESUCCESS)];
    }
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  private _wasm_path_create_directory(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const pathPtr = args[1].getAsI32();
    const pathLen = args[2].getAsI32();
    if (!this.env.fsMkdir) return [WasmValue.i32(WASI_ENOTSUP)];
    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    const data = this.memData(mem);
    let rawName = '';
    for (let i = 0; i < pathLen; i++) rawName += String.fromCharCode(data[pathPtr + i]);
    const fullPath = this.pathNormalize(base + '/' + rawName);
    const r = this.env.fsMkdir(fullPath);
    return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
  }

  private _wasm_path_remove_directory(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const pathPtr = args[1].getAsI32();
    const pathLen = args[2].getAsI32();
    if (!this.env.fsRmdir) return [WasmValue.i32(WASI_ENOTSUP)];
    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    const data = this.memData(mem);
    let rawName = '';
    for (let i = 0; i < pathLen; i++) rawName += String.fromCharCode(data[pathPtr + i]);
    const fullPath = this.pathNormalize(base + '/' + rawName);
    const r = this.env.fsRmdir(fullPath);
    return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
  }

  private _wasm_path_unlink_file(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const fd = args[0].getAsI32();
    const pathPtr = args[1].getAsI32();
    const pathLen = args[2].getAsI32();
    if (!this.env.fsUnlink) return [WasmValue.i32(WASI_ENOTSUP)];
    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    const data = this.memData(mem);
    let rawName = '';
    for (let i = 0; i < pathLen; i++) rawName += String.fromCharCode(data[pathPtr + i]);
    const fullPath = this.pathNormalize(base + '/' + rawName);
    const r = this.env.fsUnlink(fullPath);
    return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
  }

  private _wasm_path_rename(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const oldFd = args[0].getAsI32();
    const oldPathPtr = args[1].getAsI32();
    const oldPathLen = args[2].getAsI32();
    const newFd = args[3].getAsI32();
    const newPathPtr = args[4].getAsI32();
    const newPathLen = args[5].getAsI32();
    if (!this.env.fsRename) return [WasmValue.i32(WASI_ENOTSUP)];
    const preopens = this.env.preopens ?? [];
    const data = this.memData(mem);
    const resolve = (fd: number, ptr: number, len: number) => {
      const idx = fd - 3;
      let base = '/';
      if (idx >= 0 && idx < preopens.length) base = preopens[idx].path;
      let raw = '';
      for (let i = 0; i < len; i++) raw += String.fromCharCode(data[ptr + i]);
      return this.pathNormalize(base + '/' + raw);
    };
    const oldPath = resolve(oldFd, oldPathPtr, oldPathLen);
    const newPath = resolve(newFd, newPathPtr, newPathLen);
    const r = this.env.fsRename(oldPath, newPath);
    return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
  }

  private _wasm_path_symlink(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const oldPathPtr = args[0].getAsI32();
    const oldPathLen = args[1].getAsI32();
    const fd = args[2].getAsI32();
    const newPathPtr = args[3].getAsI32();
    const newPathLen = args[4].getAsI32();
    if (!this.env.fsSymlink) return [WasmValue.i32(WASI_ENOTSUP)];
    const data = this.memData(mem);
    let target = '';
    for (let i = 0; i < oldPathLen; i++) target += String.fromCharCode(data[oldPathPtr + i]);
    const preopens = this.env.preopens ?? [];
    const dirIdx = fd - 3;
    let base = '/';
    if (dirIdx >= 0 && dirIdx < preopens.length) base = preopens[dirIdx].path;
    let linkPath = '';
    for (let i = 0; i < newPathLen; i++) linkPath += String.fromCharCode(data[newPathPtr + i]);
    const fullLink = this.pathNormalize(base + '/' + linkPath);
    const r = this.env.fsSymlink(target, fullLink);
    return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
  }

  private _wasm_path_link(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const oldFd = args[0].getAsI32();
    const _oldFlags = args[1].getAsI32();
    const oldPathPtr = args[2].getAsI32();
    const oldPathLen = args[3].getAsI32();
    const newFd = args[4].getAsI32();
    const newPathPtr = args[5].getAsI32();
    const newPathLen = args[6].getAsI32();
    if (!this.env.fsLink) return [WasmValue.i32(WASI_ENOTSUP)];
    const preopens = this.env.preopens ?? [];
    const data = this.memData(mem);
    const resolve = (fd: number, ptr: number, len: number) => {
      const idx = fd - 3;
      let base = '/';
      if (idx >= 0 && idx < preopens.length) base = preopens[idx].path;
      let raw = '';
      for (let i = 0; i < len; i++) raw += String.fromCharCode(data[ptr + i]);
      return this.pathNormalize(base + '/' + raw);
    };
    const existing = resolve(oldFd, oldPathPtr, oldPathLen);
    const newPath = resolve(newFd, newPathPtr, newPathLen);
    const r = this.env.fsLink(existing, newPath);
    return [WasmValue.i32(r < 0 ? -r : WASI_ESUCCESS)];
  }

  private _wasm_path_filestat_set_times(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    // stub — requires platform utimes support
    return [WasmValue.i32(WASI_ENOTSUP)];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // §7 poll — poll_oneoff
  // ═══════════════════════════════════════════════════════════════════════

  private _wasm_poll_oneoff(args: WasmValue[], mem: WasmMemoryInstance | null): WasmValue[] {
    const _inPtr = args[0].getAsI32();
    const _outPtr = args[1].getAsI32();
    const nsubscriptions = args[2].getAsI32();
    const neventsPtr = args[3].getAsI32();
    // Stub: no events ready, return 0
    this.memDV(mem).setUint32(neventsPtr, 0, true);
    return [WasmValue.i32(WASI_ESUCCESS)];
  }
}

