"""Module extension for configuring experimental Rust toolchains."""

load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "load_arbitrary_tool",
    "BUILD_for_cargo",
)
load("@rules_rust//rust/platform:triple.bzl", "triple")

def _cargo_repository_impl(rctx):
    exec_triple = triple(rctx.attr.exec_triple)

    load_arbitrary_tool(
        rctx,
        iso_date = rctx.attr.iso_date,
        target_triple = exec_triple,
        tool_name = "cargo",
        tool_subdirectories = ["cargo"],
        version = rctx.attr.version,
        sha256 = rctx.attr.sha256,
    )

    rctx.file("BUILD.bazel", BUILD_for_cargo(exec_triple))
    rctx.file(rctx.name, "")

    return rctx.repo_metadata(reproducible = True)

cargo_repository = repository_rule(
    implementation = _cargo_repository_impl,
    attrs = {
        "exec_triple": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "iso_date": attr.string(),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)
