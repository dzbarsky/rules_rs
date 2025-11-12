## Overview

This ruleset is a companion to [rules_rust](https://github.com/bazelbuild/rules_rust) which provides a reimplementation of `crate_universe`. It integrates tightly with Bazel's downloader and the lockfile facts API, allowing automatic,
extremely fast, incremental resolution without the Bazel-specific Cargo lockfile that `rules_rust` uses.

## Installation

```
bazel_dep(name = "rules_rs", version = "0.0.1")
```

## Usage
Usage is basically the same as in rules_rust, with a few attributes renamed for clarity.

```
crate = use_extension("@rules_rs//rs:extensions.bzl", "crate")

crate.from_cargo(
    name = "crates",
    cargo_lock = "//:Cargo.lock",
    cargo_toml = "//:Cargo.toml",
    platform_triples = [
        "aarch64-apple-darwin",
        "aarch64-unknown-linux-gnu",
        "x86_64-apple-darwin",
        "x86_64-unknown-linux-gnu",
    ],
)

crate.annotation(
   crate = "backtrace",
   gen_build_script = "off",
)

...
```

`crate.spec` and vendoring mode are currently unsupported.
