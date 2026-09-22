fn main() {
    if let Err(error) = overlay_win32::run_fixture() {
        eprintln!("fixture failed: {error}");
        std::process::exit(1);
    }
}
