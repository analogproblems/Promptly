//! `promptly`, the command-line companion.
//!
//! The vault format is open; this tool is the proof. It reads a vault folder
//! with its passphrase and can inspect, export, import, sync, turn the
//! hosts into an OpenSSH config, remove devices and give the vault a new key. It is a device of its own, with its own
//! small local store, so it merges like any other.

mod commands;

use anyhow::Result;
use clap::{Args, Parser, Subcommand};

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

#[derive(Args, Clone)]
struct VaultArgs {
    /// The vault folder.
    folder: std::path::PathBuf,
    /// Unlock with the recovery code instead of the passphrase (asked for,
    /// or read from PROMPTLY_RECOVERY_CODE).
    #[arg(long)]
    recovery_code: bool,
    /// Read from PROMPTLY_PASSPHRASE, never from the command line, where
    /// anyone on the machine could see it in the process list.
    #[arg(skip = std::env::var("PROMPTLY_PASSPHRASE").ok())]
    passphrase: Option<String>,
    #[arg(skip = std::env::var("PROMPTLY_RECOVERY_CODE").ok())]
    recovery_code_env: Option<String>,
}

#[derive(Subcommand)]
enum Command {
    /// Print the engine version.
    Version,
    /// Parse a `user@host:port` string the way the app does.
    Parse { endpoint: String },
    /// Devices, files, clocks and warnings of a vault.
    Inspect(VaultArgs),
    /// The merged vault as one JSON document on stdout.
    Export {
        #[command(flatten)]
        vault: VaultArgs,
        /// Include secrets (passwords, private keys) in plain text.
        #[arg(long)]
        with_secrets: bool,
    },
    /// Merge a JSON document (as produced by export) into the vault.
    Import {
        #[command(flatten)]
        vault: VaultArgs,
        /// The JSON file; `-` for stdin.
        file: std::path::PathBuf,
    },
    /// Pull and push, so this tool's copy and the vault agree.
    Sync(VaultArgs),
    /// An OpenSSH config for the vault's hosts, on stdout.
    SshConfig {
        #[command(flatten)]
        vault: VaultArgs,
        /// Also write private keys here (owner-only files) and reference them.
        #[arg(long)]
        keys_dir: Option<std::path::PathBuf>,
    },
    /// Re-wrap the vault's key under a new passphrase. Data is untouched.
    ChangePassphrase(VaultArgs),
    /// Give the vault a new key, under a new passphrase and recovery code.
    /// Devices with only the old key can read nothing written afterwards.
    RotateDek(VaultArgs),
    /// The devices that sync with the vault.
    Devices {
        #[command(subcommand)]
        action: DevicesAction,
    },
}

#[derive(Subcommand)]
enum DevicesAction {
    /// Every device, with when it joined and was last seen.
    List(VaultArgs),
    /// Remove a device: what it writes from now on is ignored.
    Remove {
        #[command(flatten)]
        vault: VaultArgs,
        /// The device's id, or its name.
        device: String,
        /// Also give the vault a new key, so the removed device can read
        /// nothing new. Use this for a lost or stolen device.
        #[arg(long)]
        rekey: bool,
    },
}

/// Ask for a new passphrase twice.
fn new_passphrase() -> Result<String> {
    let new = rpassword::prompt_password("New passphrase: ")?;
    let again = rpassword::prompt_password("Again: ")?;
    anyhow::ensure!(new == again, "the two passphrases differ");
    anyhow::ensure!(new.chars().count() >= 8, "use at least eight characters");
    Ok(new)
}

