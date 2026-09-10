module dnr.algo;

// ---------------------------------------------------------------------------
// algo — operations over slices
// ---------------------------------------------------------------------------
// Plain functions on `T[]` / `const(T)[]`. No allocation, no `Allocator` — a
// slice is a view the caller already owns. betterC: everything @nogc nothrow,
// no exceptions. This is the `std.algorithm` subset the game actually reaches
// for — sort, search, and the small rearrangers.
//
// Ordering is a `less` function pointer, of type
//   bool function(const(T), const(T)) @nogc nothrow
// — return true when the first argument sorts before the second. It defaults
// to `a < b` (needs T to support `<`: a built-in number, or a struct with
// `opCmp`); pass an explicit one for descending order or sort-by-key.

// The default comparator. Guarded so it still *compiles* as the default
// argument of `sort!P` etc. for a P with no `<` — you just can't call those
// without an explicit `less` (it asserts if you do).
import res = dnr.result;

private bool default_less(T)(const T a, const T b) @nogc nothrow {
    static if (__traits(compiles, () { bool r = a < b; }))
        return a < b;
    else
        assert(0, "dnr.algo: this type has no `<` — pass an explicit `less`");
}

// ---------------------------------------------------------------------------
// rearrange
// ---------------------------------------------------------------------------

void swap(T)(ref T a, ref T b) @nogc nothrow {
    T t = a; a = b; b = t;
}

void reverse(T)(T[] s) @nogc nothrow {
    if (s.length < 2) return;
    size_t i = 0, j = s.length - 1;
    while (i < j) { swap(s[i], s[j]); i++; j--; }
}

void fill(T)(T[] s, T v) @nogc nothrow {
    foreach (ref e; s) e = v;
}

// Rotate left by `n` (element at index n becomes index 0). O(len), O(1) space
// (three reversals). `n` is taken modulo len.
void rotate_left(T)(T[] s, size_t n) @nogc nothrow {
    if (s.length < 2) return;
    n %= s.length;
    if (n == 0) return;
    reverse(s[0 .. n]);
    reverse(s[n .. $]);
    reverse(s);
}

// ---------------------------------------------------------------------------
// scan
// ---------------------------------------------------------------------------

// Index of the first element equal to `v`, or `none`.
res.Option!size_t index_of(T)(const(T)[] s, const T v) @nogc nothrow {
    foreach (i, ref e; s) if (e == v) return res.some(i);
    return res.none!size_t();
}

bool contains(T)(const(T)[] s, const T v) @nogc nothrow {
    return index_of(s, v).is_some();
}

// How many elements equal `v`.
size_t count(T)(const(T)[] s, const T v) @nogc nothrow {
    size_t n = 0;
    foreach (ref e; s) if (e == v) n++;
    return n;
}

bool equal(T)(const(T)[] a, const(T)[] b) @nogc nothrow {
    if (a.length != b.length) return false;
    foreach (i, ref e; a) if (e != b[i]) return false;
    return true;
}

// Index of the min / max element, or `none` on an empty slice. Ties -> first.
res.Option!size_t min_index(T)(const(T)[] s, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    if (s.length == 0) return res.none!size_t();
    size_t best = 0;
    foreach (i; 1 .. s.length) if (less(s[i], s[best])) best = i;
    return res.some(best);
}
res.Option!size_t max_index(T)(const(T)[] s, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    if (s.length == 0) return res.none!size_t();
    size_t best = 0;
    foreach (i; 1 .. s.length) if (less(s[best], s[i])) best = i;
    return res.some(best);
}

bool is_sorted(T)(const(T)[] s, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    foreach (i; 1 .. s.length) if (less(s[i], s[i - 1])) return false;
    return true;
}

