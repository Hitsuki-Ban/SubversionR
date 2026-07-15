fn main() {
    let version = std::env::var("SUBVERSIONR_TEST_PRODUCT_VERSION")
        .expect("SUBVERSIONR_TEST_PRODUCT_VERSION must be set by the fixture builder");
    println!("cargo:rustc-env=SUBVERSIONR_TEST_PRODUCT_VERSION={version}");
    println!("cargo:rerun-if-env-changed=SUBVERSIONR_TEST_PRODUCT_VERSION");
}
