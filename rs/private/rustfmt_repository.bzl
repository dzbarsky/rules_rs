load("@rules_rust//rust/platform:triple.bzl", "triple")
load("@rules_rust//rust/private:repository_utils.bzl", "BUILD_for_rustfmt")
load(":rust_repository_utils.bzl", "download_and_extract", "RUST_REPOSITORY_COMMON_ATTR")

_RUSTFMT_LIB_FILEGROUP_TEMPLATE = """
filegroup(
    name = "rustc_lib",
    srcs = ["lib", {upstream_rustc_lib}],
    visibility = ["//visibility:public"],
)
"""

def _rustfmt_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustfmt", "rustfmt-preview", exec_triple)

    rctx.file(
        "BUILD.bazel",
        BUILD_for_rustfmt(exec_triple) + _RUSTFMT_LIB_FILEGROUP_TEMPLATE.format(
            upstream_rustc_lib = repr(str(rctx.attr.rustc_repo_build_file.same_package_label("rustc_lib"))),
        ),
    )

    rustc_repo_root = rctx.path(rctx.attr.rustc_repo_build_file).dirname
    rctx.symlink(rustc_repo_root.get_child("lib"), "lib")

    return rctx.repo_metadata(reproducible = True)

rustfmt_repository = repository_rule(
    implementation = _rustfmt_repository_impl,
    attrs = {
        "rustc_repo_build_file": attr.label(allow_single_file = True, mandatory = True),
    } | RUST_REPOSITORY_COMMON_ATTR,
)
