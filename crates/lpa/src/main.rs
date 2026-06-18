mod cfg;
mod chain;
mod exec;
mod position;
mod proto;
mod serve;
mod strategy;

#[cfg(test)]
mod pipeline_tests;

use std::sync::Arc;

use clap::{Parser, Subcommand, ValueEnum};

use chain::config::ChainConfig;
use position::tracker::{compute_position_id, PositionRow, Tracker};

#[derive(Parser)]
#[command(name = "lpa", version, about = "LP Position Autopilot")]
struct Cli {
    #[arg(long, global = true, help = "path to lpa.toml")]
    config: Option<String>,
    #[arg(long, global = true, value_enum, default_value_t = LogFormat::Json)]
    log_format: LogFormat,
    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Copy, ValueEnum)]
enum LogFormat {
    Json,
    Pretty,
}

#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long, env = "LPA_GRPC_PORT", default_value_t = 50051)]
        port: u16,
        #[arg(long, env = "LPA_GRPC_HOST", default_value = "127.0.0.1")]
        host: String,
        #[arg(long, env = "LPA_DB")]
        db: Option<String>,
    },
    Watch {
        #[arg(long)]
        chain: Option<String>,
        #[arg(long, env = "LPA_DB")]
        db: Option<String>,
    },
    #[command(allow_negative_numbers = true)]
    Register {
        #[arg(long)]
        chain: Option<String>,
        #[arg(long)]
        pool_id: String,
        #[arg(long)]
        owner: String,
        #[arg(long)]
        tick_lower: i32,
        #[arg(long)]
        tick_upper: i32,
        #[arg(long, env = "LPA_DB")]
        db: Option<String>,
    },
    #[command(allow_negative_numbers = true)]
    Rebalance {
        #[arg(long)]
        chain: Option<String>,
        #[arg(long)]
        position_id: String,
        #[arg(long)]
        new_lower: i32,
        #[arg(long)]
        new_upper: i32,
        #[arg(long, env = "AUTOPILOT_HOOK_ADDRESS")]
        hook: Option<String>,
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        slippage_bps: Option<u32>,
        #[arg(long, env = "DEFAULT_MAX_GAS_USD")]
        max_gas_usd: Option<f64>,
        #[arg(long, env = "ETH_PRICE_USD")]
        eth_price_usd: Option<f64>,
    },
    Simulate {
        #[arg(long)]
        position_id: String,
        #[arg(long, default_value_t = 60)]
        tick_spacing: i32,
        #[arg(long, default_value_t = 3000)]
        fee: u32,
        #[arg(long, default_value_t = 200)]
        window: usize,
        #[arg(long, env = "LPA_DB")]
        db: Option<String>,
    },
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
}

#[derive(Subcommand)]
enum ConfigAction {
    Init {
        #[arg(long)]
        force: bool,
    },
    Show,
    Path,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    let cli = Cli::parse();
    init_logging(cli.log_format);

