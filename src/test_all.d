module test_all;

// dnr-std test runner. betterC has no unittest runner, so this is a plain
// extern(C) main that calls each module's run_*_tests() and exits non-zero on
// any failure. Mirrors Dopashooter's src/test.d. Add a run_*_tests() call here
// when you add a <module>_test.d.

import dnr.testing;
import dnr.mem_test;
import dnr.array_test;
import dnr.algo_test;
import dnr.math_test;
import dnr.rng_test;
import dnr.str_test;
import c = core.stdc.stdio;

extern (C) int main() {
    c.printf("dnr-std tests\n");

    c.printf("mem\n");        run_mem_tests();
    c.printf("array\n");      run_array_tests();
    c.printf("algo\n");       run_algo_tests();
    c.printf("math\n");       run_math_tests();
    c.printf("rng\n");        run_rng_tests();
    c.printf("str\n");        run_str_tests();

    return testing_summary();
}
