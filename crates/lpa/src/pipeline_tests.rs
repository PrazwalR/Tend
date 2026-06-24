use crate::position::tracker::{PositionRow, Tracker};
use crate::strategy::{default_config, CostModel, DecideInput, StrategyEngine};

struct Cost;
impl CostModel for Cost {
    fn rebalance_cost_usd(&self, _c: &str) -> f64 {
        5.0
    }
    fn volume_usd_per_block(&self, _p: &str) -> f64 {
        50_000.0
    }
}

fn position(pool: &str, lower: i32, upper: i32, entry: i32) -> PositionRow {
    PositionRow {
        position_id: "0xpos".into(),
        owner: "0x1111111111111111111111111111111111111111".into(),
        pool_id: pool.into(),
        chain_id: "8453".into(),
        tick_lower: lower,
        tick_upper: upper,
        current_tick: None,
        in_range: false,
        entry_tick: Some(entry),
        fee: Some(3000),
        tick_spacing: Some(60),
    }
}

fn feed_stream(t: &Tracker, pool: &str) {
    for block in 1000u64..1200 {
        let tick = ((block as i32 * 7) % 11) - 5;
        t.update_pool_tick(pool, tick).unwrap();
        t.record_tick(pool, tick, block).unwrap();
    }
}

fn decide(t: &Tracker, pool: &str) -> Option<crate::strategy::Decision> {
    let p = t.get_position("0xpos").unwrap().unwrap();
    let ticks = t.recent_ticks(pool, 200).unwrap();
    let cfg = default_config();
    let input = DecideInput {
        pool_id: pool,
        chain_id: &p.chain_id,
        current_tick: p.current_tick.unwrap(),
        entry_tick: p.entry_tick.unwrap(),
        cur_lower: p.tick_lower,
        cur_upper: p.tick_upper,
        tick_spacing: 60,
        fee_pips: 3000,
        ticks: &ticks,
        config: &cfg,
    };
    StrategyEngine::default().decide(&input, &Cost)
}

#[test]
fn swap_stream_drives_rebalance_for_oor_position() {
    let t = Tracker::open_in_memory().unwrap();
    let pool = "0xpool";
    t.register(&position(pool, 5000, 6000, 5500)).unwrap();
    feed_stream(&t, pool);

    assert_eq!(t.recent_ticks(pool, 200).unwrap().len(), 200);
    assert!(!t.get_position("0xpos").unwrap().unwrap().in_range);

    let d = decide(&t, pool).expect("OOR position should rebalance");
    assert!(d.new_lower < 0 && d.new_upper > 0);
    assert_eq!(d.new_lower % 60, 0);
    assert_eq!(d.new_upper % 60, 0);
    assert!(d.reason.contains("out of range"));
}

#[test]
fn swap_stream_holds_for_centered_position() {
    let t = Tracker::open_in_memory().unwrap();
    let pool = "0xpool2";
    t.register(&position(pool, -90, 90, 0)).unwrap();
    feed_stream(&t, pool);

    assert!(t.get_position("0xpos").unwrap().unwrap().in_range);
    assert!(decide(&t, pool).is_none());
}

#[test]
fn persistence_then_decision_across_reopen() {
    let f = tempfile::NamedTempFile::new().unwrap();
    let path = f.path().to_str().unwrap().to_string();
    {
        let t = Tracker::open(&path).unwrap();
        t.register(&position("0xpool", 5000, 6000, 5500)).unwrap();
        feed_stream(&t, "0xpool");
    }
    let t = Tracker::open(&path).unwrap();
    assert_eq!(t.recent_ticks("0xpool", 200).unwrap().len(), 200);
    assert!(decide(&t, "0xpool").is_some());
}
