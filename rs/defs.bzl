load(
    "@rules_rust//rust:defs.bzl",
    _rust_binary = "rust_binary",
    _rust_library = "rust_library",
    _rust_proc_macro = "rust_proc_macro",
    _rust_test = "rust_test",
)

rust_binary = _rust_binary
rust_library = _rust_library
rust_proc_macro = _rust_proc_macro
rust_test = _rust_test