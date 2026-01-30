"""Module extension that provisions the rules_rust repository."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _rules_rust_impl(mctx):
    http_archive(
        name = "rules_rust",
        integrity = "sha256-vWvR41KPZcxUCb/cF+I1ssKntMpftDSaA9oQNLgdxJI=",
        strip_prefix = "rules_rust-7c8a8f6d1f6af0a5b95da7b248bf3222731f3a4f",
        urls = ["https://github.com/dzbarsky/rules_rust/archive/7c8a8f6d1f6af0a5b95da7b248bf3222731f3a4f.tar.gz"],
    )

    return mctx.extension_metadata(reproducible = True)

rules_rust = module_extension(
    implementation = _rules_rust_impl,
)
