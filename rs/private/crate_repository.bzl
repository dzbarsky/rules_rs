load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")
load(":repository_utils.bzl", "generate_build_file", "common_attrs")
load(":toml2json.bzl", "run_toml2json")

def _crate_repository_impl(rctx):
    rctx.download_and_extract(
        rctx.attr.url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [rctx.attr.url]),
        strip_prefix = rctx.attr.strip_prefix,
        sha256 = rctx.attr.checksum,
    )

    patch(rctx)

    if rctx.attr.use_wasm:
        wasm_blob = rctx.load_wasm(Label("@rules_rs//toml2json:toml2json.wasm"))
    else:
        wasm_blob = None
    cargo_toml = run_toml2json(rctx, wasm_blob, "Cargo.toml")

    rctx.file("BUILD.bazel", generate_build_file(rctx.attr, cargo_toml))

    return rctx.repo_metadata(reproducible = True)

crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "checksum": attr.string(),
    } | common_attrs,
)