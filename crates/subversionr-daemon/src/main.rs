use std::env;
use std::io;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use subversionr_daemon::{
    NativeBridge, ProcessRemoteWorkerSupervisor, remote_worker_control_channel_is_private,
    run_json_rpc_stdio_with_remote_worker, run_remote_worker,
};

const PRIVATE_REMOTE_WORKER_MODE: &str = "--subversionr-private-remote-worker-v1";

fn main() -> ExitCode {
    let arguments = env::args_os().skip(1).collect::<Vec<_>>();
    if arguments.len() == 1 && arguments[0] == PRIVATE_REMOTE_WORKER_MODE {
        if !remote_worker_control_channel_is_private() {
            eprintln!("SubversionR private worker requires inherited control pipes.");
            return ExitCode::from(2);
        }
        return run_remote_worker(io::stdin().lock(), io::stdout().lock());
    }
    if !arguments.is_empty() {
        eprintln!("SubversionR daemon does not accept command-line arguments.");
        return ExitCode::from(2);
    }

    let Some(bridge_path) = env::var_os("SUBVERSIONR_BRIDGE_DLL") else {
        eprintln!("SUBVERSIONR_BRIDGE_DLL is required.");
        return ExitCode::from(2);
    };

    let bridge_path = PathBuf::from(bridge_path);
    let bridge_path = match bridge_path.canonicalize() {
        Ok(path) if path.is_absolute() && path.is_file() => path,
        _ => {
            eprintln!("SUBVERSIONR_BRIDGE_DLL must resolve to an absolute file.");
            return ExitCode::from(2);
        }
    };
    let bridge = match NativeBridge::load(&bridge_path) {
        Ok(bridge) => bridge,
        Err(error) => {
            eprintln!("{}", error.startup_error());
            return ExitCode::from(2);
        }
    };
    let worker_executable = match env::current_exe().and_then(|path| path.canonicalize()) {
        Ok(path) if path.is_absolute() && path.is_file() => path,
        _ => {
            eprintln!("SubversionR daemon executable path could not be verified.");
            return ExitCode::from(2);
        }
    };
    let temp_base = env::temp_dir().join("SubversionR").join("remote-workers");
    let remote_worker =
        match ProcessRemoteWorkerSupervisor::new(worker_executable, bridge_path, temp_base) {
            Ok(supervisor) => Arc::new(supervisor),
            Err(_) => {
                eprintln!("SubversionR remote worker supervisor could not be initialized.");
                return ExitCode::from(2);
            }
        };

    let stdin = io::stdin();
    let stdout = io::stdout();
    match run_json_rpc_stdio_with_remote_worker(stdin, stdout.lock(), &bridge, remote_worker) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}
