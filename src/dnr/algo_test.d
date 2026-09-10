module dnr.algo_test;

import dnr.testing;
import dnr.algo;

// A throwaway LCG so the sort tests can hit non-trivial input without taking a
// dependency on dnr.rng.
private struct Lcg { ulong s = 0x2545F4914F6CDD1D; }
private uint next(ref Lcg r) @nogc nothrow {
    r.s = r.s * 6364136223846793005UL + 1442695040888963407UL;
    return cast(uint)(r.s >> 33);
}

private bool desc_int(const int a, const int b) @nogc nothrow { return a > b; }

void test_swap_reverse_fill() {
    int a = 1, b = 2;
    swap(a, b);
    check(a == 2 && b == 1, "swap");

    int[5] xs = [1, 2, 3, 4, 5];
    reverse(xs[]);
    check(xs == [5, 4, 3, 2, 1], "reverse odd length");
    int[4] ys = [1, 2, 3, 4];
    reverse(ys[]);
    check(ys == [4, 3, 2, 1], "reverse even length");

    int[3] z;
    fill(z[], 9);
    check(z == [9, 9, 9], "fill");

    int[1] one = [7];
    reverse(one[]);
    check(one == [7], "reverse length 1 is a no-op");
}

void test_rotate() {
    int[6] a = [0, 1, 2, 3, 4, 5];
    rotate_left(a[], 2);
    check(a == [2, 3, 4, 5, 0, 1], "rotate_left by 2");
    rotate_left(a[], 6);
    check(a == [2, 3, 4, 5, 0, 1], "rotate by len is a no-op");
    rotate_left(a[], 8);
    check(a == [4, 5, 0, 1, 2, 3], "rotate by len+2 == rotate by 2");
}

void test_scan() {
    int[6] a = [3, 1, 4, 1, 5, 9];
    check(index_of(a[], 4).unwrap() == 2, "index_of hit");
    check(index_of(a[], 1).unwrap() == 1, "index_of returns the first match");
    check(index_of(a[], 7).is_none(), "index_of miss");
    check(contains(a[], 9), "contains hit");
    check(!contains(a[], 0), "contains miss");
    check(count(a[], 1) == 2, "count");

    check(equal(a[], a[]), "equal to self");
    int[6] b = [3, 1, 4, 1, 5, 8];
    check(!equal(a[], b[]), "equal detects a difference");
    int[2] c = [3, 1];
    check(!equal(a[], c[]), "equal detects a length mismatch");

    check(min_index(a[]).unwrap() == 1, "min_index");
    check(max_index(a[]).unwrap() == 5, "max_index");
    check(min_index(a[], &desc_int).unwrap() == 5, "min_index under a reversed comparator");

    int[0] empty;
    check(min_index(empty[]).is_none(), "min_index of empty");
}

void test_is_sorted() {
    int[4] up = [1, 2, 2, 3];
    check(is_sorted(up[]), "ascending with a dup is sorted");
    int[4] down = [3, 2, 1, 0];
    check(!is_sorted(down[]), "descending is not ascending-sorted");
    check(is_sorted(down[], &desc_int), "descending is sorted under desc comparator");
    int[1] one = [5];
    check(is_sorted(one[]), "length 1 is sorted");
}

private void check_sorted_run(ref Lcg r, size_t n) {
    // heap buffer would need an allocator; cap at a fixed stack array
    int[512] buf = void;
    assert(n <= buf.length);
    foreach (i; 0 .. n) buf[i] = cast(int)(next(r) % 1000);
    int[] s = buf[0 .. n];

    // reference: count-sort the 0..999 range
    int[1000] freq = 0;
    foreach (v; s) freq[v]++;

    sort(s);
    check(is_sorted(s), "sort produced a sorted slice");

    int[1000] freq2 = 0;
    foreach (v; s) freq2[v]++;
    bool sameMultiset = true;
    foreach (i; 0 .. 1000) if (freq[i] != freq2[i]) sameMultiset = false;
    check(sameMultiset, "sort is a permutation of the input");
}

