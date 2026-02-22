#!/usr/bin/env bash
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "error: rg is required" >&2
  exit 1
fi

if ! command -v buildozer >/dev/null 2>&1; then
  echo "error: buildozer is required" >&2
  exit 1
fi

if ! command -v buildifier >/dev/null 2>&1; then
  echo "error: buildifier is required" >&2
  exit 1
fi

workspace_root="${1:-.}"
cd "${workspace_root}"

starlark_globs=(
  --glob 'BUILD'
  --glob 'BUILD.*'
  --glob '*.bzl'
)

mapfile -t candidate_files < <(rg -l "${starlark_globs[@]}" 'load\("@rules_rust//(rust|cargo):' || true)

if ((${#candidate_files[@]} == 0)); then
  echo "No @rules_rust rust/cargo load statements found."
  exit 0
fi

to_targets() {
  local files=("$@")
  local file basename dir
  local -A seen=()
  targets_out=()
  for file in "${files[@]}"; do
    file="${file#./}"
    basename="$(basename "${file}")"
    case "${basename}" in
      BUILD | BUILD.*)
        dir="$(dirname "${file}")"
        if [[ "${dir}" == "." ]]; then
          target="//:all"
        else
          target="//${dir}:all"
        fi
        ;;
      *.bzl)
        # buildozer edits non-BUILD files when the file path is used as package.
        target="//${file}:all"
        ;;
      *)
        continue
        ;;
    esac
    if [[ -z "${seen["${target}"]:-}" ]]; then
      targets_out+=("${target}")
      seen["${target}"]=1
    fi
  done
}

to_targets "${candidate_files[@]}"
all_targets=("${targets_out[@]}")

for command in \
  'substitute_load ^@rules_rust//rust:rust_static_library\.bzl$ @rules_rs//rs:rust_static_library.bzl' \
  'substitute_load ^@rules_rust//rust:rust_shared_library\.bzl$ @rules_rs//rs:rust_shared_library.bzl' \
  'substitute_load ^@rules_rust//cargo/private:cargo_build_script_wrapper\.bzl$ @rules_rs//rs:cargo_build_script.bzl'
do
  buildozer -k "${command}" "${all_targets[@]}" >/dev/null 2>&1 || true
done

rewrites=(
  'rust_binary @rules_rs//rs:rust_binary.bzl'
  'rust_library @rules_rs//rs:rust_library.bzl'
  'rust_proc_macro @rules_rs//rs:rust_proc_macro.bzl'
  'rust_test @rules_rs//rs:rust_test.bzl'
  'rust_static_library @rules_rs//rs:rust_static_library.bzl'
  'rust_shared_library @rules_rs//rs:rust_shared_library.bzl'
  'cargo_build_script @rules_rs//rs:cargo_build_script.bzl'
)

for rewrite in "${rewrites[@]}"; do
  symbol="${rewrite%% *}"
  module="${rewrite##* }"

  # Match only positional imports (example: "rust_binary"), not aliased imports.
  pattern="load\\(\\s*\"@rules_rust//[^\\\"]+\"(?s:[^\\)]*?,\\s*\"${symbol}\")"
  mapfile -t symbol_files < <(rg -l -U -P "${starlark_globs[@]}" "${pattern}" || true)
  if ((${#symbol_files[@]} == 0)); then
    continue
  fi

  to_targets "${symbol_files[@]}"
  symbol_targets=("${targets_out[@]}")
  buildozer -k "replace_load ${module} ${symbol}" "${symbol_targets[@]}" >/dev/null 2>&1 || true
done

buildifier -mode=fix "${candidate_files[@]}"

echo "Rewrote common @rules_rust load statements in ${#candidate_files[@]} file(s)."
echo "Note: aliased imports (example: rb = \"rust_binary\") are not auto-rewritten."
