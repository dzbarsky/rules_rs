## Overview

`rules_rs` is both a wrapper around [rules_rust](https://github.com/bazelbuild/rules_rust) and an alternative implementation for selected parts of the Rust + Bazel stack.

It is designed to:

- Reuse stable `rules_rust` functionality, such as the core compilation rules.
- Provide alternative implementations where there is a benefit to be gained (`crate_universe`-style dependency resolution and toolchain provisioning).
- Let users migrate incrementally while still reusing selected `rules_rust` components (for example toolchains).

## Advantages Over `rules_rust`

- Extremely fast (~200ms) incremental dependency resolution via Bazel downloader integration and lockfile facts. Uses your Cargo lockfile directly. No "Cargo workspace splicing", no Bazel-specific Cargo lockfile. 
- Toolchains are more flexible, powerful, and lightweight. We don't register any toolchains by default, but with a 1-line `register_toolchains` call you can have a working setup for the entire cross-product of supported exec and target triples. The support matrix is wider than rules_rust, we support multiple ABIs per OS (-msvc, -gnu, and -gnullvm on Windows, -gnu and -musl on Linux). We bring fully hermetic `-musl`, `-gnullvm`, and OSX linker runtimes thanks to @llvm module, so you can do full cross builds from any host platform to any target platform, including with remote execution. (OSX host, linux remote executor, Windows gnullvm target works seamlessly). See [PR #21](https://github.com/dzbarsky/rules_rs/pull/21) for more details.
- The patched `rules_rust` extension provides all underlying rules_rust functionality with many fixes applied (Windows linking works now, various rust-analyzer improvements, etc.)

# Installation and Configuraiton

```bzl
bazel_dep(name = "rules_rs", version = "0.0.33")
```

## Rules

Recommended: use `rules_rs` rule wrappers.

You can still use `rules_rust` rule definitions while doing a gradual migration, but using
`rules_rs` all the way saves you from having to refer to both.

Example `BUILD.bazel` using `rules_rs` wrappers:

```bzl
load("@rules_rs//rs:rust_library.bzl", "rust_library")
load("@rules_rs//rs:rust_binary.bzl", "rust_binary")
load("@crates//:defs.bzl", "aliases", "all_crate_deps")

rust_library(
    name = "lib",
    srcs = ["src/lib.rs"],
    aliases = aliases(),
    deps = all_crate_deps(normal = True),
    proc_macro_deps = all_crate_deps(proc_macro = True),
)

rust_binary(
    name = "app",
    srcs = ["src/main.rs"],
    deps = [":lib"],
)
```

For migration details, see [Migration](#migration).

## Toolchains

Strongly recommended: use `rules_rs` toolchains.

You can still use `rules_rust` toolchains when doing a gradual migration, but that should be considered a compatibility on-ramp rather than the default.

### Option A: `rules_rs` toolchains (recommended)

```bzl
toolchains = use_extension("@rules_rs//rs/experimental/toolchains:module_extension.bzl", "toolchains")

toolchains.toolchain(
    edition = "2024",
    version = "1.92.0",
)

use_repo(toolchains, "default_rust_toolchains")
register_toolchains("@default_rust_toolchains//:all")
```

Make sure you set `use_experimental_platforms = True` in `crate.from_cargo(...)`.

### Option B: Keep your existing `rules_rust` toolchain configuration.

## Dependency Resolution

`rules_rs` uses its own `crate_universe` implementation through `crate.from_cargo`:

```bzl
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
    # True when using rules_rs experimental toolchains/platforms.
    # False (default) when using rules_rust toolchains/platforms.
    use_experimental_platforms = True,
)

use_repo(crate, "crates")
```

`crate.spec` and vendoring mode are currently unsupported.

### Exec vs target triple caveats

- Windows: the default Windows **exec** toolchain is MSVC-flavored. The upstream `gnullvm` toolchain dynamically links `libunwind`, which may not exist on a stock Windows machine.
- If you target `*-pc-windows-gnullvm`, resolve both triples in dependency resolution (`crate.from_cargo`): one MSVC triple for exec/build-script/proc-macro work and one `gnullvm` triple for target artifacts.
- Linux: similarly, when targeting `*-unknown-linux-musl`, also include the corresponding `*-unknown-linux-gnu` triple for exec. Proc macros and build scripts run in exec configuration, and Linux exec toolchains are GNU. This is required because the `@llvm` toolchain currently cannot produce musl-flavored proc-macro `.so` artifacts, and the proc macro ABI must match the rustc ABI.

Example `platform_triples` values:

```bzl
# Windows gnullvm target with MSVC exec.
platform_triples = [
    "x86_64-pc-windows-msvc",     # exec
    "x86_64-pc-windows-gnullvm",  # target
]

# Linux musl target with GNU exec.
platform_triples = [
    "x86_64-unknown-linux-gnu",   # exec
    "x86_64-unknown-linux-musl",  # target
]
```

# TODO(zbarsky): Should we issue warnings if you configure the triples in an unexpected way?

## Import `rules_rust` from `rules_rs`

`rules_rs` exports a `rules_rust` module extension you can use to provision the pinned `rules_rust` repo:

```bzl
rules_rust = use_extension("@rules_rs//rs/experimental:rules_rust.bzl", "rules_rust")
use_repo(rules_rust, "rules_rust")
```

The core compilation rules (`rust_library`, `rust_binary`, `rust_test`, `rust_proc_macro`, `rust_static_library`, and `rust_dynamic_library`) can be loaded directly from `@rules_rs//rs:*.bzl` but clippy integration, protobuf, etc come from rules_rust for now.
Using this extension is STRONGLY ENCOURAGED because it carries fixes that improve Windows behavior, rust-analyzer integration, and related compatibility work.
In addition, when using the `rules_rs` toolchains, loading the compilation rules from `@rules_rs` directly and using the extension is REQUIRED for toolchain resolution to work correctly, at least until https://github.com/bazelbuild/rules_rust/pull/3857 is accepted by rules_rust maintainers. See the Migration section for more info.

## Platform Configuration

For reliable toolchain resolution, ABI choices should be explicit on every platform participating in your build, including the host platform.

Linux and Windows each have ABI variants that affect toolchain matching (gnu/musl on Linux, msvc/gnu/gnullvm on Windows). Implicit/default platforms lacking these constraints will result in toolchain resolution errors, as no toolchains will match.

At minimum, set an explicit `--host_platform` that adds your ABI constraint on top of `@platforms//host`:

`.bazelrc`:

```bazelrc
common:linux --host_platform=//platforms:local_gnu
common:windows --host_platform=//platforms:local_windows_msvc
```

`platforms/BUILD.bazel`:

```bzl
# Host platform with an explicit Linux GNU ABI choice.
platform(
    name = "local_gnu",
    parents = ["@platforms//host"],
    constraint_values = [
        "@llvm//constraints/libc:gnu.2.28",
    ],
)

# Host platform with an explicit Windows ABI choice.
platform(
    name = "local_windows_msvc",
    parents = ["@platforms//host"],
    constraint_values = [
        "@rules_rs//rs/experimental/platforms/constraints:windows_msvc",
    ],
)
```

Set host ABI constraints to match your exec toolchain choice; handle target ABI differences via target platforms and `platform_triples`.

For remote execution platforms, you can inherit from a triple-based platform published in `@rules_rs//rs/experimental/platforms` and then layer exec properties:

```bzl
platform(
    name = "rbe_linux_amd64_gnu",
    parents = ["@rules_rs//rs/experimental/platforms:x86_64-unknown-linux-gnu"],
    exec_properties = {
        "container-image": "docker://ghcr.io/example/rbe-linux-gnu:latest",
    },
)
```

## Migration

A sample migration script is provided at `scripts/rewrite_rules_rust_loads.sh`. It rewrites common `@rules_rust` Rust loads to `@rules_rs//rs:*` wrappers and then formats with `buildifier`.

```bash
./scripts/rewrite_rules_rust_loads.sh
```

## Public API

See https://registry.bazel.build/docs/rules_rs

## Users

- [OpenAI Codex](https://github.com/openai/codex)
- [Aspect CLI](https://github.com/aspect-build/aspect-cli)
- [Datadog Agent](https://github.com/DataDog/datadog-agent)
- [ZML](https://github.com/zml/zml/tree/zml/v2)

## Telemetry & privacy policy

This ruleset collects limited usage data via [`tools_telemetry`](https://github.com/aspect-build/tools_telemetry), which is reported to Aspect Build Inc and governed by their [privacy policy](https://www.aspect.build/privacy-policy).
