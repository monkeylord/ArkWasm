/**
 * WasiTypes.ets — WASI Preview 1 shared constants & types.
 *
 * All values sourced from the WASI snapshot_preview1 spec
 * (platform_wasi_types.h in WAMR/bytecodealliance).
 *
 * This file has zero platform dependencies — safe for all targets.
 */

// ═══════════════════════════════════════════════════════════════════════════
// errno codes
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_ESUCCESS        = 0;
export const WASI_E2BIG           = 1;
export const WASI_EACCES          = 2;
export const WASI_EADDRINUSE      = 3;
export const WASI_EADDRNOTAVAIL   = 4;
export const WASI_EAFNOSUPPORT    = 5;
export const WASI_EAGAIN          = 6;
export const WASI_EALREADY        = 7;
export const WASI_EBADF           = 8;
export const WASI_EBADMSG         = 9;
export const WASI_EBUSY           = 10;
export const WASI_ECANCELED       = 11;
export const WASI_ECHILD          = 12;
export const WASI_ECONNABORTED    = 13;
export const WASI_ECONNREFUSED    = 14;
export const WASI_ECONNRESET      = 15;
export const WASI_EDEADLK         = 16;
export const WASI_EDESTADDRREQ    = 17;
export const WASI_EDOM            = 18;
export const WASI_EDQUOT          = 19;
export const WASI_EEXIST          = 20;
export const WASI_EFAULT          = 21;
export const WASI_EFBIG           = 22;
export const WASI_EHOSTUNREACH    = 23;
export const WASI_EIDRM           = 24;
export const WASI_EILSEQ          = 25;
export const WASI_EINPROGRESS     = 26;
export const WASI_EINTR           = 27;
export const WASI_EINVAL          = 28;
export const WASI_EIO             = 29;
export const WASI_EISCONN         = 30;
export const WASI_EISDIR          = 31;
export const WASI_ELOOP           = 32;
export const WASI_EMFILE          = 33;
export const WASI_EMLINK          = 34;
export const WASI_EMSGSIZE        = 35;
export const WASI_EMULTIHOP       = 36;
export const WASI_ENAMETOOLONG    = 37;
export const WASI_ENETDOWN        = 38;
export const WASI_ENETRESET       = 39;
export const WASI_ENETUNREACH     = 40;
export const WASI_ENFILE          = 41;
export const WASI_ENOBUFS         = 42;
export const WASI_ENODEV          = 43;
export const WASI_ENOENT          = 44;
export const WASI_ENOEXEC         = 45;
export const WASI_ENOLCK          = 46;
export const WASI_ENOLINK         = 47;
export const WASI_ENOMEM          = 48;
export const WASI_ENOMSG          = 49;
export const WASI_ENOPROTOOPT     = 50;
export const WASI_ENOSPC          = 51;
export const WASI_ENOSYS          = 52;
export const WASI_ENOTCONN        = 53;
export const WASI_ENOTDIR         = 54;
export const WASI_ENOTEMPTY       = 55;
export const WASI_ENOTRECOVERABLE = 56;
export const WASI_ENOTSOCK        = 57;
export const WASI_ENOTSUP         = 58;
export const WASI_ENOTTY          = 59;
export const WASI_ENXIO           = 60;
export const WASI_EOVERFLOW       = 61;
export const WASI_EOWNERDEAD      = 62;
export const WASI_EPERM           = 63;
export const WASI_EPIPE           = 64;
export const WASI_EPROTO          = 65;
export const WASI_EPROTONOSUPPORT = 66;
export const WASI_EPROTOTYPE      = 67;
export const WASI_ERANGE          = 68;
export const WASI_EROFS           = 69;
export const WASI_ESPIPE          = 70;
export const WASI_ESRCH           = 71;
export const WASI_ESTALE          = 72;
export const WASI_ETIMEDOUT       = 73;
export const WASI_ETXTBSY         = 74;
export const WASI_EXDEV           = 75;
export const WASI_ENOTCAPABLE     = 76;

