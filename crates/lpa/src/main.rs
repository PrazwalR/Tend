mod chain;
mod position;
mod proto;
mod serve;
mod strategy;

#[cfg(test)]
mod pipeline_tests;

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
    Simulate {
        #[arg(long)]
        position_id: String,
        #[arg(long, default_value_t = 60)]
        tick_spacing: i32,
        #[arg(long, default_value_t = 3000)]
        fee: u32,
        #[arg(long, default_value_t = 200)]
        window: usize,
        #[arg(long, env = "LPA_DB", default_value = "lpa.sqlite")]
        db: String,
    },
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
                entry_tick: None,
            })?;
            println!("registered position {position_id} on {}", cfg.name);
        }
        Command::Rebalance => println!("rebalance (unimplemented)"),
        Command::Simulate {
            position_id,
            tick_spacing,
            fee,
            window,
            db,
        } => {
            let tracker = Tracker::open(&db)?;
            let pos = tracker
                .get_position(&position_id)?
                .ok_or_else(|| anyhow::anyhow!("position not found: {position_id}"))?;
            let ticks = tracker.recent_ticks(&pos.pool_id, window)?;
            let current_tick = pos
                .current_tick
                .or_else(|| ticks.last().copied())
                .ok_or_else(|| anyhow::anyhow!("no tick data for pool {}", pos.pool_id))?;
            let entry_tick = pos.entry_tick.unwrap_or((pos.tick_lower + pos.tick_upper) / 2);
            let config = strategy::default_config();
            let input = strategy::DecideInput {
                pool_id: &pos.pool_id,
                chain_id: &pos.chain_id,
                current_tick,
                entry_tick,
                cur_lower: pos.tick_lower,
                cur_upper: pos.tick_upper,
                tick_spacing,
                fee_pips: fee,
                ticks: &ticks,
                config: &config,
            };
            match strategy::StrategyEngine::default().decide(&input, &strategy::StubCostModel) {
                Some(d) => println!(
                    "REBALANCE [{}, {}] -> [{}, {}] | {} | ~${:.2} | {:?}",
                    pos.tick_lower, pos.tick_upper, d.new_lower, d.new_upper, d.reason, d.est_cost_usd, d.strategy
                ),
                None => println!("HOLD: no EV-positive rebalance for {position_id}"),
            }
        }
        Command::Config => println!("config (unimplemented)"),
    }
    Ok(())
}
