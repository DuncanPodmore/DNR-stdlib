module dnr.mem_test;

// Tests for dnr.mem — the allocator layer. Every test runs against a
// tracking_allocator wrapped around malloc_allocator, so each one also
// asserts nothing leaked.

import dnr.testing;
import dnr.mem;

private struct Point { int x = 7; int y = 0; float z = 1.5f; }

// A fresh tracking allocator over real malloc. The caller checks
// t.bytes_outstanding == 0 at the end.
private Allocator tracked(ref Tracker t) {
    return tracking_allocator(t, malloc_allocator());
}

void test_make_unmake() {
    Tracker t;
    Allocator a = tracked(t);

    Point* p = make!Point(a).unwrap;
    check(p !is null, "make returned a pointer");
    expect_eq(p.x, 7, "make: declared field initializer honoured");
    expect_eq(p.y, 0, "make: zero field");
    near(p.z, 1.5, 1e-6, "make: float initializer honoured (not NaN)");
    check(t.allocs_outstanding == 1, "one alloc outstanding");
    check(t.bytes_outstanding == Point.sizeof, "byte count matches");

    unmake(a, p);
    check(t.bytes_outstanding == 0, "unmake freed the block");
    check(t.allocs_outstanding == 0, "no allocs outstanding");
}

void test_make_n() {
    Tracker t;
    Allocator a = tracked(t);

    Point[] s = make_n!Point(a, 16).unwrap;
    check(s.length == 16, "make_n length");
    bool allInit = true;
    foreach (ref e; s) if (e.x != 7 || e.z != 1.5f) allInit = false;
    check(allInit, "make_n: every element .init-filled");

    check(make_n!Point(a, 0).unwrap is null, "make_n(0) is empty");

    free_n(a, s);
    check(t.bytes_outstanding == 0, "free_n cleaned up");
}

void test_resize_n() {
    Tracker t;
    Allocator a = tracked(t);

    int[] s = make_n!int(a, 4).unwrap;
    foreach (i, ref e; s) e = cast(int) i + 1;

    check(resize_n(a, s, 8).is_ok(), "grow succeeded");
    check(s.length == 8, "grew to 8");
    expect_eq(s[0], 1, "old data survived grow");
    expect_eq(s[3], 4, "old data survived grow (last old)");
    expect_eq(s[4], 0, "new tail .init-filled");
    expect_eq(s[7], 0, "new tail .init-filled (last)");

    check(resize_n(a, s, 2).is_ok(), "shrink succeeded");
    check(s.length == 2, "shrank to 2");
    expect_eq(s[1], 2, "data survived shrink");

    check(resize_n(a, s, 0).is_ok(), "resize to 0 succeeded");
    check(s is null, "resize to 0 nulls the slice");
    check(t.bytes_outstanding == 0, "resize chain left nothing");
}

void test_dup() {
    Tracker t;
    Allocator a = tracked(t);

    immutable int[5] src = [10, 20, 30, 40, 50];
    int[] copy = dup!int(a, src[]).unwrap;
    check(copy.length == 5, "dup length");
    check(copy.ptr !is src.ptr, "dup is a distinct block");
    expect_eq(copy[2], 30, "dup copied contents");

    check(dup!int(a, null).unwrap is null, "dup of empty is empty");

    free_n(a, copy);
    check(t.bytes_outstanding == 0, "dup freed");
}

void test_arena_basic() {
    ubyte[1024] backing;
    Arena ar;
    ar.buf = backing[];
    Allocator a = arena_allocator(ar);

    int* x = make!int(a).unwrap;
    *x = 42;
    long* y = make!long(a).unwrap;
    *y = 99;

    check(arena_used(ar) >= int.sizeof + long.sizeof, "arena advanced");
    expect_eq(*x, 42, "arena block x intact");
    expect_eq(*y, 99, "arena block y intact");

    // y was the most recent allocation -> raw_free pops it.
    size_t before = arena_used(ar);
    a.raw_free(y, long.sizeof);
    check(arena_used(ar) < before, "arena LIFO free reclaimed the last block");

    // x is NOT the most recent -> free is a no-op, no corruption.
    size_t afterY = arena_used(ar);
    a.raw_free(x, int.sizeof);
    check(arena_used(ar) == afterY, "arena free of a non-last block is a no-op");

    arena_reset(ar);
    check(arena_used(ar) == 0, "arena_reset");
}

