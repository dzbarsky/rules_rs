use itoa::Buffer;

fn main() {
    let mut buffer = Buffer::new();
    println!("{}", buffer.format(1234));
}
