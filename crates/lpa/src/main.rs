mod chain;
mod position;
mod proto;
mod serve;

use std::sync::Arc;

use clap::{Parser, Subcommand};

use chain::config::ChainConfig;
use position::tracker::{compute_position_id, PositionRow, Tracker};

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
    Watch {
        #[arg(long, default_value = "base")]
        chain: String,
        #[arg(long, env = "LPA_DB", default_value = "lpa.sqlite")]
        db: String,
    },
    #[command(allow_negative_numbers = true)]
    Register {
        #[arg(long, default_value = "base")]
        chain: String,
        #[arg(long)]
        pool_id: String,
        #[arg(long)]
        owner: String,
        #[arg(long)]
        tick_lower: i32,
        #[arg(long)]
        tick_upper: i32,
        #[arg(long, env = "LPA_DB", default_value = "lpa.sqlite")]
        db: String,
    },
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
        Command::Watch { chain, db } => {
            let cfg = ChainConfig::from_name(&chain)?;
            let tracker = Arc::new(Tracker::open(&db)?);
            tracing::info!(
                chain = cfg.name,
                positions = tracker.count_positions()?,
                "starting watch"
            );
            chain::subscriber::run_watch(cfg, tracker).await?;
        }
        Command::Register {
            chain,
            pool_id,
            owner,
            tick_lower,
            tick_upper,
            db,
        } => {
            if tick_lower >= tick_upper {
                anyhow::bail!("tick_lower must be < tick_upper");
            }
            let cfg = ChainConfig::from_name(&chain)?;
            let tracker = Tracker::open(&db)?;
            let position_id = compute_position_id(&owner, &pool_id, tick_lower, tick_upper)?;
            tracker.register(&PositionRow {
                position_id: position_id.clone(),
                owner,
                pool_id,
                chain_id: cfg.chain_id.to_string(),
                tick_lower,
                tick_upper,
                current_tick: None,
                in_range: false,
            })?;
            println!("registered position {position_id} on {}", cfg.name);
        }
        Command::Rebalance => println!("rebalance (unimplemented)"),
        Command::Simulate => println!("simulate (unimplemented)"),
        Command::Config => println!("config (unimplemented)"),
    }
    Ok(())
}
