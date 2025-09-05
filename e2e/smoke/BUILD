"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

build_test(
    name = "smoke_test",
    targets = [
        "@crates//:zvariant_utils",
    ],
)
