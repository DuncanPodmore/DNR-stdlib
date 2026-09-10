module dnr.array_test;

// Tests for dnr.array. Each runs against a tracking_allocator over malloc and
// asserts nothing leaked at the end.

import dnr.testing;
import dnr.mem;
import dnr.array;

private Allocator tracked(ref Tracker t) {
    return tracking_allocator(t, malloc_allocator());
}

void test_push_grow() {
    Tracker t;
    Array!int a = array_make!int(tracked(t));

    foreach (i; 0 .. 100) check(array_push(a, i * 10), "push succeeded");
    check(array_len(a) == 100, "length after 100 pushes");
    check(a.cap >= 100, "capacity grew to fit");
    expect_eq(a.items[0], 0, "first element");
    expect_eq(a.items[99], 990, "last element");
    check(t.total_allocs >= 1, "at least one allocation happened");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
    check(array_len(a) == 0 && a.cap == 0, "array reusable after free");
}

void test_reserve_no_realloc() {
    Tracker t;
    Array!long a = array_make!long(tracked(t), 64);
    check(a.cap >= 64, "reserve gave capacity up front");
    void* p0 = a.items.ptr;
    size_t allocs0 = t.total_allocs;

    foreach (i; 0 .. 64) array_push(a, i);
    check(a.items.ptr is p0, "no realloc while under reserved capacity");
    check(t.total_allocs == allocs0, "no extra allocation");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_pop_back() {
    Tracker t;
    Array!int a = array_make!int(tracked(t));
    array_push(a, 1); array_push(a, 2); array_push(a, 3);

    expect_eq(array_back(a), 3, "back is the last pushed");
    expect_eq(array_pop(a), 3, "pop returns last");
    expect_eq(array_pop(a), 2, "pop returns next");
    check(array_len(a) == 1, "length dropped");

    int v;
    check(array_try_pop(a, v) && v == 1, "try_pop drains the last");
    check(!array_try_pop(a, v), "try_pop on empty is false");
    check(array_empty(a), "empty after draining");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_append() {
    Tracker t;
    Array!int a = array_make!int(tracked(t));
    array_push(a, 1);
    immutable int[3] more = [2, 3, 4];
    check(array_append(a, more[]), "append succeeded");
    check(array_len(a) == 4, "length after append");
    expect_eq(a.items[3], 4, "appended tail correct");
    check(array_append(a, null), "append of empty is a no-op success");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_insert_remove() {
    Tracker t;
    Array!int a = array_make!int(tracked(t));
    foreach (i; 0 .. 5) array_push(a, i);        // 0 1 2 3 4

    check(array_insert(a, 2, 99), "insert mid");   // 0 1 99 2 3 4
    check(array_len(a) == 6, "length after insert");
    expect_eq(a.items[2], 99, "inserted value in place");
    expect_eq(a.items[3], 2, "tail shifted up");

    check(array_insert(a, array_len(a), 7), "insert at end");  // ... 4 7
    expect_eq(array_back(a), 7, "end insert lands last");

    array_remove(a, 2);                            // 0 1 2 3 4 7
    expect_eq(a.items[2], 2, "ordered remove closed the gap");
    check(array_len(a) == 6, "length after remove");

    array_remove(a, array_len(a) - 1);             // 0 1 2 3 4
    expect_eq(array_back(a), 4, "remove last works");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_swap_remove() {
    Tracker t;
    Array!int a = array_make!int(tracked(t));
    foreach (i; 0 .. 5) array_push(a, i);          // 0 1 2 3 4

    array_swap_remove(a, 1);                        // 0 4 2 3
    check(array_len(a) == 4, "length dropped");
    expect_eq(a.items[1], 4, "last element moved into the hole");
    expect_eq(a.items[3], 3, "rest untouched");

    array_swap_remove(a, array_len(a) - 1);         // 0 4 2
    expect_eq(array_back(a), 2, "swap_remove of the last just pops");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_resize_clear() {
    Tracker t;
    Array!int a = array_make!int(tracked(t));
    foreach (i; 0 .. 4) array_push(a, i + 1);      // 1 2 3 4

    check(array_resize(a, 7), "grow via resize");
    check(array_len(a) == 7, "length grew");
    expect_eq(a.items[3], 4, "old data kept");
    expect_eq(a.items[6], 0, "grown tail .init-filled");

    check(array_resize(a, 2), "shrink via resize");
    check(array_len(a) == 2, "length shrank");
    check(a.cap >= 7, "capacity retained on shrink");

    array_clear(a);
    check(array_empty(a), "clear empties");
    check(a.cap >= 7, "clear keeps capacity");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_from_and_shrink() {
    Tracker t;
    Allocator al = tracked(t);
    immutable int[4] src = [10, 20, 30, 40];
    Array!int a = array_from!int(al, src[]);
    check(array_len(a) == 4, "array_from length");
    check(a.items.ptr !is src.ptr, "array_from is a distinct block");
    expect_eq(a.items[2], 30, "array_from copied");

    array_push(a, 50);
    array_pop(a);
    array_pop(a);                                   // len 3, cap >= 8
    array_shrink_to_fit(a);
    check(a.cap == 3, "shrink_to_fit trims capacity to length");
    expect_eq(a.items[0], 10, "data survived the shrink");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

private struct Vec2 { float x = 0; float y = 0; }

void test_struct_elements() {
    Tracker t;
    Array!Vec2 a = array_make!Vec2(tracked(t));
    array_push(a, Vec2(1, 2));
    array_push(a, Vec2(3, 4));
    check(array_resize(a, 4), "grow struct array");
    // resize must .init-fill, and Vec2.init is (0,0) not (NaN,NaN)
    near(a.items[3].x, 0, 1e-9, "grown struct tail is zero, not NaN");
    near(a.items[3].y, 0, 1e-9, "grown struct tail is zero, not NaN");
    near(a.items[1].x, 3, 1e-9, "struct element intact");

    array_free(a);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_array_tests() {
    test_push_grow();
    test_reserve_no_realloc();
    test_pop_back();
    test_append();
    test_insert_remove();
    test_swap_remove();
    test_resize_clear();
    test_from_and_shrink();
    test_struct_elements();
}
