module dnr.result;

// ---------------------------------------------------------------------------
// result — Option!T, Result!(T,E), Status
// ---------------------------------------------------------------------------
// dnr-std reports failure with a value, not a thrown exception (betterC has
// none) and not a bare `bool` + out-parameter. Three shapes:
//
//   Option!T          a T, or nothing            (a lookup that may miss)
//   Result!(T, E)     a T, or an error E         (a computation that may fail)
//   Status(E)         success, or an error E     (an action with no result)
//
// E defaults to `StdErr`, a small shared enum. Construct with `some` / `none`,
// `ok` / `err`, `pass` / `fail`. Read with `is_some` / `is_ok` etc., or pull
// the value out with `unwrap` (which panics on the empty case, via
// dnr.panic), `unwrap_or` (a default), or `take` / `failed` (the imperative
// bridge — copy into an out-parameter, return a bool).
//
// betterC: @nogc nothrow. No union — Result just holds both fields; T and E
// are small (pointers, slices, scalars, enums) in every dnr-std use.

import pnc = dnr.panic;

enum StdErr : ubyte {
    unknown,
    oom,             // an allocation failed
    not_found,       // a key / file / entry was absent
    invalid,         // malformed or out-of-domain input
    overflow,        // a value did not fit the target type
    io,              // a read or write failed
    unexpected_eof,  // the input ended mid-item
    permission,      // denied by the OS
}

const(char)[] err_name(StdErr e) @nogc nothrow {
    final switch (e) {
        case StdErr.unknown:        return "unknown";
        case StdErr.oom:            return "out of memory";
        case StdErr.not_found:      return "not found";
        case StdErr.invalid:        return "invalid input";
        case StdErr.overflow:       return "overflow";
        case StdErr.io:             return "I/O error";
        case StdErr.unexpected_eof: return "unexpected end of input";
        case StdErr.permission:     return "permission denied";
    }
}

// ===========================================================================
// Option!T
// ===========================================================================

struct Option(T) {
    private T    _val;
    private bool _has = false;

    bool is_some() const @nogc nothrow { return _has; }
    bool is_none() const @nogc nothrow { return !_has; }

    // The value, or a panic if none.
    T unwrap(string file = __FILE__, int line = __LINE__) @nogc nothrow {
        if (!_has) pnc.panic("Option.unwrap on a none value", file, line);
        return _val;
    }

    T unwrap_or(T fallback) @nogc nothrow { return _has ? _val : fallback; }

    // Imperative bridge: if some, copy into `out_` and return true.
    //   T v; if (opt.take(v)) use(v);
    bool take(ref T out_) @nogc nothrow {
        if (!_has) return false;
        out_ = _val;
        return true;
    }
}

Option!T some(T)(T v) @nogc nothrow {
    Option!T o;
    o._val = v;
    o._has = true;
    return o;
}

Option!T none(T)() @nogc nothrow {
    Option!T o;
    return o;
}

// some(*p) when p != null, else none — for wrapping a nullable pointer.
Option!(T*) opt_ptr(T)(T* p) @nogc nothrow {
    return p is null ? none!(T*)() : some!(T*)(p);
}

// ===========================================================================
// Result!(T, E)
// ===========================================================================

struct Result(T, E = StdErr) {
    private T    _val;
    private E    _err;
    private bool _ok = false;

    bool is_ok()  const @nogc nothrow { return _ok; }
    bool is_err() const @nogc nothrow { return !_ok; }

    // The value, or a panic naming the error.
    T unwrap(string file = __FILE__, int line = __LINE__) @nogc nothrow {
        if (!_ok) {
            static if (is(E == StdErr))
                pnc.panic(err_name(_err), file, line);
            else
                pnc.panic("Result.unwrap on an error value", file, line);
        }
        return _val;
    }

    T unwrap_or(T fallback) @nogc nothrow { return _ok ? _val : fallback; }

    E unwrap_err(string file = __FILE__, int line = __LINE__) @nogc nothrow {
        if (_ok) pnc.panic("Result.unwrap_err on an ok value", file, line);
        return _err;
    }

    // The error, or `fallback` when ok.
    E err_or(E fallback) @nogc nothrow { return _ok ? fallback : _err; }

    // Imperative bridge: if err, copy it into `out_` and return true.
    bool failed(ref E out_) @nogc nothrow {
        if (_ok) return false;
        out_ = _err;
        return true;
    }

    // Imperative bridge: if ok, copy the value into `out_` and return true.
    //   T v; if (parse(s).take(v)) use(v);
    bool take(ref T out_) @nogc nothrow {
        if (!_ok) return false;
        out_ = _val;
        return true;
    }

    // Discard the error, becoming an Option.
    Option!T optional() @nogc nothrow {
        return _ok ? some!T(_val) : none!T();
    }
}

Result!(T, E) ok(T, E = StdErr)(T v) @nogc nothrow {
    Result!(T, E) r;
    r._val = v;
    r._ok = true;
    return r;
}

// Error variant — T is explicit since there's no value to infer it from:
//   return err!int(StdErr.overflow);
Result!(T, E) err(T, E = StdErr)(E e) @nogc nothrow {
    Result!(T, E) r;
    r._err = e;
    return r;
}

// ===========================================================================
// Status — success or a StdErr, no value
// ===========================================================================
// Not templated on the error type (unlike Option / Result): a value-less
// fallible action in dnr-std always fails with a StdErr, and keeping Status
// plain lets it be written bare as `res.Status`. Need a custom error with no
// value? Use `Result!(bool, MyErr)`.

struct Status {
    private StdErr _err;
    private bool   _ok = false;

    bool is_ok()  const @nogc nothrow { return _ok; }
    bool is_err() const @nogc nothrow { return !_ok; }

    void unwrap(string file = __FILE__, int line = __LINE__) @nogc nothrow {
        if (!_ok) pnc.panic(err_name(_err), file, line);
    }

    StdErr unwrap_err(string file = __FILE__, int line = __LINE__) @nogc nothrow {
        if (_ok) pnc.panic("Status.unwrap_err on an ok status", file, line);
        return _err;
    }

    StdErr err_or(StdErr fallback) @nogc nothrow { return _ok ? fallback : _err; }

    bool failed(ref StdErr out_) @nogc nothrow {
        if (_ok) return false;
        out_ = _err;
        return true;
    }
}

Status pass() @nogc nothrow {
    Status s;
    s._ok = true;
    return s;
}

Status fail(StdErr e) @nogc nothrow {
    Status s;
    s._err = e;
    return s;
}
