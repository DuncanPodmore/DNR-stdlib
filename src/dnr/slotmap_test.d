module dnr.slotmap_test;

import dnr.testing;
import dnr.mem;
import dnr.slotmap;
import dnr.rng;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_insert_get_remove() {
    Tracker t;
    auto m = slotmap_make!int(tracked(t));

    Handle a = slotmap_insert(m, 100).unwrap();
    Handle b = slotmap_insert(m, 200).unwrap();
    Handle c = slotmap_insert(m, 300).unwrap();
    check(slotmap_len(m) == 3, "len after 3 inserts");
    check(!handle_is_null(a), "a real handle is not null");
    check(handle_is_null(NULL_HANDLE), "NULL_HANDLE is null");

    check(*slotmap_get(m, b).unwrap() == 200, "get b");
    check(slotmap_contains(m, a) && slotmap_contains(m, c), "contains");

    *slotmap_get(m, a).unwrap() += 1;
    check(*slotmap_get(m, a).unwrap() == 101, "value is mutable through the handle");

    check(slotmap_remove(m, b), "remove b");
    check(slotmap_len(m) == 2, "len after remove");
    check(!slotmap_remove(m, b), "double remove is false");
    check(slotmap_get(m, b).is_none(), "get of a removed handle is none");
    check(!slotmap_contains(m, b), "contains of a removed handle is false");
    // a and c untouched
    check(*slotmap_get(m, a).unwrap() == 101 && *slotmap_get(m, c).unwrap() == 300,
          "other entries survive a remove");

    slotmap_free(m);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_stale_handle_after_reuse() {
    Tracker t;
    auto m = slotmap_make!int(tracked(t));

    Handle first = slotmap_insert(m, 1).unwrap();
    uint firstIndex = first.index;
    check(slotmap_remove(m, first), "remove the first entry");

    // the next insert should reuse that exact slot, with a bumped generation
    Handle second = slotmap_insert(m, 2).unwrap();
    check(second.index == firstIndex, "the freed slot is reused");
    check(second.gen != first.gen, "the reused slot has a new generation");

    check(slotmap_get(m, first).is_none(), "the STALE handle to the reused slot is none");
    check(*slotmap_get(m, second).unwrap() == 2, "the fresh handle resolves");

    slotmap_free(m);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_grow() {
    Tracker t;
    auto m = slotmap_make!int(tracked(t));

    Handle[1000] hs;
    foreach (i; 0 .. 1000) hs[i] = slotmap_insert(m, i * 3).unwrap();
    check(slotmap_len(m) == 1000, "1000 inserts");

    bool allResolve = true;
    foreach (i; 0 .. 1000) {
        int* v;
        if (!slotmap_get(m, hs[i]).take(v) || *v != cast(int) i * 3) allResolve = false;
    }
    check(allResolve, "every handle still resolves after the resizes");

    slotmap_free(m);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_iteration() {
    Tracker t;
    auto m = slotmap_make!int(tracked(t));

    Handle[20] hs;
    foreach (i; 0 .. 20) hs[i] = slotmap_insert(m, i).unwrap();
    // remove the even-valued ones
    foreach (i; 0 .. 20) if (i % 2 == 0) slotmap_remove(m, hs[i]);
    check(slotmap_len(m) == 10, "10 left after removing evens");

    int seen = 0;
    bool allOdd = true, handlesValid = true;
    auto it = slotmap_iter(m);
    Handle h;
    int* v;
    while (slotmap_next(it, h, v)) {
        seen++;
        if (*v % 2 == 0) allOdd = false;
        if (!slotmap_contains(m, h)) handlesValid = false;
    }
    check(seen == 10, "iteration visits every live entry");
    check(allOdd, "only the odd values remain");
    check(handlesValid, "iterator hands back working handles");

    slotmap_free(m);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_clear() {
    Tracker t;
    auto m = slotmap_make!int(tracked(t));
    Handle[8] hs;
    foreach (i; 0 .. 8) hs[i] = slotmap_insert(m, i).unwrap();

    slotmap_clear(m);
    check(slotmap_empty(m), "clear empties");
    foreach (i; 0 .. 8) check(slotmap_get(m, hs[i]).is_none(), "every pre-clear handle is stale");

    Handle fresh = slotmap_insert(m, 99).unwrap();
    check(*slotmap_get(m, fresh).unwrap() == 99, "usable after clear");

    slotmap_free(m);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_random_stress() {
    Tracker t;
    auto m = slotmap_make!int(tracked(t));
    Rng r = rng_seed(7);

    Handle[600] live;
    int[600] liveVal;
    size_t liveCount = 0;
    bool consistent = true;

    foreach (iter; 0 .. 15_000) {
        if (liveCount < 500 && (liveCount == 0 || chance(r, 0.55f))) {
            int val = range_i(r, 0, 1_000_000);
            Handle h = slotmap_insert(m, val).unwrap();
            live[liveCount] = h;
            liveVal[liveCount] = val;
            liveCount++;
        } else {
            size_t k = below(r, cast(uint) liveCount);
            int* v;
            if (!slotmap_get(m, live[k]).take(v) || *v != liveVal[k]) consistent = false;
            slotmap_remove(m, live[k]);
            if (slotmap_contains(m, live[k])) consistent = false;
            live[k] = live[liveCount - 1];
            liveVal[k] = liveVal[liveCount - 1];
            liveCount--;
        }
    }
    check(consistent, "15k insert/get/remove stay consistent with generation checks");
    check(slotmap_len(m) == liveCount, "count matches the live set");

    slotmap_free(m);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_slotmap_tests() {
    test_insert_get_remove();
    test_stale_handle_after_reuse();
    test_grow();
    test_iteration();
    test_clear();
    test_random_stress();
}
