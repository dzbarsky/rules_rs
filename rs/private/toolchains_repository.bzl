def _toolchains_repository_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//rs/experimental/toolchains:declare_rustc_toolchains.bzl", "declare_rustc_toolchains")
load("@rules_rs//rs/experimental/toolchains:declare_rustfmt_toolchains.bzl", "declare_rustfmt_toolchains")

declare_rustc_toolchains(
    version = {version},
    edition = {edition},
)

declare_rustfmt_toolchains(
    version = {version},
    rustfmt_version = {rustfmt_version},
    edition = {edition},
)
""".format(
            version = repr(rctx.attr.version),
            rustfmt_version = repr(rctx.attr.rustfmt_version),
            edition = repr(rctx.attr.edition),
        ),
    )

    return rctx.repo_metadata(reproducible = True)

toolchains_repository = repository_rule(
    implementation = _toolchains_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "rustfmt_version": attr.string(mandatory = True),
        "edition": attr.string(mandatory = True),
    },
)
