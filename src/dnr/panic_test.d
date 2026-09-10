module dnr.panic_test;

// The abort() paths can't be unit-tested in-process; `format_panic` is the
// testable half, and `panic_if(false, …)` must be a plain no-op.

import dnr.testing;
import p = dnr.panic;
import s = dnr.str;

void test_format_panic() {
    char[512] buf = void;
    const(char)[] line = p.format_panic(buf[], "something broke", "src/foo.d", 123);
    check(s.equals(line, "panic: something broke  (src/foo.d:123)"), "format_panic layout");

    // truncation: a tiny buffer must not overflow and must stay a valid slice
    char[16] tiny = void;
    const(char)[] t = p.format_panic(tiny[], "a very long message that will not fit", "x.d", 9);
    check(t.length <= 15, "format_panic respects a small buffer");
    check(s.starts_with(t, "panic:"), "truncated line still starts sanely");

    char[1] one = void;
    const(char)[] z = p.format_panic(one[], "msg", "f", 1);
    check(z.length == 0, "format_panic with a 1-byte buffer yields nothing, no crash");
}

void test_panic_if_false() {
    int reached = 0;
    p.panic_if(false, "should not fire");
    reached = 1;                       // we get here only because it didn't abort
    check(reached == 1, "panic_if(false) returns normally");
    p.panic_if(1 == 2, "also should not fire");
    check(true, "second panic_if(false) also fine");
}

void run_panic_tests() {
    test_format_panic();
    test_panic_if_false();
}
