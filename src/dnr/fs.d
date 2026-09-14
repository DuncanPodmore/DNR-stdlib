module dnr.fs;

// ---------------------------------------------------------------------------
// fs — filesystem STRUCTURE
// ---------------------------------------------------------------------------
// dnr.io owns file CONTENTS (whole-file read/write, file_exists, file_size).
// This is everything else about where files live: directories, copying /
// deleting / renaming, listing and walking a directory tree, and comparing
// mtimes for incremental builds. Ported from the filesystem half of
// tsoding/nob.h — see nobd.d (dnr-std's own build tool, repo root) for the
// motivating use case.
//
// ⚠️ Windows only for now. The version(Posix) branch has the right
// signatures so callers type-check on any platform, but its bodies are
// `dnr.panic.todo()` — not a design gap, just not implemented yet (see
// dnr.process's header for the same note, same reasoning).
//
// betterC: @nogc nothrow throughout. Paths are `const(char)[]`, copied into a
// stack buffer to null-terminate (so a path over 1023 bytes is rejected) —
// same convention as dnr.io.

import mem = dnr.mem;
import arr = dnr.array;
import res = dnr.result;
import pan = dnr.panic;
import cstr = core.stdc.string;

private enum size_t PATH_MAX = 1024;

private bool to_cpath(const(char)[] path, ref char[PATH_MAX] buf) @nogc nothrow {
    if (path.length >= PATH_MAX) return false;
    foreach (i, c; path) buf[i] = c;
    buf[path.length] = 0;
    return true;
}

// dir/name (a '/' inserted only if `dir` doesn't already end in one).
// Truncates silently if it doesn't fit buf — callers size buf to PATH_MAX.
private const(char)[] join_path(ref char[PATH_MAX] buf, const(char)[] dir, const(char)[] name) @nogc nothrow {
    size_t n = 0;
    foreach (c; dir) { if (n >= buf.length) break; buf[n++] = c; }
    if (n > 0 && n < buf.length && buf[n - 1] != '/' && buf[n - 1] != '\\') buf[n++] = '/';
    foreach (c; name) { if (n >= buf.length) break; buf[n++] = c; }
    return buf[0 .. n];
}

enum FileType : ubyte { not_found, regular, directory, other }

// A directory entry's own struct, as returned by read_dir — its name is an
// OWNED slice from the Allocator you passed; free the whole listing with
// free_dir_listing rather than each name by hand.
alias DirListing = arr.Array!(char[]);

void free_dir_listing(mem.Allocator a, ref DirListing listing) @nogc nothrow {
    foreach (name; listing.items) mem.free_n(a, name);
    arr.array_free(listing);
}

// Called once per entry by walk_dir. Return false to stop the walk early
// (walk_dir then reports StdErr.unknown). `userData` is the C-style context
// pointer walk_dir was given — same shape as dnr.mem's Allocator vtable,
// since a plain function pointer can't close over locals.
alias WalkFunc = bool function(const(char)[] path, bool isDir, void* userData) @nogc nothrow;

version (Windows) {

private enum uint INVALID_FILE_ATTRIBUTES  = 0xFFFF_FFFF;
private enum uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
private enum uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
private enum uint MOVEFILE_REPLACE_EXISTING = 0x1;
private enum uint ERROR_ALREADY_EXISTS = 183;
private enum uint MAX_PATH_WIN = 260;
private void* INVALID_HANDLE_VALUE() @nogc nothrow { return cast(void*)(-1); }

private struct FileTime { uint dwLowDateTime, dwHighDateTime; }
private struct FileAttributeData {
    uint dwFileAttributes;
    FileTime ftCreationTime, ftLastAccessTime, ftLastWriteTime;
    uint nFileSizeHigh, nFileSizeLow;
}
private struct FindDataA {
    uint dwFileAttributes;
    FileTime ftCreationTime, ftLastAccessTime, ftLastWriteTime;
    uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
    char[MAX_PATH_WIN] cFileName;
    char[14] cAlternateFileName;
}

extern (C) {
    pragma(mangle, "CreateDirectoryA")
    private int win32_CreateDirectoryA(const(char)* path, void* sa) @nogc nothrow;
    pragma(mangle, "RemoveDirectoryA")
    private int win32_RemoveDirectoryA(const(char)* path) @nogc nothrow;
    pragma(mangle, "DeleteFileA")
    private int win32_DeleteFileA(const(char)* path) @nogc nothrow;
    pragma(mangle, "CopyFileA")
    private int win32_CopyFileA(const(char)* existing, const(char)* dst, int failIfExists) @nogc nothrow;
    pragma(mangle, "MoveFileExA")
    private int win32_MoveFileExA(const(char)* existing, const(char)* dst, uint flags) @nogc nothrow;
    pragma(mangle, "GetFileAttributesExA")
    private int win32_GetFileAttributesExA(const(char)* path, int infoLevel, FileAttributeData* data) @nogc nothrow;
    pragma(mangle, "CompareFileTime")
    private int win32_CompareFileTime(const(FileTime)* a, const(FileTime)* b) @nogc nothrow;
    pragma(mangle, "GetLastError")
    private uint win32_get_last_error() @nogc nothrow;
    pragma(mangle, "FindFirstFileA")
    private void* win32_FindFirstFileA(const(char)* pattern, FindDataA* data) @nogc nothrow;
    pragma(mangle, "FindNextFileA")
    private int win32_FindNextFileA(void* handle, FindDataA* data) @nogc nothrow;
    pragma(mangle, "FindClose")
    private int win32_FindClose(void* handle) @nogc nothrow;
}

private bool get_attrs(const(char)[] path, out FileAttributeData data) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return false;
    return win32_GetFileAttributesExA(cp.ptr, 0, &data) != 0;
}

