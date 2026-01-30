"""Shared helpers for toolchain generation."""

def sanitize_triple(triple_str):
    return triple_str.replace("-", "_").replace(".", "_")
