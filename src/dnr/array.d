module dnr.array;

// ---------------------------------------------------------------------------
// Array!T — a growable array over an explicit Allocator
// ---------------------------------------------------------------------------
// betterC has no `~` append and no `arr.length = n` resize (both are runtime
// calls). This is the replacement: a struct holding a slice, a capacity, and
// the Allocator that owns the block. Every mutator is a free function taking
// `ref Array!T` — the struct stays plain data, same style as dnr.mem's
// `pool_*` / `arena_*`.
//
// ⚠️ `Array!T` is a HANDLE, not a value. Copying one aliases the block and a
// second `array_free` double-frees. Pass it by `ref`; move it, don't copy it.
//
// ⚠️ It is a POD container: element destructors are NEVER run — not on
// `array_pop`, `array_remove`, `array_clear` or `array_free`. If T owns a
// resource, release it before you drop the slot. (The game runs no struct
// destructors at all; this matches that.)
//
// Growth is amortised: capacity doubles (from a floor of MIN_CAP), so N
// pushes are O(N). Failure to allocate is a `false` return from any mutator
// that can grow — the array is left exactly as it was.

import dnr.mem;
import cstr = core.stdc.string;

enum size_t MIN_CAP = 8;

struct Array(T) {
    T[]       items;   // the live elements — .length is the count
    size_t    cap;     // allocated slots (>= items.length)
    Allocator a;
}

// A fresh array. `reserve` slots are allocated up front (0 = allocate lazily
// on the first push). Returns an empty array with a null block on OOM — the
// first push will retry.
Array!T array_make(T)(Allocator a, size_t reserve = 0) @nogc nothrow {
    Array!T r;
    r.a = a;
    if (reserve > 0) array_reserve(r, reserve);
    return r;
}

// Copy `src` into a new array sized exactly to it.
Array!T array_from(T)(Allocator a, const(T)[] src) @nogc nothrow {
    Array!T r = array_make!T(a, src.length);
    if (src.length && r.cap >= src.length) {
        cstr.memcpy(r.items.ptr, src.ptr, src.length * T.sizeof);
        r.items = r.items.ptr[0 .. src.length];
    }
    return r;
}

// Release the block. The array is empty and reusable afterwards (a push
// re-allocates).
void array_free(T)(ref Array!T arr) @nogc nothrow {
    if (arr.cap) arr.a.raw_free(arr.items.ptr, arr.cap * T.sizeof);
    arr.items = null;
    arr.cap = 0;
}

size_t array_len(T)(ref const Array!T arr) @nogc nothrow { return arr.items.length; }
bool   array_empty(T)(ref const Array!T arr) @nogc nothrow { return arr.items.length == 0; }

// Make room for at least `want` slots total. true on success (or if the
// capacity was already there), false on OOM (array unchanged).
bool array_reserve(T)(ref Array!T arr, size_t want) @nogc nothrow {
    if (want <= arr.cap) return true;
    size_t newCap = arr.cap < MIN_CAP ? MIN_CAP : arr.cap;
    while (newCap < want) newCap *= 2;

    size_t len = arr.items.length;
    void* p = arr.cap
        ? arr.a.raw_realloc(arr.items.ptr, arr.cap * T.sizeof, newCap * T.sizeof, T.alignof)
        : arr.a.raw_alloc(newCap * T.sizeof, T.alignof);
    if (p is null) return false;

    arr.items = (cast(T*) p)[0 .. len];
    arr.cap = newCap;
    return true;
}

// Append one. false on OOM.
bool array_push(T)(ref Array!T arr, T v) @nogc nothrow {
    if (!array_reserve(arr, arr.items.length + 1)) return false;
    size_t i = arr.items.length;
    arr.items = arr.items.ptr[0 .. i + 1];
    arr.items[i] = v;
    return true;
}