FileType get_file_type(const(char)[] path) @nogc nothrow {
    FileAttributeData d;
    if (!get_attrs(path, d)) return FileType.not_found;
    if (d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) return FileType.directory;
    if (d.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) return FileType.other;
    return FileType.regular;
}

// Idempotent — "already exists" is success, matching Dopashooter's own
// CreateDirectoryA convention (src/screens.d).
res.Status mkdir_if_not_exists(const(char)[] path) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return res.fail(res.StdErr.invalid);
    if (win32_CreateDirectoryA(cp.ptr, null)) return res.pass();
    if (win32_get_last_error() == ERROR_ALREADY_EXISTS) return res.pass();
    return res.fail(res.StdErr.io);
}

// Overwrites `dst` if it already exists.
res.Status copy_file(const(char)[] src, const(char)[] dst) @nogc nothrow {
    char[PATH_MAX] csrc = void, cdst = void;
    if (!to_cpath(src, csrc) || !to_cpath(dst, cdst)) return res.fail(res.StdErr.invalid);
    return win32_CopyFileA(csrc.ptr, cdst.ptr, 0) ? res.pass() : res.fail(res.StdErr.io);
}

res.Status delete_file(const(char)[] path) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return res.fail(res.StdErr.invalid);
    return win32_DeleteFileA(cp.ptr) ? res.pass() : res.fail(res.StdErr.io);
}

// Overwrites `to` if it already exists (MOVEFILE_REPLACE_EXISTING) — the
// shape nob.h's own "Go Rebuild Urself" rename dance needs.
res.Status rename_path(const(char)[] from, const(char)[] to) @nogc nothrow {
    char[PATH_MAX] cfrom = void, cto = void;
    if (!to_cpath(from, cfrom) || !to_cpath(to, cto)) return res.fail(res.StdErr.invalid);
    return win32_MoveFileExA(cfrom.ptr, cto.ptr, MOVEFILE_REPLACE_EXISTING) ? res.pass() : res.fail(res.StdErr.io);
}

// The entries of `path` (files and subdirectories), "." and ".." excluded.
// Each name is its own allocation from `a` — free the whole thing with
// free_dir_listing.
res.Result!DirListing read_dir(mem.Allocator a, const(char)[] path) @nogc nothrow {
    char[PATH_MAX] pattern = void;
    if (path.length + 3 >= PATH_MAX) return res.err!DirListing(res.StdErr.invalid);
    foreach (i, c; path) pattern[i] = c;
    pattern[path.length]     = '\\';
    pattern[path.length + 1] = '*';
    pattern[path.length + 2] = '\0';

    FindDataA fd;
    void* h = win32_FindFirstFileA(pattern.ptr, &fd);
    if (h == INVALID_HANDLE_VALUE()) return res.err!DirListing(res.StdErr.not_found);
    scope (exit) win32_FindClose(h);

    auto listing = arr.array_make!(char[])(a);
    bool more = true;
    while (more) {
        size_t nlen = cstr.strlen(fd.cFileName.ptr);
        const(char)[] name = fd.cFileName[0 .. nlen];
        bool dot    = name.length == 1 && name[0] == '.';
        bool dotdot = name.length == 2 && name[0] == '.' && name[1] == '.';
        if (!dot && !dotdot) {
            auto dupR = mem.make_n!char(a, name.length);
            if (dupR.is_ok) {
                char[] slot = dupR.unwrap;
                cstr.memcpy(slot.ptr, name.ptr, name.length);
                if (arr.array_push(listing, slot).is_err) mem.free_n(a, slot);
            }
        }
        more = win32_FindNextFileA(h, &fd) != 0;
    }
    return res.ok(listing);
}

