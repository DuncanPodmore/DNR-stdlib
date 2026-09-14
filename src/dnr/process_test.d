module dnr.process_test;

import dnr.testing;
import dnr.mem;
import s = dnr.str;
import p = dnr.process;
import io = dnr.io;
import c = core.stdc.stdio;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

// win32_quote_cmd is pure text transformation — the one piece of this module
// that's fully deterministic without touching the OS, so it gets the most
// scrutiny. Ported line-for-line from tsoding/nob.h's nob__win32_cmd_quote;
// these cases are the ones that actually exercise the escaping rules.
// One Cmd, rendered, freed, compared against `expected` — every case below is
// this shape, so it's pulled out rather than repeated five times. `cmd` is
// built by the caller (a sequence of cmd_add calls) so no array literal /
// variadic ever has to be constructed — both are GC-backed in general D and
// this project stays clear of anything that might quietly need it.
private bool quotes_as(ref p.Cmd cmd, string expected) {
    char[256] buf = void;
    auto sb = s.sb_fixed(buf[]);
    p.win32_quote_cmd(cmd, sb);
    return s.equals(s.sb_slice(sb), expected);
}

version (Windows)
void test_quote_cmd() {
    Tracker t;
    Allocator a = tracked(t);

    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "ldc2"); p.cmd_add(cmd, "-betterC"); p.cmd_add(cmd, "foo.d");
        check(quotes_as(cmd, "ldc2 -betterC foo.d"), "plain args are space-joined, unquoted");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "a b"); p.cmd_add(cmd, "c");
        check(quotes_as(cmd, `"a b" c`), "an arg with a space is wrapped in quotes");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, `with"quote`);
        check(quotes_as(cmd, `"with\"quote"`), "an embedded quote is backslash-escaped");
        p.cmd_free(cmd);
    }
    {
        // Not argv[0] here (a leading "prog" arg keeps win32_needs_dot_prefix
        // out of the picture) — this case is purely about the escaping rule
        // for a plain, non-argv[0] arg that happens to contain a separator.
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "prog"); p.cmd_add(cmd, `trailing\`);
        check(quotes_as(cmd, `prog trailing\`), "a lone trailing backslash needs no escaping when unquoted");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "prog"); p.cmd_add(cmd, `a\\b`);
        check(quotes_as(cmd, `prog a\\b`), "backslashes not before a quote pass through untouched");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "");
        check(quotes_as(cmd, `""`), "an empty arg is quoted so it isn't dropped");
        p.cmd_free(cmd);
    }

    // argv[0]-specific: CreateProcess won't resolve a bare relative path with
    // a separator (see the doc comment on win32_needs_dot_prefix) — verified
    // against the real API in test_run_exit_codes below; these are the
    // pure-text half of that.
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "build/test");
        check(quotes_as(cmd, "./build/test"), "a bare relative argv[0] gets a ./ prefix");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "./build/test");
        check(quotes_as(cmd, "./build/test"), "...but not if it already has one");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "ldc2"); p.cmd_add(cmd, "src/foo.d");
        check(quotes_as(cmd, "ldc2 src/foo.d"), "the ./ rule only applies to argv[0], not later args");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, `C:\tools\ldc2.exe`);
        check(quotes_as(cmd, `C:\tools\ldc2.exe`), "an already-absolute argv[0] is left alone");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "ldc2");   // bare name, no separator at all
        check(quotes_as(cmd, "ldc2"), "a bare PATH-searched name is unaffected");
        p.cmd_free(cmd);
    }

    check(t.bytes_outstanding == 0, "no leaks");
}

void test_run_exit_codes() {
    Tracker t;
    Allocator a = tracked(t);

    // cmd.exe is always present on Windows and its /C exit N is a reliable,
    // dependency-free way to test exit-code plumbing without a helper binary.
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "cmd"); p.cmd_add(cmd, "/C"); p.cmd_add(cmd, "exit"); p.cmd_add(cmd, "0");
        int code = -1;
        auto r = p.cmd_run(cmd, p.RunOpt(false), &code);
        check(r == p.ProcessResult.ok, "exit 0 reports ok");
        check(code == 0, "...with exit code 0");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "cmd"); p.cmd_add(cmd, "/C"); p.cmd_add(cmd, "exit"); p.cmd_add(cmd, "3");
        int code = -1;
        auto r = p.cmd_run(cmd, p.RunOpt(false), &code);
        check(r == p.ProcessResult.failed, "a non-zero exit reports failed, not spawn_error");
        check(code == 3, "...and the real exit code comes through");
        p.cmd_free(cmd);
    }
    {
        auto cmd = p.cmd_make(a);
        p.cmd_add(cmd, "this_binary_almost_certainly_does_not_exist_9x7z");
        auto r = p.cmd_run(cmd, p.RunOpt(false));
        check(r == p.ProcessResult.spawn_error, "a missing executable reports spawn_error");
        p.cmd_free(cmd);
    }

    // End-to-end proof of the argv[0] dot-prefix fix (test_quote_cmd only
    // checks the rendered text): compile a throwaway helper and run it by a
    // bare relative path with a separator and no "./" — exactly the shape
    // that used to fail with ERROR_FILE_NOT_FOUND before win32_needs_dot_prefix.
    {
        enum HELPER_SRC = "build/process_test_helper.d";
        enum HELPER_BIN = "build/process_test_helper";
        check(io.write_file(HELPER_SRC, "extern(C) int main() { return 42; }").is_ok(),
              "wrote a throwaway helper source");

        auto build = p.cmd_make(a);
        p.cmd_add(build, "ldc2"); p.cmd_add(build, "-betterC"); p.cmd_add(build, "-mscrtlib=msvcrt");
        p.cmd_add(build, HELPER_SRC); p.cmd_add(build, "-of"); p.cmd_add(build, HELPER_BIN);
        check(p.cmd_run(build, p.RunOpt(false)) == p.ProcessResult.ok, "compiled the throwaway helper");
        p.cmd_free(build);

        auto run = p.cmd_make(a);
        p.cmd_add(run, HELPER_BIN);          // no "./" added here — cmd_run must add it
        int code = -1;
        auto r = p.cmd_run(run, p.RunOpt(false), &code);
        check(r != p.ProcessResult.spawn_error, "a bare relative path WITH a separator still spawns");
        check(code == 42, "...and it's really the helper that ran");
        p.cmd_free(run);

        c.remove(HELPER_SRC);
        c.remove(HELPER_BIN);
    }

    check(t.bytes_outstanding == 0, "no leaks");
}

private enum OUT_TMP = "build/process_test_stdout.txt";

void test_stdout_redirect() {
    Tracker t;
    Allocator a = tracked(t);

    auto cmd = p.cmd_make(a);
    p.cmd_add(cmd, "cmd"); p.cmd_add(cmd, "/C"); p.cmd_add(cmd, "echo"); p.cmd_add(cmd, "hello-from-dnr-process");
    p.RunOpt opt; opt.echo = false; opt.stdoutPath = OUT_TMP;
    int code = -1;
    auto r = p.cmd_run(cmd, opt, &code);
    p.cmd_free(cmd);
    check(r == p.ProcessResult.ok, "redirected run still reports ok");

    char[] got = io.read_file_text(a, OUT_TMP).unwrap();
    check(s.contains(got, "hello-from-dnr-process"), "the child's stdout landed in the redirect file");
    free_n(a, got);
    c.remove(OUT_TMP);

    check(t.bytes_outstanding == 0, "no leaks");
}

void run_process_tests() {
    version (Windows) test_quote_cmd();
    test_run_exit_codes();
    test_stdout_redirect();
}
