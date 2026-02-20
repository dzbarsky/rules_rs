load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "produce_tool_suburl",
    "produce_tool_path",
)

def download_and_extract(rctx, tool, dir, triple):
    tool_suburl = produce_tool_suburl(tool, triple, rctx.attr.version, rctx.attr.iso_date)
    urls = [url.format(tool_suburl) for url in rctx.attr.urls]

    tool_path = produce_tool_path(tool, rctx.attr.version, triple)

    rctx.download_and_extract(
        urls,
        sha256 = rctx.attr.sha256,
        auth = get_auth(rctx, urls),
        strip_prefix = "{}/{}".format(tool_path, dir),
    )

RUST_REPOSITORY_COMMON_ATTR = {
    "triple": attr.string(mandatory = True),
    "version": attr.string(mandatory = True),
    "iso_date": attr.string(),
    "sha256": attr.string(mandatory = True),
    "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
}