// Visits every file and directory under `root`, recursively. `postOrder`
// controls whether a directory's own callback fires before or after its
// children — recursive delete needs post-order (children gone before their
// parent); a build-and-collect walk usually wants pre-order (the default).
res.Status walk_dir(mem.Allocator a, const(char)[] root, WalkFunc func, void* userData,
                    bool postOrder = false) @nogc nothrow {
    auto listingR = read_dir(a, root);
    if (listingR.is_err) return res.fail(listingR.unwrap_err);
    auto listing = listingR.unwrap;
    scope (exit) free_dir_listing(a, listing);

    foreach (name; listing.items) {
        char[PATH_MAX] buf = void;
        const(char)[] child = join_path(buf, root, name);
        bool isDir = get_file_type(child) == FileType.directory;

        if (isDir && !postOrder && !func(child, true, userData)) return res.fail(res.StdErr.unknown);
        if (isDir) {
            auto s = walk_dir(a, child, func, userData, postOrder);
            if (s.is_err) return s;
        } else {
            if (!func(child, false, userData)) return res.fail(res.StdErr.unknown);
        }
        if (isDir && postOrder && !func(child, true, userData)) return res.fail(res.StdErr.unknown);
    }
    return res.pass();
}

private bool delete_walk_cb(const(char)[] path, bool isDir, void* userData) @nogc nothrow {
    if (isDir) { char[PATH_MAX] cp = void; if (to_cpath(path, cp)) win32_RemoveDirectoryA(cp.ptr); }
    else cast(void) delete_file(path);
    return true;
}

// Deletes everything under `path`, then `path` itself.
res.Status delete_directory_recursively(mem.Allocator a, const(char)[] path) @nogc nothrow {
    auto s = walk_dir(a, path, &delete_walk_cb, null, /* postOrder */ true);
    if (s.is_err) return s;
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return res.fail(res.StdErr.invalid);
    return win32_RemoveDirectoryA(cp.ptr) ? res.pass() : res.fail(res.StdErr.io);
}

// true if `outputPath` is missing, or older than any of `inputPaths` — the
// mtime check that drives an incremental build. `StdErr.not_found` if an
// INPUT is missing (it's needed to build in the first place, so that's
// always an error, unlike a missing output).
res.Result!bool needs_rebuild(const(char)[] outputPath, const(char)[][] inputPaths) @nogc nothrow {
    FileAttributeData outData;
    if (!get_attrs(outputPath, outData)) return res.ok(true);
    foreach (input; inputPaths) {
        FileAttributeData inData;
        if (!get_attrs(input, inData)) return res.err!bool(res.StdErr.not_found);
        if (win32_CompareFileTime(&inData.ftLastWriteTime, &outData.ftLastWriteTime) > 0) return res.ok(true);
    }
    return res.ok(false);
}

res.Result!bool needs_rebuild1(const(char)[] outputPath, const(char)[] inputPath) @nogc nothrow {
    FileAttributeData outData;
    if (!get_attrs(outputPath, outData)) return res.ok(true);
    FileAttributeData inData;
    if (!get_attrs(inputPath, inData)) return res.err!bool(res.StdErr.not_found);
    return res.ok(win32_CompareFileTime(&inData.ftLastWriteTime, &outData.ftLastWriteTime) > 0);
}

} else version (Posix) {

FileType get_file_type(const(char)[] path) @nogc nothrow { pan.todo("dnr.fs.get_file_type: POSIX not implemented yet"); }
res.Status mkdir_if_not_exists(const(char)[] path) @nogc nothrow { pan.todo("dnr.fs.mkdir_if_not_exists: POSIX not implemented yet"); }
res.Status copy_file(const(char)[] src, const(char)[] dst) @nogc nothrow { pan.todo("dnr.fs.copy_file: POSIX not implemented yet"); }
res.Status delete_file(const(char)[] path) @nogc nothrow { pan.todo("dnr.fs.delete_file: POSIX not implemented yet"); }
res.Status rename_path(const(char)[] from, const(char)[] to) @nogc nothrow { pan.todo("dnr.fs.rename_path: POSIX not implemented yet"); }
res.Result!DirListing read_dir(mem.Allocator a, const(char)[] path) @nogc nothrow { pan.todo("dnr.fs.read_dir: POSIX not implemented yet"); }
res.Status walk_dir(mem.Allocator a, const(char)[] root, WalkFunc func, void* userData,
                    bool postOrder = false) @nogc nothrow { pan.todo("dnr.fs.walk_dir: POSIX not implemented yet"); }
res.Status delete_directory_recursively(mem.Allocator a, const(char)[] path) @nogc nothrow { pan.todo("dnr.fs.delete_directory_recursively: POSIX not implemented yet"); }
res.Result!bool needs_rebuild(const(char)[] outputPath, const(char)[][] inputPaths) @nogc nothrow { pan.todo("dnr.fs.needs_rebuild: POSIX not implemented yet"); }
res.Result!bool needs_rebuild1(const(char)[] outputPath, const(char)[] inputPath) @nogc nothrow { pan.todo("dnr.fs.needs_rebuild1: POSIX not implemented yet"); }

} else {
    static assert(false, "dnr.fs: unsupported platform");
}
