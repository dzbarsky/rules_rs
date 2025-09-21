rustls::crypto::default_fips_provider()
    .install_default()
    .expect("default provider already set elsewhere");
