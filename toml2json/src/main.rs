use std::{env, fs, io::{self, BufWriter, Write}, process};
use serde_transcode::transcode;

fn bail(msg: &str) -> ! {
    eprintln!("{msg}");
    process::exit(1)
}

fn main() {
    let mut args = env::args();
    let prog = args.next().unwrap_or_else(|| "toml2json".into());
    let path = match args.next() {
        Some(p) => p,
        None => bail(&format!("Usage: {prog} <input.toml>")),
    };
    if args.next().is_some() {
        bail(&format!("Usage: {prog} <input.toml>"));
    }

    let input = fs::read_to_string(&path)
        .unwrap_or_else(|e| bail(&format!("Failed to read {path}: {e}")));

    // Set up TOML -> JSON transcoding
    let toml_de = toml::de::Deserializer::parse(&input)
        .unwrap_or_else(|e| bail(&format!("Parse failed: {e}")));

    // Buffered stdout to reduce write syscalls.
    let stdout = io::stdout();
    let handle = stdout.lock();
    let mut out = BufWriter::with_capacity(256 * 1024, handle);
    let mut json_ser = serde_json::Serializer::new(&mut out); // compact/fast

    // Stream from TOML deserializer into JSON serializer.
    transcode(toml_de, &mut json_ser)
        .unwrap_or_else(|e| bail(&format!("Transcode failed: {e}")));

    // Ensure everything is flushed to stdout before exiting.
    out.flush().unwrap_or_else(|e| bail(&format!("Flush failed: {e}")));
}