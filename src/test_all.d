module test_all;

// dnr-std test runner. betterC has no unittest runner, so this is a plain
// extern(C) main that calls each module's run_*_tests() and exits non-zero on
// any failure. Mirrors Dopashooter's src/test.d. Add a run_*_tests() call here
// when you add a <module>_test.d.

import dnr.testing;
import dnr.mem_test;
import c = core.stdc.stdio;

extern (C) int main() {
    c.printf("dnr-std tests\n");

    c.printf("mem\n");        run_mem_tests();

    return testing_summary();
}
