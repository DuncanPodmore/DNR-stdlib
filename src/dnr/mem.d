module dnr.mem;

// ---------------------------------------------------------------------------
// Allocators — the Zig model
// ---------------------------------------------------------------------------
// `Allocator` is a small C-style vtable: an opaque context + three function
// pointers. You pass one EXPLICITLY to anything that allocates. There is no
// hidden global default and no thread-local context — an allocation's source
// is always visible at the call site.
//
// The caller tracks the size of every block it holds (like Zig): `raw_free`
// and `raw_realloc` take the old size. A malloc-backed allocator ignores it;
// an arena or a pool needs it. That bookkeeping is the honest cost of
// allocating without a runtime; the typed helpers (make_n / free_n / …) and
// the containers built on them carry it for you.
//
// betterC constraints in play: no GC, no exceptions. Every path here is
// @nogc nothrow. Failure is a null return, never a throw. A block is raw
// bytes — `make` / `make_n` .init-fill (respecting a struct's declared
// initializers, so no NaN-uninitialised-float surprises), `alloc_raw` hands
// back undefined memory for the caller to fill.

import cstd = core.stdc.stdlib;
import cstr = core.stdc.string;
import res = dnr.result;

alias AllocFn   = void* function(void* ctx, size_t size, size_t alignment) @nogc nothrow;
alias ReallocFn = void* function(void* ctx, void* ptr, size_t oldSize, size_t newSize, size_t alignment) @nogc nothrow;
alias FreeFn    = void  function(void* ctx, void* ptr, size_t size) @nogc nothrow;

enum size_t DEFAULT_ALIGN = 16;   // what malloc guarantees on x64

struct Allocator {
    void*     ctx;
    AllocFn   alloc_fn;
    ReallocFn realloc_fn;
    FreeFn    free_fn;

    // `alignment` is a power of two; 0 means DEFAULT_ALIGN. Returns null on a
    // zero-size request or on failure.
    void* raw_alloc(size_t size, size_t alignment = 0) @nogc nothrow {
        if (size == 0) return null;
        return alloc_fn(ctx, size, alignment ? alignment : DEFAULT_ALIGN);
    }

    // Grow / shrink the block at `ptr` (currently `oldSize` bytes) to
    // `newSize`. On failure the old block is untouched and null is returned.
    // `newSize == 0` frees and returns null.
    void* raw_realloc(void* ptr, size_t oldSize, size_t newSize, size_t alignment = 0) @nogc nothrow {
        return realloc_fn(ctx, ptr, oldSize, newSize, alignment ? alignment : DEFAULT_ALIGN);
    }

    // `ptr == null` is a no-op.
    void raw_free(void* ptr, size_t size) @nogc nothrow {
        if (ptr !is null) free_fn(ctx, ptr, size);
    }
}

// ---------------------------------------------------------------------------
// typed helpers
// ---------------------------------------------------------------------------
// These report an allocation failure the dnr-std way — Result!(T*) / Result!(T[])
// / Status — rather than a bare null. `raw_alloc` etc. above stay pointer-and-null
// (they are the C-ABI primitive layer the vtable is built on).

// One T, .init-filled.
res.Result!(T*) make(T)(Allocator a) @nogc nothrow {
    T* p = cast(T*) a.raw_alloc(T.sizeof, T.alignof);
    if (p is null) return res.err!(T*)(res.StdErr.oom);
    *p = T.init;
    return res.ok(p);
}

void unmake(T)(Allocator a, T* p) @nogc nothrow {
    a.raw_free(p, T.sizeof);
}

// A slice of n T, each .init-filled. n == 0 succeeds with an empty slice.
res.Result!(T[]) make_n(T)(Allocator a, size_t n) @nogc nothrow {
    if (n == 0) return res.ok!(T[])(null);
    T* p = cast(T*) a.raw_alloc(n * T.sizeof, T.alignof);
    if (p is null) return res.err!(T[])(res.StdErr.oom);
    T[] s = p[0 .. n];
    foreach (ref e; s) e = T.init;
    return res.ok(s);
}

