use std::env;
use std::io;
use std::path::PathBuf;
use std::process::ExitCode;

use subversionr_daemon::{NativeBridge, run_json_rpc_stdio};

fn main() -> ExitCode {
    let Some(bridge_path) = env::var_os("SUBVERSIONR_BRIDGE_DLL") else {
        eprintln!("SUBVERSIONR_BRIDGE_DLL is required.");
        return ExitCode::from(2);
    };

    let bridge_path = PathBuf::from(bridge_path);
    let bridge = match NativeBridge::load(&bridge_path) {
        Ok(bridge) => bridge,
        Err(error) => {
            eprintln!("{}", error.startup_error());
            return ExitCode::from(2);
        }
    };

    let stdin = io::stdin();
    let stdout = io::stdout();
    match run_json_rpc_stdio(stdin, stdout.lock(), &bridge) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}
