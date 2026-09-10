module dnr.hashmap;

// ---------------------------------------------------------------------------
// HashMap!(K, V) — open-addressed hash table over an explicit Allocator
// ---------------------------------------------------------------------------
// Linear probing with backward-shift deletion (no tombstones). Grows ×2 at a
// 0.75 load factor. The per-slot hash is cached so a probe walk and a resize
// never recompute it.
//
// Keys: integers, enums and pointers hash and compare with no help. String
// keys — anything implicitly `const(char)[]` — get an FNV-1a hash and a
// memcmp compare by default. Any other K needs an explicit `hash` + `eq`
// pair passed to `hm_make` (it won't compile to *call* the map otherwise).
//
// ⚠️ The map stores keys and values BY VALUE and copies nothing behind them.
// A string key is a slice — its backing bytes must outlive the entry. (A
// key-duplicating variant is a later addition.)
//
// ⚠️ Same handle discipline as dnr.array: a HashMap is not a value, copying
// one aliases the block. Pass by `ref`. POD — no element destructors run.
//
// betterC: @nogc nothrow. OOM on `hm_put` is a `false` return (the map is
// left unchanged).

import mem = dnr.mem;
import mth = dnr.math;
import res = dnr.result;
import hsh = dnr.hash;
import cstr = core.stdc.string;

enum size_t HM_MIN_CAP = 8;

// --- default key hashing / equality -------------------------------------

private size_t default_hash(K)(const K k) @nogc nothrow {
    return hsh.hash_of!K(k);
}

private bool default_eq(K)(const K a, const K b) @nogc nothrow {
    static if (is(K : const(char)[])) {
        if (a.length != b.length) return false;
        return a.length == 0 || cstr.memcmp(a.ptr, b.ptr, a.length) == 0;
    } else static if (is(K : ulong) || is(K == enum) || is(K : const(void)*)) {
        return a == b;
    } else {
        assert(0, "dnr.hashmap: no default eq for this key type — pass `eq` to hm_make");
    }
}

// --- the map ----------------------------------------------------------

struct HashMap(K, V) {
    struct Slot {
        K      key;
        V      value;
        size_t hash;
        bool   used;
    }
    Slot[]        slots;
    size_t        count;
    size_t        mask;     // slots.length - 1 (slots.length is a power of 2), or 0 when empty
    mem.Allocator a;
    size_t function(const K) @nogc nothrow hashfn;
    bool   function(const K, const K) @nogc nothrow eqfn;
}

// `capacity` is the element count you expect — enough slots are allocated up
// front to hold it under the load factor (0 = allocate on first insert).
HashMap!(K, V) hm_make(K, V)(
    mem.Allocator a,
    size_t capacity = 0,
    size_t function(const K) @nogc nothrow hash = &default_hash!K,
    bool   function(const K, const K) @nogc nothrow eq = &default_eq!K,
) @nogc nothrow {
    HashMap!(K, V) h;
    h.a = a;
    h.hashfn = hash;
    h.eqfn = eq;
    if (capacity > 0) {
        size_t need = mth.next_pow2(capacity + capacity / 2 + 1);
        if (need < HM_MIN_CAP) need = HM_MIN_CAP;
        hm_grow(h, need);
    }
    return h;
}

void hm_free(K, V)(ref HashMap!(K, V) h) @nogc nothrow {
    if (h.slots.length) mem.free_n(h.a, h.slots);
    h.slots = null;
    h.count = 0;
    h.mask = 0;
}

size_t hm_len(K, V)(ref const HashMap!(K, V) h) @nogc nothrow { return h.count; }
bool   hm_empty(K, V)(ref const HashMap!(K, V) h) @nogc nothrow { return h.count == 0; }

// Length to 0, slots kept and blanked.
void hm_clear(K, V)(ref HashMap!(K, V) h) @nogc nothrow {
    foreach (ref sl; h.slots) sl.used = false;
    h.count = 0;
}

private bool hm_grow(K, V)(ref HashMap!(K, V) h, size_t newCap) @nogc nothrow {
    alias Slot = HashMap!(K, V).Slot;
    auto freshR = mem.make_n!Slot(h.a, newCap);
    if (freshR.is_err) return false;
    Slot[] fresh = freshR.unwrap;

    Slot[] old = h.slots;
    h.slots = fresh;
    h.mask = newCap - 1;

    foreach (ref sl; old) {
        if (!sl.used) continue;
        size_t i = sl.hash & h.mask;
        while (h.slots[i].used) i = (i + 1) & h.mask;
        h.slots[i] = sl;
    }
    if (old.length) mem.free_n(h.a, old);
    return true;
}