// ═══════════════════════════════════════════════════════════════════════════
// Rights (each is 1 << bit)
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_RIGHT_FD_DATASYNC             = 1n << 0n;
export const WASI_RIGHT_FD_READ                 = 1n << 1n;
export const WASI_RIGHT_FD_SEEK                 = 1n << 2n;
export const WASI_RIGHT_FD_FDSTAT_SET_FLAGS     = 1n << 3n;
export const WASI_RIGHT_FD_SYNC                 = 1n << 4n;
export const WASI_RIGHT_FD_TELL                 = 1n << 5n;
export const WASI_RIGHT_FD_WRITE                = 1n << 6n;
export const WASI_RIGHT_FD_ADVISE               = 1n << 7n;
export const WASI_RIGHT_FD_ALLOCATE             = 1n << 8n;
export const WASI_RIGHT_PATH_CREATE_DIRECTORY   = 1n << 9n;
export const WASI_RIGHT_PATH_CREATE_FILE        = 1n << 10n;
export const WASI_RIGHT_PATH_LINK_SOURCE        = 1n << 11n;
export const WASI_RIGHT_PATH_LINK_TARGET        = 1n << 12n;
export const WASI_RIGHT_PATH_OPEN               = 1n << 13n;
export const WASI_RIGHT_FD_READDIR              = 1n << 14n;
export const WASI_RIGHT_PATH_READLINK           = 1n << 15n;
export const WASI_RIGHT_PATH_RENAME_SOURCE      = 1n << 16n;
export const WASI_RIGHT_PATH_RENAME_TARGET      = 1n << 17n;
export const WASI_RIGHT_PATH_FILESTAT_GET       = 1n << 18n;
export const WASI_RIGHT_PATH_FILESTAT_SET_SIZE  = 1n << 19n;
export const WASI_RIGHT_PATH_FILESTAT_SET_TIMES = 1n << 20n;
export const WASI_RIGHT_FD_FILESTAT_GET         = 1n << 21n;
export const WASI_RIGHT_FD_FILESTAT_SET_SIZE    = 1n << 22n;
export const WASI_RIGHT_FD_FILESTAT_SET_TIMES   = 1n << 23n;
export const WASI_RIGHT_PATH_SYMLINK            = 1n << 24n;
export const WASI_RIGHT_PATH_REMOVE_DIRECTORY   = 1n << 25n;
export const WASI_RIGHT_PATH_UNLINK_FILE        = 1n << 26n;
export const WASI_RIGHT_POLL_FD_READWRITE       = 1n << 27n;
export const WASI_RIGHT_SOCK_CONNECT            = 1n << 28n;
export const WASI_RIGHT_SOCK_LISTEN             = 1n << 29n;
export const WASI_RIGHT_SOCK_BIND               = 1n << 30n;
export const WASI_RIGHT_SOCK_ACCEPT             = 1n << 31n;
export const WASI_RIGHT_SOCK_RECV               = 1n << 32n;
export const WASI_RIGHT_SOCK_SEND               = 1n << 33n;
export const WASI_RIGHT_SOCK_ADDR_LOCAL         = 1n << 34n;
export const WASI_RIGHT_SOCK_ADDR_REMOTE        = 1n << 35n;
export const WASI_RIGHT_SOCK_RECV_FROM          = 1n << 36n;
export const WASI_RIGHT_SOCK_SEND_TO            = 1n << 37n;

// Composite rights for standard fd types
export const WASI_RIGHTS_STDIN  = WASI_RIGHT_FD_READ | WASI_RIGHT_FD_WRITE |
  WASI_RIGHT_FD_ADVISE | WASI_RIGHT_FD_FILESTAT_GET | WASI_RIGHT_POLL_FD_READWRITE;
export const WASI_RIGHTS_STDOUT = WASI_RIGHTS_STDIN | WASI_RIGHT_FD_DATASYNC |
  WASI_RIGHT_FD_SYNC | WASI_RIGHT_FD_WRITE;
