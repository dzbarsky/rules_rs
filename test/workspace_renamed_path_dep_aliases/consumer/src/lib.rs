pub fn consume() -> &'static str {
    renamed_dep::dep_value()
}

#[cfg(test)]
mod tests {
    #[test]
    fn dependency_is_linked() {
        assert_eq!(super::consume(), "dep");
    }
}
