load("@rules_rust//rust/private:repository_utils.bzl", "BUILD_for_stdlib")
load("@rules_rust//rust/platform:triple.bzl", "triple")
load(":rust_repository_utils.bzl", "download_and_extract", "RUST_REPOSITORY_COMMON_ATTR")

def _stdlib_repository_impl(rctx):
    target = triple(rctx.attr.triple)
    download_and_extract(rctx, "rust-std", "rust-std-{}".format(target.str), target)
    rctx.file("BUILD.bazel", BUILD_for_stdlib(target))

    return rctx.repo_metadata(reproducible = True)

stdlib_repository = repository_rule(
    implementation = _stdlib_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