void free_n(T)(Allocator a, T[] s) @nogc nothrow {
    a.raw_free(s.ptr, s.length * T.sizeof);
}

// Grow / shrink `s` to newN T. On success `s` is replaced (the pointer may
// move) and any new tail elements are .init-filled. On failure `s` is
// unchanged. newN == 0 frees `s` and sets it null.
res.Status resize_n(T)(Allocator a, ref T[] s, size_t newN) @nogc nothrow {
    if (newN == 0) { free_n(a, s); s = null; return res.pass(); }
    void* np = a.raw_realloc(s.ptr, s.length * T.sizeof, newN * T.sizeof, T.alignof);
    if (np is null) return res.fail(res.StdErr.oom);
    size_t old = s.length;
    s = (cast(T*) np)[0 .. newN];
    for (size_t i = old; i < newN; i++) s[i] = T.init;
    return res.pass();
}

// Copy `src` into a fresh block. Empty input succeeds with an empty slice.
res.Result!(T[]) dup(T)(Allocator a, const(T)[] src) @nogc nothrow {
    if (src.length == 0) return res.ok!(T[])(null);
    T* p = cast(T*) a.raw_alloc(src.length * T.sizeof, T.alignof);
    if (p is null) return res.err!(T[])(res.StdErr.oom);
    cstr.memcpy(p, src.ptr, src.length * T.sizeof);
    return res.ok(p[0 .. src.length]);
}

// The escape hatch: `size` bytes of UNDEFINED memory for the caller to fill.
res.Result!(void[]) alloc_raw(Allocator a, size_t size, size_t alignment = 0) @nogc nothrow {
    void* p = a.raw_alloc(size, alignment);
    return p is null ? res.err!(void[])(res.StdErr.oom) : res.ok!(void[])(p[0 .. size]);
}

// ---------------------------------------------------------------------------
// malloc_allocator — the default backend, wraps core.stdc.stdlib
// ---------------------------------------------------------------------------
// Alignment beyond DEFAULT_ALIGN (16) is not supported yet — asserts. Add an
// _aligned_malloc / aligned_alloc backend the day something needs SIMD-aligned
// blocks.

private void* malloc_alloc(void* ctx, size_t size, size_t alignment) @nogc nothrow {
    assert(alignment <= DEFAULT_ALIGN, "malloc_allocator: alignment > 16 unsupported");
    return cstd.malloc(size);
}
private void* malloc_realloc(void* ctx, void* ptr, size_t oldSize, size_t newSize, size_t alignment) @nogc nothrow {
    assert(alignment <= DEFAULT_ALIGN, "malloc_allocator: alignment > 16 unsupported");
    if (newSize == 0) { cstd.free(ptr); return null; }
    return cstd.realloc(ptr, newSize);
}
private void malloc_free(void* ctx, void* ptr, size_t size) @nogc nothrow {
    cstd.free(ptr);
}

Allocator malloc_allocator() @nogc nothrow {
    return Allocator(null, &malloc_alloc, &malloc_realloc, &malloc_free);
}

// ---------------------------------------------------------------------------
// Arena — a bump allocator over a fixed backing buffer
// ---------------------------------------------------------------------------
// `raw_alloc` bumps a cursor. `raw_free` is a no-op EXCEPT for the most recent
// allocation, which it pops (a cheap LIFO reclaim, enough for a StringBuilder
// or an Array that only ever grows the last thing). `arena_reset` frees
// everything at once — O(1), no per-object teardown. This is the game
// allocator: per-frame scratch, per-level data.
//
// No parent and no growth: hand it a `static ubyte[N] buf;` or a block from
// another allocator. Out of space -> raw_alloc returns null and the caller
// decides. A growing (block-chaining) variant is a later addition.
//
// ⚠️ The Allocator returned by arena_allocator holds `&arena`. The Arena must
// outlive every use of that Allocator.

