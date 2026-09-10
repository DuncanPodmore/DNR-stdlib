module dnr.math_test;

import dnr.testing;
import m = dnr.math;

void test_minmax_clamp() {
    check(m.min(3, 7) == 3, "min int");
    check(m.max(3, 7) == 7, "max int");
    near(m.min(2.5, 1.5), 1.5, 1e-12, "min double");
    check(m.clamp(5, 0, 10) == 5, "clamp inside");
    check(m.clamp(-3, 0, 10) == 0, "clamp low");
    check(m.clamp(42, 0, 10) == 10, "clamp high");
    check(m.abs(-4) == 4, "abs negative int");
    check(m.abs(4) == 4, "abs positive int");
    near(m.abs(-2.5), 2.5, 1e-12, "abs double");
    check(m.sign(-9) == -1 && m.sign(9) == 1 && m.sign(0) == 0, "sign");
}

void test_interp() {
    near(m.lerp(0.0, 10.0, 0.25), 2.5, 1e-12, "lerp midpoint");
    near(m.lerp(0.0, 10.0, 2.0), 20.0, 1e-12, "lerp is not clamped");
    near(m.lerp_clamped(0.0, 10.0, 2.0), 10.0, 1e-12, "lerp_clamped clamps t");
    near(m.inv_lerp(10.0, 20.0, 12.5), 0.25, 1e-12, "inv_lerp");
    near(m.remap(5.0, 0.0, 10.0, 100.0, 200.0), 150.0, 1e-12, "remap");
    near(m.saturate(1.5), 1.0, 1e-12, "saturate high");
    near(m.saturate(-0.5), 0.0, 1e-12, "saturate low");

    near(m.smoothstep(0.0, 1.0, -1.0), 0.0, 1e-12, "smoothstep below");
    near(m.smoothstep(0.0, 1.0, 2.0), 1.0, 1e-12, "smoothstep above");
    near(m.smoothstep(0.0, 1.0, 0.5), 0.5, 1e-12, "smoothstep midpoint is 0.5");
    check(m.smoothstep(0.0, 1.0, 0.25) < 0.25, "smoothstep eases in below the diagonal");

    // damp: closes a fixed fraction of the gap each step, frame-rate independent
    double x = 0.0;
    foreach (i; 0 .. 1000) x = m.damp(x, 100.0, 5.0, 0.016);
    near(x, 100.0, 1e-3, "damp converges to the target");
    double a = m.damp(0.0, 1.0, 5.0, 0.1);
    double b2 = m.damp(m.damp(0.0, 1.0, 5.0, 0.05), 1.0, 5.0, 0.05);
    near(a, b2, 1e-9, "damp is frame-rate independent (one 0.1 step == two 0.05 steps)");
}

void test_approx() {
    check(m.approx_eq(1.0f, 1.0f + 1e-7f), "approx_eq within default eps");
    check(!m.approx_eq(1.0f, 1.1f), "approx_eq rejects a real difference");
    check(m.approx_eq(100.0, 100.0 + 1e-10, 1e-9), "approx_eq double with eps");
    check(m.approx_zero(1e-6f), "approx_zero");
    check(!m.approx_zero(0.01f), "approx_zero rejects");
}

void test_angles() {
    near(m.wrap_angle(m.TAU + 0.5), 0.5, 1e-9, "wrap_angle removes a full turn");
    near(m.wrap_angle(-m.PI - 0.1), m.PI - 0.1, 1e-9, "wrap_angle wraps past -PI");
    check(m.wrap_angle(3.0 * m.PI) <= m.PI + 1e-9, "wrap_angle result in range");

    near(m.angle_diff(0.1, 0.4), 0.3, 1e-9, "angle_diff small");
    // from just under PI to just over -PI: shortest path is a small positive step
    near(m.angle_diff(m.PI - 0.1, -m.PI + 0.1), 0.2, 1e-9, "angle_diff takes the short way round");

    near(m.lerp_angle(0.0, m.HALF_PI, 0.5), m.HALF_PI / 2, 1e-9, "lerp_angle midpoint");

    near(m.to_rad(180.0), m.PI, 1e-12, "to_rad");
    near(m.to_deg(m.PI), 180.0, 1e-12, "to_deg");
}

void test_float_to_int() {
    check(m.ifloor(2.7f) == 2, "ifloor positive");
    check(m.ifloor(-2.3f) == -3, "ifloor negative");
    check(m.ifloor(5.0f) == 5, "ifloor exact");
    check(m.iceil(2.1f) == 3, "iceil positive");
    check(m.iceil(-2.7f) == -2, "iceil negative");
    check(m.iceil(5.0f) == 5, "iceil exact");
    check(m.iround(2.4f) == 2, "iround down");
    check(m.iround(2.6f) == 3, "iround up");
    check(m.iround(-2.6f) == -3, "iround negative");
}

void test_int_helpers() {
    check(m.is_pow2(1) && m.is_pow2(2) && m.is_pow2(1024), "is_pow2 yes");
    check(!m.is_pow2(0) && !m.is_pow2(3) && !m.is_pow2(1000), "is_pow2 no");

    check(m.next_pow2(0) == 1, "next_pow2 of 0");
    check(m.next_pow2(1) == 1, "next_pow2 of 1");
    check(m.next_pow2(5) == 8, "next_pow2 of 5");
    check(m.next_pow2(1024) == 1024, "next_pow2 of an exact power");
    check(m.next_pow2(1025) == 2048, "next_pow2 just over");

    check(m.align_up(13, 8) == 16, "align_up");
    check(m.align_up(16, 8) == 16, "align_up already aligned");
    check(m.align_down(13, 8) == 8, "align_down");

    check(m.ceil_div(10, 3) == 4, "ceil_div rounds up");
    check(m.ceil_div(9, 3) == 3, "ceil_div exact");
    check(m.abs_diff(3u, 10u) == 7, "abs_diff unsigned, no underflow");
    check(m.abs_diff(10u, 3u) == 7, "abs_diff other order");

    check(m.gcd(54, 24) == 6, "gcd");
    check(m.gcd(17, 5) == 1, "gcd coprime");
    check(m.gcd(0, 9) == 9, "gcd with zero");
}

void run_math_tests() {
    test_minmax_clamp();
    test_interp();
    test_approx();
    test_angles();
    test_float_to_int();
    test_int_helpers();
}
