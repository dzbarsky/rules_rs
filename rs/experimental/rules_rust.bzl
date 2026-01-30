"""Module extension that provisions the rules_rust repository."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _rules_rust_impl(mctx):
    http_archive(
        name = "rules_rust",
        integrity = "sha256-nyWyW+oeggZNsko3kYsglcMSFQMs15PUqt4X9ebOxWg=",
        strip_prefix = "rules_rust-2e5387c8ccbeed36285de0d81274887de8605af1",
        urls = ["https://github.com/dzbarsky/rules_rust/archive/2e5387c8ccbeed36285de0d81274887de8605af1.tar.gz"],
    )

    return mctx.extension_metadata(reproducible = True)

rules_rust = module_extension(
    implementation = _rules_rust_impl,
)
