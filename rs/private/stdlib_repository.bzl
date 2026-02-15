load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "BUILD_for_stdlib",
    "load_arbitrary_tool",
)
load("@rules_rust//rust/platform:triple.bzl", "triple")


def _stdlib_repository_impl(rctx):
    target = triple(rctx.attr.target_triple)

    load_arbitrary_tool(
        rctx,
        iso_date = rctx.attr.iso_date,
        target_triple = target,
        tool_name = "rust-std",
        tool_subdirectories = ["rust-std-{}".format(target.str)],
        version = rctx.attr.version,
        sha256 = rctx.attr.sha256,
    )

    rctx.file("BUILD.bazel", BUILD_for_stdlib(target))
    rctx.file(rctx.name, "")

    return rctx.repo_metadata(reproducible = True)

stdlib_repository = repository_rule(
    implementation = _stdlib_repository_impl,
    attrs = {
        "target_triple": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "iso_date": attr.string(),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)