// ---------------------------------------------------------------------------
// sort
// ---------------------------------------------------------------------------
// `insertion_sort` — stable, O(n²), the right call for small or nearly-sorted
// slices. `sort` — an iterative quicksort (median-of-three pivot, insertion
// cutoff, always-recurse-the-smaller-half so the explicit stack is bounded at
// ~log2(n)), unstable, O(n log n) typical. Neither recurses without bound and
// neither allocates.
//
// ⚠️ `sort` is NOT stable — equal elements can be reordered. Use
// `insertion_sort` (or sort on a key that breaks ties) when order matters.

enum size_t SORT_INSERTION_CUTOFF = 24;

void insertion_sort(T)(T[] s, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    foreach (i; 1 .. s.length) {
        T v = s[i];
        size_t j = i;
        while (j > 0 && less(v, s[j - 1])) { s[j] = s[j - 1]; j--; }
        s[j] = v;
    }
}

private size_t median3(T)(T[] s, size_t a, size_t b, size_t c, bool function(const(T), const(T)) @nogc nothrow less) @nogc nothrow {
    if (less(s[a], s[b]))
        return less(s[b], s[c]) ? b : (less(s[a], s[c]) ? c : a);
    else
        return less(s[a], s[c]) ? a : (less(s[b], s[c]) ? c : b);
}

void sort(T)(T[] s, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    // Explicit work stack of [lo, hi) ranges. Depth is bounded because we only
    // push the larger side and loop on the smaller — so a 64-deep stack covers
    // any size_t-length slice.
    static struct Range { size_t lo, hi; }
    Range[64] stack = void;
    int sp = 0;
    size_t lo = 0, hi = s.length;

    for (;;) {
        if (hi - lo <= SORT_INSERTION_CUTOFF) {
            insertion_sort(s[lo .. hi], less);
            if (sp == 0) break;
            sp--; lo = stack[sp].lo; hi = stack[sp].hi;
            continue;
        }

        // median-of-three into s[lo] as the pivot slot
        size_t mid = lo + (hi - lo) / 2;
        size_t m = median3(s, lo, mid, hi - 1, less);
        swap(s[lo], s[m]);
        T pivot = s[lo];

        // Hoare-ish partition around the pivot value
        size_t i = lo + 1, j = hi - 1;
        for (;;) {
            while (i < hi && less(s[i], pivot)) i++;
            while (j > lo && less(pivot, s[j])) j--;
            if (i >= j) break;
            swap(s[i], s[j]);
            i++; j--;
        }
        swap(s[lo], s[j]);   // pivot to its final home

        // recurse smaller half now, defer larger half on the stack
        size_t leftLo = lo, leftHi = j;
        size_t rightLo = j + 1, rightHi = hi;
        if (leftHi - leftLo > rightHi - rightLo) {
            stack[sp].lo = leftLo; stack[sp].hi = leftHi; sp++;
            lo = rightLo; hi = rightHi;
        } else {
            stack[sp].lo = rightLo; stack[sp].hi = rightHi; sp++;
            lo = leftLo; hi = leftHi;
        }
    }
}

// ---------------------------------------------------------------------------
// binary search — assume `s` is sorted by the same `less`
// ---------------------------------------------------------------------------

// First index i where `!less(s[i], v)` — i.e. where `v` could be inserted
// keeping the slice sorted, as early as possible. In [0, s.length].
size_t lower_bound(T)(const(T)[] s, const T v, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    size_t lo = 0, hi = s.length;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (less(s[mid], v)) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

// First index i where `less(v, s[i])` — the latest valid insertion point.
size_t upper_bound(T)(const(T)[] s, const T v, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    size_t lo = 0, hi = s.length;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (less(v, s[mid])) hi = mid;
        else lo = mid + 1;
    }
    return lo;
}

// Index of some element equal to `v` (equality = `!less(a,b) && !less(b,a)`),
// or `none`. O(log n).
res.Option!size_t binary_search(T)(const(T)[] s, const T v, bool function(const(T), const(T)) @nogc nothrow less = &default_less!T) @nogc nothrow {
    size_t i = lower_bound(s, v, less);
    if (i < s.length && !less(v, s[i])) return res.some(i);
    return res.none!size_t();
}
