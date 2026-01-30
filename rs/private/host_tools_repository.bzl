def _host_tools_repository_impl(rctx):
    defs_bzl_content = """\
RS_HOST_CARGO_LABEL = Label("@{host_cargo_repo}//:bin/cargo{binary_suffix}")
""".format(
        host_cargo_repo = rctx.attr.host_cargo_repo,
        binary_suffix = rctx.attr.binary_suffix,
    )

    rctx.file("defs.bzl", defs_bzl_content)
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')

    return rctx.repo_metadata(reproducible = True)

host_tools_repository = repository_rule(
    implementation = _host_tools_repository_impl,
    attrs = {
        "host_cargo_repo": attr.string(mandatory = True),
        "binary_suffix": attr.string(mandatory = True),
    },
)
