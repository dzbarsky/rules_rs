"""Shared helpers for toolchain generation."""

def sanitize_triple(triple_str):
    return triple_str.replace("-", "_").replace(".", "_")

def sanitize_version(version):
    return version.replace("/", "_").replace(".", "_").replace("-", "_")
