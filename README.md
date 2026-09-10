# dnr-std — D no-runtime standard

A small standard library for **D compiled with `-betterC`** — no druntime, no
GC, no Phobos. Extracted from the patterns that carried the *Dopashooter* game,
and built to the same imperative, explicit, no-magic philosophy.

betterC drops Phobos along with the runtime, and what's left in `core.stdc.*` is
just libc. `dnr-std` is the layer between libc and application code: allocation,
containers, strings, math, and the odd jobs (`rng`, `io`, `option`/`result`)
that every program re-implements otherwise.

## Philosophy

- **Imperative, not generic-functional.** Plain functions over data. Templates
  where a container genuinely needs a type parameter; not as a style.
- **`snake_case` functions, `PascalCase` types.** `pool_get`, not `Pool.get`;
  free functions taking `ref T` over methods, so the data stays a plain struct.
- **No hidden control flow.** No exceptions (betterC has none anyway), no hidden
  allocation, no destructor-driven resource magic beyond what betterC gives.
  A function that can fail returns a value that says so.
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
  mem.d         Allocator + malloc / arena / pool / tracking allocators
  array.d       Array!T — growable array over an Allocator
  algo.d        sort / search / rearrange over slices
  *_test.d      one per module
src/test_all.d  the test runner (extern(C) main)
makefile        `make test`, `make check`
```

`import dnr.mem;` — the package prefix is `dnr.`.

## Build

```
make test     # compile the lib + tests to build/test and run it
make check    # type-check the library alone (-o-, no codegen, no main)
```

Toolchain: **LDC** (tested on 1.42), `-betterC -mscrtlib=msvcrt`, mingw `make`.
No external libraries — `core.stdc` only.

## `dnr.mem` — the allocator layer

`Allocator` is a C-style vtable: an opaque `ctx` pointer plus `alloc` / `realloc`
/ `free` function pointers. You pass one explicitly to anything that allocates.
The caller tracks the size of every block it holds (like Zig) — `raw_free` and
`raw_realloc` take the old size; a malloc backend ignores it, an arena needs it.
The typed helpers carry that bookkeeping for you.

| Helper | Does |
|---|---|
| `make!T` / `unmake!T` | one `T`, `.init`-filled (declared field initializers honoured — no NaN floats) |
| `make_n!T` / `free_n!T` | a slice of `n`, each `.init`-filled |
| `resize_n!T(ref s, n)` | grow / shrink a slice, new tail `.init`-filled, `-> bool` |
| `dup!T` | copy a slice into a fresh block |
| `alloc_raw` | `size` bytes of undefined memory — the escape hatch |

Backends:

| Constructor | Model |
|---|---|
| `malloc_allocator()` | wraps `core.stdc.stdlib`; alignment ≤ 16 |
| `arena_allocator(ref Arena)` | bump allocator over a caller-provided buffer; `raw_free` pops only the most-recent block; `arena_reset` frees all at once; OOM → null |
| `pool_alloc_storage` / `pool_init` → `Pool!T` | fixed-capacity slot allocator, O(1) free list (a separate index stack); `pool_get` / `pool_put`; slots not zeroed — the game's `Enemy[700]` pattern |
| `tracking_allocator(ref Tracker, inner)` | wraps another allocator, counts `bytes_outstanding` / `peak_bytes` / `total_allocs` — assert zero at teardown to catch a leak (test-only) |

## `dnr.array` — `Array!T`

The `~` append / `arr.length = n` resize that betterC drops. A struct holding a
slice + capacity + the owning `Allocator`; every mutator is a free function over
`ref Array!T`. Amortised doubling growth, so N pushes are O(N). A mutator that
can grow returns `false` on OOM and leaves the array untouched.

`array_make` / `array_from` / `array_free` · `array_push` / `array_append` /
`array_pop` / `array_try_pop` / `array_back` · `array_insert` / `array_remove`
(ordered) / `array_swap_remove` (O(1)) · `array_resize` (grow `.init`-fills) /
`array_clear` / `array_reserve` / `array_shrink_to_fit` · `array_len` /
`array_empty`, and `arr.items` is the live slice for iteration and indexing.

⚠️ A handle, not a value — copying aliases the block. Pass by `ref`. POD
container — element destructors are never run.

## `dnr.algo` — slice operations

Plain functions over `T[]` / `const(T)[]` — no allocator, a slice is a view the
caller owns. The `std.algorithm` subset the game actually reaches for.

- rearrange: `swap`, `reverse`, `fill`, `rotate_left`
- scan: `index_of` / `contains` / `count` / `equal`, `min_index` / `max_index`,
  `is_sorted`
- sort: `insertion_sort` (stable, O(n²) — small / nearly-sorted) and `sort` (an
  iterative quicksort — median-of-three, insertion cutoff, bounded explicit
  stack; **unstable**, no recursion, no allocation)
- search a sorted slice: `lower_bound` / `upper_bound` / `binary_search`

Ordering is a `bool function(const(T), const(T)) @nogc nothrow` `less` argument,
defaulting to `a < b`. Pass one for descending order or sort-by-key.

## Roadmap

**Tier 0** (foundation, in order):

- [x] `testing` — the assertion harness
- [x] `mem` — allocators
- [x] `array` — `Array!T` (growable array over an `Allocator`), the `~` / `.length`
      replacement
- [x] `algo` — sort, binary search, and the small slice rearrangers / scans
- [ ] `math` — the `core.stdc.math` gaps: lerp, `PI` etc., int helpers, a stable
      `f32` compare

**Tier 1:**

- [ ] `str` — `StringBuilder`, split/trim/starts_with over `const(char)[]`,
      int/float ⇄ string
- [ ] `hashmap` — `HashMap!(K,V)`, open-addressed, `Allocator`-backed
- [ ] `rng` — a small PRNG (xoshiro / pcg), explicit state
- [ ] `io` — thin `FILE*` wrappers: read-whole-file, line iterator, buffered writer
- [ ] `option` / `result` / `panic` — `Option!T`, `Result!(T,E)`, a `panic()` that
      prints and aborts
