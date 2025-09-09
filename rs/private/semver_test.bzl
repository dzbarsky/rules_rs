load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":semver.bzl", "select_matching_version")

def _semver_select_caret_major_impl(ctx):
    env = unittest.begin(ctx)

    got = select_matching_version("^1.2", ["1.1.9", "1.2.0", "1.9.5", "2.0.0"])
    asserts.equals(env, "1.9.5", got)

    return unittest.end(env)

def _semver_select_zero_major_minor_impl(ctx):
    env = unittest.begin(ctx)

    got = select_matching_version("^0.2.3", ["0.2.3", "0.2.9", "0.3.0"])
    asserts.equals(env, "0.2.9", got)

    return unittest.end(env)

def _semver_select_zero_major_zero_minor_impl(ctx):
    env = unittest.begin(ctx)

    got = select_matching_version("^0.0.3", ["0.0.3", "0.0.4"])
    asserts.equals(env, "0.0.3", got)

    return unittest.end(env)

def _semver_select_bare_zero_equiv_impl(ctx):
    env = unittest.begin(ctx)

    # Bare "0" (Cargo default requirement) == "^0"
    got1 = select_matching_version("0", ["0.0.9", "0.3.6", "1.0.0"])
    asserts.equals(env, "0.3.6", got1)

    got2 = select_matching_version("^0", ["0.0.9", "0.3.6", "1.0.0"])
    asserts.equals(env, "0.3.6", got2)

    return unittest.end(env)

def _semver_select_comparators_impl(ctx):
    env = unittest.begin(ctx)

    # < upper bound
    got_lt = select_matching_version("<0.10.0", ["0.9.6", "1.7.0"])
    asserts.equals(env, "0.9.6", got_lt)

    # >= lower bound, pick highest satisfying
    got_ge = select_matching_version(">=%s" % "1.2.0", ["1.1.9", "1.2.0", "1.2.1"])
    asserts.equals(env, "1.2.1", got_ge)

    return unittest.end(env)

def _semver_select_no_match_impl(ctx):
    env = unittest.begin(ctx)

    got = select_matching_version("<0.1.0", ["0.1.0", "0.2.0"])
    asserts.equals(env, None, got)

    return unittest.end(env)

def _semver_select_bare_exact_is_default_req_impl(ctx):
    env = unittest.begin(ctx)

    # Bare "1.2.3" follows Cargo default requirement semantics (same as ^1.2.3)
    got = select_matching_version("1.2.3", ["1.2.3", "1.9.9", "2.0.0"])
    asserts.equals(env, "1.9.9", got)

    return unittest.end(env)

semver_select_caret_major_test = unittest.make(_semver_select_caret_major_impl)
semver_select_zero_major_minor_test = unittest.make(_semver_select_zero_major_minor_impl)
semver_select_zero_major_zero_minor_test = unittest.make(_semver_select_zero_major_zero_minor_impl)
semver_select_bare_zero_equiv_test = unittest.make(_semver_select_bare_zero_equiv_impl)
semver_select_comparators_test = unittest.make(_semver_select_comparators_impl)
semver_select_no_match_test = unittest.make(_semver_select_no_match_impl)
semver_select_bare_exact_is_default_req_test = unittest.make(_semver_select_bare_exact_is_default_req_impl)

def semver_select_tests():
    return unittest.suite(
        "semver_select_tests",
        semver_select_caret_major_test,
        semver_select_zero_major_minor_test,
        semver_select_zero_major_zero_minor_test,
        semver_select_bare_zero_equiv_test,
        semver_select_comparators_test,
        semver_select_no_match_test,
        semver_select_bare_exact_is_default_req_test,
    )
