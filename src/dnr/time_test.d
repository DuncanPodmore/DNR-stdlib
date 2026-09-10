module dnr.time_test;

import dnr.testing;
import tm = dnr.time;

void test_duration_math() {
    check(tm.dur_as_millis(tm.dur_millis(250)) == 250, "millis round-trip");
    check(tm.dur_as_micros(tm.dur_millis(1)) == 1000, "1 ms is 1000 us");
    check(tm.dur_as_nanos(tm.dur_micros(1)) == 1000, "1 us is 1000 ns");
    near(tm.dur_as_seconds(tm.dur_millis(1500)), 1.5, 1e-9, "1500 ms is 1.5 s");
    near(tm.dur_as_seconds(tm.dur_seconds(2.25)), 2.25, 1e-9, "seconds round-trip");

    auto a = tm.dur_millis(100);
    auto b = tm.dur_millis(30);
    check(tm.dur_as_millis(tm.dur_add(a, b)) == 130, "dur_add");
    check(tm.dur_as_millis(tm.dur_sub(a, b)) == 70, "dur_sub");
    check(tm.dur_cmp(a, b) == 1 && tm.dur_cmp(b, a) == -1 && tm.dur_cmp(a, a) == 0, "dur_cmp");
}

void test_monotonic() {
    auto t0 = tm.now();
    auto t1 = tm.now();
    // now() must never go backward
    check(tm.dur_as_nanos(tm.elapsed(t0, t1)) >= 0, "now() is monotonic");

    // spin for a measurable interval and check the clock advanced sensibly
    auto start = tm.now();
    long acc = 0;
    foreach (i; 0 .. 20_000_000) acc += i & 7;
    auto took = tm.since(start);
    check(acc >= 0, "keep the spin loop from being optimised away");
    check(tm.dur_as_nanos(took) > 0, "the clock advanced across real work");
    check(tm.dur_as_seconds(took) < 10.0, "…but not by an absurd amount");
}

void test_sleep_and_stopwatch() {
    auto sw = tm.sw_start();
    tm.sleep(tm.dur_millis(20));
    auto slept = tm.sw_read(sw);
    // allow generous slack — scheduler granularity, CI load
    check(tm.dur_as_millis(slept) >= 15, "sleep(20ms) waited at least ~15ms");
    check(tm.dur_as_millis(slept) < 500, "sleep(20ms) did not hang");

    auto lap1 = tm.sw_lap(sw);              // ~ the same as `slept`
    tm.sleep(tm.dur_millis(10));
    auto lap2 = tm.sw_lap(sw);
    check(tm.dur_as_nanos(lap1) > 0 && tm.dur_as_nanos(lap2) > 0, "both laps are positive");
    check(tm.dur_cmp(lap2, tm.dur_millis(400)) < 0, "second lap is bounded");

    tm.sleep(tm.dur_millis(-5));            // negative: no-op, no crash
    check(true, "sleep of a negative duration is a safe no-op");
}

void run_time_tests() {
    test_duration_math();
    test_monotonic();
    test_sleep_and_stopwatch();
}
