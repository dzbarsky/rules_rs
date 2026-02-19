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

def _semver_select_tilde_impl(ctx):
    env = unittest.begin(ctx)

    got_minor = select_matching_version("~0.6", ["0.5.9", "0.6.0", "0.6.9", "0.7.0"])
    asserts.equals(env, "0.6.9", got_minor)

    got_major = select_matching_version("~1", ["1.0.0", "1.9.9", "2.0.0"])
    asserts.equals(env, "1.9.9", got_major)

    return unittest.end(env)

def _semver_select_wildcards_impl(ctx):
    env = unittest.begin(ctx)

    got_patch = select_matching_version("0.2.*", ["0.1.9", "0.2.0", "0.2.9", "0.3.0"])
    asserts.equals(env, "0.2.9", got_patch)

    got_x = select_matching_version("1.x", ["0.9.9", "1.0.0", "1.9.9", "2.0.0"])
    asserts.equals(env, "1.9.9", got_x)

    got_star = select_matching_version("*", ["0.9.9", "1.0.0-alpha", "1.0.0"])
    asserts.equals(env, "1.0.0", got_star)

    got_star_prerelease_only = select_matching_version("*", ["1.0.0-alpha"])
    asserts.equals(env, None, got_star_prerelease_only)

    return unittest.end(env)

def _semver_select_caret_zero_zero_impl(ctx):
    env = unittest.begin(ctx)

    got = select_matching_version("^0.0", ["0.0.0", "0.0.9", "0.1.0"])
    asserts.equals(env, "0.0.9", got)

    return unittest.end(env)

def _semver_select_partial_comparators_impl(ctx):
    env = unittest.begin(ctx)

    got_eq = select_matching_version("=1.2", ["1.1.9", "1.2.0", "1.2.9", "1.3.0"])
    asserts.equals(env, "1.2.9", got_eq)

    got_le = select_matching_version("<=1.2", ["1.2.0", "1.2.9", "1.3.0"])
    asserts.equals(env, "1.2.9", got_le)

    got_gt = select_matching_version(">1", ["1.0.1", "2.0.0-alpha", "2.0.0"])
    asserts.equals(env, "2.0.0", got_gt)

    return unittest.end(env)

def _semver_select_prerelease_behavior_impl(ctx):
    env = unittest.begin(ctx)

    got_implicit = select_matching_version("<2.0.0", ["1.5.0-alpha", "1.5.0", "2.0.0-alpha"])
    asserts.equals(env, "1.5.0", got_implicit)

    got_explicit = select_matching_version(
        "1.0.0-alpha",
        ["1.0.0-alpha", "1.0.0-alpha.2", "1.0.0-beta", "1.0.0", "1.1.0-alpha", "1.2.0"],
    )
    asserts.equals(env, "1.2.0", got_explicit)

    return unittest.end(env)

semver_select_caret_major_test = unittest.make(_semver_select_caret_major_impl)
semver_select_zero_major_minor_test = unittest.make(_semver_select_zero_major_minor_impl)
semver_select_zero_major_zero_minor_test = unittest.make(_semver_select_zero_major_zero_minor_impl)
semver_select_bare_zero_equiv_test = unittest.make(_semver_select_bare_zero_equiv_impl)
semver_select_comparators_test = unittest.make(_semver_select_comparators_impl)
semver_select_no_match_test = unittest.make(_semver_select_no_match_impl)
semver_select_bare_exact_is_default_req_test = unittest.make(_semver_select_bare_exact_is_default_req_impl)
semver_select_tilde_test = unittest.make(_semver_select_tilde_impl)
semver_select_wildcards_test = unittest.make(_semver_select_wildcards_impl)
semver_select_caret_zero_zero_test = unittest.make(_semver_select_caret_zero_zero_impl)
semver_select_partial_comparators_test = unittest.make(_semver_select_partial_comparators_impl)
semver_select_prerelease_behavior_test = unittest.make(_semver_select_prerelease_behavior_impl)

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
        semver_select_tilde_test,
        semver_select_wildcards_test,
        semver_select_caret_zero_zero_test,
        semver_select_partial_comparators_test,
        semver_select_prerelease_behavior_test,
    )
