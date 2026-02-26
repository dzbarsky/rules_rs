#[cfg(feature = "with_itoa")]
pub fn render() -> String {
    let mut buf = itoa::Buffer::new();
    buf.format(7).to_owned()
}

#[cfg(not(feature = "with_itoa"))]
pub fn render() -> String {
    "missing".to_owned()
}
