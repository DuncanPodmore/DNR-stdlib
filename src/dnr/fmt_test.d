module dnr.fmt_test;

import dnr.testing;
import dnr.mem;
import s = dnr.str;
import f = dnr.fmt;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

private enum Color { red, green, blue }

void test_default_dispatch() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));

    f.format!"n={} u={} f={} b={} c={} s={}"(b, -12, 34u, 1.5, true, 'Z', "hi");
    check(s.equals(s.sb_slice(b), "n=-12 u=34 f=1.500000 b=true c=Z s=hi"), "default dispatch by type");

    s.sb_reset(b);
    f.format!"{}"(b, Color.green);
    check(s.equals(s.sb_slice(b), "green"), "enum formats as its member name");

    s.sb_reset(b);
    f.format!"just a literal, no args"(b);
    check(s.equals(s.sb_slice(b), "just a literal, no args"), "no-placeholder format string");

    s.sb_reset(b);
    f.format!"braces {{ and }} literal, val {}"(b, 7);
    check(s.equals(s.sb_slice(b), "braces { and } literal, val 7"), "{{ }} escapes");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_specs() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));

    f.format!"{x} {X}"(b, 0xdeadBEEF, 0xdeadBEEF);
    check(s.equals(s.sb_slice(b), "deadbeef DEADBEEF"), "{x} / {X} hex");

    s.sb_reset(b);
    f.format!"pi={.2} e={.4}"(b, 3.14159, 2.71828);
    check(s.equals(s.sb_slice(b), "pi=3.14 e=2.7183"), "{.N} float precision (rounds)");

    s.sb_reset(b);
    f.format!"{}:{02}:{02}"(b, 9, 5, 42);
    check(s.equals(s.sb_slice(b), "9:05:42"), "{0N} zero-pad");

    s.sb_reset(b);
    f.format!"{04}"(b, -5);
    check(s.equals(s.sb_slice(b), "-005"), "{0N} pads after a leading minus");

    s.sb_reset(b);
    f.format!"{06}"(b, 1234567);
    check(s.equals(s.sb_slice(b), "1234567"), "{0N} no-op when already wider than the width");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_format_buf() {
    char[32] buf = void;
    auto line = f.format_buf!"{}-{}-{}"(buf[], 2026, 9, 10);
    check(s.equals(line, "2026-9-10"), "format_buf into a stack buffer");

    // truncation: buffer too small, output is cut, no overflow
    char[8] tiny = void;
    auto cut = f.format_buf!"abcdefghij {}"(tiny[], 999);
    check(cut.length == 8, "format_buf truncates to the buffer size");
    check(s.equals(cut, "abcdefgh"), "truncated content is the leading bytes");
}

void test_grows_sb() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));
    foreach (i; 0 .. 300)
        f.format!"[{}]"(b, i);          // forces the Sb to grow repeatedly
    check(s.sb_len(b) > 900, "format drove several Sb grows");
    check(s.starts_with(s.sb_slice(b), "[0][1][2]"), "content is correct after growth");
    check(s.ends_with(s.sb_slice(b), "[299]"), "…through to the end");
    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_fmt_tests() {
    test_default_dispatch();
    test_specs();
    test_format_buf();
    test_grows_sb();
}
