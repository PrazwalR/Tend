use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub chain: Option<String>,
    pub db: Option<String>,
    pub hook: Option<String>,
    pub max_gas_usd: Option<f64>,
    pub eth_price_usd: Option<f64>,
    pub slippage_bps: Option<u32>,
    pub il_threshold_pct: Option<f64>,
    pub bollinger_period: Option<u32>,
    pub bollinger_stddev: Option<f64>,
}

pub const TEMPLATE: &str = r#"# lpa config — every key optional. Precedence: CLI flag > env var > this file > built-in default.
# chain = "base"
# db = "lpa.sqlite"
# hook = "0x0000000000000000000000000000000000000000"  # AutopilotHook address
# max_gas_usd = 50.0
# eth_price_usd = 3000.0
# slippage_bps = 100        # rebalance min-liquidity floor
# il_threshold_pct = 5.0
# bollinger_period = 200
# bollinger_stddev = 2.0
"#;

pub fn default_path() -> Option<String> {
    if std::path::Path::new("lpa.toml").exists() {
        return Some("lpa.toml".to_string());
    }
    std::env::var("HOME").ok().map(|h| format!("{h}/.config/lpa/lpa.toml"))
}

pub fn resolved_path(explicit: Option<&str>) -> String {
    explicit
        .map(str::to_string)
        .or_else(default_path)
        .unwrap_or_else(|| "lpa.toml".to_string())
}

pub fn load(explicit: Option<&str>) -> Result<Config> {
    let path = match explicit {
        Some(p) => Some(p.to_string()),
        None => default_path(),
    };
    match path {
        Some(p) if std::path::Path::new(&p).exists() => {
            let raw = std::fs::read_to_string(&p).with_context(|| format!("reading config {p}"))?;
            toml::from_str(&raw).with_context(|| format!("parsing config {p}"))
        }
        Some(p) if explicit.is_some() => anyhow::bail!("config file not found: {p}"),
        _ => Ok(Config::default()),
    }
}

pub fn init(explicit: Option<&str>, force: bool) -> Result<String> {
    let path = explicit.map(str::to_string).unwrap_or_else(|| "lpa.toml".to_string());
    if std::path::Path::new(&path).exists() && !force {
        anyhow::bail!("{path} already exists (use --force to overwrite)");
    }
    if let Some(parent) = std::path::Path::new(&path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
        }
    }
    std::fs::write(&path, TEMPLATE).with_context(|| format!("writing {path}"))?;
    Ok(path)
}
