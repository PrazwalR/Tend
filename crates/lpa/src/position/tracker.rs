use std::sync::Mutex;

use alloy::primitives::{keccak256, Address, B256};
use anyhow::{anyhow, Result};
use rusqlite::{params, Connection, Row};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS positions (
    position_id     TEXT PRIMARY KEY,
    owner           TEXT NOT NULL,
    pool_id         TEXT NOT NULL,
    chain_id        TEXT NOT NULL,
    tick_lower      INTEGER NOT NULL,
    tick_upper      INTEGER NOT NULL,
    current_tick    INTEGER,
    in_range        INTEGER NOT NULL DEFAULT 0,
    entry_tick      INTEGER,
    last_updated_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_positions_pool ON positions(pool_id);
CREATE TABLE IF NOT EXISTS tick_history (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    pool_id      TEXT NOT NULL,
    tick         INTEGER NOT NULL,
    block_number INTEGER NOT NULL,
    observed_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tick_pool ON tick_history(pool_id, block_number);
CREATE TABLE IF NOT EXISTS configs (
    position_id       TEXT PRIMARY KEY,
    strategy          INTEGER NOT NULL,
    il_threshold_pct  REAL NOT NULL,
    fee_capture_ratio REAL NOT NULL,
    bollinger_period  INTEGER NOT NULL,
    bollinger_stddev  REAL NOT NULL,
    max_gas_usd       REAL NOT NULL,
    auto_compound_fees INTEGER NOT NULL,
    use_flashbots     INTEGER NOT NULL
);
";

#[derive(Debug, Clone, PartialEq)]
pub struct PositionRow {
    pub position_id: String,
    pub owner: String,
    pub pool_id: String,
    pub chain_id: String,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub current_tick: Option<i32>,
    pub in_range: bool,
    pub entry_tick: Option<i32>,
}

#[derive(Debug, Clone)]
pub struct TickCross {
    pub position_id: String,
    pub was_in_range: bool,
    pub now_in_range: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ConfigRow {
    pub strategy: i32,
    pub il_threshold_pct: f64,
    pub fee_capture_ratio: f64,
    pub bollinger_period: u32,
    pub bollinger_stddev: f64,
    pub max_gas_usd: f64,
    pub auto_compound_fees: bool,
    pub use_flashbots: bool,
}

pub struct Tracker {
    conn: Mutex<Connection>,
}

impl Tracker {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    #[allow(dead_code)]
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    pub fn register(&self, p: &PositionRow) -> Result<()> {
        let entry = p.entry_tick.unwrap_or((p.tick_lower + p.tick_upper) / 2);
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO positions
             (position_id, owner, pool_id, chain_id, tick_lower, tick_upper, current_tick, in_range, entry_tick, last_updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, strftime('%s','now'))",
            params![
                p.position_id, p.owner, p.pool_id, p.chain_id,
                p.tick_lower, p.tick_upper, p.current_tick, p.in_range as i64, entry
            ],
        )?;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn get_position(&self, position_id: &str) -> Result<Option<PositionRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT position_id, owner, pool_id, chain_id, tick_lower, tick_upper, current_tick, in_range, entry_tick
             FROM positions WHERE position_id = ?1",
        )?;
        let mut rows = stmt.query_map(params![position_id], row_to_position)?;
        match rows.next() {
            Some(r) => Ok(Some(r?)),
            None => Ok(None),
        }
    }

    pub fn positions_for_pool(&self, pool_id: &str) -> Result<Vec<PositionRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT position_id, owner, pool_id, chain_id, tick_lower, tick_upper, current_tick, in_range, entry_tick
             FROM positions WHERE pool_id = ?1",
        )?;
        let rows = stmt.query_map(params![pool_id], row_to_position)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn update_pool_tick(&self, pool_id: &str, tick: i32) -> Result<Vec<TickCross>> {
        let positions = self.positions_for_pool(pool_id)?;
        let mut crosses = Vec::with_capacity(positions.len());
        let conn = self.conn.lock().unwrap();
        for p in positions {
            let now_in_range = tick >= p.tick_lower && tick <= p.tick_upper;
            crosses.push(TickCross {
                position_id: p.position_id.clone(),
                was_in_range: p.in_range,
                now_in_range,
            });
            conn.execute(
                "UPDATE positions SET current_tick = ?1, in_range = ?2, last_updated_at = strftime('%s','now')
                 WHERE position_id = ?3",
                params![tick, now_in_range as i64, p.position_id],
            )?;
        }
        Ok(crosses)
    }

    pub fn record_tick(&self, pool_id: &str, tick: i32, block: u64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO tick_history (pool_id, tick, block_number, observed_at)
             VALUES (?1, ?2, ?3, strftime('%s','now'))",
            params![pool_id, tick, block as i64],
        )?;
        Ok(())
    }

    pub fn recent_ticks(&self, pool_id: &str, n: usize) -> Result<Vec<i32>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT tick FROM tick_history WHERE pool_id = ?1 ORDER BY block_number DESC, id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![pool_id, n as i64], |r| r.get::<_, i32>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        out.reverse();
        Ok(out)
    }

    pub fn set_config(&self, position_id: &str, c: &ConfigRow) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO configs
             (position_id, strategy, il_threshold_pct, fee_capture_ratio, bollinger_period,
              bollinger_stddev, max_gas_usd, auto_compound_fees, use_flashbots)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                position_id, c.strategy, c.il_threshold_pct, c.fee_capture_ratio,
                c.bollinger_period, c.bollinger_stddev, c.max_gas_usd,
                c.auto_compound_fees as i64, c.use_flashbots as i64
            ],
        )?;
        Ok(())
    }

    pub fn get_config(&self, position_id: &str) -> Result<Option<ConfigRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT strategy, il_threshold_pct, fee_capture_ratio, bollinger_period,
                    bollinger_stddev, max_gas_usd, auto_compound_fees, use_flashbots
             FROM configs WHERE position_id = ?1",
        )?;
        let mut rows = stmt.query_map(params![position_id], |row| {
            Ok(ConfigRow {
                strategy: row.get(0)?,
                il_threshold_pct: row.get(1)?,
                fee_capture_ratio: row.get(2)?,
                bollinger_period: row.get::<_, i64>(3)? as u32,
                bollinger_stddev: row.get(4)?,
                max_gas_usd: row.get(5)?,
                auto_compound_fees: row.get::<_, i64>(6)? != 0,
                use_flashbots: row.get::<_, i64>(7)? != 0,
            })
        })?;
        match rows.next() {
            Some(r) => Ok(Some(r?)),
            None => Ok(None),
        }
    }

    pub fn delete_position(&self, position_id: &str) -> Result<bool> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM configs WHERE position_id = ?1", params![position_id])?;
        let n = conn.execute("DELETE FROM positions WHERE position_id = ?1", params![position_id])?;
        Ok(n > 0)
    }

    pub fn all_position_ids(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT position_id FROM positions")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn count_positions(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM positions", [], |r| r.get(0))?;
        Ok(n)
    }
}

