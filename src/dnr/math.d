module dnr.math;

// ---------------------------------------------------------------------------
// math — the scalar helpers betterC leaves you to write
// ---------------------------------------------------------------------------
// `core.stdc.math` gives you the transcendentals (sin/cos/sqrt/pow/…) and
// that's all — no min/max/clamp, no lerp, no angle wrap, no pow2 helpers,
// because those normally live in Phobos. This is that layer, kept small: the
// things a game or a parser actually reaches for, nothing speculative.
//
// Generic scalar ops (`min` / `max` / `clamp` / `abs` / `lerp` / …) are
// templates that work for any `T` with the operators they use — ints and
// floats both. Angle + float→int helpers are computed in `double` and cast
// back. betterC: @nogc nothrow, no libc dependency except `fmod` for the
// angle wrap.

import cm = core.stdc.math;

// --- constants -------------------------------------------------------------

enum double PI       = 3.14159265358979323846;
enum double TAU      = 6.28318530717958647692;   // 2·PI
enum double HALF_PI  = 1.57079632679489661923;
enum double E        = 2.71828182845904523536;
enum double SQRT2    = 1.41421356237309504880;

enum double DEG2RAD  = PI / 180.0;
enum double RAD2DEG  = 180.0 / PI;

enum float  PI_F     = cast(float) PI;
enum float  TAU_F    = cast(float) TAU;
enum float  HALF_PI_F = cast(float) HALF_PI;

// A reasonable "close enough" for single-precision game math.
enum float  EPSILON  = 1e-5f;

// --- generic scalar ops --------------------------------------------------

T min(T)(T a, T b) @nogc nothrow { return a < b ? a : b; }
T max(T)(T a, T b) @nogc nothrow { return a > b ? a : b; }

// x clamped to [lo, hi]. Caller ensures lo <= hi.
T clamp(T)(T x, T lo, T hi) @nogc nothrow {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

T abs(T)(T x) @nogc nothrow { return x < 0 ? -x : x; }

// -1 / 0 / +1. NaN gives 0.
int sign(T)(T x) @nogc nothrow {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}

// --- interpolation -------------------------------------------------------

// a at t=0, b at t=1. `t` is not clamped — pass a saturated t (or use
// `lerp_clamped`) if you need to stay on the segment.
T lerp(T)(T a, T b, T t) @nogc nothrow { return a + (b - a) * t; }

T lerp_clamped(T)(T a, T b, T t) @nogc nothrow {
    return lerp(a, b, clamp(t, cast(T) 0, cast(T) 1));
}

// Where `v` sits between a and b, as a fraction (the inverse of lerp).
T inv_lerp(T)(T a, T b, T v) @nogc nothrow { return (v - a) / (b - a); }

// Map v from [inLo, inHi] onto [outLo, outHi], linearly. Not clamped.
T remap(T)(T v, T inLo, T inHi, T outLo, T outHi) @nogc nothrow {
    return outLo + (outHi - outLo) * ((v - inLo) / (inHi - inLo));
}

// clamp(x, 0, 1)
T saturate(T)(T x) @nogc nothrow { return clamp(x, cast(T) 0, cast(T) 1); }

// Hermite smoothstep: 0 below edge0, 1 above edge1, an eased ramp between.
T smoothstep(T)(T edge0, T edge1, T x) @nogc nothrow {
    T t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * (cast(T) 3 - cast(T) 2 * t);
}

// A frame-rate-independent exponential approach: move `current` toward
// `target`, closing `1 - exp(-rate·dt)` of the gap this step. The same shape
// the game uses for camera / knockback / HP-trail decay.
T damp(T)(T current, T target, T rate, T dt) @nogc nothrow {
    return lerp(current, target, cast(T)(1.0 - cm.exp(cast(double)(-rate * dt))));
}

// --- float comparison --------------------------------------------------

bool approx_eq(float a, float b, float eps = EPSILON) @nogc nothrow {
    float d = a - b;
    return (d < 0 ? -d : d) <= eps;
}
bool approx_eq(double a, double b, double eps = 1e-9) @nogc nothrow {
    double d = a - b;
    return (d < 0 ? -d : d) <= eps;
}
bool approx_zero(float x, float eps = EPSILON) @nogc nothrow {
    return (x < 0 ? -x : x) <= eps;
}

// --- angles (radians) --------------------------------------------------

// Wrap to (-PI, PI].
T wrap_angle(T)(T a) @nogc nothrow {
    double r = cm.fmod(cast(double) a + PI, TAU);
    if (r <= 0) r += TAU;
    return cast(T)(r - PI);
}

// Shortest signed rotation to get from `from` to `to`, in (-PI, PI].
T angle_diff(T)(T from, T to) @nogc nothrow {
    return wrap_angle!T(to - from);
}

// Interpolate along the shortest arc.
T lerp_angle(T)(T a, T b, T t) @nogc nothrow {
    return wrap_angle!T(a + angle_diff!T(a, b) * t);
}

T to_rad(T)(T deg) @nogc nothrow { return cast(T)(deg * DEG2RAD); }
T to_deg(T)(T rad) @nogc nothrow { return cast(T)(rad * RAD2DEG); }

// --- float -> int -----------------------------------------------------

int ifloor(float x) @nogc nothrow {
    int i = cast(int) x;
    return (x < 0 && cast(float) i != x) ? i - 1 : i;
}
int iceil(float x) @nogc nothrow {
    int i = cast(int) x;
    return (x > 0 && cast(float) i != x) ? i + 1 : i;
}
int iround(float x) @nogc nothrow {
    return x >= 0 ? cast(int)(x + 0.5f) : cast(int)(x - 0.5f);
}

// --- integer helpers -------------------------------------------------

bool is_pow2(ulong x) @nogc nothrow { return x != 0 && (x & (x - 1)) == 0; }

// Smallest power of two >= x. 0 -> 1. Saturates rather than wrapping past
// 2^63.
ulong next_pow2(ulong x) @nogc nothrow {
    if (x <= 1) return 1;
    x--;
    x |= x >> 1;  x |= x >> 2;  x |= x >> 4;
    x |= x >> 8;  x |= x >> 16; x |= x >> 32;
    return x + 1;
}

// Round n up / down to a multiple of `a`. `a` must be a power of two.
size_t align_up(size_t n, size_t a) @nogc nothrow {
    assert(is_pow2(a), "align_up: alignment not a power of two");
    return (n + (a - 1)) & ~(a - 1);
}
size_t align_down(size_t n, size_t a) @nogc nothrow {
    assert(is_pow2(a), "align_down: alignment not a power of two");
    return n & ~(a - 1);
}

// ceil(a / b) for non-negative integers, no floating point.
T ceil_div(T)(T a, T b) @nogc nothrow {
    assert(b > 0, "ceil_div: b must be positive");
    return cast(T)((a + b - 1) / b);
}

// |a - b| without the intermediate underflowing an unsigned type.
T abs_diff(T)(T a, T b) @nogc nothrow { return a > b ? cast(T)(a - b) : cast(T)(b - a); }

ulong gcd(ulong a, ulong b) @nogc nothrow {
    while (b) { ulong t = b; b = a % b; a = t; }
    return a;
}
