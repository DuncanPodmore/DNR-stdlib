module dnr.ringbuf;

// ---------------------------------------------------------------------------
// RingBuffer!T — a growable double-ended queue over an Allocator
// ---------------------------------------------------------------------------
// dnr.array is a stack — there's no cheap pop-front. This is the FIFO: a
// circular buffer with O(1) push/pop at both ends. Capacity is a power of two
// so the wrap is a mask; it doubles when full (amortised O(1) push). Elements
// stay contiguous in ring order, not in memory — index with `ring_at`, not
// `.ptr`.
//
// Uses: event queues, BFS frontiers, sliding windows / bounded history (the
// game's per-frame player-snapshot ring).
//
// ⚠️ Handle, not a value (copying aliases the block). POD (no element
// destructors). betterC: @nogc nothrow; a grow failure is `StdErr.oom`.

import mem = dnr.mem;
import res = dnr.result;
import cstr = core.stdc.string;

enum size_t RING_MIN_CAP = 8;

struct RingBuffer(T) {
    T[]           buf;    // buf.length is a power of two (the capacity), or 0
    size_t        head;   // index of the front element
    size_t        len;    // live element count
    mem.Allocator a;
}

private size_t mask(T)(ref const RingBuffer!T r) @nogc nothrow {
    return r.buf.length - 1;
}

RingBuffer!T ring_make(T)(mem.Allocator a, size_t capacity = 0) @nogc nothrow {
    RingBuffer!T r;
    r.a = a;
    if (capacity > 0) cast(void) ring_reserve(r, capacity);
    return r;
}

void ring_free(T)(ref RingBuffer!T r) @nogc nothrow {
    if (r.buf.length) mem.free_n(r.a, r.buf);
    r.buf = null;
    r.head = 0;
    r.len = 0;
}

size_t ring_len(T)(ref const RingBuffer!T r)   @nogc nothrow { return r.len; }
size_t ring_cap(T)(ref const RingBuffer!T r)   @nogc nothrow { return r.buf.length; }
bool   ring_empty(T)(ref const RingBuffer!T r) @nogc nothrow { return r.len == 0; }

// Make room for at least `want` elements. `StdErr.oom` on failure (unchanged).
res.Status ring_reserve(T)(ref RingBuffer!T r, size_t want) @nogc nothrow {
    if (want <= r.buf.length) return res.pass();
    size_t cap = r.buf.length < RING_MIN_CAP ? RING_MIN_CAP : r.buf.length;
    while (cap < want) cap *= 2;

    auto nb = mem.make_n!T(r.a, cap);
    if (nb.is_err) return res.fail(res.StdErr.oom);
    T[] fresh = nb.unwrap;

    // copy the live run into fresh[0 .. len], unwrapping the ring
    if (r.len) {
        size_t firstRun = r.buf.length - r.head;
        if (firstRun >= r.len) {
            cstr.memcpy(fresh.ptr, r.buf.ptr + r.head, r.len * T.sizeof);
        } else {
            cstr.memcpy(fresh.ptr, r.buf.ptr + r.head, firstRun * T.sizeof);
            cstr.memcpy(fresh.ptr + firstRun, r.buf.ptr, (r.len - firstRun) * T.sizeof);
        }
    }
    if (r.buf.length) mem.free_n(r.a, r.buf);
    r.buf = fresh;
    r.head = 0;
    return res.pass();
}

// Append at the back. `StdErr.oom` on a failed grow.
res.Status ring_push_back(T)(ref RingBuffer!T r, T v) @nogc nothrow {
    if (r.len == r.buf.length && ring_reserve(r, r.len + 1).is_err)
        return res.fail(res.StdErr.oom);
    r.buf[(r.head + r.len) & mask(r)] = v;
    r.len++;
    return res.pass();
}

// Prepend at the front.
res.Status ring_push_front(T)(ref RingBuffer!T r, T v) @nogc nothrow {
    if (r.len == r.buf.length && ring_reserve(r, r.len + 1).is_err)
        return res.fail(res.StdErr.oom);
    r.head = (r.head + r.buf.length - 1) & mask(r);
    r.buf[r.head] = v;
    r.len++;
    return res.pass();
}

// Remove and return the front element, or `none`.
res.Option!T ring_pop_front(T)(ref RingBuffer!T r) @nogc nothrow {
    if (r.len == 0) return res.none!T();
    T v = r.buf[r.head];
    r.head = (r.head + 1) & mask(r);
    r.len--;
    return res.some(v);
}

// Remove and return the back element, or `none`.
res.Option!T ring_pop_back(T)(ref RingBuffer!T r) @nogc nothrow {
    if (r.len == 0) return res.none!T();
    r.len--;
    return res.some(r.buf[(r.head + r.len) & mask(r)]);
}

// Element `i` from the front, by reference. Asserts `i < len` — a
// precondition-guarded accessor, like `arr.items[i]`.
ref T ring_at(T)(ref RingBuffer!T r, size_t i) @nogc nothrow {
    assert(i < r.len, "ring_at: out of range");
    return r.buf[(r.head + i) & mask(r)];
}

ref T ring_front(T)(ref RingBuffer!T r) @nogc nothrow {
    assert(r.len > 0, "ring_front: empty");
    return r.buf[r.head];
}
ref T ring_back(T)(ref RingBuffer!T r) @nogc nothrow {
    assert(r.len > 0, "ring_back: empty");
    return r.buf[(r.head + r.len - 1) & mask(r)];
}

// Drop everything (capacity kept).
void ring_clear(T)(ref RingBuffer!T r) @nogc nothrow {
    r.head = 0;
    r.len = 0;
}