struct Arena {
    ubyte[] buf;
    size_t  offset;      // bytes used
    size_t  lastOffset;  // start of the most recent allocation (for LIFO free)
}

private size_t align_up(size_t n, size_t a) @nogc nothrow {
    return (n + (a - 1)) & ~(a - 1);
}

private void* arena_alloc(void* ctx, size_t size, size_t alignment) @nogc nothrow {
    Arena* ar = cast(Arena*) ctx;
    size_t start = align_up(ar.offset, alignment);
    if (start + size > ar.buf.length) return null;
    ar.lastOffset = start;
    ar.offset = start + size;
    return ar.buf.ptr + start;
}
private void* arena_realloc(void* ctx, void* ptr, size_t oldSize, size_t newSize, size_t alignment) @nogc nothrow {
    Arena* ar = cast(Arena*) ctx;
    if (ptr is ar.buf.ptr + ar.lastOffset) {           // most recent -> resize in place
        if (ar.lastOffset + newSize > ar.buf.length) return null;
        ar.offset = ar.lastOffset + newSize;
        return ptr;
    }
    void* np = arena_alloc(ctx, newSize, alignment);    // else copy forward
    if (np is null) return null;
    cstr.memcpy(np, ptr, oldSize < newSize ? oldSize : newSize);
    return np;
}
private void arena_free(void* ctx, void* ptr, size_t size) @nogc nothrow {
    Arena* ar = cast(Arena*) ctx;
    if (ptr is ar.buf.ptr + ar.lastOffset) ar.offset = ar.lastOffset;   // LIFO pop
}

Allocator arena_allocator(ref Arena a) @nogc nothrow {
    return Allocator(&a, &arena_alloc, &arena_realloc, &arena_free);
}
void   arena_reset(ref Arena a) @nogc nothrow { a.offset = 0; a.lastOffset = 0; }
size_t arena_used(ref Arena a)  @nogc nothrow { return a.offset; }
size_t arena_free_bytes(ref Arena a) @nogc nothrow { return a.buf.length - a.offset; }

// ---------------------------------------------------------------------------
// GrowingArena — a bump allocator that chains new blocks as it fills
// ---------------------------------------------------------------------------
// `Arena` is one fixed buffer; this asks a parent Allocator for another
// (geometrically larger) block when the current one is full. You keep the
// arena's O(1) bump and O(1) mass-free without sizing the buffer up front.
//
//   `garena_reset` frees every block but the largest and rewinds it to empty
//   — reuse it every frame. `garena_free` returns everything to the parent.
//
// Per-allocation `raw_free` is a no-op (arena semantics); `raw_realloc`
// extends the last allocation in place when it can, else copies forward.
//
// ⚠️ The Allocator holds `&arena`; the GrowingArena must outlive it.

struct GrowingArena {
    private static struct Block {
        ubyte[]      mem;      // usable bytes (past this header)
        size_t       used;
        Block*       next;     // toward the older / larger blocks
    }
    Allocator parent;
    private Block* head;
    private size_t firstSize;
}

GrowingArena garena_make(Allocator parent, size_t firstBlock = 4096) @nogc nothrow {
    GrowingArena a;
    a.parent = parent;
    a.firstSize = firstBlock < 64 ? 64 : firstBlock;
    return a;
}

private GrowingArena.Block* garena_new_block(ref GrowingArena a, size_t need) @nogc nothrow {
    alias Block = GrowingArena.Block;
    size_t prev = a.head ? a.head.mem.length : a.firstSize / 2;
    size_t want = prev * 2;
    if (want < need) want = need;
    if (want < a.firstSize) want = a.firstSize;

    void* raw = a.parent.raw_alloc(Block.sizeof + want, DEFAULT_ALIGN);
    if (raw is null) return null;
    Block* b = cast(Block*) raw;
    b.mem = (cast(ubyte*) raw + Block.sizeof)[0 .. want];
    b.used = 0;
    b.next = a.head;
    a.head = b;
    return b;
}

