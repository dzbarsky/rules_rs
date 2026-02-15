def _toolchains_repository_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//rs/experimental/toolchains:declare_toolchains.bzl", "declare_toolchains")

declare_toolchains(
    version = {version},
    edition = {edition},
)
""".format(
            version = repr(rctx.attr.version),
            edition = repr(rctx.attr.edition),
        ),
    )

    return rctx.repo_metadata(reproducible = True)

toolchains_repository = repository_rule(
    implementation = _toolchains_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "edition": attr.string(mandatory = True),
    },
)
