module dnr.ini;

// ---------------------------------------------------------------------------
// ini — a small `key = value` + `[section]` config format
// ---------------------------------------------------------------------------
// The format the game's `.cfg` / `.lang` loaders hand-roll, done once:
//
//   # or ; starts a comment (whole line)
//   [section]         a section header
//   key = value       a pair (whitespace around key and value is trimmed;
//                     the value runs to end of line, '#'/';' inside it is not
//                     a comment)
//   blank lines and unparseable lines are skipped
//
// Reading is a zero-allocation streaming walk (slices into your buffer):
//
//   auto p = ini_parse(buf);
//   IniEntry e;
//   while (ini_next(p).take(e)) {
//       if (e.is_section) { ... }
//       else if (str.equals(e.key, "volume")) { ... e.value ... }
//   }
//
// Writing builds into an Sb (`ini_section` / `ini_pair` / `ini_pair_int` / …).
//
// betterC: @nogc nothrow.

import str = dnr.str;
import io  = dnr.io;
import fmt = dnr.fmt;
import res = dnr.result;

// ===========================================================================
// reading
// ===========================================================================

struct IniEntry {
    const(char)[] section;      // the section in effect ("" before any header)
    const(char)[] key;          // "" for a section header
    const(char)[] value;        // the section name for a header
    bool          is_section;
}

struct IniParser {
    io.LineReader lines;
    const(char)[] section;
}

IniParser ini_parse(const(char)[] buf) @nogc nothrow {
    return IniParser(io.lines(buf), null);
}
IniParser ini_parse(const(ubyte)[] buf) @nogc nothrow {
    return IniParser(io.lines(buf), null);
}

// The next section header or key/value pair, or `none` at end of input.
res.Option!IniEntry ini_next(ref IniParser p) @nogc nothrow {
    const(char)[] raw;
    while (io.read_line(p.lines).take(raw)) {
        const(char)[] line = str.trim(raw);
        if (line.length == 0 || line[0] == '#' || line[0] == ';') continue;

        if (line[0] == '[') {
            size_t close;
            if (!str.index_of(line, ']').take(close) || close < 2) continue;   // malformed header
            p.section = str.trim(line[1 .. close]);
            return res.some(IniEntry(p.section, null, p.section, true));
        }

        size_t eq;
        if (!str.index_of(line, '=').take(eq)) continue;                        // no '='
        const(char)[] key = str.trim(line[0 .. eq]);
        if (key.length == 0) continue;
        const(char)[] value = str.trim(line[eq + 1 .. $]);
        return res.some(IniEntry(p.section, key, value, false));
    }
    return res.none!IniEntry();
}

// ===========================================================================
// writing
// ===========================================================================

// A blank line then `[name]`.
void ini_section(ref str.Sb sb, const(char)[] name) @nogc nothrow {
    if (str.sb_len(sb) != 0) str.sb_put_char(sb, '\n');
    fmt.format!"[{}]\n"(sb, name);
}

void ini_pair(ref str.Sb sb, const(char)[] key, const(char)[] value) @nogc nothrow {
    fmt.format!"{} = {}\n"(sb, key, value);
}

void ini_pair_int(ref str.Sb sb, const(char)[] key, long v) @nogc nothrow {
    fmt.format!"{} = {}\n"(sb, key, v);
}

void ini_pair_float(ref str.Sb sb, const(char)[] key, double v, int prec = 6) @nogc nothrow {
    str.sb_put(sb, key);
    str.sb_put(sb, " = ");
    str.sb_put_float(sb, v, prec);
    str.sb_put_char(sb, '\n');
}

void ini_pair_bool(ref str.Sb sb, const(char)[] key, bool v) @nogc nothrow {
    fmt.format!"{} = {}\n"(sb, key, v);
}

// `# text`
void ini_comment(ref str.Sb sb, const(char)[] text) @nogc nothrow {
    fmt.format!"# {}\n"(sb, text);
}
