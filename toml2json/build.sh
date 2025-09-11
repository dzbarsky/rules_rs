#!/bin/sh
cargo build --release --target wasm32-unknown-unknown
cp target/wasm32-unknown-unknown/release/toml2json.wasm ./toml2json.wasm
