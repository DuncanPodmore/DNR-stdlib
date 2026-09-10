module dnr.time;

// ---------------------------------------------------------------------------
// time — a monotonic clock and durations
// ---------------------------------------------------------------------------
// MONOTONIC: never runs backward, unaffected by wall-clock adjustments — for
// frame timing, timeouts, profiling. This is NOT a calendar; use
// `core.stdc.time` for dates.
//
//   auto t0 = now();
//   ... work ...
//   auto took = since(t0);           // a Duration
//   dur_as_millis(took);             // -> long
//
//   auto sw = sw_start();
//   dur_as_seconds(sw_lap(sw));      // elapsed, and restart
//
// This is dnr-std's first per-OS shim: `QueryPerformanceCounter` on Windows,
// `clock_gettime(CLOCK_MONOTONIC)` on POSIX. betterC: @nogc nothrow.

// An opaque point on the monotonic clock. Subtract two with `elapsed`.
struct Instant {
    ulong ticks = 0;      // platform units (QPC counts / nanoseconds)
}

// A signed span of time, held as nanoseconds. ~292 years of range.
struct Duration {
    long nanos = 0;
}

// ===========================================================================
// platform: now()
// ===========================================================================

version (Windows) {
    private extern (Windows) int QueryPerformanceCounter(long* count) @nogc nothrow;
    private extern (Windows) int QueryPerformanceFrequency(long* freq) @nogc nothrow;
    private extern (Windows) void Sleep(uint milliseconds) @nogc nothrow;

    private __gshared long g_qpcFreq = 0;

    private long qpc_freq() @nogc nothrow {
        if (g_qpcFreq == 0) QueryPerformanceFrequency(&g_qpcFreq);
        return g_qpcFreq;
    }

    Instant now() @nogc nothrow {
        long c = 0;
        QueryPerformanceCounter(&c);
        return Instant(cast(ulong) c);
    }

    // to - from, as a Duration. QPC counts -> nanoseconds without overflowing.
    Duration elapsed(Instant from, Instant to) @nogc nothrow {
        immutable long f = qpc_freq();
        immutable long d = cast(long)(to.ticks - from.ticks);
        immutable long whole = d / f;
        immutable long rem   = d % f;
        return Duration(whole * 1_000_000_000L + rem * 1_000_000_000L / f);
    }

    void sleep(Duration d) @nogc nothrow {
        long ms = d.nanos / 1_000_000L;
        if (ms < 0) ms = 0;
        Sleep(cast(uint) ms);
    }
} else version (Posix) {
    private struct timespec { long tv_sec; long tv_nsec; }
    private extern (C) int clock_gettime(int clk_id, timespec* tp) @nogc nothrow;
    private extern (C) int nanosleep(const(timespec)* req, timespec* rem) @nogc nothrow;

    // CLOCK_MONOTONIC: 1 on Linux, 4 on FreeBSD, 6 on macOS/Darwin.
    version (linux)  private enum int CLOCK_MONOTONIC = 1;
    else version (FreeBSD) private enum int CLOCK_MONOTONIC = 4;
    else version (OSX)     private enum int CLOCK_MONOTONIC = 6;
    else                   private enum int CLOCK_MONOTONIC = 1;

    Instant now() @nogc nothrow {
        timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return Instant(cast(ulong)(cast(long) ts.tv_sec * 1_000_000_000L + ts.tv_nsec));
    }

    Duration elapsed(Instant from, Instant to) @nogc nothrow {
        return Duration(cast(long)(to.ticks - from.ticks));   // already nanoseconds
    }

    void sleep(Duration d) @nogc nothrow {
        if (d.nanos <= 0) return;
        timespec req = timespec(d.nanos / 1_000_000_000L, d.nanos % 1_000_000_000L);
        nanosleep(&req, null);
    }
} else {
    static assert(false, "dnr.time: no monotonic clock for this platform");
}

// Duration from `from` to right now.
Duration since(Instant from) @nogc nothrow {
    return elapsed(from, now());
}

// ===========================================================================
// Duration — build, read, compare
// ===========================================================================

Duration dur_nanos(long n)   @nogc nothrow { return Duration(n); }
Duration dur_micros(long n)  @nogc nothrow { return Duration(n * 1_000L); }
Duration dur_millis(long n)  @nogc nothrow { return Duration(n * 1_000_000L); }
Duration dur_seconds(double s) @nogc nothrow { return Duration(cast(long)(s * 1_000_000_000.0)); }

long   dur_as_nanos(Duration d)  @nogc nothrow { return d.nanos; }
long   dur_as_micros(Duration d) @nogc nothrow { return d.nanos / 1_000L; }
long   dur_as_millis(Duration d) @nogc nothrow { return d.nanos / 1_000_000L; }
double dur_as_seconds(Duration d) @nogc nothrow { return cast(double) d.nanos / 1_000_000_000.0; }

Duration dur_add(Duration a, Duration b) @nogc nothrow { return Duration(a.nanos + b.nanos); }
Duration dur_sub(Duration a, Duration b) @nogc nothrow { return Duration(a.nanos - b.nanos); }

// -1 if a < b, 0 if equal, 1 if a > b.
int dur_cmp(Duration a, Duration b) @nogc nothrow {
    return a.nanos < b.nanos ? -1 : (a.nanos > b.nanos ? 1 : 0);
}

// ===========================================================================
// Stopwatch
// ===========================================================================

struct Stopwatch {
    Instant started;
}

Stopwatch sw_start() @nogc nothrow {
    return Stopwatch(now());
}

// Elapsed since the last start/lap, no reset.
Duration sw_read(ref Stopwatch sw) @nogc nothrow {
    return since(sw.started);
}

// Elapsed since the last start/lap, then restart the clock.
Duration sw_lap(ref Stopwatch sw) @nogc nothrow {
    immutable Instant t = now();
    immutable Duration d = elapsed(sw.started, t);
    sw.started = t;
    return d;
}
