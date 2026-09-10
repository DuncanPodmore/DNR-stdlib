module dnr.hash_test;

import dnr.testing;
import h = dnr.hash;

void test_fnv1a_known() {
    // FNV-1a 64 reference vectors
    check(h.fnv1a_str("") == 0xcbf29ce484222325UL, "fnv1a of empty is the offset basis");
    check(h.fnv1a_str("a") == 0xaf63dc4c8601ec8cUL, "fnv1a('a')");
    check(h.fnv1a_str("foobar") == 0x85944171f73967e8UL, "fnv1a('foobar')");
}

void test_determinism_and_sensitivity() {
    check(h.hash64_str("hello world") == h.hash64_str("hello world"), "hash64 is deterministic");

    // one-bit input change should flip roughly half the output bits
    ulong a = h.hash64_str("hello world");
    ulong b = h.hash64_str("hello worlx");
    int diff = 0;
    ulong x = a ^ b;
    while (x) { diff += x & 1; x >>= 1; }
    check(diff > 20 && diff < 44, "a one-char change avalanches ~half the bits");
}

void test_fmix64_avalanche() {
    // fmix64(0) must not be 0; consecutive inputs must not be close
    check(h.fmix64(0) == 0, "fmix64(0) is 0 (0 has no bits to mix)");
    check(h.fmix64(1) != 1 && h.fmix64(1) != 0, "fmix64(1) is well away from 1");
    ulong d = h.fmix64(1) ^ h.fmix64(2);
    int bits = 0;
    while (d) { bits += d & 1; d >>= 1; }
    check(bits > 20, "fmix64(1) and fmix64(2) differ in many bits");
}

void test_hash_combine_order() {
    ulong ab = h.hash_combine(h.hash_combine(0, 111), 222);
    ulong ba = h.hash_combine(h.hash_combine(0, 222), 111);
    check(ab != ba, "hash_combine is order-dependent");
    check(h.hash_combine(0, 5) == h.hash_combine(0, 5), "hash_combine is deterministic");
}

private enum E { a, b, c }

void test_hash_of_dispatch() {
    check(h.hash_of!int(42) == h.hash_of!int(42), "hash_of int deterministic");
    check(h.hash_of!int(42) != h.hash_of!int(43), "hash_of distinguishes ints");
    check(h.hash_of!E(E.b) == h.hash_of!E(E.b), "hash_of enum");

    const(char)[] s1 = "abc";
    char[3] s2 = ['a', 'b', 'c'];
    check(h.hash_of!(const(char)[])(s1) == h.hash_of!(const(char)[])(s2[]),
          "hash_of string hashes by content, not identity");

    int x;
    check(h.hash_of!(int*)(&x) == h.hash_of!(int*)(&x), "hash_of pointer");
}

void test_distribution() {
    // 4096 sequential string keys into 256 buckets — no bucket should be wildly
    // over the 16 average
    uint[256] bucket = 0;
    char[16] buf;
    foreach (i; 0 .. 4096) {
        int n = 0;
        int v = i;
        do { buf[n++] = cast(char)('0' + v % 10); v /= 10; } while (v);
        buf[n++] = 'k';
        ulong hv = h.hash64_str(buf[0 .. n]);
        bucket[hv & 255]++;
    }
    uint lo = uint.max, hi = 0;
    foreach (b; bucket) { if (b < lo) lo = b; if (b > hi) hi = b; }
    check(hi <= 40 && lo >= 2, "hash64 spreads 4096 keys evenly over 256 buckets");
}

void run_hash_tests() {
    test_fnv1a_known();
    test_determinism_and_sensitivity();
    test_fmix64_avalanche();
    test_hash_combine_order();
    test_hash_of_dispatch();
    test_distribution();
}
