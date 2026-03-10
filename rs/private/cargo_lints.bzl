"""Rule that provides LintsInfo from pre-computed lint flags."""

load("@rules_rust//rust/private:providers.bzl", "LintsInfo")

def _cargo_lints_impl(ctx):
    return [
        LintsInfo(
            rustc_lint_flags = ctx.attr.rustc_lint_flags,
            rustc_lint_files = [],
            clippy_lint_flags = ctx.attr.clippy_lint_flags,
            clippy_lint_files = [],
            rustdoc_lint_flags = ctx.attr.rustdoc_lint_flags,
            rustdoc_lint_files = [],
        ),
    ]

cargo_lints = rule(
    implementation = _cargo_lints_impl,
    attrs = {
        "rustc_lint_flags": attr.string_list(),
        "clippy_lint_flags": attr.string_list(),
        "rustdoc_lint_flags": attr.string_list(),
    },
)
