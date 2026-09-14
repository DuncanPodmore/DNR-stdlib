# dnr-std — D no-runtime standard

> **Written with AI.** Every module here was implemented by Claude (Anthropic's
> Sonnet) working from the author's design direction and review, not hand-typed.
> If that matters to you, now you know before you read the code.

A small standard library for **D compiled with `-betterC`** — no druntime, no
GC, no Phobos. Extracted from the patterns that carried the *Dopashooter* game,
and built to the same imperative, explicit, no-magic philosophy.

betterC drops Phobos along with the runtime, and what's left in `core.stdc.*` is
just libc. `dnr-std` is the layer between libc and application code: allocation,
containers, strings, math, and the odd jobs (`rng`, `io`, `result`) that every
program re-implements otherwise.

## Philosophy

- **Imperative, not generic-functional.** Plain functions over data. Templates
  where a container genuinely needs a type parameter; not as a style.
- **`snake_case` functions, `PascalCase` types.** `pool_get`, not `Pool.get`;
  free functions taking `ref T` over methods, so the data stays a plain struct.
- **No hidden control flow.** No exceptions (betterC has none anyway), no hidden
  allocation, no destructor-driven resource magic beyond what betterC gives.
- **Failure is a value.** A fallible call returns `Option!T` (a lookup that may
  miss), `Result!(T, E)` (a computation that may fail) or `Status` (an action
  with no result). `unwrap` panics on the empty case; `unwrap_or` / `take` /
  `failed` handle it. `dnr.mem`'s `raw_*` primitives stay pointer-and-null —
  that's the C-ABI layer the vtable is built on.
- **Allocation is explicit — the Zig model.** Nothing allocates without an
  `Allocator` handed to it. There is no global default. See `dnr.mem`.
- **Source-included.** No package manager. Vendor `src/dnr/` into your project
  and add the files to your build, the same way *Dopashooter* vendors raylib.
- **Every module has a `*_test.d`.** betterC has no `unittest` runner, so tests
  are plain functions gathered by `src/test_all.d`. `dnr.testing` is that
  harness, and it ships — it's usable by consumers too.

## Layout

```
src/dnr/
  testing.d     assertion harness (check / near / expect_eq / testing_summary)
  panic.d       panic / unreachable / todo / panic_if
  result.d      Option!T / Result!(T,E) / Status / StdErr
  mem.d         Allocator + malloc / arena / growing-arena / pool / tracking
  array.d       Array!T — growable array over an Allocator
  algo.d        sort / search / rearrange over slices
  math.d        scalar helpers — min/max/clamp, lerp, angle wrap, pow2
  rng.d         xoshiro256** PRNG with explicit state
  hash.d        FNV-1a / hash64 / fmix64 / hash_combine / hash_of
  str.d         slice ops + parsing + Sb (StringBuilder)
  utf8.d        strict decode / encode / validate + rune iterator
  hashmap.d     HashMap!(K,V) — open-addressed, Allocator-backed
  bitset.d      BitArray!N (fixed) / BitSet (dynamic) + bits_* primitives
  ringbuf.d     RingBuffer!T — growable double-ended queue
  slotmap.d     SlotMap!T — pool with generation-checked handles
  fmt.d         compile-time-checked {} formatting
  ini.d         key = value + [section] parse / write
  io.d          whole-file read/write + LineReader
  time.d        monotonic clock + Duration + Stopwatch
  *_test.d      one per module
src/test_all.d  the test runner (extern(C) main)
nobd.d          the build tool — see Build below
makefile        bootstraps nobd.d, then `make test` / `make check` hand off to it
```

`import dnr.mem;` — the package prefix is `dnr.`.

## Build

