//! `promptly`, the command-line companion.
//!
//! Milestone 2 adds `vault inspect|export|import|sync|ssh-config`. Milestone 0
//! only proves the binary builds against the engine crates.

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "promptly",
    version,
    about = "Command-line companion to the Promptly terminal"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print the engine version.
    Version,
    /// Parse a `user@host:port` string the way the app does.
    Parse { endpoint: String },
    /// Generate a device id as the vault would.
    DeviceId,
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Version => println!("promptly engine {}", env!("CARGO_PKG_VERSION")),
        Command::Parse { endpoint } => match promptly_ssh::Endpoint::parse(&endpoint) {
            Ok(e) => println!("user={} host={} port={}", e.user, e.host, e.port),
            Err(err) => anyhow::bail!("{err}"),
        },
        Command::DeviceId => println!("{}", promptly_vault::DeviceId::generate()),
    }
    Ok(())
}
