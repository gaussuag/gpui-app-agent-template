#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{ffi::OsString, process::ExitCode};

mod product_identity;

const SMOKE_ARGUMENT: &str = "--smoke-test";
const SMOKE_SUCCESS_MARKER: &str = "GPUI_SMOKE_OK";
const OVERLAY_ARGUMENT: &str = "--overlay-demo";

#[derive(Debug, PartialEq, Eq)]
enum LaunchMode {
    Template,
    Smoke,
    Overlay,
}

fn launch_mode(arguments: impl IntoIterator<Item = OsString>) -> Result<LaunchMode, &'static str> {
    let mut smoke = false;
    let mut overlay = false;
    for argument in arguments {
        smoke |= argument == SMOKE_ARGUMENT;
        overlay |= argument == OVERLAY_ARGUMENT;
    }
    match (smoke, overlay) {
        (true, true) => Err("--smoke-test and --overlay-demo cannot be combined."),
        (true, false) => Ok(LaunchMode::Smoke),
        (false, true) => Ok(LaunchMode::Overlay),
        (false, false) => Ok(LaunchMode::Template),
    }
}

fn main() -> ExitCode {
    let identity = product_identity::launch_identity();
    let mode = match launch_mode(std::env::args_os().skip(1)) {
        Ok(mode) => mode,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    if mode == LaunchMode::Overlay {
        app_ui::run_overlay_demo(identity);
        return ExitCode::SUCCESS;
    }
    if mode == LaunchMode::Smoke {
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
        assert_eq!(
            launch_mode([OsString::from(SMOKE_ARGUMENT)]),
            Ok(LaunchMode::Smoke)
        );
        assert_eq!(
            launch_mode([OsString::from("--smoke")]),
            Ok(LaunchMode::Template)
        );
        assert_eq!(launch_mode([]), Ok(LaunchMode::Template));
    }

    #[test]
    fn overlay_mode_and_conflicts_are_explicit() {
        assert_eq!(
            launch_mode([OsString::from(OVERLAY_ARGUMENT)]),
            Ok(LaunchMode::Overlay)
        );
        for arguments in [
            [SMOKE_ARGUMENT, OVERLAY_ARGUMENT],
            [OVERLAY_ARGUMENT, SMOKE_ARGUMENT],
        ] {
            assert!(launch_mode(arguments.map(OsString::from)).is_err());
        }
        assert_eq!(
            launch_mode([OsString::from("--overlay-demo-other")]),
            Ok(LaunchMode::Template)
        );
    }
}