fn row_to_position(row: &Row) -> rusqlite::Result<PositionRow> {
    Ok(PositionRow {
        position_id: row.get(0)?,
        owner: row.get(1)?,
        pool_id: row.get(2)?,
        chain_id: row.get(3)?,
        tick_lower: row.get(4)?,
        tick_upper: row.get(5)?,
        current_tick: row.get(6)?,
        in_range: row.get::<_, i64>(7)? != 0,
        entry_tick: row.get(8)?,
    })
}

fn int24_be3(v: i32) -> [u8; 3] {
    let b = v.to_be_bytes();
    [b[1], b[2], b[3]]
}

pub fn compute_position_id(owner: &str, pool_id: &str, tick_lower: i32, tick_upper: i32) -> Result<String> {
    let owner: Address = owner.parse().map_err(|_| anyhow!("invalid owner address: {owner}"))?;
    let pid: B256 = pool_id.parse().map_err(|_| anyhow!("invalid pool id: {pool_id}"))?;
    let mut buf = Vec::with_capacity(20 + 32 + 3 + 3);
    buf.extend_from_slice(owner.as_slice());
    buf.extend_from_slice(pid.as_slice());
    buf.extend_from_slice(&int24_be3(tick_lower));
    buf.extend_from_slice(&int24_be3(tick_upper));
    Ok(format!("{:#x}", keccak256(&buf)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(id: &str, pool: &str, lower: i32, upper: i32) -> PositionRow {
        PositionRow {
            position_id: id.into(),
            owner: "0x1111111111111111111111111111111111111111".into(),
            pool_id: pool.into(),
            chain_id: "8453".into(),
            tick_lower: lower,
            tick_upper: upper,
            current_tick: None,
            in_range: false,
            entry_tick: None,
        }
    }

    #[test]
    fn register_and_get() {
        let t = Tracker::open_in_memory().unwrap();
        t.register(&sample("0xabc", "0xpool", 100, 200)).unwrap();
        let got = t.get_position("0xabc").unwrap().unwrap();
        assert_eq!(got.tick_lower, 100);
        assert_eq!(got.tick_upper, 200);
        assert_eq!(t.count_positions().unwrap(), 1);
    }

    #[test]
    fn tick_update_flips_in_range() {
        let t = Tracker::open_in_memory().unwrap();
        t.register(&sample("0xabc", "0xpool", 100, 200)).unwrap();

        let crosses = t.update_pool_tick("0xpool", 150).unwrap();
        assert_eq!(crosses.len(), 1);
        assert!(!crosses[0].was_in_range);
        assert!(crosses[0].now_in_range);
        assert!(t.get_position("0xabc").unwrap().unwrap().in_range);

        let crosses = t.update_pool_tick("0xpool", 250).unwrap();
        assert!(crosses[0].was_in_range);
        assert!(!crosses[0].now_in_range);
        assert!(!t.get_position("0xabc").unwrap().unwrap().in_range);
    }

    #[test]
    fn boundary_is_inclusive() {
        let t = Tracker::open_in_memory().unwrap();
        t.register(&sample("0xabc", "0xpool", 100, 200)).unwrap();
        assert!(t.update_pool_tick("0xpool", 100).unwrap()[0].now_in_range);
        assert!(t.update_pool_tick("0xpool", 200).unwrap()[0].now_in_range);
        assert!(!t.update_pool_tick("0xpool", 99).unwrap()[0].now_in_range);
    }

    #[test]
    fn persists_across_reopen() {
        let f = tempfile::NamedTempFile::new().unwrap();
        let path = f.path().to_str().unwrap().to_string();
        {
            let t = Tracker::open(&path).unwrap();
            t.register(&sample("0xabc", "0xpool", 100, 200)).unwrap();
            t.update_pool_tick("0xpool", 150).unwrap();
        }
        let t = Tracker::open(&path).unwrap();
        let got = t.get_position("0xabc").unwrap().unwrap();
        assert_eq!(got.current_tick, Some(150));
        assert!(got.in_range);
    }

    #[test]
    fn config_roundtrip_and_delete() {
        let t = Tracker::open_in_memory().unwrap();
        t.register(&sample("0xabc", "0xpool", 100, 200)).unwrap();
        let c = ConfigRow {
            strategy: 1,
            il_threshold_pct: 5.0,
            fee_capture_ratio: 0.5,
            bollinger_period: 200,
            bollinger_stddev: 2.0,
            max_gas_usd: 50.0,
            auto_compound_fees: true,
            use_flashbots: false,
        };
        t.set_config("0xabc", &c).unwrap();
        assert_eq!(t.get_config("0xabc").unwrap().unwrap(), c);

        assert!(t.delete_position("0xabc").unwrap());
        assert!(t.get_position("0xabc").unwrap().is_none());
        assert!(t.get_config("0xabc").unwrap().is_none());
        assert!(!t.delete_position("0xabc").unwrap());
    }

    #[test]
    fn position_id_is_deterministic() {
        let owner = "0x1111111111111111111111111111111111111111";
        let pool = "0x2222222222222222222222222222222222222222222222222222222222222222";
        let a = compute_position_id(owner, pool, -100, 200).unwrap();
        let b = compute_position_id(owner, pool, -100, 200).unwrap();
        let c = compute_position_id(owner, pool, -100, 201).unwrap();
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert!(a.starts_with("0x"));
    }
}
