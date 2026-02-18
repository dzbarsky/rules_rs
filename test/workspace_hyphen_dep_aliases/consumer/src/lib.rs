pub fn consume() -> &'static str {
    dep_crate::dep_value()
}

#[cfg(test)]
mod tests {
    #[test]
    fn dependency_is_linked() {
        assert_eq!(super::consume(), "dep");
    }
}
