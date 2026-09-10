module dnr.hashmap_test;

import dnr.testing;
import dnr.mem;
import dnr.hashmap;
import dnr.rng;
import s = dnr.str;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_put_get_overwrite() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t));

    check(hm_put(h, 1, 100).is_ok(), "put 1");
    check(hm_put(h, 2, 200).is_ok(), "put 2");
    check(hm_put(h, 3, 300).is_ok(), "put 3");
    check(hm_len(h) == 3, "len after 3 puts");

    check(*hm_get(h, 2).unwrap() == 200, "get 2");
    check(hm_get(h, 99).is_none(), "get absent -> null");
    check(hm_contains(h, 1) && !hm_contains(h, 99), "contains");
    check(hm_get_or(h, 3, -1) == 300, "get_or present");
    check(hm_get_or(h, 4, -1) == -1, "get_or absent");

    check(hm_put(h, 2, 222).is_ok(), "overwrite 2");
    check(hm_len(h) == 3, "len unchanged by overwrite");
    check(*hm_get(h, 2).unwrap() == 222, "get sees the overwrite");

    // mutate through the pointer
    *hm_get(h, 1).unwrap() += 5;
    check(*hm_get(h, 1).unwrap() == 105, "value is mutable through hm_get");

    hm_free(h);
    check(t.bytes_outstanding == 0, "hm_free clean");
    check(hm_len(h) == 0, "map reusable after free");
}

void test_grow() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t));

    bool allPut = true;
    foreach (i; 0 .. 1000) if (hm_put(h, i, i * 7).is_err) allPut = false;
    check(allPut, "1000 bulk puts all succeeded");
    check(hm_len(h) == 1000, "len after 1000");

    bool allFound = true;
    foreach (i; 0 .. 1000) {
        int* v;
        if (!hm_get(h, i).take(v) || *v != i * 7) allFound = false;
    }
    check(allFound, "every key survives the resizes");
    check(hm_get(h, 1000).is_none(), "a never-inserted key is absent");
    check(hm_get(h, -1).is_none(), "another absent key");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_reserve_no_regrow() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t), 500);
    size_t allocs0 = t.total_allocs;
    foreach (i; 0 .. 300) hm_put(h, i, i);
    check(t.total_allocs == allocs0, "no resize when inserting under the reserved capacity");
    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

// force every key into one probe chain, to exercise backward-shift deletion
private size_t all_collide(const int k) @nogc nothrow { return 0; }
private bool int_eq(const int a, const int b) @nogc nothrow { return a == b; }

