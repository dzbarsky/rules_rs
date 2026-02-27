load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "merge_structured_dep_specs")

def _merge_structured_dep_specs_dedupes_and_promotes_impl(ctx):
    env = unittest.begin(ctx)

    specs = [
        (
            ["@repo//:shared", "@repo//:dup"],
            {
                "//cfg:unix": ["@repo//:linux_only", "@repo//:dup"],
                "//cfg:darwin": ["@repo//:darwin_only"],
            },
        ),
        (
            [],
            {
                "//cfg:unix": ["@repo//:everywhere"],
                "//cfg:darwin": ["@repo//:everywhere", "@repo//:darwin_only"],
                "//cfg:win": ["@repo//:everywhere"],
            },
        ),
    ]

    shared, per_platform = merge_structured_dep_specs(
        specs,
        ["//cfg:darwin", "//cfg:unix", "//cfg:win"],
        None,
    )

    asserts.equals(env, ["@repo//:dup", "@repo//:everywhere", "@repo//:shared"], shared)
    asserts.equals(env, {
        "//cfg:darwin": ["@repo//:darwin_only"],
        "//cfg:unix": ["@repo//:linux_only"],
    }, per_platform)

    return unittest.end(env)

def _merge_structured_dep_specs_applies_filter_prefix_impl(ctx):
    env = unittest.begin(ctx)

    shared, per_platform = merge_structured_dep_specs(
        [
            (
                ["@repo//:shared", "@other//:drop"],
                {
                    "//cfg:linux": ["@repo//:linux_only", "@other//:drop"],
                },
            ),
        ],
        ["//cfg:darwin", "//cfg:linux"],
        "@repo//:",
    )

    asserts.equals(env, ["@repo//:shared"], shared)
    asserts.equals(env, {"//cfg:linux": ["@repo//:linux_only"]}, per_platform)

    return unittest.end(env)

def _all_crate_deps_defaults_to_normal_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": ["//:normal"],
            "deps_by_platform": {},
            "build_deps": ["//:build"],
            "build_deps_by_platform": {},
            "dev_deps": ["//:dev"],
            "dev_deps_by_platform": {},
        },
        platforms = ["//cfg:darwin", "//cfg:linux"],
    )

    asserts.equals(env, ["//:normal"], got)

    return unittest.end(env)

def _all_crate_deps_dedupes_across_selected_kinds_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": [],
            "deps_by_platform": {
                "//cfg:linux": ["//:dep_a", "//:dep_b"],
            },
            "build_deps": [],
            "build_deps_by_platform": {},
            "dev_deps": ["//:dep_b"],
            "dev_deps_by_platform": {
                "//cfg:linux": ["//:dep_a", "//:dep_c"],
            },
        },
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
    )

    asserts.equals(env, ["//:dep_a", "//:dep_b", "//:dep_c"], got)

    return unittest.end(env)

merge_structured_dep_specs_dedupes_and_promotes_test = unittest.make(_merge_structured_dep_specs_dedupes_and_promotes_impl)
merge_structured_dep_specs_applies_filter_prefix_test = unittest.make(_merge_structured_dep_specs_applies_filter_prefix_impl)
all_crate_deps_defaults_to_normal_test = unittest.make(_all_crate_deps_defaults_to_normal_impl)
all_crate_deps_dedupes_across_selected_kinds_test = unittest.make(_all_crate_deps_dedupes_across_selected_kinds_impl)

def all_crate_deps_tests():
    return unittest.suite(
        "all_crate_deps_tests",
        merge_structured_dep_specs_dedupes_and_promotes_test,
        merge_structured_dep_specs_applies_filter_prefix_test,
        all_crate_deps_defaults_to_normal_test,
        all_crate_deps_dedupes_across_selected_kinds_test,
    )