    match cli.command {
        Command::Serve { port, host, db } => {
            let file = cfg::load(cli.config.as_deref())?;
            let db = db.or(file.db).unwrap_or_else(|| "lpa.sqlite".into());
            serve::run(&host, port, &db).await?;
        }
        Command::Watch { chain, db } => {
            let file = cfg::load(cli.config.as_deref())?;
            let chain = chain.or(file.chain).unwrap_or_else(|| "base".into());
            let db = db.or(file.db).unwrap_or_else(|| "lpa.sqlite".into());
            let cfg = ChainConfig::from_name(&chain)?;
            let tracker = Arc::new(Tracker::open(&db)?);
            tracing::info!(chain = cfg.name, positions = tracker.count_positions()?, "starting watch");
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
            let file = cfg::load(cli.config.as_deref())?;
            let chain = chain.or(file.chain).unwrap_or_else(|| "base".into());
            let db = db.or(file.db).unwrap_or_else(|| "lpa.sqlite".into());
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
        Command::Rebalance {
            chain,
            position_id,
            new_lower,
            new_upper,
            hook,
            dry_run,
            slippage_bps,
            max_gas_usd,
            eth_price_usd,
        } => {
            if new_lower >= new_upper {
                anyhow::bail!("new_lower must be < new_upper");
            }
            let file = cfg::load(cli.config.as_deref())?;
            let chain = chain.or(file.chain).unwrap_or_else(|| "base".into());
            let slippage_bps = slippage_bps.or(file.slippage_bps).unwrap_or(100);
            let max_gas_usd = max_gas_usd.or(file.max_gas_usd).unwrap_or(50.0);
            let eth_price_usd = eth_price_usd.or(file.eth_price_usd).unwrap_or(3000.0);
            let hook = hook
                .or(file.hook)
                .ok_or_else(|| anyhow::anyhow!("hook address required (--hook, AUTOPILOT_HOOK_ADDRESS, or config)"))?;

            let cfg = ChainConfig::from_name(&chain)?;
            let rpc = cfg.http_url()?;
            let pk = std::env::var("REBALANCER_PRIVATE_KEY")
                .map_err(|_| anyhow::anyhow!("REBALANCER_PRIVATE_KEY not set"))?;
            tracing::warn!("rebalancer key loaded from env (plaintext) — testnet only; use a keystore or external signer in production");
            let hook_addr: alloy::primitives::Address =
                hook.parse().map_err(|_| anyhow::anyhow!("invalid hook address: {hook}"))?;
            let pid: alloy::primitives::B256 = position_id
                .parse()
                .map_err(|_| anyhow::anyhow!("invalid --position-id (expect 0x + 64 hex)"))?;
            let private = std::env::var("FLASHBOTS_RPC").ok().filter(|s| !s.trim().is_empty());
            let executor = exec::Executor::connect(&rpc, &pk, hook_addr, private).await?;
            tracing::info!(signer = %executor.signer(), hook = %hook_addr, chain = cfg.name, "executor ready");

            if dry_run {
                let s = executor.simulate(pid, new_lower, new_upper).await?;
                if s.ok {
                    println!("DRY-RUN OK | est_gas={} | quoted_liquidity={}", s.gas_estimate, s.quoted_liquidity);
                } else {
                    println!("DRY-RUN REVERT | {}", s.revert.unwrap_or_default());
                }
            } else {
                let r = executor
                    .execute(pid, new_lower, new_upper, slippage_bps, max_gas_usd, eth_price_usd)
                    .await?;
                println!(
                    "{} | tx={} | gas_used={}",
                    if r.success { "SUCCESS" } else { "FAILED" },
                    r.tx_hash,
                    r.gas_used
                );
            }
        }
        Command::Simulate {
            position_id,
            tick_spacing,
            fee,
            window,
            db,
        } => {
            let file = cfg::load(cli.config.as_deref())?;
            let db = db.or(file.db).unwrap_or_else(|| "lpa.sqlite".into());
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
            let config = strategy::config_from(
                file.il_threshold_pct,
                file.bollinger_period,
                file.bollinger_stddev,
            );
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
        Command::Config { action } => match action {
            ConfigAction::Init { force } => {
                let path = cfg::init(cli.config.as_deref(), force)?;
                println!("wrote config template to {path}");
            }
            ConfigAction::Show => {
                let file = cfg::load(cli.config.as_deref())?;
                println!("path: {}", cfg::resolved_path(cli.config.as_deref()));
                println!("{}", toml::to_string_pretty(&file)?);
            }
            ConfigAction::Path => println!("{}", cfg::resolved_path(cli.config.as_deref())),
        },
    }
    Ok(())
}

fn init_logging(format: LogFormat) {
    let filter = tracing_subscriber::EnvFilter::from_default_env();
    let builder = tracing_subscriber::fmt().with_env_filter(filter);
    match format {
        LogFormat::Json => builder.json().init(),
        LogFormat::Pretty => builder.init(),
    }
}
