use app_ui::LaunchIdentity;

const PRODUCT_DISPLAY_NAME: &str = env!("PRODUCT_DISPLAY_NAME");

pub const fn launch_identity() -> LaunchIdentity {
    LaunchIdentity::new(PRODUCT_DISPLAY_NAME)
}

#[cfg(test)]
mod tests {
    use super::launch_identity;

    #[test]
    fn build_identity_is_available_to_process_startup() {
        assert!(!launch_identity().display_name().is_empty());
    }
}
