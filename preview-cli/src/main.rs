// Compile the same implementation as vimg, with only the preview dependencies.
#[path = "../../src/command/preview.rs"]
mod preview;
#[path = "../../src/command/probe.rs"]
mod probe;

use clap::Parser;

#[derive(Parser)]
#[command(version, about)]
enum Command {
    Preview(preview::Preview),
    Probe(probe::Probe),
}

fn main() -> anyhow::Result<()> {
    let command = Command::parse();
    _ = ctrlc::set_handler(|| std::process::exit(1));
    match command {
        Command::Preview(command) => command.run(),
        Command::Probe(command) => command.run(),
    }
}
