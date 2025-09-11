load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cfg_parser.bzl", "cfg_matches", "cfg_matches_expr_for_triples")

def _cfg(expr):
    return "cfg(%s)" % expr

def _cfg_parser_smoke_test_impl(ctx):
    env = unittest.begin(ctx)

    mac = "aarch64-apple-darwin"
    linux_gnu = "x86_64-unknown-linux-gnu"
    linux_musl = "aarch64-unknown-linux-musl"
    win = "x86_64-pc-windows-msvc"

    # MacOS facts facts
    asserts.true(env, cfg_matches(_cfg("unix"), mac))
    asserts.true(env, cfg_matches(_cfg('target_os = "macos"'), mac))
    asserts.true(env, cfg_matches(_cfg('target_arch = "aarch64"'), mac))
    asserts.true(env, cfg_matches(_cfg('target_family = "unix"'), mac))
    asserts.false(env, cfg_matches(_cfg("windows"), mac))

    # Linux facts
    asserts.true(env, cfg_matches(_cfg("unix"), linux_gnu))
    asserts.true(env, cfg_matches(_cfg('target_os = "linux"'), linux_gnu))
    asserts.true(env, cfg_matches(_cfg('target_env = "gnu"'), linux_gnu))
    asserts.false(env, cfg_matches(_cfg('target_env = "musl"'), linux_gnu))
    asserts.true(env, cfg_matches(_cfg('target_env = "musl"'), linux_musl))

    # Windows facts
    asserts.true(env, cfg_matches(_cfg("windows"), win))
    asserts.false(env, cfg_matches(_cfg("unix"), win))
    asserts.true(env, cfg_matches(_cfg('target_env = "msvc"'), win))
    asserts.true(env, cfg_matches(_cfg('target_family = "windows"'), win))
    asserts.true(env, cfg_matches(_cfg('target_pointer_width = "64"'), win))

    # Combinators
    asserts.false(env, cfg_matches(_cfg("any()"), mac))
    asserts.true(env, cfg_matches(_cfg("not(any())"), mac))
    asserts.true(env, cfg_matches(_cfg("all()"), mac))
    asserts.false(env, cfg_matches(_cfg("not(all())"), mac))
    asserts.false(env, cfg_matches(_cfg("false"), mac))
    asserts.true(env, cfg_matches(_cfg("true"), mac))
    asserts.true(env, cfg_matches(_cfg("any(true)"), mac))
    asserts.true(env, cfg_matches(_cfg("any(true, false)"), mac))
    asserts.true(env, cfg_matches(_cfg("all(true)"), mac))
    asserts.false(env, cfg_matches(_cfg("all(true, false)"), mac))

    triples = [mac, linux_gnu, linux_musl, win]

    results = cfg_matches_expr_for_triples(_cfg('all(unix, any(target_env = "gnu", target_env = "musl"))'), triples)
    asserts.false(env, results[mac])
    asserts.true(env, results[linux_gnu])
    asserts.true(env, results[linux_musl])
    asserts.false(env, results[win])

    results = cfg_matches_expr_for_triples(
        _cfg('any(target_arch = "aarch64", target_arch = "x86_64", target_arch = "x86")'),
        triples)
    asserts.true(env, results[mac])
    asserts.true(env, results[linux_gnu])
    asserts.true(env, results[linux_musl])
    asserts.true(env, results[win])

    return unittest.end(env)

cfg_parser_smoke_test = unittest.make(_cfg_parser_smoke_test_impl)

def cfg_parser_tests():
    return unittest.suite(
        "cfg_parser_tests",
        cfg_parser_smoke_test,
    )