private void* garena_alloc(void* ctx, size_t size, size_t alignment) @nogc nothrow {
    auto a = cast(GrowingArena*) ctx;
    if (a.head !is null) {
        size_t start = align_up(a.head.used, alignment);
        if (start + size <= a.head.mem.length) {
            a.head.used = start + size;
            return a.head.mem.ptr + start;
        }
    }
    auto b = garena_new_block(*a, size + alignment);
    if (b is null) return null;
    size_t start = align_up(b.used, alignment);
    b.used = start + size;
    return b.mem.ptr + start;
}

private void* garena_realloc(void* ctx, void* ptr, size_t oldSize, size_t newSize, size_t alignment) @nogc nothrow {
    auto a = cast(GrowingArena*) ctx;
    auto h = a.head;
    if (h !is null && ptr is h.mem.ptr + (h.used - oldSize)) {   // the last allocation
        if ((h.used - oldSize) + newSize <= h.mem.length) {
            h.used = (h.used - oldSize) + newSize;
            return ptr;
        }
    }
    void* np = garena_alloc(ctx, newSize, alignment);
    if (np is null) return null;
    cstr.memcpy(np, ptr, oldSize < newSize ? oldSize : newSize);
    return np;
}

private void garena_free_one(void* ctx, void* ptr, size_t size) @nogc nothrow {
    // arena semantics — reclaim happens in garena_reset / garena_free
}

Allocator garena_allocator(ref GrowingArena a) @nogc nothrow {
    return Allocator(&a, &garena_alloc, &garena_realloc, &garena_free_one);
}

// Free every block except the largest (the first one requested — it sits at
// the tail of the chain), and rewind it to empty for reuse.
void garena_reset(ref GrowingArena a) @nogc nothrow {
    alias Block = GrowingArena.Block;
    Block* tail = a.head;
    while (tail !is null && tail.next !is null) tail = tail.next;

    Block* b = a.head;
    while (b !is null && b !is tail) {
        Block* nx = b.next;
        a.parent.raw_free(b, Block.sizeof + b.mem.length);
        b = nx;
    }
    if (tail !is null) { tail.used = 0; tail.next = null; }
    a.head = tail;
}

void garena_free(ref GrowingArena a) @nogc nothrow {
    alias Block = GrowingArena.Block;
    Block* b = a.head;
    while (b !is null) {
        Block* nx = b.next;
        a.parent.raw_free(b, Block.sizeof + b.mem.length);
        b = nx;
    }
    a.head = null;
}

// Total live bytes handed out since the last reset.
size_t garena_used(ref GrowingArena a) @nogc nothrow {
    size_t n = 0;
    for (auto b = a.head; b !is null; b = b.next) n += b.used;
    return n;
}

// ---------------------------------------------------------------------------
// Pool!T — a fixed-capacity slot allocator with an O(1) free list
// ---------------------------------------------------------------------------
// The game's `Enemy[700]` + `alive` flag pattern, generalised. `pool_get`
// pops a free slot (null when full); `pool_put` returns one. Slots are NOT
// zeroed on get — you initialise. (Generation-checked stable handles are a
// separate SlotMap, later.)
//
// Storage is either caller-provided (`pool_init` over two same-length slices)
// or allocated (`pool_alloc_storage`). The free list is a separate index
// stack, so T need not be pointer-sized.

struct Pool(T) {
    T[]    slots;
    uint[] freeStack;
    uint   freeCount;
}

void pool_init(T)(ref Pool!T p, T[] slots, uint[] freeStorage) @nogc nothrow {
    assert(slots.length == freeStorage.length, "pool_init: slice lengths differ");
    assert(slots.length <= uint.max);
    p.slots = slots;
    p.freeStack = freeStorage;
    p.freeCount = cast(uint) slots.length;
    // Fill so the first gets hand out 0, 1, 2, … (stack is popped from the top).
    foreach (uint i; 0 .. cast(uint) slots.length)
        p.freeStack[i] = cast(uint) slots.length - 1 - i;
}

