module dnr.rng_test;

import dnr.testing;
import dnr.rng;
import algo = dnr.algo;

void test_determinism() {
    Rng a = rng_seed(12345);
    Rng b = rng_seed(12345);
    bool same = true;
    foreach (i; 0 .. 1000) if (next_u64(a) != next_u64(b)) same = false;
    check(same, "same seed -> identical sequence");

    Rng c = rng_seed(12346);
    Rng d = rng_seed(12345);
    int diffs = 0;
    foreach (i; 0 .. 64) if (next_u64(c) != next_u64(d)) diffs++;
    check(diffs > 60, "a one-bit seed change decorrelates the stream");
}

void test_zero_seed_ok() {
    Rng z = rng_seed(0);
    ulong acc = 0;
    foreach (i; 0 .. 8) acc |= next_u64(z);
    check(acc != 0, "a zero seed still produces non-zero output (splitmix expansion)");
}

void test_float_range() {
    Rng r = rng_seed(99);
    float lo = 1.0f, hi = 0.0f;
    bool inRange = true;
    foreach (i; 0 .. 5000) {
        float v = next_float(r);
        if (v < 0.0f || v >= 1.0f) inRange = false;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    check(inRange, "next_float always in [0, 1)");
    check(lo < 0.05f, "next_float reaches near 0");
    check(hi > 0.95f, "next_float reaches near 1");

    bool dInRange = true;
    foreach (i; 0 .. 2000) {
        double d = next_double(r);
        if (d < 0.0 || d >= 1.0) dInRange = false;
    }
    check(dInRange, "next_double always in [0, 1)");
}

void test_below_and_range() {
    Rng r = rng_seed(7);
    check(below(r, 0) == 0, "below(0) is 0");

    uint[10] hist = 0;
    bool inBound = true;
    foreach (i; 0 .. 100_000) {
        uint v = below(r, 10);
        if (v >= 10) inBound = false;
        hist[v]++;
    }
    check(inBound, "below(10) always in [0, 10)");
    bool balanced = true;
    foreach (h; hist) if (h < 8000 || h > 12000) balanced = false;
    check(balanced, "below() is roughly uniform over its range");

    bool hitLo = false, hitHiMinus1 = false, everHi = false, iInRange = true;
    foreach (i; 0 .. 20_000) {
        int v = range_i(r, -5, 5);
        if (v < -5 || v >= 5) iInRange = false;
        if (v == -5) hitLo = true;
        if (v == 4) hitHiMinus1 = true;
        if (v == 5) everHi = true;
    }
    check(iInRange, "range_i always in [lo, hi)");
    check(hitLo && hitHiMinus1, "range_i reaches both ends of [lo, hi)");
    check(!everHi, "range_i never returns hi");

    bool fInRange = true;
    foreach (i; 0 .. 2000) {
        float f = range_f(r, 10.0f, 20.0f);
        if (f < 10.0f || f >= 20.0f) fInRange = false;
    }
    check(fInRange, "range_f always in [lo, hi)");
}

void test_chance_and_sign() {
    Rng r = rng_seed(3);
    check(!chance(r, 0.0f), "chance(0) is always false");
    check(chance(r, 1.0f), "chance(1) is always true");
    int hits = 0;
    foreach (i; 0 .. 10_000) if (chance(r, 0.25f)) hits++;
    check(hits > 2200 && hits < 2800, "chance(0.25) fires about a quarter of the time");

    int pos = 0;
    foreach (i; 0 .. 10_000) if (sign(r) > 0) pos++;
    check(pos > 4700 && pos < 5300, "sign() is balanced");
}

void test_pick() {
    Rng r = rng_seed(555);
    int[4] xs = [10, 20, 30, 40];
    bool[4] seen = false;
    bool member = true;
    foreach (i; 0 .. 500) {
        int e = pick(r, xs[]);
        if (e != 10 && e != 20 && e != 30 && e != 40) member = false;
        foreach (k; 0 .. 4) if (xs[k] == e) seen[k] = true;
    }
    check(member, "pick always returns a member");
    check(seen[0] && seen[1] && seen[2] && seen[3], "pick eventually hits every element");
}

void test_shuffle() {
    Rng r = rng_seed(2024);

    int[32] a;
    foreach (i; 0 .. 32) a[i] = cast(int) i;
    int[32] original = a;

    shuffle(r, a[]);

    int[32] sortedBack = a;
    algo.sort(sortedBack[]);
    bool permutation = true;
    foreach (i; 0 .. 32) if (sortedBack[i] != cast(int) i) permutation = false;
    check(permutation, "shuffle preserves the multiset");

    int moved = 0;
    foreach (i; 0 .. 32) if (a[i] != original[i]) moved++;
    check(moved > 20, "shuffle actually permutes (most elements moved)");

    int[1] one = [7];
    shuffle(r, one[]);
    check(one[0] == 7, "shuffle of length 1 is a no-op");
}

void run_rng_tests() {
    test_determinism();
    test_zero_seed_ok();
    test_float_range();
    test_below_and_range();
    test_chance_and_sign();
    test_pick();
    test_shuffle();
}
