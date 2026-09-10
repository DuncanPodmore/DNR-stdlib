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
// pushes are O(N). A mutator that can grow returns a `Status` (or `Result`) —
// `is_err` / `StdErr.oom` on an allocation failure, and the array is left
// exactly as it was.

import dnr.mem;
import res = dnr.result;
import cstr = core.stdc.string;

enum size_t MIN_CAP = 8;

struct Array(T) {
    T[]       items;   // the live elements — .length is the count
    size_t    cap;     // allocated slots (>= items.length)
    Allocator a;
}

// A fresh array. `reserve` slots are allocated up front (0 = allocate lazily
// on the first push). If the reserve allocation fails the array still comes
// back usable and empty — the first push retries — so this never errors;
// call `array_reserve` explicitly when you need to know.
Array!T array_make(T)(Allocator a, size_t reserve = 0) @nogc nothrow {
    Array!T r;
    r.a = a;
    if (reserve > 0) cast(void) array_reserve(r, reserve);
    return r;
}

// Copy `src` into a new array sized exactly to it. `StdErr.oom` on failure.
res.Result!(Array!T) array_from(T)(Allocator a, const(T)[] src) @nogc nothrow {
    Array!T r;
    r.a = a;
    if (src.length) {
        if (array_reserve(r, src.length).is_err) return res.err!(Array!T)(res.StdErr.oom);
        cstr.memcpy(r.items.ptr, src.ptr, src.length * T.sizeof);
        r.items = r.items.ptr[0 .. src.length];
    }
    return res.ok(r);
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

// Make room for at least `want` slots total. `pass()` on success (or if the
// capacity was already there), `StdErr.oom` on failure (array unchanged).
res.Status array_reserve(T)(ref Array!T arr, size_t want) @nogc nothrow {
    if (want <= arr.cap) return res.pass();
    size_t newCap = arr.cap < MIN_CAP ? MIN_CAP : arr.cap;
    while (newCap < want) newCap *= 2;

    size_t len = arr.items.length;
    void* p = arr.cap
        ? arr.a.raw_realloc(arr.items.ptr, arr.cap * T.sizeof, newCap * T.sizeof, T.alignof)
        : arr.a.raw_alloc(newCap * T.sizeof, T.alignof);
    if (p is null) return res.fail(res.StdErr.oom);

    arr.items = (cast(T*) p)[0 .. len];
    arr.cap = newCap;
    return res.pass();
}

// Append one. `StdErr.oom` on failure.
res.Status array_push(T)(ref Array!T arr, T v) @nogc nothrow {
    if (array_reserve(arr, arr.items.length + 1).is_err) return res.fail(res.StdErr.oom);
    size_t i = arr.items.length;
    arr.items = arr.items.ptr[0 .. i + 1];
    arr.items[i] = v;
    return res.pass();
}

// Append many. `StdErr.oom` on failure (array unchanged — reserve happens first).
res.Status array_append(T)(ref Array!T arr, const(T)[] xs) @nogc nothrow {
    if (xs.length == 0) return res.pass();
    if (array_reserve(arr, arr.items.length + xs.length).is_err) return res.fail(res.StdErr.oom);
    size_t i = arr.items.length;
    cstr.memcpy(arr.items.ptr + i, xs.ptr, xs.length * T.sizeof);
    arr.items = arr.items.ptr[0 .. i + xs.length];
    return res.pass();
}

// Remove and return the last element, or `none` if empty.
res.Option!T array_pop(T)(ref Array!T arr) @nogc nothrow {
    if (arr.items.length == 0) return res.none!T();
    size_t i = arr.items.length - 1;
    T v = arr.items[i];
    arr.items = arr.items.ptr[0 .. i];
    return res.some(v);
}

// The last element by reference. Asserts non-empty — a precondition-guarded
// accessor, like `arr.items[i]`; use `array_pop` / `array_len` when you're
// not sure.
ref T array_back(T)(ref Array!T arr) @nogc nothrow {
    assert(arr.items.length > 0, "array_back: empty");
    return arr.items[arr.items.length - 1];
}

// Insert `v` at index `i` (0..len), shifting the tail up. `StdErr.oom` on failure.
res.Status array_insert(T)(ref Array!T arr, size_t i, T v) @nogc nothrow {
    size_t len = arr.items.length;
    assert(i <= len, "array_insert: index out of range");
    if (array_reserve(arr, len + 1).is_err) return res.fail(res.StdErr.oom);
    arr.items = arr.items.ptr[0 .. len + 1];
    if (i < len)
        cstr.memmove(arr.items.ptr + i + 1, arr.items.ptr + i, (len - i) * T.sizeof);
    arr.items[i] = v;
    return res.pass();
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
// just drops the count (capacity kept). `StdErr.oom` when growing fails.
res.Status array_resize(T)(ref Array!T arr, size_t n) @nogc nothrow {
    size_t len = arr.items.length;
    if (n <= len) { arr.items = arr.items.ptr[0 .. n]; return res.pass(); }
    if (array_reserve(arr, n).is_err) return res.fail(res.StdErr.oom);
    arr.items = arr.items.ptr[0 .. n];
    for (size_t i = len; i < n; i++) arr.items[i] = T.init;
    return res.pass();
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
