module dnr.bitset;

// ---------------------------------------------------------------------------
// bitset — packed bit storage
// ---------------------------------------------------------------------------
// A `bool[]` spends a byte per flag; these spend a bit. Two containers over a
// shared set of word-array primitives:
//
//   BitArray!N   fixed, N bits inline, no allocator
//   BitSet       dynamic, N bits over an Allocator
//
// The `bits_*` primitives operate on a raw `ulong[]` (bit i lives in
// `w[i >> 6]`, bit `i & 63`) and are useful on their own. Both containers are
// plain data; the dynamic one is a handle (copying aliases) like the rest of
// dnr-std.
//
// betterC: @nogc nothrow.

import mem = dnr.mem;
import res = dnr.result;
import bop = core.bitop;

// ===========================================================================
// primitives over a ulong[] word array
// ===========================================================================

pragma(inline, true) void bits_set(ulong[] w, size_t i) @nogc nothrow {
    w[i >> 6] |= (1UL << (i & 63));
}
pragma(inline, true) void bits_clear(ulong[] w, size_t i) @nogc nothrow {
    w[i >> 6] &= ~(1UL << (i & 63));
}
pragma(inline, true) void bits_flip(ulong[] w, size_t i) @nogc nothrow {
    w[i >> 6] ^= (1UL << (i & 63));
}
pragma(inline, true) void bits_put(ulong[] w, size_t i, bool on) @nogc nothrow {
    if (on) bits_set(w, i); else bits_clear(w, i);
}
pragma(inline, true) bool bits_test(const(ulong)[] w, size_t i) @nogc nothrow {
    return ((w[i >> 6] >> (i & 63)) & 1) != 0;
}

// Population count over the whole array.
size_t bits_count(const(ulong)[] w) @nogc nothrow {
    size_t n = 0;
    foreach (x; w) n += bop.popcnt(x);
    return n;
}

// Index of the lowest set bit strictly at or after `from`, or none.
res.Option!size_t bits_first_set(const(ulong)[] w, size_t from = 0) @nogc nothrow {
    size_t wi = from >> 6;
    if (wi >= w.length) return res.none!size_t();
    ulong cur = w[wi] & (~0UL << (from & 63));   // mask off bits before `from`
    for (;;) {
        if (cur != 0) return res.some((wi << 6) + bop.bsf(cur));
        if (++wi >= w.length) return res.none!size_t();
        cur = w[wi];
    }
}

// Index of the lowest clear bit at or after `from`, within `nbits`, or none.
res.Option!size_t bits_first_clear(const(ulong)[] w, size_t nbits, size_t from = 0) @nogc nothrow {
    for (size_t i = from; i < nbits; ) {
        size_t wi = i >> 6;
        ulong inv = ~w[wi] & (~0UL << (i & 63));
        if (inv != 0) {
            size_t bit = (wi << 6) + bop.bsf(inv);
            return bit < nbits ? res.some(bit) : res.none!size_t();
        }
        i = (wi + 1) << 6;
    }
    return res.none!size_t();
}

// ===========================================================================
// BitArray!N — fixed
// ===========================================================================

struct BitArray(size_t N) {
    static assert(N > 0, "BitArray!0 is pointless");
    enum size_t bits  = N;
    enum size_t words = (N + 63) / 64;
    ulong[words] w;
}

void ba_set(size_t N)(ref BitArray!N b, size_t i) @nogc nothrow {
    assert(i < N, "ba_set: out of range");
    bits_set(b.w[], i);
}
void ba_clear(size_t N)(ref BitArray!N b, size_t i) @nogc nothrow {
    assert(i < N, "ba_clear: out of range");
    bits_clear(b.w[], i);
}
void ba_flip(size_t N)(ref BitArray!N b, size_t i) @nogc nothrow {
    assert(i < N, "ba_flip: out of range");
    bits_flip(b.w[], i);
}
void ba_put(size_t N)(ref BitArray!N b, size_t i, bool on) @nogc nothrow {
    assert(i < N, "ba_put: out of range");
    bits_put(b.w[], i, on);
}
bool ba_test(size_t N)(ref const BitArray!N b, size_t i) @nogc nothrow {
    assert(i < N, "ba_test: out of range");
    return bits_test(b.w[], i);
}

void ba_set_all(size_t N)(ref BitArray!N b) @nogc nothrow {
    foreach (ref x; b.w) x = ~0UL;
    ba_trim(b);
}
void ba_clear_all(size_t N)(ref BitArray!N b) @nogc nothrow {
    foreach (ref x; b.w) x = 0;
}

// Zero the padding bits in the last word (so count / first_clear stay honest
// after set_all).
private void ba_trim(size_t N)(ref BitArray!N b) @nogc nothrow {
    static if (N % 64 != 0)
        b.w[$ - 1] &= (1UL << (N % 64)) - 1;
}

