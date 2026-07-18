fn main() -> std::io::Result<()> {
    let version = env!("SUBVERSIONR_TEST_PRODUCT_VERSION");
    let bridge_version = format!("SubversionR-svn-bridge/{version}");
    packaged_native_probe_fixture::run_daemon(33, version, &bridge_version)
}
