load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "BUILD_for_compiler",
)
load(":rust_repository_utils.bzl", "download_and_extract", "RUST_REPOSITORY_COMMON_ATTR")

def _rustc_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustc", "rustc", exec_triple)
    rctx.file("BUILD.bazel", BUILD_for_compiler(exec_triple))

    return rctx.repo_metadata(reproducible = True)

rustc_repository = repository_rule(
    implementation = _rustc_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
