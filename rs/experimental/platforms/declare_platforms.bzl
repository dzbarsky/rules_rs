"""Platform definitions for Rust target triples."""

load("//rs/experimental/platforms:triples.bzl", "triple_to_constraint_set", "SUPPORTED_TARGET_TRIPLES")

def declare_platforms(targets = SUPPORTED_TARGET_TRIPLES):
    for target_triple in targets:
        native.platform(
            name = target_triple,
            constraint_values = triple_to_constraint_set(target_triple),
            visibility = ["//visibility:public"],
        )
