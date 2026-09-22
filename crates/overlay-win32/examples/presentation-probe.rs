//! Stage-zero native primitive experiment, not a production Overlay demo.
#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    overlay_win32::run_presentation_probe()
}

#[cfg(not(windows))]
fn main() {
    eprintln!("PRESENTATION_PROBE_ABORT: Windows is required.");
    std::process::exit(1);
}