void test_remove_backshift() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t), 32, &all_collide, &int_eq);

    foreach (i; 0 .. 10) hm_put(h, i, i * 11);
    check(hm_len(h) == 10, "10 colliding keys inserted");

    // remove from the middle of the chain
    check(hm_remove(h, 4), "remove 4");
    check(hm_remove(h, 5), "remove 5");
    check(hm_remove(h, 0), "remove 0 (chain head)");
    check(hm_len(h) == 7, "len after 3 removes");
    check(!hm_remove(h, 4), "remove of an already-removed key -> false");

    bool restOk = true;
    foreach (i; [1, 2, 3, 6, 7, 8, 9]) {
        int* v;
        if (!hm_get(h, i).take(v) || *v != i * 11) restOk = false;
    }
    check(restOk, "every surviving key still reachable after the shifts");
    check(hm_get(h, 4).is_none() && hm_get(h, 5).is_none() && hm_get(h, 0).is_none(),
          "removed keys are gone");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_remove_random_stress() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t));
    Rng r = rng_seed(42);

    // reference table: present[i] and its expected value
    bool[2000] present = false;
    int[2000] value = 0;

    bool removeReturnsOk = true;
    foreach (iter; 0 .. 20_000) {
        int k = range_i(r, 0, 2000);
        if (chance(r, 0.5f)) {
            int val = range_i(r, 1, 1_000_000);
            hm_put(h, k, val);
            present[k] = true;
            value[k] = val;
        } else {
            bool had = present[k];
            if (hm_remove(h, k) != had) removeReturnsOk = false;
            present[k] = false;
        }
    }
    check(removeReturnsOk, "hm_remove's return always matched the reference");

    size_t refCount = 0;
    bool consistent = true;
    foreach (k; 0 .. 2000) {
        int* v;
        bool has = hm_get(h, k).take(v);
        if (present[k]) {
            refCount++;
            if (!has || *v != value[k]) consistent = false;
        } else if (has) {
            consistent = false;
        }
    }
    check(consistent, "map agrees with the reference after 20k mixed ops");
    check(hm_len(h) == refCount, "count matches the reference");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_string_keys() {
    Tracker t;
    auto h = hm_make!(const(char)[], int)(tracked(t));

    hm_put(h, "one", 1);
    hm_put(h, "two", 2);
    hm_put(h, "three", 3);

    check(*hm_get(h, "two").unwrap() == 2, "string key get");

    // a distinct slice with the same contents must hit the same entry
    char[8] buf = "three\0\0\0";
    check(*hm_get(h, buf[0 .. 5]).unwrap() == 3, "string key compares by content, not identity");

    check(hm_get(h, "four").is_none(), "absent string key");
    hm_put(h, "two", 22);
    check(*hm_get(h, "two").unwrap() == 22 && hm_len(h) == 3, "string key overwrite");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_iteration() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t));
    foreach (i; 0 .. 50) hm_put(h, i, i * i);

    int[50] hits = 0;
    size_t seen = 0;
    auto it = hm_iter(h);
    int key;
    int* val;
    while (hm_next(it, key, val)) {
        if (key < 0 || key >= 50) seen = 99999;
        check(*val == key * key, "iterated value matches");
        hits[key]++;
        seen++;
    }
    check(seen == 50, "iteration visited every entry");
    bool eachOnce = true;
    foreach (c; hits) if (c != 1) eachOnce = false;
    check(eachOnce, "each entry visited exactly once");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_clear() {
    Tracker t;
    auto h = hm_make!(int, int)(tracked(t));
    foreach (i; 0 .. 20) hm_put(h, i, i);
    size_t allocsAfterFill = t.total_allocs;

    hm_clear(h);
    check(hm_len(h) == 0 && hm_empty(h), "clear empties");
    check(hm_get(h, 5).is_none(), "no entries after clear");

    hm_put(h, 100, 1);
    check(*hm_get(h, 100).unwrap() == 1, "usable after clear");
    check(t.total_allocs == allocsAfterFill, "clear kept the slot storage");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

private struct Point { int x; int y; }
private size_t point_hash(const Point p) @nogc nothrow {
    return (cast(size_t) p.x * 73856093) ^ (cast(size_t) p.y * 19349663);
}
private bool point_eq(const Point a, const Point b) @nogc nothrow { return a.x == b.x && a.y == b.y; }

void test_struct_key() {
    Tracker t;
    auto h = hm_make!(Point, const(char)[])(tracked(t), 0, &point_hash, &point_eq);

    hm_put(h, Point(1, 2), "a");
    hm_put(h, Point(3, 4), "b");
    hm_put(h, Point(-5, 7), "c");

    check(hm_get(h, Point(3, 4)).is_some(), "struct key found");
    check(hm_get(h, Point(4, 3)).is_none(), "struct key eq is not commutative-collapsed");
    check(s.equals(*hm_get(h, Point(-5, 7)).unwrap(), "c"), "struct key value");

    hm_free(h);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_hashmap_tests() {
    test_put_get_overwrite();
    test_grow();
    test_reserve_no_regrow();
    test_remove_backshift();
    test_remove_random_stress();
    test_string_keys();
    test_iteration();
    test_clear();
    test_struct_key();
}
