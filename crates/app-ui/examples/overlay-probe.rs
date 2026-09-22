fn main() {
    if !app_ui::overlay::run_feasibility_probe() {
        std::process::exit(1);
    }
}
