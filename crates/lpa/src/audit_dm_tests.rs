//! PoCs for the daemon-security audit (DM-*). The anvil tests are `#[ignore]`:
//! they need `anvil` and `python3` on PATH and mutate process env, so run them
//! single-threaded:
//!
//!   cargo test -p lpa audit_dm -- --ignored --test-threads=1 --nocapture
//!
//! Plain local anvil with its default dev key only; never a fork or a real RPC.

use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use alloy::primitives::{address, b256, Address, Bytes, B256};
use alloy::providers::{Provider, ProviderBuilder};

use crate::chain::oracle::connect_eth_price;
use crate::exec::{ExecFailure, Executor};

/// anvil account #0 — public dev key.
const ANVIL_KEY0: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const HOOK: Address = address!("0x00000000000000000000000000000000000beef0");
const FEED: Address = address!("0x00000000000000000000000000000000000fee70");
const PID: B256 = b256!("0x00000000000000000000000000000000000000000000000000000000000000aa");

struct Proc(Child);
impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

async fn wait_port(port: u16) {
    for _ in 0..100 {
        if tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .is_ok()
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("port {port} never opened");
}

async fn anvil() -> (Proc, String) {
    let port = free_port();
    let child = Command::new("anvil")
        .args(["--port", &port.to_string(), "--silent"])
        .stdout(Stdio::null())
        .spawn()
        .expect("anvil on PATH");
    wait_port(port).await;
    let url = format!("http://127.0.0.1:{port}");
    // A stand-in hook: every call returns 32 zero bytes, so `rebalance` quotes 0
    // liquidity and succeeds. All the tests care about is what the daemon signs.
    let p = ProviderBuilder::new().connect_http(url.parse().unwrap());
    let _: Option<bool> = p
        .raw_request(
            "anvil_setCode".into(),
            (HOOK, Bytes::from_static(&[0x60, 0x20, 0x60, 0x00, 0xf3])),
        )
        .await
        .unwrap();
    (Proc(child), url)
}

async fn proxy(upstream: &str, extra: &[&str]) -> (Proc, String) {
    let port = free_port();
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/evil_rpc.py");
    let mut args = vec![
        script.to_string(),
        "--port".into(),
        port.to_string(),
        "--upstream".into(),
        upstream.to_string(),
    ];
    args.extend(extra.iter().map(|s| s.to_string()));
    let child = Command::new("python3")
        .args(&args)
        .stdout(Stdio::null())
        .spawn()
        .expect("python3 on PATH");
    wait_port(port).await;
    (Proc(child), format!("http://127.0.0.1:{port}"))
}

/// A fresh, honest $3000 ETH/USD handle, served through a mock feed.
async fn fresh_price(anvil_url: &str) -> (Proc, crate::chain::oracle::EthPrice) {
    let (p, url) = proxy(anvil_url, &["--feed", &format!("{FEED:#x}")]).await;
    let price = connect_eth_price(Some(url), FEED, 3000.0).await;
    assert!(
        price.get_fresh().is_some(),
        "mock feed must make the price fresh"
    );
    (p, price)
}

/// [DM-1] The spend cap is priced with `eth_gasPrice` from the primary RPC,
/// but the transaction's fee fields are filled independently by alloy's
/// GasFiller on the *submit* provider (FLASHBOTS_RPC when set). A relay that
/// lies in `eth_feeHistory` makes the daemon sign a priority fee of its choice.
#[tokio::test]
#[ignore = "needs anvil + python3"]
async fn audit_dm1_relay_sets_priority_fee_past_spend_cap() {
    let (_a, anvil_url) = anvil().await;
    let (_f, price) = fresh_price(&anvil_url).await;
    // 100,000 gwei tip.
    let (_r, relay) = proxy(&anvil_url, &["--tip", "100000000000000"]).await;

    let ex = Executor::connect(&anvil_url, ANVIL_KEY0, HOOK, Some(relay), 31337)
        .await
        .unwrap();
    let max_gas_usd = 50.0;
    let r = match ex.execute(PID, -600, 600, None, max_gas_usd, &price).await {
        Ok(r) => r,
        Err(e) => panic!("execute failed: {e}"),
    };
    assert!(r.success);

    let p = ProviderBuilder::new().connect_http(anvil_url.parse().unwrap());
    let rc = p
        .get_transaction_receipt(r.tx_hash.parse().unwrap())
        .await
        .unwrap()
        .unwrap();
    let paid_usd = rc.gas_used as f64 * rc.effective_gas_price as f64 / 1e18 * 3000.0;
    println!(
        "DM-1: cap ${max_gas_usd}, gas_used {}, effective_gas_price {} wei, paid ${paid_usd:.2}",
        rc.gas_used, rc.effective_gas_price
    );
    // Fixed: the priority fee is capped and the worst case is checked against
    // the cap before signing.
    assert!(
        paid_usd <= max_gas_usd,
        "the signed tx paid ${paid_usd:.2} against a ${max_gas_usd} cap"
    );
}

/// [DM-1b] The daemon never checks `eth_chainId` against the configured chain:
/// whatever chain id the submit RPC reports is what the key signs for.
#[tokio::test]
#[ignore = "needs anvil + python3"]
async fn audit_dm1b_chain_id_comes_from_the_rpc() {
    use alloy::consensus::TxEnvelope;
    use alloy::eips::eip2718::Decodable2718;

    let (_a, anvil_url) = anvil().await;
    let (_f, price) = fresh_price(&anvil_url).await;
    let log = std::env::temp_dir().join(format!("dm1b-{}.log", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let (_r, relay) = proxy(
        &anvil_url,
        &["--chain-id", "1", "--log", log.to_str().unwrap()],
    )
    .await;
    // Fixed: a relay naming another chain is refused at connect, and nothing is
    // ever signed for it.
    let ex = Executor::connect(&anvil_url, ANVIL_KEY0, HOOK, Some(relay), 31337).await;
    println!("DM-1b: connect -> {:?}", ex.as_ref().err());
    assert!(ex.is_err(), "a relay reporting the wrong chain is refused");
    let _ = &price;
    assert!(
        std::fs::read_to_string(&log)
            .map(|l| l.trim().is_empty())
            .unwrap_or(true),
        "no signed transaction reached the relay"
    );
    let _ = TxEnvelope::decode_2718;
}

/// [DM-2] alloy's default NonceFiller is a CachedNonceManager: a nonce is
/// consumed when the tx is *filled*, whether or not it is ever mined. One
/// transaction a private relay accepts and then drops leaves a gap, and every
/// later transaction from the executor queues behind it forever.
#[tokio::test]
#[ignore = "needs anvil + python3"]
async fn audit_dm2_one_dropped_send_gaps_the_nonce_for_good() {
    std::env::set_var("LPA_TX_TIMEOUT_SECS", "3");
    let (_a, anvil_url) = anvil().await;
    let (_f, price) = fresh_price(&anvil_url).await;
    let (_r, relay) = proxy(&anvil_url, &["--drop-sends", "1"]).await;
    let ex = Executor::connect(&anvil_url, ANVIL_KEY0, HOOK, Some(relay.clone()), 31337)
        .await
        .unwrap();
    let signer = ex.signer();
    let p = ProviderBuilder::new().connect_http(anvil_url.parse().unwrap());

    // The relay drops the first send.
    match ex.execute(PID, -600, 600, None, 50.0, &price).await {
        Err(ExecFailure::Unconfirmed { tx_hash, .. }) => {
            println!("DM-2: attempt 0: dropped {tx_hash}")
        }
        other => panic!(
            "attempt 0 should be dropped: {:?}",
            other.map(|r| r.tx_hash)
        ),
    }
    // Fixed: the next attempt reuses the confirmed nonce and lands, no restart.
    let next = ex.execute(PID, -600, 600, None, 50.0, &price).await;
    assert!(
        next.as_ref().is_ok_and(|r| r.success),
        "the next attempt lands: {:?}",
        next.as_ref().err()
    );
    let mined = p.get_transaction_count(signer).await.unwrap();
    println!("DM-2: on-chain nonce after the retry: {mined}");
    assert_eq!(mined, 1, "no gap left behind");
    let _ = relay;
    std::env::remove_var("LPA_TX_TIMEOUT_SECS");
}

/// [DM-4] A feed answer below one micro-dollar is stored as 0 *and* stamped
/// fresh, so the spend cap prices every transaction at $0.
#[tokio::test]
#[ignore = "needs anvil + python3"]
async fn audit_dm4_tiny_feed_answer_zeroes_the_spend_cap() {
    let (_a, anvil_url) = anvil().await;
    // answer = 1 with 8 decimals = $0.00000001.
    let (_f, url) = proxy(
        &anvil_url,
        &["--feed", &format!("{FEED:#x}"), "--feed-answer", "1"],
    )
    .await;
    let price = connect_eth_price(Some(url), FEED, 3000.0).await;
    let fresh = price.get_fresh();
    println!("DM-4: get_fresh() = {fresh:?}");
    // Fixed: an implausible answer is rejected and never stamped fresh.
    assert_eq!(fresh, None, "a $0.00000001 answer is not a price");
}

/// [DM-5] A StreamPositions call whose ids match nothing never sends, so it
/// never notices the client is gone: the polling task lives forever.
#[tokio::test]
async fn audit_dm5_stream_for_unknown_ids_leaks_its_task() {
    use crate::proto::autopilot_strategy_server::AutopilotStrategy;
    use crate::proto::StreamPositionsRequest;
    use std::sync::Arc;

    let tracker = Arc::new(crate::position::tracker::Tracker::open_in_memory().unwrap());
    let svc = crate::serve::strategy_service_for_audit(Arc::clone(&tracker));
    for _ in 0..100 {
        let resp = svc
            .stream_positions(tonic::Request::new(StreamPositionsRequest {
                position_ids: vec!["0xdoesnotexist".into()],
            }))
            .await
            .unwrap();
        drop(resp); // client disconnects
    }
    tokio::time::sleep(Duration::from_secs(5)).await;
    let live = Arc::strong_count(&tracker) - 2; // minus the test's handle and the service's
    println!("DM-5: polling tasks still alive 5s (2+ poll cycles) after 100 disconnects: {live}");
    // Fixed: each task exits when its client goes away.
    assert_eq!(live, 0);
}

/// [DM-6] Every Swap runs one autocommit UPDATE per position in the pool,
/// inline on the log stream and under the tracker mutex. Dust positions in a
/// busy pool turn each swap into thousands of SQLite commits.
#[test]
fn audit_dm6_swap_cost_scales_with_dust_positions() {
    use crate::position::tracker::{PositionRow, Tracker};
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("lpa.sqlite");
    let t = Tracker::open(db.to_str().unwrap()).unwrap();
    let pool = "0x00000000000000000000000000000000000000000000000000000000000000bb";
    let n = 2000;
    for i in 0..n {
        t.register(&PositionRow {
            position_id: format!("0x{i:064x}"),
            owner: "0x1111111111111111111111111111111111111111".into(),
            pool_id: pool.into(),
            chain_id: "8453".into(),
            tick_lower: -600,
            tick_upper: 600,
            current_tick: None,
            in_range: false,
            entry_tick: Some(0),
            fee: Some(3000),
            tick_spacing: Some(60),
        })
        .unwrap();
    }
    let started = std::time::Instant::now();
    t.update_pool_tick(pool, 10).unwrap();
    let one_swap = started.elapsed();
    println!("DM-6: one Swap with {n} positions in the pool took {one_swap:?}");
    // Fixed: one read and one write per swap, not one commit per position.
    assert!(one_swap < Duration::from_millis(100), "{one_swap:?}");
}

/// [DM-7] Ticks from RegisterPosition / `lpa register` are plain i32 with no
/// int24 bound; arithmetic on them overflows (panics in debug, wraps in release).
#[test]
fn audit_dm7_unbounded_ticks_overflow_strategy_arithmetic() {
    use crate::strategy::{default_config, DecideInput, EstimateCostModel, StrategyEngine};
    let cfg = default_config();
    let ticks = vec![0i32; 50];
    let r = std::panic::catch_unwind(|| {
        let input = DecideInput {
            pool_id: "0xpool",
            chain_id: "8453",
            current_tick: 0,
            entry_tick: 0,
            cur_lower: i32::MIN,
            cur_upper: i32::MAX,
            tick_spacing: 60,
            fee_pips: 3000,
            ticks: &ticks,
            weighted: &[],
            config: &cfg,
            position_value_usd: 0.0,
        };
        StrategyEngine::default().decide(&input, &EstimateCostModel)
    });
    // Fixed: out-of-domain ticks are refused, not computed on.
    assert!(matches!(r, Ok(None)), "no panic and no decision");
    assert!(!crate::strategy::ticks_in_domain(&[i32::MAX]));
}

/// [DM-8] Transport errors carry the full RPC URL, and the daemon logs them
/// verbatim (`warn!(error = %e, ..)`). Provider URLs embed the API key.
#[tokio::test]
async fn audit_dm8_rpc_errors_embed_the_url_with_its_api_key() {
    let p = ProviderBuilder::new()
        .connect_http("http://127.0.0.1:1/v2/SUPERSECRETAPIKEY".parse().unwrap());
    let e = p.get_block_number().await.unwrap_err();
    let shown = crate::redact(&e);
    println!("DM-8: error as logged: {shown}");
    // Fixed: errors are logged through `redact`, which keeps only scheme://host.
    assert!(!shown.contains("SUPERSECRETAPIKEY"), "{shown}");
    assert!(shown.contains("127.0.0.1"));
}

/// Verified: a malformed private key does not echo the key in the error.
#[test]
fn audit_dm_key_parse_error_does_not_echo_the_key() {
    let bad = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ffZZ";
    let e: anyhow::Error = bad
        .parse::<alloy::signers::local::PrivateKeySigner>()
        .map_err(anyhow::Error::from)
        .unwrap_err()
        .context("invalid REBALANCER_PRIVATE_KEY");
    let shown = format!("{e:#} {e:?}");
    assert!(
        !shown.contains("ac0974bec39a17e36ba4a6b4d238ff944bacb478"),
        "{shown}"
    );
}
