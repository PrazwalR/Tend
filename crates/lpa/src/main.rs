mod cfg;
mod chain;
mod exec;
mod position;
mod proto;
mod serve;
mod strategy;

#[cfg(test)]
mod audit_dm_tests;
#[cfg(test)]
mod pipeline_tests;

use std::sync::Arc;

/// An error for logging, with every URL cut to scheme://host. Provider URLs carry
/// the API key in their path, and transport errors echo the URL (full audit DM-8).
pub fn redact(e: &dyn std::fmt::Display) -> String {
    let s = e.to_string();
    let mut out = String::with_capacity(s.len());
    let mut rest = s.as_str();
    while let Some(i) = rest.find("://") {
        let start = rest[..i]
            .rfind(|c: char| !c.is_ascii_alphanumeric())
            .map_or(0, |j| j + 1);
        out.push_str(&rest[..i + 3]);
        let after = &rest[i + 3..];
        let host_end = after
            .find(['/', '?', ' ', ')', '"', '\''])
            .unwrap_or(after.len());
        out.push_str(&after[..host_end]);
        let tail = &after[host_end..];
        let url_end = tail.find([' ', ')', '"', '\'']).unwrap_or(tail.len());
        if url_end > 0 {
            out.push_str("/<redacted>");
        }
        rest = &tail[url_end..];
        let _ = start;
    }
    out.push_str(rest);
    out
}

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
        #[arg(long)]
        chain: Option<String>,
        #[arg(long, env = "AUTOPILOT_HOOK_ADDRESS")]
        hook: Option<String>,
        /// Serve without LPA_API_TOKEN. Anyone who can reach the port can then
        /// register and delete tracked positions.
        #[arg(long)]
        insecure_no_auth: bool,
    },
    Watch {
        #[arg(long)]
        chain: Option<String>,
        #[arg(long, env = "LPA_DB")]
        db: Option<String>,
        #[arg(long, env = "AUTOPILOT_HOOK_ADDRESS")]
        hook: Option<String>,
        #[arg(
            long,
            help = "send real rebalance txs for indexed positions (requires --hook + REBALANCER_PRIVATE_KEY)"
        )]
        execute: bool,
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
        #[arg(long)]
        fee: Option<u32>,
        #[arg(long)]
        tick_spacing: Option<i32>,
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
        #[arg(long)]
        tick_spacing: Option<i32>,
        #[arg(long)]
        fee: Option<u32>,
        #[arg(long, default_value_t = 200)]
        window: usize,
        #[arg(
            long,
            env = "LPA_POSITION_VALUE_USD",
            help = "USD value backing the position; enables the IL/slippage/MEV terms of the EV gate"
        )]
        position_value_usd: Option<f64>,
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
    // Only ./.env. `dotenv()` walks up through parent directories, so a .env
    // anywhere above the working directory could supply the signing key, the
    // RPC URLs or the hook address (full audit, daemon Info).
    dotenvy::from_path(".env").ok();
    let cli = Cli::parse();
    init_logging(cli.log_format);

    match cli.command {
        Command::Serve {
            port,
            host,
            db,
            chain,
            hook,
            insecure_no_auth,
        } => {
            let file = cfg::load(cli.config.as_deref())?;
            let db = db.or(file.db).unwrap_or_else(|| "lpa.sqlite".into());
            let chain = chain.or(file.chain).unwrap_or_else(|| "base".into());
            let hook_addr = hook
                .or(file.hook)
                .filter(|h| !h.trim().is_empty())
                .map(|h| h.parse::<alloy::primitives::Address>())
                .transpose()
                .map_err(|_| anyhow::anyhow!("invalid hook address"))?;
            serve::run(&host, port, &db, &chain, hook_addr, insecure_no_auth).await?;
        }
        Command::Watch {
            chain,
            db,
            hook,
            execute,
        } => {
            let file = cfg::load(cli.config.as_deref())?;
            let chain = chain
                .or(file.chain.clone())
                .unwrap_or_else(|| "base".into());
            let db = db
                .or(file.db.clone())
                .unwrap_or_else(|| "lpa.sqlite".into());
            let hook_addr = hook
                .or(file.hook.clone())
                .filter(|h| !h.trim().is_empty())
                .map(|h| h.parse::<alloy::primitives::Address>())
                .transpose()
                .map_err(|_| anyhow::anyhow!("invalid hook address"))?;
            let cfg = ChainConfig::from_name(&chain)?;
            let tracker = Arc::new(Tracker::open(&db)?);

            let eth_seed = file
                .eth_price_usd
                .or_else(|| {
                    std::env::var("ETH_PRICE_USD")
                        .ok()
                        .and_then(|v| v.parse().ok())
                })
                .unwrap_or(exec::DEFAULT_ETH_PRICE_USD);
            let eth_price = chain::oracle::connect_eth_price(
                cfg.http_url().ok(),
                cfg.addrs.eth_usd_feed,
                eth_seed,
            )
            .await;

            let intent_tx = if execute {
                let hook_addr =
                    hook_addr.ok_or_else(|| anyhow::anyhow!("--execute requires --hook"))?;
                let pk = std::env::var("REBALANCER_PRIVATE_KEY")
                    .map_err(|_| anyhow::anyhow!("--execute requires REBALANCER_PRIVATE_KEY"))?;
                let rpc = cfg.http_url()?;
                let private = std::env::var("FLASHBOTS_RPC")
                    .ok()
                    .filter(|s| !s.trim().is_empty());
                let executor =
                    exec::Executor::connect(&rpc, &pk, hook_addr, private, cfg.chain_id).await?;
                let auto = exec::AutoExec {
                    max_gas_usd: file
                        .max_gas_usd
                        .or_else(|| {
                            std::env::var("DEFAULT_MAX_GAS_USD")
                                .ok()
                                .and_then(|v| v.parse().ok())
                        })
                        .unwrap_or(exec::DEFAULT_MAX_GAS_USD),
                    eth_price: eth_price.clone(),
                    min_interval: std::time::Duration::from_secs(
                        std::env::var("LPA_AUTO_INTERVAL_SECS")
                            .ok()
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(exec::DEFAULT_AUTO_INTERVAL_SECS),
                    ),
                };
                let (tx, rx) = tokio::sync::mpsc::channel(exec::AUTO_INTENT_CHANNEL_CAP);
                tokio::spawn(exec::run_executor_loop(rx, executor, auto));
                Some(tx)
            } else {
                None
            };

            tracing::info!(
                chain = cfg.name,
                positions = tracker.count_positions()?,
                indexing_hook = hook_addr.is_some(),
                auto_execute = execute,
                "starting watch"
            );
            chain::subscriber::run_watch(cfg, tracker, hook_addr, intent_tx, eth_price).await?;
        }
        Command::Register {
            chain,
            pool_id,
            owner,
            tick_lower,
            tick_upper,
            fee,
            tick_spacing,
            db,
        } => {
            if tick_lower >= tick_upper {
                anyhow::bail!("tick_lower must be < tick_upper");
            }
            if !strategy::ticks_in_domain(&[tick_lower, tick_upper]) {
                anyhow::bail!("ticks outside the tick domain [-887272, 887272]");
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
                fee,
                tick_spacing,
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
            let slippage_bps = slippage_bps
                .or(file.slippage_bps)
                .unwrap_or(exec::DEFAULT_SLIPPAGE_BPS);
            let max_gas_usd = max_gas_usd
                .or(file.max_gas_usd)
                .unwrap_or(exec::DEFAULT_MAX_GAS_USD);
            let eth_price_usd = eth_price_usd
                .or(file.eth_price_usd)
                .unwrap_or(exec::DEFAULT_ETH_PRICE_USD);
            let hook = hook.or(file.hook).ok_or_else(|| {
                anyhow::anyhow!("hook address required (--hook, AUTOPILOT_HOOK_ADDRESS, or config)")
            })?;

            let cfg = ChainConfig::from_name(&chain)?;
            let rpc = cfg.http_url()?;
            let pk = std::env::var("REBALANCER_PRIVATE_KEY")
                .map_err(|_| anyhow::anyhow!("REBALANCER_PRIVATE_KEY not set"))?;
            tracing::warn!("rebalancer key loaded from env (plaintext) — testnet only; use a keystore or external signer in production");
            let hook_addr: alloy::primitives::Address = hook
                .parse()
                .map_err(|_| anyhow::anyhow!("invalid hook address: {hook}"))?;
            let pid: alloy::primitives::B256 = position_id
                .parse()
                .map_err(|_| anyhow::anyhow!("invalid --position-id (expect 0x + 64 hex)"))?;
            let private = std::env::var("FLASHBOTS_RPC")
                .ok()
                .filter(|s| !s.trim().is_empty());
            let executor =
                exec::Executor::connect(&rpc, &pk, hook_addr, private, cfg.chain_id).await?;
            let eth_price = chain::oracle::connect_eth_price(
                Some(rpc.clone()),
                cfg.addrs.eth_usd_feed,
                eth_price_usd,
            )
            .await;
            tracing::info!(signer = %executor.signer(), hook = %hook_addr, chain = cfg.name, "executor ready");

            if dry_run {
                let s = executor.simulate(pid, new_lower, new_upper).await?;
                if s.ok {
                    println!(
                        "DRY-RUN OK | est_gas={} | quoted_liquidity={}",
                        s.gas_estimate, s.quoted_liquidity
                    );
                } else {
                    println!("DRY-RUN REVERT | {}", s.revert.unwrap_or_default());
                }
            } else {
                let r = executor
                    .execute(
                        pid,
                        new_lower,
                        new_upper,
                        // A human running `lpa rebalance` asked for a floor; keep it.
                        Some(slippage_bps),
                        max_gas_usd,
                        &eth_price,
                    )
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
            position_value_usd,
            db,
        } => {
            let file = cfg::load(cli.config.as_deref())?;
            let db = db.or(file.db).unwrap_or_else(|| "lpa.sqlite".into());
            let tracker = Tracker::open(&db)?;
            let pos = tracker
                .get_position(&position_id)?
                .ok_or_else(|| anyhow::anyhow!("position not found: {position_id}"))?;
            let ticks = tracker.recent_ticks(&pos.pool_id, window)?;
            let weighted = tracker.recent_ticks_weighted(&pos.pool_id, window)?;
            let current_tick = pos
                .current_tick
                .or_else(|| ticks.last().copied())
                .ok_or_else(|| anyhow::anyhow!("no tick data for pool {}", pos.pool_id))?;
            let entry_tick = pos
                .entry_tick
                .unwrap_or((pos.tick_lower + pos.tick_upper) / 2);
            let tick_spacing = tick_spacing
                .or(pos.tick_spacing)
                .unwrap_or(strategy::DEFAULT_TICK_SPACING);
            let fee_pips = fee.or(pos.fee).unwrap_or(strategy::DEFAULT_FEE_PIPS);
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
                fee_pips,
                ticks: &ticks,
                weighted: &weighted,
                config: &config,
                position_value_usd: position_value_usd.unwrap_or(0.0),
            };
            match strategy::StrategyEngine::default().decide(&input, &strategy::EstimateCostModel) {
                Some(d) => println!(
                    "REBALANCE [{}, {}] -> [{}, {}] | {} | ~${:.2} | {:?}",
                    pos.tick_lower,
                    pos.tick_upper,
                    d.new_lower,
                    d.new_upper,
                    d.reason,
                    d.est_cost_usd,
                    d.strategy
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
