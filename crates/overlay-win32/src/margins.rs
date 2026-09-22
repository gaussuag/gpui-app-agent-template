use crate::{HiddenReason, HostSnapshot, PhysicalRect};

/// Nonnegative whole logical pixels (96 DPI), relative to the host client area.
/// Zero preserves full-client coverage. Oversized margins produce an empty viewport.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OverlayMargins {
    pub top: u32,
    pub right: u32,
    pub bottom: u32,
    pub left: u32,
}
impl OverlayMargins {
    pub fn inset(self, rect: PhysicalRect, dpi: u32) -> PhysicalRect {
        let pixels = |value: u32| {
            ((u64::from(value) * u64::from(dpi) + 48) / 96).min(u64::from(u32::MAX)) as i64
        };
        let left = (i64::from(rect.left) + pixels(self.left)).min(i64::from(rect.right));
        let top = (i64::from(rect.top) + pixels(self.top)).min(i64::from(rect.bottom));
        PhysicalRect {
            left: left as i32,
            top: top as i32,
            right: (i64::from(rect.right) - pixels(self.right)).max(left) as i32,
            bottom: (i64::from(rect.bottom) - pixels(self.bottom)).max(top) as i32,
        }
    }
}
impl HostSnapshot {
    pub fn with_margins(mut self, margins: OverlayMargins) -> Self {
        self.physical_overlay_rect = margins.inset(self.physical_client_rect, self.dpi);
        if self.visibility_reason.is_none()
            && (self.physical_overlay_rect.width() <= 0 || self.physical_overlay_rect.height() <= 0)
        {
            self.visibility_reason = Some(HiddenReason::EmptyViewport);
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn margins_scale_and_clamp_without_losing_signed_origin() {
        let rect = PhysicalRect {
            left: -1000,
            top: -500,
            right: -400,
            bottom: -100,
        };
        assert_eq!(OverlayMargins::default().inset(rect, 144), rect);
        let margins = OverlayMargins {
            top: 40,
            right: 8,
            bottom: 6,
            left: 4,
        };
        assert_eq!(
            margins.inset(rect, 144),
            PhysicalRect {
                left: -994,
                top: -440,
                right: -412,
                bottom: -109
            }
        );
        assert_eq!(margins.inset(rect, 96).top, -460);
        assert_eq!(margins.inset(rect, 192).top, -420);
        let empty = OverlayMargins {
            top: u32::MAX,
            left: u32::MAX,
            right: u32::MAX,
            bottom: u32::MAX,
        }
        .inset(rect, u32::MAX);
        assert_eq!(empty.width(), 0);
        assert_eq!(empty.height(), 0);
    }
}
