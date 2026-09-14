module dnr.fs_test;

// ⚠️ No `~` anywhere in this file, including inside `enum` string
// declarations — betterC rejects it even in a pure-CTFE context (bit
// dnr.fmt's parse_fmt once, see CLAUDE.md-equivalent project history), so
// every scratch path below is its own fully-spelled-out literal rather than
// ROOT ~ "/something". Same reasoning for the needs_rebuild input lists: a
// named `const(char)[][N]` local, not an array literal inlined at the call
// site.

import dnr.testing;
import dnr.mem;
import r = dnr.result;
import fs = dnr.fs;
import io = dnr.io;
import tm = dnr.time;
import c = core.stdc.stdio;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

private enum ROOT       = "build/fs_test_scratch";
private enum SUB        = "build/fs_test_scratch/sub";
private enum SRC1_PATH  = "build/fs_test_scratch/src.txt";
private enum DST_PATH   = "build/fs_test_scratch/dst.txt";
private enum MOVED_PATH = "build/fs_test_scratch/moved.txt";
private enum A_PATH     = "build/fs_test_scratch/a.txt";
private enum B_PATH     = "build/fs_test_scratch/b.txt";
private enum TOP_PATH   = "build/fs_test_scratch/top.txt";
private enum NESTED_PATH = "build/fs_test_scratch/sub/nested.txt";
private enum ONE_PATH   = "build/fs_test_scratch/one.d";
private enum TWO_PATH   = "build/fs_test_scratch/two.d";
private enum OUT_PATH   = "build/fs_test_scratch/out.bin";
private enum MISSING_PATH = "build/fs_test_scratch/does_not_exist.d";

void test_mkdir_and_file_type() {
    Tracker t;
    Allocator a = tracked(t);

    check(fs.get_file_type("build") == fs.FileType.directory, "build/ is a directory");
    check(fs.get_file_type("makefile") == fs.FileType.regular, "the makefile is a regular file");
    check(fs.get_file_type("build/definitely_not_here_9x7z") == fs.FileType.not_found,
          "a missing path is not_found");

    check(fs.mkdir_if_not_exists(ROOT).is_ok(), "mkdir_if_not_exists creates it");
    check(fs.get_file_type(ROOT) == fs.FileType.directory, "...and it's there");
    check(fs.mkdir_if_not_exists(ROOT).is_ok(), "...and creating it again is still ok (idempotent)");

    fs.delete_directory_recursively(a, ROOT);
    check(t.bytes_outstanding == 0, "no leaks");
}

void test_copy_delete_rename() {
    Tracker t;
    Allocator a = tracked(t);
    fs.mkdir_if_not_exists(ROOT);

    check(io.write_file(SRC1_PATH, "hello").is_ok(), "wrote the source file");
    check(fs.copy_file(SRC1_PATH, DST_PATH).is_ok(), "copy_file succeeded");
    check(io.file_exists(DST_PATH), "the copy exists");
    {
        char[] got = io.read_file_text(a, DST_PATH).unwrap();
        check(got == "hello", "the copy's content matches the source");
        free_n(a, got);
    }

    check(fs.rename_path(DST_PATH, MOVED_PATH).is_ok(), "rename_path succeeded");
    check(!io.file_exists(DST_PATH), "the old name is gone");
    check(io.file_exists(MOVED_PATH), "the new name exists");

    check(fs.delete_file(SRC1_PATH).is_ok(), "delete_file succeeded");
    check(!io.file_exists(SRC1_PATH), "...and it's really gone");
    check(fs.delete_file(SRC1_PATH).is_err(), "deleting it again fails cleanly");

    fs.delete_directory_recursively(a, ROOT);
    check(t.bytes_outstanding == 0, "no leaks");
}

