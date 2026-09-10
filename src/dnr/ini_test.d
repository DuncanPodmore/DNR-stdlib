module dnr.ini_test;

import dnr.testing;
import dnr.mem;
import s = dnr.str;
import ini = dnr.ini;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_parse() {
    immutable string cfg =
        "# a config file\n" ~
        "\n" ~
        "name = dnr-std\n" ~
        "  spaced key  =  spaced value  \n" ~
        "\n" ~
        "[audio]\n" ~
        "; comment inside a section\n" ~
        "master = 0.8\n" ~
        "muted = false\n" ~
        "[video]\n" ~
        "vsync=1\n" ~
        "url = http://example.com/#anchor\n" ~
        "malformed line with no equals\n" ~
        "trailing = ok";

    auto p = ini.ini_parse(cfg);
    ini.IniEntry e;

    check(ini.ini_next(p).take(e) && !e.is_section && s.equals(e.key, "name")
          && s.equals(e.value, "dnr-std") && e.section.length == 0,
          "top-level pair before any section");

    check(ini.ini_next(p).take(e) && s.equals(e.key, "spaced key") && s.equals(e.value, "spaced value"),
          "key and value are trimmed");

    check(ini.ini_next(p).take(e) && e.is_section && s.equals(e.value, "audio"),
          "section header");

    check(ini.ini_next(p).take(e) && s.equals(e.section, "audio") && s.equals(e.key, "master")
          && s.equals(e.value, "0.8"),
          "pair carries its section");

    check(ini.ini_next(p).take(e) && s.equals(e.key, "muted") && s.equals(e.value, "false"),
          "second pair in the section");

    check(ini.ini_next(p).take(e) && e.is_section && s.equals(e.value, "video"), "next section");
    check(ini.ini_next(p).take(e) && s.equals(e.key, "vsync") && s.equals(e.value, "1"),
          "no spaces around '='");
    check(ini.ini_next(p).take(e) && s.equals(e.key, "url")
          && s.equals(e.value, "http://example.com/#anchor"),
          "'#' inside a value is not a comment");
    // "malformed line with no equals" is skipped
    check(ini.ini_next(p).take(e) && s.equals(e.key, "trailing") && s.equals(e.value, "ok"),
          "parsing continues past a malformed line");
    check(ini.ini_next(p).is_none(), "exhausted");
}

void test_parse_empty_and_edge() {
    auto p = ini.ini_parse("");
    ini.IniEntry e;
    check(ini.ini_next(p).is_none(), "empty input yields nothing");

    auto p2 = ini.ini_parse("   \n#only comments\n;another\n");
    check(ini.ini_next(p2).is_none(), "comments and blanks only");

    auto p3 = ini.ini_parse("[unclosed\nkey = val\n");
    check(ini.ini_next(p3).take(e) && !e.is_section && s.equals(e.key, "key"),
          "a malformed '[' line is skipped, not fatal");

    auto p4 = ini.ini_parse("empty =\n= novalue\n");
    check(ini.ini_next(p4).take(e) && s.equals(e.key, "empty") && e.value.length == 0,
          "an empty value is allowed");
    check(ini.ini_next(p4).is_none(), "a line with an empty key is skipped");
}

void test_write() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));

    ini.ini_comment(b, "generated");
    ini.ini_pair(b, "name", "dnr-std");
    ini.ini_section(b, "audio");
    ini.ini_pair_float(b, "master", 0.75, 2);
    ini.ini_pair_bool(b, "muted", false);
    ini.ini_section(b, "video");
    ini.ini_pair_int(b, "fps", 144);

    immutable string want =
        "# generated\n" ~
        "name = dnr-std\n" ~
        "\n[audio]\n" ~
        "master = 0.75\n" ~
        "muted = false\n" ~
        "\n[video]\n" ~
        "fps = 144\n";
    check(s.equals(s.sb_slice(b), want), "ini writer output");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_roundtrip() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));

    ini.ini_pair_int(b, "width", 1920);
    ini.ini_section(b, "keys");
    ini.ini_pair(b, "fire", "MOUSE1");
    ini.ini_pair_int(b, "dash", 32);

    // read it back
    int width = 0, dash = 0;
    const(char)[] fire;
    auto p = ini.ini_parse(s.sb_slice(b));
    ini.IniEntry e;
    while (ini.ini_next(p).take(e)) {
        if (e.is_section) continue;
        if (s.equals(e.key, "width")) width = cast(int) s.parse_int(e.value).unwrap_or(0);
        else if (s.equals(e.key, "dash")) dash = cast(int) s.parse_int(e.value).unwrap_or(0);
        else if (s.equals(e.key, "fire")) fire = e.value;
    }
    check(width == 1920 && dash == 32 && s.equals(fire, "MOUSE1"), "write then parse round-trips");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_ini_tests() {
    test_parse();
    test_parse_empty_and_edge();
    test_write();
    test_roundtrip();
}
