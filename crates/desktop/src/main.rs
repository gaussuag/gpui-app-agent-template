#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{ffi::OsString, process::ExitCode};

mod product_identity;

const SMOKE_ARGUMENT: &str = "--smoke-test";
const SMOKE_SUCCESS_MARKER: &str = "GPUI_SMOKE_OK";

fn smoke_requested(arguments: impl IntoIterator<Item = OsString>) -> bool {
    arguments
        .into_iter()
        .any(|argument| argument == SMOKE_ARGUMENT)
}

fn main() -> ExitCode {
    let identity = product_identity::launch_identity();
    if smoke_requested(std::env::args_os().skip(1)) {
        if app_ui::run_smoke(identity) {
            println!("{SMOKE_SUCCESS_MARKER}");
            return ExitCode::SUCCESS;
        }

        eprintln!("GPUI native smoke did not observe the expected state.");
        return ExitCode::FAILURE;
    }

    app_ui::run(identity);
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smoke_mode_requires_the_exact_internal_argument() {
        assert!(smoke_requested([OsString::from(SMOKE_ARGUMENT)]));
        assert!(!smoke_requested([OsString::from("--smoke")]));
        assert!(!smoke_requested([]));
    }
}