void test_sort() {
    // edge sizes
    int[0] e0;            sort(e0[]);  check(true, "sort of empty doesn't crash");
    int[1] e1 = [1];      sort(e1[]);  check(e1 == [1], "sort of 1");
    int[2] e2 = [2, 1];   sort(e2[]);  check(e2 == [1, 2], "sort of 2");
    int[2] e2b = [1, 2];  sort(e2b[]); check(e2b == [1, 2], "sort of 2 already sorted");

    int[7] all = [4, 4, 4, 4, 4, 4, 4];
    sort(all[]);
    check(all == [4, 4, 4, 4, 4, 4, 4], "sort of all-equal");

    int[8] rev = [8, 7, 6, 5, 4, 3, 2, 1];
    sort(rev[]);
    check(rev == [1, 2, 3, 4, 5, 6, 7, 8], "sort of reverse-sorted");

    int[8] srt = [1, 2, 3, 4, 5, 6, 7, 8];
    sort(srt[]);
    check(srt == [1, 2, 3, 4, 5, 6, 7, 8], "sort of already-sorted");

    // descending via comparator
    int[6] d = [1, 5, 2, 4, 3, 0];
    sort(d[], &desc_int);
    check(d == [5, 4, 3, 2, 1, 0], "sort descending");

    // randomised, various sizes — including well past the insertion cutoff
    Lcg r;
    foreach (n; [3, 10, 25, 50, 128, 300, 511])
        check_sorted_run(r, n);
}

void test_insertion_sort_stable() {
    // (key, tag) pairs; sort by key only, tags must keep their relative order
    static struct P { int key; int tag; }
    static bool by_key(const P a, const P b) @nogc nothrow { return a.key < b.key; }

    P[6] p = [P(2, 0), P(1, 1), P(2, 2), P(1, 3), P(2, 4), P(1, 5)];
    insertion_sort(p[], &by_key);
    check(p[0].key == 1 && p[0].tag == 1, "stable: first 1 keeps earliest tag");
    check(p[1].tag == 3, "stable: second 1");
    check(p[2].tag == 5, "stable: third 1");
    check(p[3].key == 2 && p[3].tag == 0, "stable: first 2 keeps earliest tag");
    check(p[4].tag == 2, "stable: second 2");
    check(p[5].tag == 4, "stable: third 2");
}

void test_binary_search() {
    int[8] a = [1, 3, 3, 3, 5, 7, 9, 11];

    check(lower_bound(a[], 3) == 1, "lower_bound of a run points at its first");
    check(upper_bound(a[], 3) == 4, "upper_bound of a run points past its last");
    check(lower_bound(a[], 0) == 0, "lower_bound below everything");
    check(lower_bound(a[], 100) == 8, "lower_bound above everything");
    check(lower_bound(a[], 4) == 4, "lower_bound of an absent middle value");

    check(binary_search(a[], 7).unwrap() == 5, "binary_search finds 7");
    check(binary_search(a[], 5).unwrap() == 4, "binary_search finds 5");
    check(binary_search(a[], 3).unwrap() >= 1 && binary_search(a[], 3).unwrap() <= 3, "binary_search finds some 3");
    check(binary_search(a[], 2).is_none(), "binary_search misses 2");
    check(binary_search(a[], 12).is_none(), "binary_search misses past the end");

    int[0] empty;
    check(binary_search(empty[], 1).is_none(), "binary_search of empty");

    // consistency with a comparator-sorted slice
    int[5] d = [9, 7, 5, 3, 1];
    check(is_sorted(d[], &desc_int), "desc slice is sorted for the search");
    check(binary_search(d[], 5, &desc_int).unwrap() == 2, "binary_search under desc comparator");
    check(binary_search(d[], 6, &desc_int).is_none(), "binary_search desc miss");
}

void run_algo_tests() {
    test_swap_reverse_fill();
    test_rotate();
    test_scan();
    test_is_sorted();
    test_sort();
    test_insertion_sort_stable();
    test_binary_search();
}
