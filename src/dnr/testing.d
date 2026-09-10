module dnr.testing;

// A tiny assertion harness for betterC — there is no `unittest` runner
// without druntime. A test is a plain function; call check() / near() /
// expect_eq() inside it; a runner calls the test functions and then
// testing_summary(). Reusable by anything that imports dnr-std, not just
// dnr-std's own tests.

import c = core.stdc.stdio;
import m = core.stdc.math;

__gshared int g_checks;
__gshared int g_fails;

void check(bool cond, string msg) {
    g_checks++;
    if (!cond) {
        g_fails++;
        c.printf("  FAIL: %.*s\n", cast(int) msg.length, msg.ptr);
    }
}

// Floating-point equality within a tolerance.
void near(double a, double b, double eps, string msg) {
    check(m.fabs(a - b) <= eps, msg);
}

// Like check(a == b), but prints both sides on failure when T is a number.
void expect_eq(T)(T a, T b, string msg) {
    g_checks++;
    if (a == b) return;
    g_fails++;
    c.printf("  FAIL: %.*s", cast(int) msg.length, msg.ptr);
    static if (__traits(isIntegral, T))
        c.printf("  (got %lld, want %lld)", cast(long) a, cast(long) b);
    else static if (__traits(isFloating, T))
        c.printf("  (got %g, want %g)", cast(double) a, cast(double) b);
    c.printf("\n");
}

// Print the tally. Returns the fail count so a runner can use it as an exit
// code.
int testing_summary() {
    c.printf("\n%d checks, %d failed\n", g_checks, g_fails);
    return g_fails;
}
