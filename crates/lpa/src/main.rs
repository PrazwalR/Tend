mod proto;
mod serve;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "lpa", version, about = "LP Position Autopilot")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long, env = "LPA_GRPC_PORT", default_value_t = 50051)]
        port: u16,
    },
    Watch,
    Register,
    Rebalance,
    Simulate,
    Config,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Serve { port } => serve::run(port).await?,
        Command::Watch => println!("watch (unimplemented)"),
        Command::Register => println!("register (unimplemented)"),
        Command::Rebalance => println!("rebalance (unimplemented)"),
        Command::Simulate => println!("simulate (unimplemented)"),
        Command::Config => println!("config (unimplemented)"),
    }
    Ok(())
}