void test_arena_oom() {
    ubyte[64] backing;
    Arena ar;
    ar.buf = backing[];
    Allocator a = arena_allocator(ar);

    void* big = a.raw_alloc(128);
    check(big is null, "arena over-capacity request returns null");

    void* ok = a.raw_alloc(32);
    check(ok !is null, "arena in-capacity request still works after an OOM");
}

void test_arena_alignment() {
    ubyte[256] backing;
    Arena ar;
    ar.buf = backing[];
    Allocator a = arena_allocator(ar);

    a.raw_alloc(1);                       // knock the cursor off alignment
    void* p = a.raw_alloc(8, 16);
    check((cast(size_t) p % 16) == 0, "arena honours a 16-byte alignment request");
}

void test_arena_realloc_last() {
    ubyte[256] backing;
    Arena ar;
    ar.buf = backing[];
    Allocator a = arena_allocator(ar);

    int[] s = make_n!int(a, 2).unwrap;
    s[0] = 1; s[1] = 2;
    void* p0 = s.ptr;
    check(resize_n(a, s, 4).is_ok(), "arena grow of the last block");
    check(s.ptr is p0, "arena grew the last block in place");
    expect_eq(s[0], 1, "data survived in-place grow");
    expect_eq(s[2], 0, "grown tail .init-filled");
}

void test_pool() {
    Tracker t;
    Allocator a = tracked(t);

    Pool!Point p;
    check(pool_alloc_storage(p, a, 3).is_ok(), "pool storage allocated");
    check(pool_capacity(p) == 3, "pool capacity");
    check(pool_available(p) == 3, "pool starts fully available");

    Point* p1 = pool_get(p);
    Point* p2 = pool_get(p);
    Point* p3 = pool_get(p);
    check(p1 !is null && p2 !is null && p3 !is null, "three gets from a 3-pool");
    check(pool_get(p) is null, "fourth get from a full pool is null");
    check(pool_available(p) == 0, "pool exhausted");
    check(pool_owns(p, p1), "pool_owns recognises its slot");

    p1.x = 111;
    p2.x = 222;
    pool_put(p, p2);
    check(pool_available(p) == 1, "put returned a slot");

    Point* p4 = pool_get(p);
    check(p4 is p2, "get reuses the just-freed slot (LIFO)");
    expect_eq(p1.x, 111, "other live slot untouched by the recycle");

    pool_free_storage(p, a);
    check(t.bytes_outstanding == 0, "pool storage freed");
    check(pool_capacity(p) == 0, "pool zeroed after free_storage");
}

void test_pool_caller_storage() {
    Point[4] slots;
    uint[4] freelist;
    Pool!Point p;
    pool_init(p, slots[], freelist[]);
    check(pool_capacity(p) == 4, "caller-storage pool capacity");

    Point* a0 = pool_get(p);
    check(a0 is &slots[0], "first get hands out slot 0");
    Point* a1 = pool_get(p);
    check(a1 is &slots[1], "second get hands out slot 1");
}

void test_tracker_peak() {
    Tracker t;
    Allocator a = tracked(t);

    int[] s1 = make_n!int(a, 100).unwrap;   // 400 bytes
    int[] s2 = make_n!int(a, 100).unwrap;   // 800 total
    check(t.peak_bytes >= 800, "tracker recorded the peak");
    free_n(a, s1);
    int[] s3 = make_n!int(a, 10).unwrap;    // back down then up a little
    check(t.peak_bytes >= 800, "peak is a high-water mark, never drops");
    check(t.total_allocs == 3, "total_allocs counts every alloc");
    free_n(a, s2);
    free_n(a, s3);
    check(t.bytes_outstanding == 0, "everything freed");
}

void run_mem_tests() {
    test_make_unmake();
    test_make_n();
    test_resize_n();
    test_dup();
    test_arena_basic();
    test_arena_oom();
    test_arena_alignment();
    test_arena_realloc_last();
    test_pool();
    test_pool_caller_storage();
    test_tracker_peak();
}
