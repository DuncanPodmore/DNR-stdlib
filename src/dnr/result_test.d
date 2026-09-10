module dnr.result_test;

import dnr.testing;
import r = dnr.result;

void test_option() {
    auto a = r.some(42);
    check(a.is_some() && !a.is_none(), "some is_some");
    check(a.unwrap() == 42, "some unwrap");
    check(a.unwrap_or(0) == 42, "some unwrap_or returns the value");

    auto b = r.none!int();
    check(b.is_none() && !b.is_some(), "none is_none");
    check(b.unwrap_or(7) == 7, "none unwrap_or returns the fallback");

    int got = -1;
    check(a.take(got) && got == 42, "take drains a some");
    got = -1;
    check(!b.take(got) && got == -1, "take of a none leaves the out-param alone");

    int x = 5;
    auto p = r.opt_ptr(&x);
    check(p.is_some() && *p.unwrap() == 5, "opt_ptr wraps a non-null pointer");
    int* np = null;
    check(r.opt_ptr(np).is_none(), "opt_ptr of null is none");
}

void test_result() {
    auto a = r.ok(3.5);
    check(a.is_ok() && !a.is_err(), "ok is_ok");
    check(a.unwrap() == 3.5, "ok unwrap");
    check(a.unwrap_or(0.0) == 3.5, "ok unwrap_or");
    check(a.err_or(r.StdErr.unknown) == r.StdErr.unknown, "err_or on ok returns the fallback");

    auto b = r.err!double(r.StdErr.overflow);
    check(b.is_err() && !b.is_ok(), "err is_err");
    check(b.unwrap_or(9.0) == 9.0, "err unwrap_or returns the fallback");
    check(b.unwrap_err() == r.StdErr.overflow, "err unwrap_err returns the error");
    check(b.err_or(r.StdErr.unknown) == r.StdErr.overflow, "err_or on err returns the error");

    r.StdErr e = r.StdErr.unknown;
    check(b.failed(e) && e == r.StdErr.overflow, "failed drains the error");
    check(!a.failed(e), "failed on ok is false");

    check(a.optional().is_some(), "ok.optional is some");
    check(b.optional().is_none(), "err.optional is none");

    // a custom error type
    auto c = r.err!(int, char)('X');
    check(c.is_err() && c.unwrap_err() == 'X', "Result with a non-StdErr error type");
}

void test_status() {
    auto a = r.pass();
    check(a.is_ok(), "pass is_ok");
    a.unwrap();
    check(true, "pass unwrap does not panic");

    auto b = r.fail(r.StdErr.io);
    check(b.is_err(), "fail is_err");
    check(b.unwrap_err() == r.StdErr.io, "fail unwrap_err");
    check(b.err_or(r.StdErr.unknown) == r.StdErr.io, "status err_or on err");
    check(a.err_or(r.StdErr.io) == r.StdErr.io, "status err_or on ok");

    r.StdErr e;
    check(b.failed(e) && e == r.StdErr.io, "status failed drains");
    check(!a.failed(e), "status failed on ok is false");
}

void test_err_name() {
    check(r.err_name(r.StdErr.oom).length > 0, "err_name oom");
    check(r.err_name(r.StdErr.not_found).length > 0, "err_name not_found");
    // every enumerator has a name (final switch would fail to compile otherwise,
    // but check it doesn't return empty)
    bool allNamed = true;
    foreach (v; [r.StdErr.unknown, r.StdErr.oom, r.StdErr.not_found, r.StdErr.invalid,
                 r.StdErr.overflow, r.StdErr.io, r.StdErr.unexpected_eof, r.StdErr.permission])
        if (r.err_name(v).length == 0) allNamed = false;
    check(allNamed, "every StdErr has a non-empty name");
}

void run_result_tests() {
    test_option();
    test_result();
    test_status();
    test_err_name();
}