// Append many. false on OOM (array unchanged — the reserve happens first).
bool array_append(T)(ref Array!T arr, const(T)[] xs) @nogc nothrow {
    if (xs.length == 0) return true;
    if (!array_reserve(arr, arr.items.length + xs.length)) return false;
    size_t i = arr.items.length;
    cstr.memcpy(arr.items.ptr + i, xs.ptr, xs.length * T.sizeof);
    arr.items = arr.items.ptr[0 .. i + xs.length];
    return true;
}

// Remove and return the last element. Asserts non-empty.
T array_pop(T)(ref Array!T arr) @nogc nothrow {
    assert(arr.items.length > 0, "array_pop: empty");
    size_t i = arr.items.length - 1;
    T v = arr.items[i];
    arr.items = arr.items.ptr[0 .. i];
    return v;
}

// Pop into `out_`, or return false if empty (no assert).
bool array_try_pop(T)(ref Array!T arr, ref T out_) @nogc nothrow {
    if (arr.items.length == 0) return false;
    out_ = array_pop(arr);
    return true;
}

ref T array_back(T)(ref Array!T arr) @nogc nothrow {
    assert(arr.items.length > 0, "array_back: empty");
    return arr.items[arr.items.length - 1];
}

// Insert `v` at index `i` (0..len), shifting the tail up. false on OOM.
bool array_insert(T)(ref Array!T arr, size_t i, T v) @nogc nothrow {
    size_t len = arr.items.length;
    assert(i <= len, "array_insert: index out of range");
    if (!array_reserve(arr, len + 1)) return false;
    arr.items = arr.items.ptr[0 .. len + 1];
    if (i < len)
        cstr.memmove(arr.items.ptr + i + 1, arr.items.ptr + i, (len - i) * T.sizeof);
    arr.items[i] = v;
    return true;
}

// Remove index `i`, shifting the tail down — order preserved, O(n).
void array_remove(T)(ref Array!T arr, size_t i) @nogc nothrow {
    size_t len = arr.items.length;
    assert(i < len, "array_remove: index out of range");
    if (i + 1 < len)
        cstr.memmove(arr.items.ptr + i, arr.items.ptr + i + 1, (len - i - 1) * T.sizeof);
    arr.items = arr.items.ptr[0 .. len - 1];
}

// Remove index `i` by moving the last element into its place — O(1), order
// NOT preserved. The game's pool-compaction move.
void array_swap_remove(T)(ref Array!T arr, size_t i) @nogc nothrow {
    size_t len = arr.items.length;
    assert(i < len, "array_swap_remove: index out of range");
    if (i != len - 1) arr.items[i] = arr.items[len - 1];
    arr.items = arr.items.ptr[0 .. len - 1];
}

// Set the length. Growing .init-fills the new tail (no NaN floats); shrinking
// just drops the count (capacity kept). false on OOM when growing.
bool array_resize(T)(ref Array!T arr, size_t n) @nogc nothrow {
    size_t len = arr.items.length;
    if (n <= len) { arr.items = arr.items.ptr[0 .. n]; return true; }
    if (!array_reserve(arr, n)) return false;
    arr.items = arr.items.ptr[0 .. n];
    for (size_t i = len; i < n; i++) arr.items[i] = T.init;
    return true;
}

// Length to 0, capacity untouched. (No element destructors — see the header.)
void array_clear(T)(ref Array!T arr) @nogc nothrow {
    arr.items = arr.items.ptr[0 .. 0];
}

// Give back unused capacity — realloc down to exactly the live length. A
// no-op on failure (shrink-realloc failing is harmless, the block stays).
void array_shrink_to_fit(T)(ref Array!T arr) @nogc nothrow {
    size_t len = arr.items.length;
    if (len == arr.cap) return;
    if (len == 0) { array_free(arr); return; }
    void* p = arr.a.raw_realloc(arr.items.ptr, arr.cap * T.sizeof, len * T.sizeof, T.alignof);
    if (p is null) return;
    arr.items = (cast(T*) p)[0 .. len];
    arr.cap = len;
}
