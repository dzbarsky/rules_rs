load("@rules_rust//rust:toolchain.bzl", "rustfmt_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_version")

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def declare_rustfmt_toolchains(
        *,
        version,
        rustfmt_version,
        edition,
        execs = SUPPORTED_EXEC_TRIPLES):
    version_key = sanitize_version(version)
    rustfmt_version_key = sanitize_version(rustfmt_version)
    channel = _channel(version)

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, version_key)
        rustfmt_repo_label = "@rustfmt_{}_{}//:".format(triple_suffix, rustfmt_version_key)

        rustfmt_toolchain_name = "{}_{}_{}_rustfmt_toolchain".format(
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )

        rustfmt_toolchain(
            name = rustfmt_toolchain_name,
            rustfmt = "{}rustfmt_bin".format(rustfmt_repo_label),
            rustc = "{}rustc".format(rustc_repo_label),
            rustc_lib = "{}rustc_lib".format(rustfmt_repo_label),
            visibility = ["//visibility:public"],
            tags = ["rust_version={}".format(version)],
        )

        native.toolchain(
            name = "{}_{}_rustfmt_{}".format(exec_triple.system, exec_triple.arch, version_key),
            exec_compatible_with = [
                "@platforms//os:" + exec_triple.system,
                "@platforms//cpu:" + exec_triple.arch,
            ],
            target_compatible_with = [],
            target_settings = [
                "@rules_rust//rust/toolchain/channel:" + channel,
            ],
            toolchain = rustfmt_toolchain_name,
            toolchain_type = "@rules_rust//rust/rustfmt:toolchain_type",
            visibility = ["//visibility:public"],
        )
