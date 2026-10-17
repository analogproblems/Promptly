//! The bridge between the Flutter app and the Rust engine.
//!
//! Everything under `api/` is scanned by `flutter_rust_bridge_codegen` and
//! becomes a Dart function. Keep this crate thin: it adapts, it does not decide.
//! Business logic lives in the other engine crates.

pub mod api;
mod frb_generated;
mod host_plan;
mod ssh_flow;
mod sync_engine;
mod transfers;

/// Engine version, from the workspace manifest.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