size_t ba_count(size_t N)(ref const BitArray!N b) @nogc nothrow { return bits_count(b.w[]); }
bool   ba_any(size_t N)(ref const BitArray!N b)   @nogc nothrow { return bits_count(b.w[]) != 0; }
bool   ba_none(size_t N)(ref const BitArray!N b)  @nogc nothrow { return bits_count(b.w[]) == 0; }
bool   ba_all(size_t N)(ref const BitArray!N b)   @nogc nothrow { return bits_count(b.w[]) == N; }

res.Option!size_t ba_first_set(size_t N)(ref const BitArray!N b, size_t from = 0) @nogc nothrow {
    return bits_first_set(b.w[], from);
}
res.Option!size_t ba_first_clear(size_t N)(ref const BitArray!N b, size_t from = 0) @nogc nothrow {
    return bits_first_clear(b.w[], N, from);
}

// Iterate the set bits in ascending order:
//   auto it = ba_iter(b); size_t i;
//   while (ba_next(it).take(i)) { ... }
struct BaIter(size_t N) {
    const(BitArray!N)* b;
    size_t next;
}
BaIter!N ba_iter(size_t N)(ref const BitArray!N b) @nogc nothrow {
    return BaIter!N(&b, 0);
}
res.Option!size_t ba_next(size_t N)(ref BaIter!N it) @nogc nothrow {
    auto hit = bits_first_set(it.b.w[], it.next);
    size_t i;
    if (!hit.take(i)) return res.none!size_t();
    it.next = i + 1;
    return res.some(i);
}

// ===========================================================================
// BitSet — dynamic
// ===========================================================================

struct BitSet {
    ulong[]       w;
    size_t        nbits;
    mem.Allocator a;
}

res.Result!BitSet bitset_make(mem.Allocator a, size_t nbits) @nogc nothrow {
    BitSet b;
    b.a = a;
    b.nbits = nbits;
    if (nbits > 0) {
        auto wr = mem.make_n!ulong(a, (nbits + 63) / 64);
        if (wr.is_err) return res.err!BitSet(res.StdErr.oom);
        b.w = wr.unwrap;
    }
    return res.ok(b);
}

void bitset_free(ref BitSet b) @nogc nothrow {
    if (b.w.length) mem.free_n(b.a, b.w);
    b.w = null;
    b.nbits = 0;
}

size_t bitset_len(ref const BitSet b) @nogc nothrow { return b.nbits; }

void bitset_set(ref BitSet b, size_t i) @nogc nothrow {
    assert(i < b.nbits, "bitset_set: out of range");
    bits_set(b.w, i);
}
void bitset_clear(ref BitSet b, size_t i) @nogc nothrow {
    assert(i < b.nbits, "bitset_clear: out of range");
    bits_clear(b.w, i);
}
void bitset_flip(ref BitSet b, size_t i) @nogc nothrow {
    assert(i < b.nbits, "bitset_flip: out of range");
    bits_flip(b.w, i);
}
void bitset_put(ref BitSet b, size_t i, bool on) @nogc nothrow {
    assert(i < b.nbits, "bitset_put: out of range");
    bits_put(b.w, i, on);
}
bool bitset_test(ref const BitSet b, size_t i) @nogc nothrow {
    assert(i < b.nbits, "bitset_test: out of range");
    return bits_test(b.w, i);
}

void bitset_set_all(ref BitSet b) @nogc nothrow {
    foreach (ref x; b.w) x = ~0UL;
    if (b.nbits % 64 != 0 && b.w.length)
        b.w[$ - 1] &= (1UL << (b.nbits % 64)) - 1;
}
void bitset_clear_all(ref BitSet b) @nogc nothrow {
    foreach (ref x; b.w) x = 0;
}

size_t bitset_count(ref const BitSet b) @nogc nothrow { return bits_count(b.w); }
bool   bitset_any(ref const BitSet b)   @nogc nothrow { return bits_count(b.w) != 0; }
bool   bitset_none(ref const BitSet b)  @nogc nothrow { return bits_count(b.w) == 0; }

res.Option!size_t bitset_first_set(ref const BitSet b, size_t from = 0) @nogc nothrow {
    return bits_first_set(b.w, from);
}
res.Option!size_t bitset_first_clear(ref const BitSet b, size_t from = 0) @nogc nothrow {
    return bits_first_clear(b.w, b.nbits, from);
}

struct BitSetIter {
    const(BitSet)* b;
    size_t next;
}
BitSetIter bitset_iter(ref const BitSet b) @nogc nothrow {
    return BitSetIter(&b, 0);
}
res.Option!size_t bitset_next(ref BitSetIter it) @nogc nothrow {
    auto hit = bits_first_set(it.b.w, it.next);
    size_t i;
    if (!hit.take(i)) return res.none!size_t();
    it.next = i + 1;
    return res.some(i);
}
