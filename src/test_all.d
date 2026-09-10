module test_all;

// dnr-std test runner. betterC has no unittest runner, so this is a plain
// extern(C) main that calls each module's run_*_tests() and exits non-zero on
// any failure. Mirrors Dopashooter's src/test.d. Add a run_*_tests() call here
// when you add a <module>_test.d.

import dnr.testing;
import dnr.result_test;
import dnr.mem_test;
import dnr.array_test;
import dnr.algo_test;
import dnr.math_test;
import dnr.rng_test;
import dnr.hash_test;
import dnr.str_test;
import dnr.hashmap_test;
import dnr.panic_test;
import dnr.io_test;
import dnr.bitset_test;
import dnr.ringbuf_test;
import dnr.slotmap_test;
import dnr.fmt_test;
import dnr.ini_test;
import dnr.utf8_test;
import dnr.time_test;
import c = core.stdc.stdio;

extern (C) int main() {
    c.printf("dnr-std tests\n");

    c.printf("result\n");     run_result_tests();
    c.printf("mem\n");        run_mem_tests();
    c.printf("array\n");      run_array_tests();
    c.printf("algo\n");       run_algo_tests();
    c.printf("math\n");       run_math_tests();
    c.printf("rng\n");        run_rng_tests();
    c.printf("hash\n");       run_hash_tests();
    c.printf("str\n");        run_str_tests();
    c.printf("hashmap\n");    run_hashmap_tests();
    c.printf("panic\n");      run_panic_tests();
    c.printf("io\n");         run_io_tests();
    c.printf("bitset\n");     run_bitset_tests();
    c.printf("ringbuf\n");    run_ringbuf_tests();
    c.printf("slotmap\n");    run_slotmap_tests();
    c.printf("fmt\n");        run_fmt_tests();
    c.printf("ini\n");        run_ini_tests();
    c.printf("utf8\n");       run_utf8_tests();
    c.printf("time\n");       run_time_tests();

    return testing_summary();
}
