module dnr.ringbuf_test;

import dnr.testing;
import dnr.mem;
import dnr.ringbuf;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_fifo() {
    Tracker t;
    auto r = ring_make!int(tracked(t));

    foreach (i; 0 .. 5) check(ring_push_back(r, i).is_ok(), "push_back");
    check(ring_len(r) == 5, "len after 5 push_back");
    check(ring_front(r) == 0 && ring_back(r) == 4, "front / back");

    int v;
    check(ring_pop_front(r).take(v) && v == 0, "pop_front FIFO order 0");
    check(ring_pop_front(r).take(v) && v == 1, "pop_front FIFO order 1");
    check(ring_len(r) == 3, "len after 2 pops");
    check(ring_at(r, 0) == 2 && ring_at(r, 2) == 4, "ring_at indexes from the front");

    ring_free(r);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_deque() {
    Tracker t;
    auto r = ring_make!int(tracked(t));

    ring_push_back(r, 1);
    ring_push_front(r, 0);
    ring_push_back(r, 2);
    ring_push_front(r, -1);
    // order is now: -1 0 1 2
    check(ring_len(r) == 4, "deque len");
    check(ring_at(r, 0) == -1 && ring_at(r, 1) == 0 && ring_at(r, 2) == 1 && ring_at(r, 3) == 2,
          "push_front / push_back keep ring order");

    int v;
    check(ring_pop_back(r).take(v) && v == 2, "pop_back");
    check(ring_pop_front(r).take(v) && v == -1, "pop_front");
    check(ring_at(r, 0) == 0 && ring_at(r, 1) == 1, "remaining order");

    ring_free(r);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_grow_wraps_correctly() {
    Tracker t;
    auto r = ring_make!int(tracked(t), 4);   // cap starts at 8 (RING_MIN_CAP)
    check(ring_cap(r) == 8, "reserve rounds up to a power of two >= RING_MIN_CAP");

    // rotate the ring so head is not 0, then force a grow and check order
    foreach (i; 0 .. 8) ring_push_back(r, i);
    int v;
    ring_pop_front(r).take(v);       // drop 0
    ring_pop_front(r).take(v);       // drop 1, head is now 2
    ring_push_back(r, 8);
    ring_push_back(r, 9);            // cap full again (2..9)
    check(ring_len(r) == 8, "8 live, head mid-buffer");

    check(ring_push_back(r, 10).is_ok(), "push that triggers a grow");
    check(ring_cap(r) == 16, "capacity doubled");
    check(ring_len(r) == 9, "len 9 after grow");
    bool ordered = true;
    foreach (i; 0 .. 9) if (ring_at(r, i) != cast(int)(i + 2)) ordered = false;
    check(ordered, "grow preserved ring order across the wrap");

    ring_free(r);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_empty_and_clear() {
    Tracker t;
    auto r = ring_make!int(tracked(t));
    check(ring_empty(r), "starts empty");
    check(ring_pop_front(r).is_none(), "pop_front on empty is none");
    check(ring_pop_back(r).is_none(), "pop_back on empty is none");

    foreach (i; 0 .. 10) ring_push_back(r, i);
    ring_clear(r);
    check(ring_empty(r) && ring_len(r) == 0, "clear empties");
    check(ring_cap(r) >= 10, "clear keeps capacity");
    ring_push_back(r, 42);
    check(ring_front(r) == 42, "usable after clear");

    ring_free(r);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_stress_vs_reference() {
    Tracker t;
    auto r = ring_make!int(tracked(t));

    // model: a plain growing window we compare against
    int[4096] model = void;
    size_t mHead = 0, mLen = 0;

    uint seed = 0x1234;
    uint rnd() { seed = seed * 1664525 + 1013904223; return seed >> 8; }

    bool ok = true;
    foreach (iter; 0 .. 20_000) {
        uint op = rnd() % 4;
        if (op < 2 && mLen < model.length) {
            int val = cast(int) rnd();
            ring_push_back(r, val);
            model[(mHead + mLen) % model.length] = val;
            mLen++;
        } else if (op == 2 && mLen > 0) {
            int got;
            bool had = ring_pop_front(r).take(got);
            if (!had || got != model[mHead]) ok = false;
            mHead = (mHead + 1) % model.length;
            mLen--;
        } else if (mLen > 0) {
            int got;
            bool had = ring_pop_back(r).take(got);
            if (!had || got != model[(mHead + mLen - 1) % model.length]) ok = false;
            mLen--;
        }
        if (ring_len(r) != mLen) ok = false;
    }
    check(ok, "20k mixed push/pop match the reference window");

    ring_free(r);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_ringbuf_tests() {
    test_fifo();
    test_deque();
    test_grow_wraps_correctly();
    test_empty_and_clear();
    test_stress_vs_reference();
}
