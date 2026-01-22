fn main() {
    let mut buffer = itoa::Buffer::new();
    let formatted = buffer.format(42);
    println!("vendored itoa says: {formatted}");
}
