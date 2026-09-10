module dnr.slotmap;

// ---------------------------------------------------------------------------
// SlotMap!T — a pool with stable, generation-checked handles
// ---------------------------------------------------------------------------
// dnr.mem's Pool!T hands out a T* that a later reuse of the same slot silently
// re-points. This is the fix: `slotmap_insert` returns a `Handle` carrying the
// slot index AND a generation counter; `slotmap_get` only resolves it while
// the generation still matches. A handle to a removed entry reads as `none`
// rather than aliasing whatever moved in — the game's `Enemy.uid` pattern,
// done so a dangling reference is impossible.
//
// Dense in capacity, not iteration order. Grows ×2. betterC: @nogc nothrow;
// insert failure is `StdErr.oom`. Handle, not a value; POD (no dtors).

import mem = dnr.mem;
import res = dnr.result;

enum size_t SLOTMAP_MIN_CAP = 8;

struct Handle {
    uint index = 0;
    uint gen   = 0;      // 0 is never a live generation -> Handle.init is null
}

enum Handle NULL_HANDLE = Handle(0, 0);

bool handle_is_null(Handle h) @nogc nothrow { return h.gen == 0; }

struct SlotMap(T) {
    struct Slot {
        T    value;
        uint gen      = 0;
        bool occupied  = false;
    }
    Slot[]        slots;
    uint[]        freeStack;
    uint          freeCount;
    size_t        count;
    mem.Allocator a;
}

SlotMap!T slotmap_make(T)(mem.Allocator a, size_t capacity = 0) @nogc nothrow {
    SlotMap!T m;
    m.a = a;
    if (capacity > 0) cast(void) slotmap_grow(m, capacity < SLOTMAP_MIN_CAP ? SLOTMAP_MIN_CAP : capacity);
    return m;
}

void slotmap_free(T)(ref SlotMap!T m) @nogc nothrow {
    if (m.slots.length)     mem.free_n(m.a, m.slots);
    if (m.freeStack.length) mem.free_n(m.a, m.freeStack);
    m = SlotMap!T.init;
}

size_t slotmap_len(T)(ref const SlotMap!T m)      @nogc nothrow { return m.count; }
size_t slotmap_capacity(T)(ref const SlotMap!T m) @nogc nothrow { return m.slots.length; }
bool   slotmap_empty(T)(ref const SlotMap!T m)    @nogc nothrow { return m.count == 0; }

private res.Status slotmap_grow(T)(ref SlotMap!T m, size_t newCap) @nogc nothrow {
    alias Slot = SlotMap!T.Slot;
    size_t oldCap = m.slots.length;
    if (newCap <= oldCap) return res.pass();

    auto sr = mem.make_n!Slot(m.a, newCap);
    if (sr.is_err) return res.fail(res.StdErr.oom);
    auto fr = mem.make_n!uint(m.a, newCap);
    if (fr.is_err) { mem.free_n(m.a, sr.unwrap); return res.fail(res.StdErr.oom); }

    Slot[] ns = sr.unwrap;
    uint[] nf = fr.unwrap;

    // carry existing slots over verbatim (indices are stable)
    foreach (i; 0 .. oldCap) ns[i] = m.slots[i];
    // carry the existing free stack
    foreach (i; 0 .. m.freeCount) nf[i] = m.freeStack[i];
    // the freshly added slots become free, highest index on top so the next
    // inserts hand out oldCap, oldCap+1, …
    uint fc = m.freeCount;
    for (size_t i = newCap; i > oldCap; i--)
        nf[fc++] = cast(uint)(i - 1);

    if (oldCap)             mem.free_n(m.a, m.slots);
    if (m.freeStack.length) mem.free_n(m.a, m.freeStack);
    m.slots = ns;
    m.freeStack = nf;
    m.freeCount = fc;
    return res.pass();
}

// Insert a value, returning a handle to it. `StdErr.oom` on a failed grow.
res.Result!Handle slotmap_insert(T)(ref SlotMap!T m, T value) @nogc nothrow {
    if (m.freeCount == 0) {
        size_t next = m.slots.length < SLOTMAP_MIN_CAP ? SLOTMAP_MIN_CAP : m.slots.length * 2;
        if (slotmap_grow(m, next).is_err) return res.err!Handle(res.StdErr.oom);
    }
    uint idx = m.freeStack[--m.freeCount];
    auto sl = &m.slots[idx];
    if (sl.gen == 0) sl.gen = 1;      // first use of this slot
    sl.value = value;
    sl.occupied = true;
    m.count++;
    return res.ok(Handle(idx, sl.gen));
}

private bool live(T)(ref SlotMap!T m, Handle h) @nogc nothrow {
    return h.gen != 0
        && h.index < m.slots.length
        && m.slots[h.index].occupied
        && m.slots[h.index].gen == h.gen;
}

// The value behind `h`, or `none` if the handle is null / stale / removed.
res.Option!(T*) slotmap_get(T)(ref SlotMap!T m, Handle h) @nogc nothrow {
    return live(m, h) ? res.some!(T*)(&m.slots[h.index].value) : res.none!(T*)();
}

bool slotmap_contains(T)(ref SlotMap!T m, Handle h) @nogc nothrow {
    return live(m, h);
}

// Remove the entry `h` points at. true if it was live. Bumps the slot's
// generation so every existing handle to it goes stale.
bool slotmap_remove(T)(ref SlotMap!T m, Handle h) @nogc nothrow {
    if (!live(m, h)) return false;
    auto sl = &m.slots[h.index];
    sl.occupied = false;
    sl.gen++;
    if (sl.gen == 0) sl.gen = 1;      // skip the null generation on wrap
    m.freeStack[m.freeCount++] = h.index;
    m.count--;
    return true;
}

// Empty the map. Every outstanding handle goes stale (all generations bumped).
void slotmap_clear(T)(ref SlotMap!T m) @nogc nothrow {
    m.freeCount = 0;
    foreach_reverse (i; 0 .. m.slots.length) {
        auto sl = &m.slots[i];
        if (sl.occupied) {
            sl.occupied = false;
            sl.gen++;
            if (sl.gen == 0) sl.gen = 1;
        }
        m.freeStack[m.freeCount++] = cast(uint) i;
    }
    m.count = 0;
}

// Iterate live entries (order unspecified):
//   auto it = slotmap_iter(m); Handle h; T* v;
//   while (slotmap_next(it, h, v)) { ... }
struct SlotMapIter(T) {
    SlotMap!T* map;
    size_t idx;
}
SlotMapIter!T slotmap_iter(T)(ref SlotMap!T m) @nogc nothrow {
    return SlotMapIter!T(&m, 0);
}
bool slotmap_next(T)(ref SlotMapIter!T it, ref Handle h, ref T* value) @nogc nothrow {
    while (it.idx < it.map.slots.length) {
        auto sl = &it.map.slots[it.idx];
        uint i = cast(uint) it.idx;
        it.idx++;
        if (sl.occupied) {
            h = Handle(i, sl.gen);
            value = &sl.value;
            return true;
        }
    }
    return false;
}