export const WASI_RIGHTS_STDERR = WASI_RIGHTS_STDOUT;
export const WASI_RIGHTS_DIR_BASE = WASI_RIGHT_FD_FDSTAT_SET_FLAGS |
  WASI_RIGHT_FD_SYNC | WASI_RIGHT_PATH_CREATE_DIRECTORY | WASI_RIGHT_PATH_CREATE_FILE |
  WASI_RIGHT_PATH_LINK_SOURCE | WASI_RIGHT_PATH_LINK_TARGET | WASI_RIGHT_PATH_OPEN |
  WASI_RIGHT_FD_READDIR | WASI_RIGHT_PATH_READLINK | WASI_RIGHT_PATH_RENAME_SOURCE |
  WASI_RIGHT_PATH_RENAME_TARGET | WASI_RIGHT_PATH_FILESTAT_GET |
  WASI_RIGHT_PATH_FILESTAT_SET_SIZE | WASI_RIGHT_PATH_FILESTAT_SET_TIMES |
  WASI_RIGHT_FD_FILESTAT_GET | WASI_RIGHT_FD_FILESTAT_SET_SIZE |
  WASI_RIGHT_FD_FILESTAT_SET_TIMES | WASI_RIGHT_PATH_SYMLINK |
  WASI_RIGHT_PATH_UNLINK_FILE | WASI_RIGHT_PATH_REMOVE_DIRECTORY |
  WASI_RIGHT_POLL_FD_READWRITE;
export const WASI_RIGHTS_FILE_BASE = WASI_RIGHT_FD_DATASYNC | WASI_RIGHT_FD_READ |
  WASI_RIGHT_FD_SEEK | WASI_RIGHT_FD_FDSTAT_SET_FLAGS | WASI_RIGHT_FD_SYNC |
  WASI_RIGHT_FD_TELL | WASI_RIGHT_FD_WRITE | WASI_RIGHT_FD_ADVISE |
  WASI_RIGHT_FD_ALLOCATE | WASI_RIGHT_FD_FILESTAT_GET | WASI_RIGHT_FD_FILESTAT_SET_SIZE |
  WASI_RIGHT_FD_FILESTAT_SET_TIMES | WASI_RIGHT_POLL_FD_READWRITE;

// ═══════════════════════════════════════════════════════════════════════════
// fdflags (bitmask, u16)
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_FDFLAG_APPEND   = 0x0001;
export const WASI_FDFLAG_DSYNC    = 0x0002;
export const WASI_FDFLAG_NONBLOCK = 0x0004;
export const WASI_FDFLAG_RSYNC    = 0x0008;
export const WASI_FDFLAG_SYNC     = 0x0010;

// ═══════════════════════════════════════════════════════════════════════════
// oflags (for path_open)
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_O_CREAT     = 0x0001;
export const WASI_O_DIRECTORY = 0x0002;
export const WASI_O_EXCL      = 0x0004;
export const WASI_O_TRUNC     = 0x0008;

// ═══════════════════════════════════════════════════════════════════════════
// clockid
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_CLOCK_REALTIME           = 0;
export const WASI_CLOCK_MONOTONIC          = 1;
export const WASI_CLOCK_PROCESS_CPUTIME_ID = 2;
export const WASI_CLOCK_THREAD_CPUTIME_ID  = 3;

// ═══════════════════════════════════════════════════════════════════════════
// whence (for fd_seek)
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_WHENCE_SET = 0;
export const WASI_WHENCE_CUR = 1;
export const WASI_WHENCE_END = 2;

// ═══════════════════════════════════════════════════════════════════════════
// prestat / preopentype
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_PREOPENTYPE_DIR = 0;