res.Status pool_alloc_storage(T)(ref Pool!T p, Allocator a, uint capacity) @nogc nothrow {
    auto sr = make_n!T(a, capacity);
    if (sr.is_err) return res.fail(res.StdErr.oom);
    auto fr = make_n!uint(a, capacity);
    if (fr.is_err) { free_n(a, sr.unwrap); return res.fail(res.StdErr.oom); }
    pool_init(p, sr.unwrap, fr.unwrap);
    return res.pass();
}
void pool_free_storage(T)(ref Pool!T p, Allocator a) @nogc nothrow {
    free_n(a, p.slots);
    free_n(a, p.freeStack);
    p = Pool!T.init;
}

T* pool_get(T)(ref Pool!T p) @nogc nothrow {
    if (p.freeCount == 0) return null;
    return &p.slots[p.freeStack[--p.freeCount]];
}
void pool_put(T)(ref Pool!T p, T* item) @nogc nothrow {
    ptrdiff_t idx = item - p.slots.ptr;
    assert(idx >= 0 && idx < cast(ptrdiff_t) p.slots.length, "pool_put: pointer not from this pool");
    assert(p.freeCount < p.slots.length, "pool_put: double free");
    p.freeStack[p.freeCount++] = cast(uint) idx;
}
uint pool_available(T)(ref Pool!T p) @nogc nothrow { return p.freeCount; }
uint pool_capacity(T)(ref Pool!T p)  @nogc nothrow { return cast(uint) p.slots.length; }
bool pool_owns(T)(ref Pool!T p, T* item) @nogc nothrow {
    return item >= p.slots.ptr && item < p.slots.ptr + p.slots.length;
}

// ---------------------------------------------------------------------------
// tracking_allocator — wraps another allocator and counts what's outstanding
// ---------------------------------------------------------------------------
// For tests: assert `t.bytes_outstanding == 0` at teardown to catch a leak.
// NOT for production — the counters aren't atomic and every op reads the
// struct.

struct Tracker {
    Allocator inner;
    size_t bytes_outstanding;
    size_t allocs_outstanding;
    size_t peak_bytes;
    size_t total_allocs;
}

private void* track_alloc(void* ctx, size_t size, size_t alignment) @nogc nothrow {
    Tracker* t = cast(Tracker*) ctx;
    void* p = t.inner.alloc_fn(t.inner.ctx, size, alignment);
    if (p !is null) {
        t.bytes_outstanding += size;
        t.allocs_outstanding++;
        t.total_allocs++;
        if (t.bytes_outstanding > t.peak_bytes) t.peak_bytes = t.bytes_outstanding;
    }
    return p;
}
private void* track_realloc(void* ctx, void* ptr, size_t oldSize, size_t newSize, size_t alignment) @nogc nothrow {
    Tracker* t = cast(Tracker*) ctx;
    void* p = t.inner.realloc_fn(t.inner.ctx, ptr, oldSize, newSize, alignment);
    if (p !is null || newSize == 0) {
        t.bytes_outstanding = t.bytes_outstanding - oldSize + newSize;
        if (newSize == 0 && ptr !is null) t.allocs_outstanding--;
        if (t.bytes_outstanding > t.peak_bytes) t.peak_bytes = t.bytes_outstanding;
    }
    return p;
}
private void track_free(void* ctx, void* ptr, size_t size) @nogc nothrow {
    Tracker* t = cast(Tracker*) ctx;
    t.inner.free_fn(t.inner.ctx, ptr, size);
    if (ptr !is null) {
        t.bytes_outstanding -= size;
        t.allocs_outstanding--;
    }
}

Allocator tracking_allocator(ref Tracker t, Allocator inner) @nogc nothrow {
    t.inner = inner;
    return Allocator(&t, &track_alloc, &track_realloc, &track_free);
}