fn print_recovery_code(code: &str) {
    println!("{code}");
    eprintln!(
        "The vault has a new key. Above is its new recovery code: write it down and keep it \
         safe. The old code no longer works. Your other devices ask for the new passphrase \
         once."
    );
}

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    match Cli::parse().command {
        Command::Version => println!("promptly engine {}", env!("CARGO_PKG_VERSION")),
        Command::Parse { endpoint } => match promptly_ssh::Endpoint::parse(&endpoint) {
            Ok(e) => println!("user={} host={} port={}", e.user, e.host, e.port),
            Err(err) => anyhow::bail!("{err}"),
        },
        Command::Inspect(v) => {
            let out = commands::inspect(&v.folder, commands::unlock(&v)?.as_ref())?;
            print!("{out}");
        }
        Command::Export {
            vault,
            with_secrets,
        } => {
            let unlocked = commands::unlock(&vault)?
                .ok_or_else(|| anyhow::anyhow!("a passphrase is needed"))?;
            if with_secrets {
                eprintln!("WARNING: the output contains passwords and private keys in plain text. Treat it like the keys themselves.");
            }
            let json = commands::export(&vault.folder, &unlocked, with_secrets)?;
            println!("{json}");
        }
        Command::Import { vault, file } => {
            let unlocked = commands::unlock(&vault)?
                .ok_or_else(|| anyhow::anyhow!("a passphrase is needed"))?;
            let text = if file.as_os_str() == "-" {
                std::io::read_to_string(std::io::stdin())?
            } else {
                std::fs::read_to_string(&file)?
            };
            let n = commands::import(&vault.folder, &unlocked, &text)?;
            eprintln!("imported {n} records");
        }
        Command::Sync(v) => {
            let unlocked =
                commands::unlock(&v)?.ok_or_else(|| anyhow::anyhow!("a passphrase is needed"))?;
            let report = commands::sync(&v.folder, &unlocked)?;
            eprintln!("{report}");
        }
        Command::SshConfig { vault, keys_dir } => {
            let unlocked = commands::unlock(&vault)?
                .ok_or_else(|| anyhow::anyhow!("a passphrase is needed"))?;
            print!(
                "{}",
                commands::ssh_config(&vault.folder, &unlocked, keys_dir.as_deref())?
            );
        }
        Command::ChangePassphrase(v) => {
            let unlocked = commands::unlock(&v)?
                .ok_or_else(|| anyhow::anyhow!("the current passphrase is needed"))?;
            let new = new_passphrase()?;
            commands::change_passphrase(&v.folder, &unlocked, &new)?;
            eprintln!("passphrase changed");
        }
        Command::RotateDek(v) => {
            let unlocked = commands::unlock(&v)?
                .ok_or_else(|| anyhow::anyhow!("the current passphrase is needed"))?;
            let new = new_passphrase()?;
            print_recovery_code(&commands::rotate_dek(&v.folder, &unlocked, &new)?);
        }
        Command::Devices {
            action: DevicesAction::List(v),
        } => {
            let unlocked =
                commands::unlock(&v)?.ok_or_else(|| anyhow::anyhow!("a passphrase is needed"))?;
            print!("{}", commands::list_devices(&v.folder, &unlocked)?);
        }
        Command::Devices {
            action:
                DevicesAction::Remove {
                    vault,
                    device,
                    rekey,
                },
        } => {
            let unlocked = commands::unlock(&vault)?
                .ok_or_else(|| anyhow::anyhow!("a passphrase is needed"))?;
            // Asked first, so a typo does not leave the job half done.
            let new = rekey.then(new_passphrase).transpose()?;
            let name = commands::remove_device(&vault.folder, &unlocked, &device)?;
            eprintln!("removed {name}");
            if let Some(new) = new {
                print_recovery_code(&commands::rotate_dek(&vault.folder, &unlocked, &new)?);
            }
        }
    }
    Ok(())
}

impl commands::FolderPath for VaultArgs {
    fn folder_path(&self) -> &std::path::Path {
        &self.folder
    }
}

impl commands::Credentials for VaultArgs {
    fn passphrase(&self) -> Option<&str> {
        self.passphrase.as_deref()
    }
    fn wants_recovery_code(&self) -> bool {
        self.recovery_code || self.recovery_code_env.is_some()
    }
    fn recovery_code(&self) -> Option<&str> {
        self.recovery_code_env.as_deref()
    }
}
