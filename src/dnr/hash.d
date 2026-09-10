module dnr.hash;

// ---------------------------------------------------------------------------
// hash — non-cryptographic hashing
// ---------------------------------------------------------------------------
// The functions `dnr.hashmap` needs for its default keys, exposed so custom
// keys, dedup, and cheap checksums can build on the same thing.
//
//   fnv1a(bytes)          classic FNV-1a — cheap, weak avalanche
//   hash64(bytes)         FNV-1a + a Murmur3 finaliser — a solid table hash
//   fmix64(x)             the 64-bit avalanche on its own
//   hash_combine(s, v)    fold one value's hash into a running seed
//   hash_of!T(v)          dispatch for a scalar / pointer / string key
//
// Not cryptographic. betterC: @nogc nothrow, no 128-bit maths.

private enum ulong FNV_OFFSET = 14695981039346656037UL;   // 0xcbf29ce484222325
private enum ulong FNV_PRIME  = 1099511628211UL;           // 0x100000001b3

ulong fnv1a(const(void)[] data) @nogc nothrow {
    auto p = cast(const(ubyte)*) data.ptr;
    ulong h = FNV_OFFSET;
    foreach (i; 0 .. data.length) { h ^= p[i]; h *= FNV_PRIME; }
    return h;
}

ulong fnv1a_str(const(char)[] s) @nogc nothrow {
    return fnv1a(cast(const(void)[]) s);
}

// Murmur3 / SplitMix64 finaliser — turns FNV's poor bit-mixing into a
// well-avalanched 64-bit value.
ulong fmix64(ulong x) @nogc nothrow {
    x ^= x >> 33;
    x *= 0xFF51AFD7ED558CCDUL;
    x ^= x >> 33;
    x *= 0xC4CEB9FE1A85EC53UL;
    x ^= x >> 33;
    return x;
}

// A solid general-purpose table hash.
ulong hash64(const(void)[] data) @nogc nothrow {
    return fmix64(fnv1a(data));
}
ulong hash64_str(const(char)[] s) @nogc nothrow {
    return fmix64(fnv1a_str(s));
}

// Fold `value` (already a hash, or any 64 bits worth mixing) into `seed` —
// order-dependent, so `hash_combine(hash_combine(0, a), b)` distinguishes
// (a, b) from (b, a). The 64-bit analogue of boost::hash_combine.
ulong hash_combine(ulong seed, ulong value) @nogc nothrow {
    seed ^= fmix64(value) + 0x9E3779B97F4A7C15UL + (seed << 6) + (seed >> 2);
    return seed;
}

// The dispatch `dnr.hashmap` uses for its built-in key types. Strings hash by
// content; integers / enums / pointers by their bits (avalanched). Guarded so
// it still *compiles* as a default argument for an unsupported K (you just
// can't call it — pass your own `hash` instead).
size_t hash_of(T)(const T v) @nogc nothrow {
    static if (is(T : const(char)[])) {
        return cast(size_t) hash64_str(v);
    } else static if (is(T : ulong) || is(T == enum) || is(T : const(void)*)) {
        return cast(size_t) fmix64(cast(ulong) v);
    } else {
        assert(0, "dnr.hash: no built-in hash for this key type — pass your own `hash`");
    }
}
