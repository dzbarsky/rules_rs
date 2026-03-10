load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":lint_flags.bzl", "cargo_toml_lint_flags")

def _no_lints_section_impl(ctx):
    env = unittest.begin(ctx)

    result = cargo_toml_lint_flags({"package": {"name": "foo"}})
    asserts.equals(env, [], result.rustc_lint_flags)
    asserts.equals(env, [], result.clippy_lint_flags)
    asserts.equals(env, [], result.rustdoc_lint_flags)

    return unittest.end(env)

no_lints_section_test = unittest.make(_no_lints_section_impl)

def _simple_levels_impl(ctx):
    env = unittest.begin(ctx)

    result = cargo_toml_lint_flags({
        "lints": {
            "rust": {
                "unsafe_code": "deny",
                "unused_imports": "warn",
            },
            "clippy": {
                "pedantic": "allow",
            },
            "rustdoc": {
                "broken_intra_doc_links": "forbid",
            },
        },
    })

    asserts.equals(env, ["--deny=unsafe_code", "--warn=unused_imports"], result.rustc_lint_flags)
    asserts.equals(env, ["--allow=clippy::pedantic"], result.clippy_lint_flags)
    asserts.equals(env, ["--forbid=rustdoc::broken_intra_doc_links"], result.rustdoc_lint_flags)

    return unittest.end(env)

simple_levels_test = unittest.make(_simple_levels_impl)

def _priority_ordering_impl(ctx):
    env = unittest.begin(ctx)

    result = cargo_toml_lint_flags({
        "lints": {
            "clippy": {
                "pedantic": {"level": "warn", "priority": -1},
                "doc_markdown": "allow",
                "correctness": {"level": "deny", "priority": -2},
            },
        },
    })

    # priority -2 first, then -1, then 0 (default)
    asserts.equals(env, [
        "--deny=clippy::correctness",
        "--warn=clippy::pedantic",
        "--allow=clippy::doc_markdown",
    ], result.clippy_lint_flags)

    return unittest.end(env)

priority_ordering_test = unittest.make(_priority_ordering_impl)

def _workspace_inherited_impl(ctx):
    env = unittest.begin(ctx)

    result = cargo_toml_lint_flags({
        "lints": {"workspace": True},
    })
    asserts.equals(env, [], result.rustc_lint_flags)
    asserts.equals(env, [], result.clippy_lint_flags)
    asserts.equals(env, [], result.rustdoc_lint_flags)

    return unittest.end(env)

workspace_inherited_test = unittest.make(_workspace_inherited_impl)

def lint_flags_tests():
    return unittest.suite(
        "lint_flags_tests",
        no_lints_section_test,
        simple_levels_test,
        priority_ordering_test,
        workspace_inherited_test,
    )
