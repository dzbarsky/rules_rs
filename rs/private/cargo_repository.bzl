load("@rules_rust//rust/private:repository_utils.bzl", "BUILD_for_cargo")
load("@rules_rust//rust/platform:triple.bzl", "triple")
load(":rust_repository_utils.bzl", "download_and_extract", "RUST_REPOSITORY_COMMON_ATTR")

def _cargo_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "cargo", "cargo", exec_triple)
    rctx.file("BUILD.bazel", BUILD_for_cargo(exec_triple))

    return rctx.repo_metadata(reproducible = True)

cargo_repository = repository_rule(
    implementation = _cargo_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
