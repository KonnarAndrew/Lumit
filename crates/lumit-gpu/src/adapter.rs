//! Which graphics card the engine draws on, said out loud.
//!
//! # In plain terms
//!
//! A laptop often has two graphics cards: a small one built into the processor
//! (integrated) and a separate, faster one (dedicated). The engine asks for the
//! fast one. The interface around it, Flutter, draws on whichever card Windows
//! gives it by default, which on many laptops is the integrated one.
//!
//! That matters because the Viewer's picture is handed to the interface as a
//! piece of graphics memory, and graphics memory made on one card cannot be
//! opened on another. When the two disagree the handover fails without a word
//! and the Viewer stays empty while everything else carries on. Nothing in the
//! frame counters shows it; the only way to see it is to name both cards and
//! compare them, which is what this module lets the Settings page do.
//!
//! # One definition of "the card the engine picks"
//!
//! [`GpuContext::headless`](crate::GpuContext::headless) opens its adapter
//! through [`pinned_instance`] and [`request_engine_adapter`], and so does
//! [`engine_adapter`] when it is asked before any renderer exists. The readout
//! and the renderer therefore cannot drift apart: if one is changed, both are.

use std::sync::Mutex;

/// What kind of card an adapter is, in the terms a user can act on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterKind {
    /// Built into the processor and sharing its memory.
    Integrated,
    /// A separate card with memory of its own.
    Dedicated,
    /// A virtual machine's or remote session's card.
    Virtual,
    /// No card at all: drawing on the processor (WARP, llvmpipe).
    Software,
    /// The driver would not say.
    Other,
}

impl From<wgpu::DeviceType> for AdapterKind {
    fn from(kind: wgpu::DeviceType) -> Self {
        match kind {
            wgpu::DeviceType::IntegratedGpu => AdapterKind::Integrated,
            wgpu::DeviceType::DiscreteGpu => AdapterKind::Dedicated,
            wgpu::DeviceType::VirtualGpu => AdapterKind::Virtual,
            wgpu::DeviceType::Cpu => AdapterKind::Software,
            wgpu::DeviceType::Other => AdapterKind::Other,
        }
    }
}

/// One graphics adapter, reduced to what a person or a bug report needs.
///
/// `vendor_id` and `device_id` are the PCI identifiers. On Windows wgpu reads
/// them straight from the DXGI adapter description, so they compare directly
/// against what the Flutter runner reads from its own DXGI adapter. Two
/// identical cards in one machine share both numbers; that is the one case the
/// comparison cannot split, and it is also the one case where it does not
/// matter which of them draws.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterSummary {
    pub name: String,
    pub vendor_id: u32,
    pub device_id: u32,
    pub kind: AdapterKind,
    /// The graphics API the adapter was reached through ("Dx12", "Vulkan",
    /// "Metal").
    pub backend: String,
    /// Driver name and version where the driver reports them, else empty.
    pub driver: String,
}

impl AdapterSummary {
    #[must_use]
    pub fn of(info: &wgpu::AdapterInfo) -> Self {
        let driver = match (info.driver.trim(), info.driver_info.trim()) {
            ("", "") => String::new(),
            (name, "") => name.to_owned(),
            ("", version) => version.to_owned(),
            (name, version) => format!("{name} {version}"),
        };
        Self {
            name: info.name.trim().to_owned(),
            vendor_id: info.vendor,
            device_id: info.device,
            kind: info.device_type.into(),
            backend: format!("{:?}", info.backend),
            driver,
        }
    }

    /// Whether this is the card named by a PCI vendor and device pair.
    #[must_use]
    pub fn is_card(&self, vendor_id: u32, device_id: u32) -> bool {
        self.vendor_id == vendor_id && self.device_id == device_id
    }
}

/// The adapter the most recent [`GpuContext::headless`](crate::GpuContext::headless)
/// opened. A `Mutex` rather than a `OnceLock` because a lost device is rebuilt,
/// and the rebuild is entitled to land somewhere else (a card removed, a driver
/// reset onto WARP); the readout should say where it landed, not where the
/// session started.
static IN_USE: Mutex<Option<AdapterSummary>> = Mutex::new(None);

pub(crate) fn record_in_use(info: &wgpu::AdapterInfo) {
    let mut slot = IN_USE.lock().unwrap_or_else(|poison| poison.into_inner());
    *slot = Some(AdapterSummary::of(info));
}

/// The adapter a renderer has actually opened this session, or `None` before
/// the first one.
#[must_use]
pub fn adapter_in_use() -> Option<AdapterSummary> {
    IN_USE
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .clone()
}

/// The adapter the engine draws on: the one in use, or — before any renderer
/// exists — the one it *will* open, asked the same way it will be asked.
///
/// Asking costs an adapter request but no device, so it is cheap enough for a
/// Settings page and never touches the renderer's own state.
#[must_use]
pub fn engine_adapter() -> Option<AdapterSummary> {
    adapter_in_use().or_else(|| {
        let instance = pinned_instance();
        request_engine_adapter(&instance).map(|adapter| AdapterSummary::of(&adapter.get_info()))
    })
}

