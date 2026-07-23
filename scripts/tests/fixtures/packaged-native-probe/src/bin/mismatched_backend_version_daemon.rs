fn main() -> std::io::Result<()> {
    let version = env!("SUBVERSIONR_TEST_PRODUCT_VERSION");
    packaged_native_probe_fixture::run_daemon(
        35,
        "0.0.1-mismatched-backend",
        &format!("subversionr-svn-bridge/{version}"),
    )
}