// Insert or overwrite. `StdErr.oom` only on an allocation failure while
// growing (the map is unchanged in that case).
res.Status hm_put(K, V)(ref HashMap!(K, V) h, K key, V value) @nogc nothrow {
    if (h.slots.length == 0 && !hm_grow(h, HM_MIN_CAP)) return res.fail(res.StdErr.oom);
    // grow before the load factor passes 0.75
    if ((h.count + 1) * 4 > h.slots.length * 3) {
        if (!hm_grow(h, h.slots.length * 2)) return res.fail(res.StdErr.oom);
    }

    size_t hash = h.hashfn(key);
    size_t i = hash & h.mask;
    while (h.slots[i].used) {
        if (h.slots[i].hash == hash && h.eqfn(h.slots[i].key, key)) {
            h.slots[i].value = value;               // overwrite
            return res.pass();
        }
        i = (i + 1) & h.mask;
    }
    h.slots[i].key = key;
    h.slots[i].value = value;
    h.slots[i].hash = hash;
    h.slots[i].used = true;
    h.count++;
    return res.pass();
}

// The stored value by pointer (mutable, valid until the next insert/remove),
// or `none`.
res.Option!(V*) hm_get(K, V)(ref HashMap!(K, V) h, K key) @nogc nothrow {
    if (h.count == 0) return res.none!(V*)();
    size_t hash = h.hashfn(key);
    size_t i = hash & h.mask;
    while (h.slots[i].used) {
        if (h.slots[i].hash == hash && h.eqfn(h.slots[i].key, key))
            return res.some!(V*)(&h.slots[i].value);
        i = (i + 1) & h.mask;
    }
    return res.none!(V*)();
}

bool hm_contains(K, V)(ref HashMap!(K, V) h, K key) @nogc nothrow {
    return hm_get(h, key).is_some();
}

V hm_get_or(K, V)(ref HashMap!(K, V) h, K key, V fallback) @nogc nothrow {
    V* p;
    return hm_get(h, key).take(p) ? *p : fallback;
}

// Remove `key`. true if it was present. Uses backward-shift so the table
// stays tombstone-free.
bool hm_remove(K, V)(ref HashMap!(K, V) h, K key) @nogc nothrow {
    if (h.count == 0) return false;
    size_t hash = h.hashfn(key);
    size_t i = hash & h.mask;
    while (h.slots[i].used) {
        if (h.slots[i].hash == hash && h.eqfn(h.slots[i].key, key)) break;
        i = (i + 1) & h.mask;
    }
    if (!h.slots[i].used) return false;

    // shift the run after i back by one where doing so keeps every element
    // reachable from its ideal slot
    size_t j = i;
    for (;;) {
        j = (j + 1) & h.mask;
        if (!h.slots[j].used) break;
        size_t k = h.slots[j].hash & h.mask;
        bool stay = (i <= j) ? (i < k && k <= j) : (i < k || k <= j);
        if (stay) continue;
        h.slots[i] = h.slots[j];
        i = j;
    }
    h.slots[i].used = false;
    h.count--;
    return true;
}

// --- iteration ------------------------------------------------------
// Order is arbitrary and changes across a resize. Do not insert or remove
// while iterating.
//   auto it = hm_iter(h);
//   K key; V* val;
//   while (hm_next(it, key, val)) { ... }

struct HmIter(K, V) {
    HashMap!(K, V)* map;
    size_t idx;
}

HmIter!(K, V) hm_iter(K, V)(ref HashMap!(K, V) h) @nogc nothrow {
    return HmIter!(K, V)(&h, 0);
}

bool hm_next(K, V)(ref HmIter!(K, V) it, ref K key, ref V* value) @nogc nothrow {
    auto h = it.map;
    while (it.idx < h.slots.length) {
        auto sl = &h.slots[it.idx];
        it.idx++;
        if (sl.used) {
            key = sl.key;
            value = &sl.value;
            return true;
        }
    }
    return false;
}