/// Every adapter the engine's graphics API can see, in the driver's order.
///
/// The same pinned backend as the renderer, so a card listed here is a card
/// the engine could draw on. Software adapters are listed too: a machine
/// whose only entry is WARP is the answer to "why is everything slow".
#[must_use]
pub fn adapters() -> Vec<AdapterSummary> {
    pinned_instance()
        .enumerate_adapters(wgpu::Backends::all())
        .iter()
        .map(|adapter| AdapterSummary::of(&adapter.get_info()))
        .collect()
}

/// The instance every engine adapter is found through, with its backend pinned.
///
/// Pinned on all three platforms, in every build, for two reasons. The
/// zero-copy Viewer hand-off reaches through wgpu to a *specific* backend's
/// device, and with the CPU read-back transport gone there is no build left
/// that wants a mixed-backend instance. And on a hybrid iGPU+dGPU box (e.g. AMD
/// + Nvidia) mixing GL and Vulkan into one enumeration makes
/// `PowerPreference::HighPerformance` pick unreliably (commonly picking the AMD
/// iGPU driving the display), which can cause VRAM exhaustion during command
/// submission.
///
/// `from_env_or_default` supplies the rest of the descriptor (flags, the DX12
/// shader compiler, the GLES minor version) from `WGPU_*`, so those stay
/// tunable — but `backends` is set explicitly *after* it, so the pin wins and
/// `WGPU_BACKEND` cannot move it. That is intended: an environment variable
/// must not be able to break the Viewer.
pub(crate) fn pinned_instance() -> wgpu::Instance {
    #[allow(unused_mut)] // unpinned on platforms outside the three below
    let mut descriptor = wgpu::InstanceDescriptor::from_env_or_default();
    #[cfg(windows)]
    {
        descriptor.backends = wgpu::Backends::DX12;
    }
    #[cfg(target_os = "linux")]
    {
        descriptor.backends = wgpu::Backends::VULKAN;
    }
    #[cfg(target_os = "macos")]
    {
        descriptor.backends = wgpu::Backends::METAL;
    }
    wgpu::Instance::new(&descriptor)
}

/// The engine's adapter request: the high-performance card.
///
/// **Why the two sides can still disagree on Windows.** Flutter's ANGLE opens
/// the adapter Windows gives the process by default and has no high-performance
/// option of its own. The runner exports `NvOptimusEnablement` and
/// `AmdPowerXpressRequestHighPerformance` (`windows/runner/main.cpp`) so the
/// Nvidia and AMD hybrid drivers make that default the discrete card, and both
/// sides land together. Those exports are read by those two drivers only, and a
/// per-app choice in Windows' own graphics settings overrides them, so a machine
/// outside that — another vendor's hybrid pair, or Lumit set to Power saving by
/// hand — can still split. This module exists so that case is visible.
pub(crate) fn request_engine_adapter(instance: &wgpu::Instance) -> Option<wgpu::Adapter> {
    pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn info(kind: wgpu::DeviceType, driver: &str, driver_info: &str) -> wgpu::AdapterInfo {
        wgpu::AdapterInfo {
            name: "  Example Graphics 770  ".into(),
            vendor: 0x8086,
            device: 0x4680,
            device_type: kind,
            driver: driver.into(),
            driver_info: driver_info.into(),
            backend: wgpu::Backend::Dx12,
        }
    }

    #[test]
    fn a_summary_says_what_kind_of_card_it_is() {
        for (device, kind) in [
            (wgpu::DeviceType::IntegratedGpu, AdapterKind::Integrated),
            (wgpu::DeviceType::DiscreteGpu, AdapterKind::Dedicated),
            (wgpu::DeviceType::VirtualGpu, AdapterKind::Virtual),
            (wgpu::DeviceType::Cpu, AdapterKind::Software),
            (wgpu::DeviceType::Other, AdapterKind::Other),
        ] {
            assert_eq!(AdapterSummary::of(&info(device, "", "")).kind, kind);
        }
    }

    #[test]
    fn a_summary_is_tidy_and_names_the_card_by_its_pci_ids() {
        let s = AdapterSummary::of(&info(wgpu::DeviceType::IntegratedGpu, "", ""));
        assert_eq!(s.name, "Example Graphics 770");
        assert_eq!(s.backend, "Dx12");
        assert!(s.is_card(0x8086, 0x4680));
        assert!(!s.is_card(0x10de, 0x4680), "a different vendor is a different card");
        assert!(!s.is_card(0x8086, 0x0001), "a different device is a different card");
    }

    #[test]
    fn the_driver_line_uses_whatever_the_driver_reported() {
        let line = |d, i| AdapterSummary::of(&info(wgpu::DeviceType::Other, d, i)).driver;
        assert_eq!(line("", ""), "");
        assert_eq!(line("Driver", ""), "Driver");
        assert_eq!(line("", "31.0.101"), "31.0.101");
        assert_eq!(line("Driver", "31.0.101"), "Driver 31.0.101");
    }
}
