module dnr.io_test;

import dnr.testing;
import dnr.mem;
import r = dnr.result;
import io = dnr.io;
import s = dnr.str;
import c = core.stdc.stdio;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

private enum TMP = "build/io_test_scratch.txt";

void test_write_read_roundtrip() {
    Tracker t;
    Allocator a = tracked(t);

    immutable string body_ = "hello dnr-std\nsecond line\n";
    check(io.write_file(TMP, body_).is_ok(), "write_file succeeded");
    check(io.file_exists(TMP), "file_exists sees it");
    check(io.file_size(TMP).unwrap() == cast(long) body_.length, "file_size matches what we wrote");

    char[] got = io.read_file_text(a, TMP).unwrap();
    check(got.length == body_.length, "read_file_text length");
    check(s.equals(got, body_), "read_file_text content round-trips");
    free_n(a, got);
    check(t.bytes_outstanding == 0, "read buffer freed");

    check(io.append_file(TMP, "third\n").is_ok(), "append_file succeeded");
    ubyte[] all = io.read_file(a, TMP).unwrap();
    check(s.ends_with(cast(char[]) all, "third\n"), "append landed at the end");
    check(all.length == body_.length + 6, "append grew the file by exactly the bytes written");
    free_n(a, all);

    c.remove(TMP);
}

void test_missing_and_empty() {
    Tracker t;
    Allocator a = tracked(t);

    check(!io.file_exists("build/definitely_not_here_9x.dat"), "file_exists false for a missing file");
    check(io.file_size("build/definitely_not_here_9x.dat").err_or(r.StdErr.unknown) == r.StdErr.not_found,
          "file_size not_found for a missing file");
    check(io.read_file(a, "build/definitely_not_here_9x.dat").err_or(r.StdErr.unknown) == r.StdErr.not_found,
          "read_file not_found for a missing file");

    // an empty file: write succeeds, read comes back an empty (ok) slice
    check(io.write_file(TMP, "").is_ok(), "write_file of nothing");
    check(io.file_exists(TMP), "empty file exists");
    check(io.file_size(TMP).unwrap() == 0, "empty file size 0");
    auto er = io.read_file(a, TMP);
    check(er.is_ok() && er.unwrap is null, "read_file of an empty file is an ok empty slice");
    c.remove(TMP);

    check(t.bytes_outstanding == 0, "no leaks on the failure paths");
}

void test_path_too_long() {
    Tracker t;
    Allocator a = tracked(t);
    char[2000] big = 'x';
    check(io.write_file(big[], "data").is_err(), "write_file rejects an over-long path");
    check(io.read_file(a, big[]).is_err(), "read_file rejects an over-long path");
}

void test_line_reader() {
    const(char)[] ln;

    auto a = io.lines("a\nb\nc");
    io.read_line(a).take(ln); check(s.equals(ln, "a"), "line a (no trailing newline)");
    io.read_line(a).take(ln); check(s.equals(ln, "b"), "line b");
    check(io.read_line(a).take(ln) && s.equals(ln, "c"), "line c is the last");
    check(io.read_line(a).is_none(), "exhausted");

    auto b = io.lines("a\nb\nc\n");
    int n = 0;
    while (io.read_line(b).take(ln)) n++;
    check(n == 3, "trailing newline does not add a phantom empty line");

    auto d = io.lines("one\r\ntwo\r\n");
    io.read_line(d).take(ln); check(s.equals(ln, "one"), "CRLF stripped from line 1");
    io.read_line(d).take(ln); check(s.equals(ln, "two"), "CRLF stripped from line 2");
    check(io.read_line(d).is_none(), "CRLF file exhausted");

    auto e = io.lines("");
    check(io.read_line(e).is_none(), "empty buffer yields no lines");

    auto f = io.lines("solo");
    check(io.read_line(f).take(ln) && s.equals(ln, "solo"), "single line, no newline");
    check(io.read_line(f).is_none(), "then done");

    auto g = io.lines("\n\nx");
    io.read_line(g).take(ln); check(ln.length == 0, "blank line 1 preserved");
    io.read_line(g).take(ln); check(ln.length == 0, "blank line 2 preserved");
    io.read_line(g).take(ln); check(s.equals(ln, "x"), "content after the blanks");
}

void test_line_reader_over_file() {
    Tracker t;
    Allocator a = tracked(t);

    check(io.write_file(TMP, "alpha=1\r\nbeta=2\n# comment\ngamma=3").is_ok(), "wrote a config-shaped file");
    ubyte[] buf = io.read_file(a, TMP).unwrap();
    check(buf !is null, "read it back");

    int kv = 0, comments = 0;
    const(char)[] ln;
    auto it = io.lines(buf);
    while (io.read_line(it).take(ln)) {
        if (s.starts_with(ln, "#")) { comments++; continue; }
        if (s.contains(ln, "=")) kv++;
    }
    check(kv == 3, "three key=value lines");
    check(comments == 1, "one comment line");

    free_n(a, buf);
    c.remove(TMP);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_io_tests() {
    test_write_read_roundtrip();
    test_missing_and_empty();
    test_path_too_long();
    test_line_reader();
    test_line_reader_over_file();
}