Build configuration lives in **`nobd.d`**, not the makefile — a small
self-hosted D program in the spirit of [tsoding/nob.h](https://github.com/tsoding/nob.h)
("no-build": write your build tool in the same language as the project, so
building D is D, not a second, weaker language bolted on top of it). `make`
still owns the one bootstrapping step every nob-style tool needs — recompiling
`nobd.d` into `build/nobd` whenever it changes, which is exactly the mtime
tracking `make` is already good at — and then hands off:

```
make test     # (re)build nobd if needed, then: nobd test  — compile the lib
              # + tests to build/test and run it
make check    # (re)build nobd if needed, then: nobd check — type-check the
              # library alone (-o-, no codegen, no main)
```

`nobd.d` is deliberately self-contained — no `import dnr.*` — the same reason
nob.h itself depends on nothing but the C standard library and the OS: if
dnr-std is broken, the tool that builds and tests it still has to compile and
run. It's plain `core.stdc` + a handful of hand-declared `CreateProcess`/
`CreateDirectory` Win32 calls (the same "hand-roll exactly what you need"
convention *Dopashooter*'s `screens.d` uses for `CreateDirectoryA`).

Toolchain: **LDC** (tested on 1.42), `-betterC -mscrtlib=msvcrt`, mingw `make`.
No external libraries — `core.stdc` only. ⚠️ **Windows only for now** — `nobd.d`
spawns processes via `CreateProcess`; a POSIX `fork`/`execvp` path would be a
`version(Posix)` branch alongside it, not written yet.

## `dnr.result` — `Option` / `Result` / `Status`

The value-carrying failure types. Construct with `some` / `none`, `ok` / `err`
(T explicit: `err!int(StdErr.overflow)`), `pass` / `fail`. Read with `is_some` /
`is_ok`, `unwrap` (panics through `dnr.panic` on the empty case), `unwrap_or`, or
the imperative bridge — `opt.take(out_)` / `res.take(out_)` copy the value into
an out-parameter and return `bool` (`res.failed(err_out)` does the same for the
error). `E` defaults to `StdErr` (`oom` / `not_found` / `invalid` / `overflow` /
`io` / `unexpected_eof` / `permission` / `unknown`), `err_name` for messages.

## `dnr.mem` — the allocator layer

`Allocator` is a C-style vtable: an opaque `ctx` pointer plus `alloc` / `realloc`
/ `free` function pointers. You pass one explicitly to anything that allocates.
The caller tracks the size of every block it holds (like Zig) — `raw_free` and
`raw_realloc` take the old size; a malloc backend ignores it, an arena needs it.
The typed helpers carry that bookkeeping for you.

`raw_alloc` / `raw_realloc` / `raw_free` (and the vtable) return a pointer / null
— the C-ABI primitive layer. The typed helpers on top report the dnr-std way:

| Helper | Returns |
|---|---|
| `make!T` / `unmake!T` | `Result!(T*)` — one `T`, `.init`-filled (field initializers honoured, no NaN floats) |
| `make_n!T` / `free_n!T` | `Result!(T[])` — a slice of `n`, each `.init`-filled (`n == 0` is `ok(null)`) |
| `resize_n!T(ref s, n)` | `Status` — grow / shrink in place, new tail `.init`-filled |
| `dup!T` | `Result!(T[])` — copy a slice into a fresh block |
| `alloc_raw` | `Result!(void[])` — undefined bytes, the escape hatch |

Backends:

| Constructor | Model |
|---|---|
| `malloc_allocator()` | wraps `core.stdc.stdlib`; alignment ≤ 16 |
| `arena_allocator(ref Arena)` | bump allocator over a caller-provided buffer; `raw_free` pops only the most-recent block; `arena_reset` frees all at once; OOM → null |
| `garena_allocator(ref GrowingArena)` | bump allocator that asks a parent allocator for another (bigger) block when full; `garena_reset` frees all but the largest block and rewinds it; `garena_free` returns everything |
| `pool_alloc_storage` (→ `Status`) / `pool_init` → `Pool!T` | fixed-capacity slot allocator, O(1) free list (a separate index stack); `pool_get` / `pool_put`; slots not zeroed — the game's `Enemy[700]` pattern |
| `tracking_allocator(ref Tracker, inner)` | wraps another allocator, counts `bytes_outstanding` / `peak_bytes` / `total_allocs` — assert zero at teardown to catch a leak (test-only) |

## `dnr.array` — `Array!T`

The `~` append / `arr.length = n` resize that betterC drops. A struct holding a
slice + capacity + the owning `Allocator`; every mutator is a free function over
`ref Array!T`. Amortised doubling growth, so N pushes are O(N). A mutator that
can grow returns `Status` (`StdErr.oom` leaves the array untouched).

`array_make` / `array_from` (→ `Result!(Array!T)`) / `array_free` · `array_push`
/ `array_append` / `array_insert` / `array_resize` / `array_reserve` (all →
`Status`) · `array_pop` (→ `Option!T`) / `array_back` (ref, asserts non-empty) ·
`array_remove` (ordered) / `array_swap_remove` (O(1)) / `array_clear` /
`array_shrink_to_fit` · `array_len` / `array_empty`, and `arr.items` is the live
slice for iteration and indexing.

⚠️ A handle, not a value — copying aliases the block. Pass by `ref`. POD
container — element destructors are never run.

## `dnr.algo` — slice operations

Plain functions over `T[]` / `const(T)[]` — no allocator, a slice is a view the
caller owns. The `std.algorithm` subset the game actually reaches for.

- rearrange: `swap`, `reverse`, `fill`, `rotate_left`
- scan: `index_of` / `min_index` / `max_index` / `binary_search` return
  `Option!size_t`; `contains` / `count` / `equal` / `is_sorted` return plain values
- sort: `insertion_sort` (stable, O(n²) — small / nearly-sorted) and `sort` (an
  iterative quicksort — median-of-three, insertion cutoff, bounded explicit
  stack; **unstable**, no recursion, no allocation)
- search a sorted slice: `lower_bound` / `upper_bound` (an insertion index, always
  valid) / `binary_search` (`Option!size_t`)

Ordering is a `bool function(const(T), const(T)) @nogc nothrow` `less` argument,
defaulting to `a < b`. Pass one for descending order or sort-by-key.

## `dnr.math` — scalar helpers

`core.stdc.math` has the transcendentals and nothing else. This is the rest:

- generic (`T` = any int or float): `min` / `max` / `clamp` / `abs` / `sign`
- interpolation: `lerp` / `lerp_clamped` / `inv_lerp` / `remap` / `saturate` /
  `smoothstep`, and `damp` (frame-rate-independent exponential approach — the
  game's camera / knockback / HP-trail decay shape)
- float compare: `approx_eq` / `approx_zero`
- angles (radians): `wrap_angle` (→ (-π, π]) / `angle_diff` / `lerp_angle` /
  `to_rad` / `to_deg`
- float→int: `ifloor` / `iceil` / `iround`
- integers: `is_pow2` / `next_pow2` / `align_up` / `align_down` / `ceil_div` /
  `abs_diff` / `gcd`
- constants: `PI` / `TAU` / `HALF_PI` / `E` / `SQRT2` / `DEG2RAD` / `RAD2DEG`
  (plus `PI_F` / `TAU_F` / `HALF_PI_F` and `EPSILON`)

## `dnr.rng` — deterministic PRNG

`Rng` is xoshiro256** — 256 bits of state in a plain struct you pass by `ref`.
No global generator (a hidden one makes results irreproducible). Seeding is
explicit, no OS entropy (that's platform code) — a fixed seed is usually what a
game wants anyway.

`rng_seed(ulong)` · `next_u64` / `next_u32` / `next_float` / `next_double` (both
floats in `[0, 1)`) · `below(bound)` (unbiased) / `range_i(lo, hi)` /
`range_f(lo, hi)` / `chance(p)` / `sign` · `pick(slice)` / `shuffle(slice)`
(Fisher-Yates). Not cryptographic.

## `dnr.hash` — non-cryptographic hashing

What `dnr.hashmap` needs for its default keys, made public for custom keys,
dedup and cheap checksums.

`fnv1a(bytes)` (cheap, weak avalanche) · `hash64(bytes)` (FNV-1a + a Murmur3
finaliser — a solid table hash) · `fmix64(x)` (the 64-bit avalanche alone) ·
`hash_combine(seed, v)` (fold one hash into a running seed, order-dependent —
the 64-bit `boost::hash_combine`) · `hash_of!T(v)` (the scalar / pointer /
string dispatch). Not cryptographic.

## `dnr.str` — strings for betterC

A "string" is `const(char)[]` — a slice, **not** null-terminated. `from_cstr`
crosses in from C, `Sb.cstr` crosses back. ASCII only. Three parts:

**Slice ops** (views, no allocation): `equals` / `equals_ci` / `starts_with` /
`ends_with` · `index_of` (char or substring) / `last_index_of` (→ `Option!size_t`)
/ `contains` / `count_char` · `trim` / `trim_left` / `trim_right` /
`strip_prefix` / `strip_suffix` · the `Splitter` iterator — `auto it =
split(s, ','); const(char)[] f; while (split_next(it).take(f)) …` (also
`split_ws`) · classify: `is_space` / `is_digit` / `is_alpha` / … / `to_lower` /
`to_upper`.

**Parsing** (each → `Result!T`, `StdErr.invalid` / `StdErr.overflow`, whole
slice must be valid): `parse_int` / `parse_uint` / `parse_hex` / `parse_float`
(via `strtod` for correct rounding).

**`Sb`** — a StringBuilder over an `Allocator`. `sb_put` / `sb_put_char` /
`sb_put_int` / `sb_put_uint` / `sb_put_hex` / `sb_put_float` / `sb_put_rep`, all
chainable and all no-ops once an allocation fails — `sb_reserve` returns
`Status`, and `sb.ok` is the one check at the end. `sb_slice` is the contents;
`sb_cstr` appends a `\0` without counting it. `sb_fixed(char[])` wraps a caller
buffer (no allocator — overflow truncates and latches `ok` false).

## `dnr.utf8` — strict UTF-8

`dnr.str` is ASCII-only; this handles code points. **Strict** — overlong
encodings, surrogate halves and anything past U+10FFFF are errors.

- `utf8_decode(s)` → `Result!Rune` (`{ uint cp; ubyte len }`) · `utf8_encode(cp,
  ref char[4])` → `Result!size_t` · `rune_len(cp)` (1–4, or −1)
- `utf8_validate(s)` → `bool` · `utf8_count(s)` → `Result!size_t` (code points)
- `utf8_put(sb, cp)` — append one code point to an `Sb`
- `utf8_runes(s)` / `utf8_next` — a **lossy** iterator: a bad byte yields U+FFFD
  and advances one, so the loop never stalls

Code points are `uint` (char / wchar don't implicitly widen to `dchar` in D).

## `dnr.hashmap` — `HashMap!(K, V)`

Open addressing, linear probing, **backward-shift deletion** (no tombstones).
Grows ×2 at 0.75 load. The per-slot hash is cached so probing and resizing
never recompute it.

- integer / enum / pointer keys and string keys (`const(char)[]`, FNV-1a +
  memcmp) work with no help; any other `K` needs `hash` + `eq` function
  pointers passed to `hm_make`
- `hm_put` (insert or overwrite, → `Status`) · `hm_get` (→ `Option!(V*)` —
  mutable through the pointer) · `hm_contains` / `hm_get_or` · `hm_remove`
  (→ `bool`, was it there) · `hm_clear` / `hm_len` / `hm_empty`
- iterate: `auto it = hm_iter(h); K k; V* v; while (hm_next(it, k, v)) …`
  (a `bool` + two out-params — it yields a pair)

⚠️ Stores keys and values **by value, copying nothing behind them** — a string
key's bytes must outlive the entry. Handle, not a value (copying aliases). POD
— no element destructors.

## `dnr.bitset` — packed bits

A `bool[]` spends a byte per flag; these spend a bit.

- `bits_set` / `bits_clear` / `bits_flip` / `bits_test` / `bits_count` /
  `bits_first_set` / `bits_first_clear` — primitives over a raw `ulong[]`
- `BitArray!N` — fixed, N bits inline, no allocator: `ba_set` / `ba_test` /
  `ba_count` / `ba_any` / `ba_all` / `ba_first_set` / `ba_first_clear` /
  `ba_set_all` / `ba_clear_all`, and `ba_iter` / `ba_next` (ascending set bits)
- `BitSet` — the same over an `Allocator` (`bitset_make` → `Result!BitSet`,
  `bitset_free`, `bitset_*` mirroring the fixed API)

`set_all` / `count` respect the exact bit count, not the padded last word.

## `dnr.ringbuf` — `RingBuffer!T`

A FIFO / deque — `dnr.array` is a stack, this has O(1) push and pop at *both*
ends. Power-of-two capacity (mask wrap), doubles when full. Elements are
contiguous in ring order, not memory — index with `ring_at`.

`ring_make` / `ring_free` / `ring_reserve` (→ `Status`) · `ring_push_back` /
`ring_push_front` (→ `Status`) · `ring_pop_front` / `ring_pop_back`
(→ `Option!T`) · `ring_front` / `ring_back` / `ring_at` (ref, assert) ·
`ring_len` / `ring_cap` / `ring_empty` / `ring_clear`.

## `dnr.slotmap` — `SlotMap!T`

`Pool!T` hands out a `T*` that a slot reuse silently re-points. `SlotMap!T`
returns a `Handle { uint index, gen }`; `slotmap_get` only resolves it while
the generation still matches, so a handle to a removed entry reads `none`
rather than aliasing whatever moved in. This is the game's `Enemy.uid` pattern
made safe.

`slotmap_insert` (→ `Result!Handle`) · `slotmap_get` (→ `Option!(T*)`) /
`slotmap_contains` · `slotmap_remove` (→ `bool`, bumps the generation) ·
`slotmap_len` / `slotmap_capacity` / `slotmap_clear` · `slotmap_iter` /
`slotmap_next`. `Handle.init` / `NULL_HANDLE` is the null handle (`gen == 0`
is never live).

## `dnr.fmt` — typed formatting

The safe alternative to `snprintf`'s untyped varargs. The format string is a
**template argument** — parsed at compile time, so a wrong placeholder count or
a spec that can't apply to the argument type is a build error, not a garbled
string.

```d
format!"lvl {} · {} kills · {}:{02}"(sb, level, kills, mins, secs);
auto line = format_buf!"{}/{}"(buf[], a, b);   // -> const(char)[] in a stack buffer
eprintln!"unexpected tag {x}"(tag);            // -> stderr + newline
```

Placeholders: `{}` (dispatched by type), `{x}` / `{X}` (hex), `{.N}` (float
precision), `{0N}` (integer zero-pad), `{{` `}}` (literal braces). Default
dispatch covers bool / char / integers / floats / `const(char)[]` /
`const(char)*` / enum (→ member name) / pointers. Output goes through an `Sb`,
so a fixed-buffer target truncates cleanly.

## `dnr.ini` — `key = value` config

The format the game's `.cfg` / `.lang` loaders hand-roll. Reading is a
zero-allocation streaming walk (slices into your buffer):

```d
auto p = ini_parse(buf);
IniEntry e;                // { section, key, value, is_section }
while (ini_next(p).take(e)) {
    if (e.is_section) …
    else if (str.equals(e.key, "volume")) … e.value …
}
```

`#` / `;` are comment lines; `[section]` headers scope the pairs after them;
whitespace around key and value is trimmed; `#` inside a value is literal;
blank and unparseable lines are skipped. Writing builds into an `Sb`:
`ini_section` / `ini_pair` / `ini_pair_int` / `ini_pair_float` / `ini_pair_bool`
/ `ini_comment`.

## `dnr.panic` — fail loudly and stop

betterC keeps `assert` but gives you no message on `assert(0)` and no trace.
These print `panic: <msg>  (<file>:<line>)` to stderr and `abort()`:

`panic(msg)` · `unreachable()` · `todo()` — all `noreturn`, so control-flow
analysis knows the branch ends · `panic_if(cond, msg)` — a guard that returns
normally when `cond` is false. `format_panic(buf, …)` builds the line without
aborting (what the tests check).

## `dnr.io` — files

Thin `core.stdc.stdio` wrappers for the common jobs. Paths are `const(char)[]`
(copied to null-terminate; over 1023 bytes is rejected). Regular files only.

- `read_file(a, path)` → `Result!(ubyte[])` (buffer from the allocator, free
  with `mem.free_n`; an empty file is `ok(null)`), `read_file_text` →
  `Result!(char[])`
- `write_file(path, data)` / `append_file(path, data)` → `Status`
- `file_exists` → `bool`; `file_size` → `Result!long`
- `LineReader`: `auto it = lines(buf); const(char)[] ln; while (read_line(it).take(ln))`
  — splits on `\n`, strips a trailing `\r`, no phantom final empty line

## `dnr.time` — monotonic clock

Never runs backward, unaffected by wall-clock changes — frame timing, timeouts,
profiling. **Not** a calendar. dnr-std's first per-OS shim
(`QueryPerformanceCounter` on Windows, `clock_gettime(CLOCK_MONOTONIC)` on
POSIX).

`now()` → `Instant` · `since(Instant)` / `elapsed(from, to)` → `Duration` ·
`sleep(Duration)`. `Duration` is nanoseconds: `dur_millis` / `dur_micros` /
`dur_nanos` / `dur_seconds` in, `dur_as_millis` / `dur_as_seconds` / … out,
`dur_add` / `dur_sub` / `dur_cmp`. `Stopwatch`: `sw_start` / `sw_read` (elapsed)
/ `sw_lap` (elapsed + restart).

## Roadmap

**Tier 0** (foundation) — **complete:**

- [x] `testing` — the assertion harness
- [x] `mem` — allocators
- [x] `array` — `Array!T` (growable array over an `Allocator`), the `~` / `.length`
      replacement
- [x] `algo` — sort, binary search, and the small slice rearrangers / scans
- [x] `math` — the `core.stdc.math` gaps: min/max/clamp, lerp/smoothstep/damp,
      angle wrap, pow2 / align / gcd, float→int

**Tier 1 — complete:**

- [x] `result` — `Option!T` / `Result!(T,E)` / `Status`, adopted library-wide
- [x] `panic` — `panic(msg)` / `unreachable()` / `todo()` / `panic_if` — stderr + abort
- [x] `rng` — xoshiro256** PRNG, explicit state, ranges / `chance` / `pick` /
      `shuffle`
- [x] `str` — slice ops (`equals` / `trim` / `Splitter` / classify), parsing
      (`parse_int` / `parse_float` / …), and `Sb` (a StringBuilder)
- [x] `hashmap` — `HashMap!(K,V)`, open-addressed, linear probing + backward-shift
      delete, `Allocator`-backed
- [x] `io` — `read_file` / `write_file` / `append_file` / `file_size` / `file_exists`
      + the `LineReader` iterator

**Tier 2 — complete:**

- [x] `bitset` — `BitArray!N` / `BitSet` + `bits_*` primitives
- [x] `ringbuf` — `RingBuffer!T`, a growable deque
- [x] `slotmap` — `SlotMap!T`, generation-checked stable handles
- [x] `fmt` — compile-time-checked `{}` formatting into `Sb` / a fixed buffer
- [x] `hash` — FNV-1a + `hash64` (avalanched) + `fmix64` + `hash_combine`
- [x] `ini` — `key = value` + `[section]` streaming parse / `Sb` writer
- [x] `utf8` — strict decode / encode / validate / count + a lossy rune iterator
- [x] `time` — monotonic `now()` + `Duration` + `Stopwatch` (Windows + POSIX)
- [x] `mem` — a growing (block-chaining) arena (`GrowingArena`)

## Using it in a project

Vendor `src/dnr/` into your tree and add the files you use (plus their
transitive imports) to your build's source list — no globbing, same as the
game. Every module needs `panic` + `result`; `mem` pulls in nothing else;
`array` / `str` / `hashmap` / `io` / `bitset` / `ringbuf` / `slotmap` pull in
`mem`; `fmt` pulls in `str`; `hashmap` pulls in `hash`; `ini` pulls in `str` +
`io` + `fmt`; `utf8` pulls in `str`; `time` stands alone. Ship `dnr.testing`
too if you want the same `check` harness for your own tests.
