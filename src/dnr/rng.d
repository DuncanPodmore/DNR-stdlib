module dnr.rng;

// ---------------------------------------------------------------------------
// rng — a small deterministic PRNG with explicit state
// ---------------------------------------------------------------------------
// `Rng` is xoshiro256** — fast, 256 bits of state, passes the usual test
// suites. It is NOT cryptographic. State is a plain struct you own and pass by
// `ref`; there is no global generator (same reasoning as dnr.mem's explicit
// allocator — a hidden one makes results irreproducible and non-obvious).
//
// Seeding is explicit and there is no OS-entropy call (that is platform code,
// out of scope here). For a game a fixed seed is usually what you want anyway
// — reproducible runs. Mix in a clock value at startup if you want variety.
//
// betterC: @nogc nothrow, no libc.

struct Rng {
    ulong[4] s;
}

private ulong rotl(ulong x, int k) @nogc nothrow {
    return (x << k) | (x >> (64 - k));
}

// splitmix64 — used to expand a single seed into the 256-bit state so a
// zero or low-entropy seed still gives a well-mixed start.
private ulong splitmix64(ref ulong x) @nogc nothrow {
    x += 0x9E3779B97F4A7C15UL;
    ulong z = x;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    return z ^ (z >> 31);
}

enum ulong RNG_DEFAULT_SEED = 0x853C49E6748FEA9BUL;

Rng rng_seed(ulong seed) @nogc nothrow {
    Rng r;
    ulong x = seed;
    foreach (ref w; r.s) w = splitmix64(x);
    return r;
}

// --- raw output ----------------------------------------------------------

ulong next_u64(ref Rng r) @nogc nothrow {
    immutable ulong result = rotl(r.s[1] * 5, 7) * 9;
    immutable ulong t = r.s[1] << 17;
    r.s[2] ^= r.s[0];
    r.s[3] ^= r.s[1];
    r.s[1] ^= r.s[2];
    r.s[0] ^= r.s[3];
    r.s[2] ^= t;
    r.s[3] = rotl(r.s[3], 45);
    return result;
}

uint next_u32(ref Rng r) @nogc nothrow {
    return cast(uint)(next_u64(r) >> 32);
}

// [0, 1) with 24 bits of mantissa.
float next_float(ref Rng r) @nogc nothrow {
    return cast(float)(next_u64(r) >> 40) * (1.0f / 16777216.0f);
}

// [0, 1) with 53 bits of mantissa.
double next_double(ref Rng r) @nogc nothrow {
    return cast(double)(next_u64(r) >> 11) * (1.0 / 9007199254740992.0);
}

// --- ranges ------------------------------------------------------------

// Unbiased [0, bound) (Lemire). bound == 0 returns 0.
uint below(ref Rng r, uint bound) @nogc nothrow {
    if (bound == 0) return 0;
    ulong m = cast(ulong) next_u32(r) * bound;
    uint low = cast(uint) m;
    if (low < bound) {
        uint thresh = (-bound) % bound;
        while (low < thresh) {
            m = cast(ulong) next_u32(r) * bound;
            low = cast(uint) m;
        }
    }
    return cast(uint)(m >> 32);
}

// Unbiased int in [lo, hi). Asserts lo < hi.
int range_i(ref Rng r, int lo, int hi) @nogc nothrow {
    assert(lo < hi, "rng.range_i: empty or inverted range");
    return lo + cast(int) below(r, cast(uint)(hi - lo));
}

// Uniform float in [lo, hi).
float range_f(ref Rng r, float lo, float hi) @nogc nothrow {
    return lo + (hi - lo) * next_float(r);
}

// true with probability p (p <= 0 never, p >= 1 always).
bool chance(ref Rng r, float p) @nogc nothrow {
    if (p <= 0.0f) return false;
    if (p >= 1.0f) return true;
    return next_float(r) < p;
}

// A random sign, -1 or +1.
int sign(ref Rng r) @nogc nothrow {
    return (next_u64(r) & 1) ? 1 : -1;
}

// --- slices ----------------------------------------------------------

// A reference to a uniformly-chosen element. Asserts non-empty.
ref T pick(T)(ref Rng r, T[] s) @nogc nothrow {
    assert(s.length > 0, "rng.pick: empty slice");
    return s[below(r, cast(uint) s.length)];
}

// In-place Fisher-Yates shuffle.
void shuffle(T)(ref Rng r, T[] s) @nogc nothrow {
    if (s.length < 2) return;
    for (size_t i = s.length - 1; i > 0; i--) {
        size_t j = below(r, cast(uint)(i + 1));
        T tmp = s[i]; s[i] = s[j]; s[j] = tmp;
    }
}