void test_read_dir() {
    Tracker t;
    Allocator a = tracked(t);
    fs.mkdir_if_not_exists(ROOT);
    fs.mkdir_if_not_exists(SUB);
    io.write_file(A_PATH, "a");
    io.write_file(B_PATH, "b");

    auto listingR = fs.read_dir(a, ROOT);
    check(listingR.is_ok(), "read_dir succeeded");
    auto listing = listingR.unwrap;
    check(listing.items.length == 3, "sees a.txt, b.txt and sub/ — not . or ..");

    int files = 0, dirs = 0;
    foreach (name; listing.items) {
        char[512] buf = void;
        size_t n = 0;
        foreach (ch; ROOT) buf[n++] = ch;
        buf[n++] = '/';
        foreach (ch; name) buf[n++] = ch;
        auto ft = fs.get_file_type(buf[0 .. n]);
        if (ft == fs.FileType.directory) dirs++;
        else if (ft == fs.FileType.regular) files++;
    }
    check(files == 2 && dirs == 1, "two files, one subdirectory");

    fs.free_dir_listing(a, listing);
    fs.delete_directory_recursively(a, ROOT);
    check(t.bytes_outstanding == 0, "no leaks");
}

private __gshared int g_walkFiles, g_walkDirs;
private bool count_walk_cb(const(char)[] path, bool isDir, void* userData) @nogc nothrow {
    if (isDir) g_walkDirs++; else g_walkFiles++;
    return true;
}

void test_walk_dir() {
    Tracker t;
    Allocator a = tracked(t);
    fs.mkdir_if_not_exists(ROOT);
    fs.mkdir_if_not_exists(SUB);
    io.write_file(TOP_PATH, "x");
    io.write_file(NESTED_PATH, "y");

    g_walkFiles = 0; g_walkDirs = 0;
    check(fs.walk_dir(a, ROOT, &count_walk_cb, null).is_ok(), "walk_dir completed");
    check(g_walkFiles == 2, "visited both files, top-level and nested");
    check(g_walkDirs == 1, "visited the one subdirectory");

    fs.delete_directory_recursively(a, ROOT);
    check(!io.file_exists(NESTED_PATH), "delete_directory_recursively took everything with it");
    check(t.bytes_outstanding == 0, "no leaks");
}

void test_needs_rebuild() {
    Tracker t;
    Allocator a = tracked(t);
    fs.mkdir_if_not_exists(ROOT);

    io.write_file(ONE_PATH, "a");
    io.write_file(TWO_PATH, "b");

    check(fs.needs_rebuild1(OUT_PATH, ONE_PATH).unwrap() == true, "a missing output always needs a rebuild");

    // Windows FILETIME resolution in practice can be coarser than the time it
    // takes to run a few back-to-back writes — a real failure hit here once
    // (two writes landing on the identical tick, making the "strictly later"
    // comparison read as equal). A short sleep between the source write and
    // the output write is what actually guarantees the ordering these checks
    // rely on, not just program-order back-to-back calls.
    tm.sleep(tm.Duration(20_000_000));   // 20ms
    io.write_file(OUT_PATH, "built");
    check(fs.needs_rebuild1(OUT_PATH, ONE_PATH).unwrap() == false, "freshly built output is up to date");

    tm.sleep(tm.Duration(20_000_000));
    io.write_file(ONE_PATH, "a changed");
    check(fs.needs_rebuild1(OUT_PATH, ONE_PATH).unwrap() == true, "touching the source makes it stale again");

    const(char)[][2] inputs;
    inputs[0] = ONE_PATH; inputs[1] = TWO_PATH;
    check(fs.needs_rebuild(OUT_PATH, inputs[]).unwrap() == true, "needs_rebuild checks every input");

    auto missing = fs.needs_rebuild1(OUT_PATH, MISSING_PATH);
    check(missing.is_err() && missing.unwrap_err() == r.StdErr.not_found,
          "a missing INPUT is always an error, unlike a missing output");

    fs.delete_directory_recursively(a, ROOT);
    check(t.bytes_outstanding == 0, "no leaks");
}

void run_fs_tests() {
    test_mkdir_and_file_type();
    test_copy_delete_rename();
    test_read_dir();
    test_walk_dir();
    test_needs_rebuild();
}
