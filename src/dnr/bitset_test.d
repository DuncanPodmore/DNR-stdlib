module dnr.bitset_test;

import dnr.testing;
import dnr.mem;
import dnr.bitset;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_primitives() {
    ulong[2] w = 0;
    bits_set(w[], 0);
    bits_set(w[], 63);
    bits_set(w[], 64);
    bits_set(w[], 127);
    check(bits_test(w[], 0) && bits_test(w[], 63) && bits_test(w[], 64) && bits_test(w[], 127),
          "bits_set / bits_test across the word boundary");
    check(!bits_test(w[], 1) && !bits_test(w[], 62) && !bits_test(w[], 65), "unset bits read 0");
    check(bits_count(w[]) == 4, "bits_count");

    bits_clear(w[], 64);
    check(!bits_test(w[], 64) && bits_count(w[]) == 3, "bits_clear");
    bits_flip(w[], 64);
    bits_flip(w[], 0);
    check(bits_test(w[], 64) && !bits_test(w[], 0), "bits_flip");

    check(bits_first_set(w[]).unwrap() == 63, "bits_first_set");
    check(bits_first_set(w[], 64).unwrap() == 64, "bits_first_set from an offset");
    ulong[1] empty = 0;
    check(bits_first_set(empty[]).is_none(), "bits_first_set on an empty array");
}

void test_bitarray() {
    BitArray!100 b;
    check(b.bits == 100 && b.words == 2, "BitArray!100 has 2 words");
    check(ba_none(b), "starts empty");

    ba_set(b, 5);
    ba_set(b, 70);
    ba_set(b, 99);
    check(ba_test(b, 5) && ba_test(b, 70) && ba_test(b, 99), "ba_set / ba_test");
    check(ba_count(b) == 3, "ba_count");
    check(ba_any(b) && !ba_none(b) && !ba_all(b), "any / none / all");

    ba_put(b, 5, false);
    check(!ba_test(b, 5) && ba_count(b) == 2, "ba_put false");

    check(ba_first_set(b).unwrap() == 70, "ba_first_set");
    check(ba_first_clear(b).unwrap() == 0, "ba_first_clear from 0");
    check(ba_first_clear(b, 70).unwrap() == 71, "ba_first_clear skips the set bit");

    ba_set_all(b);
    check(ba_count(b) == 100, "ba_set_all counts exactly N, not the padded word");
    check(ba_all(b), "ba_all after set_all");
    check(ba_first_clear(b).is_none(), "no clear bit after set_all");

    ba_clear_all(b);
    check(ba_none(b), "ba_clear_all");

    // iteration
    ba_set(b, 3); ba_set(b, 3); ba_set(b, 40); ba_set(b, 41); ba_set(b, 95);
    int[5] got;
    int n = 0;
    auto it = ba_iter(b);
    size_t i;
    while (ba_next(it).take(i)) got[n++] = cast(int) i;
    check(n == 4, "ba_iter visited each set bit once");
    check(got[0] == 3 && got[1] == 40 && got[2] == 41 && got[3] == 95, "ba_iter is ascending");
}

void test_bitarray_exact_word() {
    BitArray!64 b;
    check(b.words == 1, "BitArray!64 is one word");
    ba_set_all(b);
    check(ba_count(b) == 64, "set_all on an exact-multiple size");
}

void test_bitset_dynamic() {
    Tracker t;
    Allocator a = tracked(t);

    BitSet b = bitset_make(a, 500).unwrap();
    check(bitset_len(b) == 500, "bitset_len");
    check(bitset_none(b), "starts empty");

    foreach (k; 0 .. 500) if (k % 7 == 0) bitset_set(b, k);
    check(bitset_count(b) == 72, "every 7th of 500 set -> 72 bits");
    check(bitset_test(b, 49) && !bitset_test(b, 50), "bitset_test");

    check(bitset_first_set(b).unwrap() == 0, "first_set");
    check(bitset_first_set(b, 1).unwrap() == 7, "first_set from an offset");
    check(bitset_first_clear(b).unwrap() == 1, "first_clear");

    bitset_flip(b, 0);
    check(!bitset_test(b, 0), "bitset_flip");

    // iterate
    int count = 0;
    auto it = bitset_iter(b);
    size_t idx, last = 0;
    bool ascending = true;
    while (bitset_next(it).take(idx)) {
        if (count > 0 && idx <= last) ascending = false;
        last = idx;
        count++;
    }
    check(ascending, "bitset_iter ascending");
    check(count == bitset_count(b), "bitset_iter count matches bitset_count");

    bitset_set_all(b);
    check(bitset_count(b) == 500, "set_all counts exactly nbits");
    bitset_clear_all(b);
    check(bitset_none(b), "clear_all");

    bitset_free(b);
    check(t.bytes_outstanding == 0, "bitset_free clean");

    // zero-size
    BitSet z = bitset_make(a, 0).unwrap();
    check(bitset_len(z) == 0 && bitset_count(z) == 0, "zero-size bitset");
    bitset_free(z);
}

void run_bitset_tests() {
    test_primitives();
    test_bitarray();
    test_bitarray_exact_word();
    test_bitset_dynamic();
}