// ═══════════════════════════════════════════════════════════════════════════
// filetype
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_FILETYPE_UNKNOWN          = 0;
export const WASI_FILETYPE_BLOCK_DEVICE     = 1;
export const WASI_FILETYPE_CHARACTER_DEVICE = 2;
export const WASI_FILETYPE_DIRECTORY        = 3;
export const WASI_FILETYPE_REGULAR_FILE     = 4;
export const WASI_FILETYPE_SOCKET_DGRAM     = 5;
export const WASI_FILETYPE_SOCKET_STREAM    = 6;
export const WASI_FILETYPE_SYMBOLIC_LINK    = 7;

// ═══════════════════════════════════════════════════════════════════════════
// lookupflags
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_LOOKUP_SYMLINK_FOLLOW = 0x00000001;

// ═══════════════════════════════════════════════════════════════════════════
// advice
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_ADVICE_NORMAL     = 0;
export const WASI_ADVICE_SEQUENTIAL = 1;
export const WASI_ADVICE_RANDOM     = 2;
export const WASI_ADVICE_WILLNEED   = 3;
export const WASI_ADVICE_DONTNEED   = 4;
export const WASI_ADVICE_NOREUSE    = 5;

// ═══════════════════════════════════════════════════════════════════════════
// eventtype / eventrwflags
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_EVENTTYPE_CLOCK    = 0;
export const WASI_EVENTTYPE_FD_READ  = 1;
export const WASI_EVENTTYPE_FD_WRITE = 2;
export const WASI_EVENT_FD_READWRITE_HANGUP = 0x0001;

// ═══════════════════════════════════════════════════════════════════════════
// fstflags (filestat set flags)
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_FILESTAT_SET_ATIM     = 0x0001;
export const WASI_FILESTAT_SET_ATIM_NOW = 0x0002;
export const WASI_FILESTAT_SET_MTIM     = 0x0004;
export const WASI_FILESTAT_SET_MTIM_NOW = 0x0008;

// ═══════════════════════════════════════════════════════════════════════════
// socket: riflags, roflags, sdflags, subclockflags
// ═══════════════════════════════════════════════════════════════════════════

export const WASI_SOCK_RECV_PEEK           = 0x0001;
export const WASI_SOCK_RECV_WAITALL        = 0x0002;
export const WASI_SOCK_RECV_DATA_TRUNCATED = 0x0001;
export const WASI_SHUT_RD = 0x01;
export const WASI_SHUT_WR = 0x02;
export const WASI_SUBSCRIPTION_CLOCK_ABSTIME = 0x0001;

// ═══════════════════════════════════════════════════════════════════════════
// WASI filestat layout (24 bytes in memory)
// ═══════════════════════════════════════════════════════════════════════════

/** Write a filestat struct into memory at ptr. */
export function writeFilestat(dv: DataView, ptr: number, dev: bigint, ino: bigint, filetype: number, nlink: bigint, size: bigint, atim: bigint, mtim: bigint, ctim: bigint): void {
  dv.setBigUint64(ptr,      dev,      true);
  dv.setBigUint64(ptr + 8,  ino,      true);
  dv.setUint8    (ptr + 16, filetype);
  dv.setBigUint64(ptr + 24, nlink,    true);
  dv.setBigUint64(ptr + 32, size,     true);
  dv.setBigUint64(ptr + 40, atim,     true);
  dv.setBigUint64(ptr + 48, mtim,     true);
  dv.setBigUint64(ptr + 56, ctim,     true);
}

// ═══════════════════════════════════════════════════════════════════════════
// WASI dirent layout (24 bytes in memory)
// ═══════════════════════════════════════════════════════════════════════════

/** Write a dirent struct into memory at ptr. */
export function writeDirent(dv: DataView, ptr: number, dNext: bigint, dIno: bigint, dNamlen: number, dType: number): void {
  dv.setBigUint64(ptr,      dNext,   true);
  dv.setBigUint64(ptr + 8,  dIno,    true);
  dv.setUint32   (ptr + 16, dNamlen, true);
  dv.setUint8    (ptr + 20, dType);
}
