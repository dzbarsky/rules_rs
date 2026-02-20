"""Module extension that provisions the rules_rust repository."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _rules_rust_impl(mctx):
    http_archive(
        name = "rules_rust",
        integrity = "sha256-kv/QVLsKOcOyqp9Eqil3aMue9+muCul4HAVE7UHQ0Xg=",
        strip_prefix = "rules_rust-81c803d944924bc9d5cc16ea48b6d0ed13c5a445",
        urls = ["https://github.com/dzbarsky/rules_rust/archive/81c803d944924bc9d5cc16ea48b6d0ed13c5a445.tar.gz"],
    )

    return mctx.extension_metadata(reproducible = True)

rules_rust = module_extension(
    implementation = _rules_rust_impl,
)
