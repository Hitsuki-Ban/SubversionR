fn main() -> std::io::Result<()> {
    let version = env!("SUBVERSIONR_TEST_PRODUCT_VERSION");
    packaged_native_probe_fixture::run_daemon(
        31,
        version,
        &format!("subversionr-svn-bridge/{version}"),
    )
}
