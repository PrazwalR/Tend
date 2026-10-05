//! Full-audit liveness PoCs (LV-*). Test-only.
use super::*;
use crate::position::tracker::{PositionRow, Tracker};
use crate::strategy::{default_config, EstimateCostModel, StrategyEngine};
use alloy::primitives::aliases::{I24, U160, U24};
use alloy::primitives::{address, b256, Log as PrimLog};
use alloy::rpc::types::Log as RpcLog;
use std::sync::Mutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// (method, body) -> JSON fragment: `"result":...` or `"error":{...}`.
pub(crate) type Handler = Arc<dyn Fn(&str, &str) -> String + Send + Sync>;

/// JSON-RPC over HTTP that answers through `h` after `delay`, recording bodies.
pub(crate) async fn mock(delay: Duration, seen: Arc<Mutex<Vec<String>>>, h: Handler) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            let (seen, h) = (seen.clone(), h.clone());
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut tmp = [0u8; 8192];
                loop {
                    let (head_end, len) = loop {
                        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&buf[..p]).to_lowercase();
                            let len = head
                                .lines()
                                .find_map(|l| l.strip_prefix("content-length:"))
                                .and_then(|v| v.trim().parse::<usize>().ok())
                                .unwrap_or(0);
                            break (p + 4, len);
                        }
                        match sock.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => buf.extend_from_slice(&tmp[..n]),
                        }
                    };
                    while buf.len() < head_end + len {
                        match sock.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => buf.extend_from_slice(&tmp[..n]),
                        }
                    }
                    let body = String::from_utf8_lossy(&buf[head_end..head_end + len]).to_string();
                    buf.drain(..head_end + len);
                    let id = body
                        .split("\"id\":")
                        .nth(1)
                        .map(|s| {
                            s.chars()
                                .take_while(|c| c.is_ascii_digit())
                                .collect::<String>()
                        })
                        .unwrap_or_else(|| "0".into());
                    let method = body
                        .split("\"method\":\"")
                        .nth(1)
                        .and_then(|s| s.split('"').next())
                        .unwrap_or("")
                        .to_string();
                    seen.lock().unwrap().push(body.clone());
                    tokio::time::sleep(delay).await;
                    let resp = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},{}}}", h(&method, &body));
                    let out = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                        resp.len(),
                        resp
                    );
                    if sock.write_all(out.as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    format!("http://{addr}")
}

fn rpc_log(addr: Address, data: alloy::primitives::LogData, block: u64) -> RpcLog {
    RpcLog {
        inner: PrimLog {
            address: addr,
            data,
        },
        block_number: Some(block),
        removed: false,
        ..Default::default()
    }
}

/// The JSON an RPC returns for a log.
fn log_json(addr: Address, data: &alloy::primitives::LogData, block: u64) -> String {
    let topics: Vec<String> = data
        .topics()
        .iter()
        .map(|t| format!("\"{t:#x}\""))
        .collect();
    format!(
        "{{\"address\":\"{addr:#x}\",\"topics\":[{}],\"data\":\"{}\",\"blockNumber\":\"{block:#x}\",\
         \"blockHash\":\"0x{}\",\"transactionHash\":\"0x{}\",\"transactionIndex\":\"0x0\",\"logIndex\":\"0x0\",\"removed\":false}}",
        topics.join(","),
        data.data,
        "11".repeat(32),
        "22".repeat(32)
    )
}

fn swap(pool: B256, tick: i32, block: u64) -> RpcLog {
    let ev = Swap {
        id: pool,
        sender: address!("0x0000000000000000000000000000000000000001"),
        amount0: 0i128,
        amount1: 0i128,
        sqrtPriceX96: U160::ZERO,
        liquidity: 0u128,
        tick: I24::try_from(tick).unwrap(),
        fee: U24::from(3000u32),
    };
    rpc_log(
        address!("0x498581ff718922c3f8e6a244956af099b2652b2b"),
        ev.encode_log_data(),
        block,
    )
}

fn feed(t: &Tracker, pool: &str, around: i32) {
    for block in 200u64..400 {
        let tick = around + ((block as i32 * 7) % 11) - 5;
        t.record_tick(pool, tick, block).unwrap();
    }
}

/// LV-4: the backfill is the only watermark writer and has no way past a chunk
/// the provider refuses (a result cap such as "more than 10000 results", or a
/// response over alloy-ws's 16 MiB frame limit — both reachable by flooding a
/// tracked pool with dust swaps). The watermark then never moves again, and
/// every sweep replays the hook events of the stuck chunk: `PositionOpened` is
/// an INSERT OR REPLACE, so a position rebalanced since is reset to its opening
/// range every 30 s, and the daemon proposes a rebalance for a position that is
/// in range on-chain.
#[tokio::test]
async fn lv4_refused_chunk_wedges_watermark_and_replays_stale_ranges() {
    let hook = address!("0x00000000000000000000000000000000000000ff");
    let pool = b256!("0x00000000000000000000000000000000000000000000000000000000000000bb");
    let pos = b256!("0x00000000000000000000000000000000000000000000000000000000000000aa");
    let opened = PositionOpened {
        positionId: pos,
        owner: address!("0x1111111111111111111111111111111111111111"),
        poolId: pool,
        tickLower: I24::try_from(-600).unwrap(),
        tickUpper: I24::try_from(600).unwrap(),
        liquidity: 1_000_000u128,
        fee: U24::from(3000u32),
        tickSpacing: I24::try_from(60).unwrap(),
    }
    .encode_log_data();
    let opened_json = log_json(hook, &opened, 105);
    let swap_sig = format!("{:#x}", Swap::SIGNATURE_HASH);
    let handler: Handler = Arc::new(move |method, body| match method {
        "eth_blockNumber" => "\"result\":\"0x3e8\"".into(), // head 1000
        "eth_getLogs" if body.contains(&swap_sig) => {
            "\"error\":{\"code\":-32005,\"message\":\"query returned more than 10000 results\"}"
                .into()
        }
        "eth_getLogs" if body.contains("\"fromBlock\":\"0x65\"") => {
            format!("\"result\":[{opened_json}]")
        }
        "eth_getLogs" => "\"result\":[]".into(),
        "eth_chainId" => "\"result\":\"0x2105\"".into(),
        _ => "\"error\":{\"code\":-32601,\"message\":\"unsupported\"}".into(),
    });
    let seen = Arc::new(Mutex::new(Vec::new()));
    let url = mock(Duration::ZERO, seen, handler).await;
    let provider = ProviderBuilder::new().connect_http(url.parse().unwrap());

    let tracker = Arc::new(Tracker::open_in_memory().unwrap());
    tracker.set_last_indexed_block("8453", 100).unwrap();
    let (tx, mut rx) = mpsc::channel(crate::exec::AUTO_INTENT_CHANNEL_CAP);
    let engine = StrategyEngine::default();
    let cfg_pos = default_config();
    let ctx = Ctx {
        tracker: &tracker,
        engine: &engine,
        cost: &EstimateCostModel,
        config: &cfg_pos,
        chain_id: 8453,
        reader: None,
        intent_tx: Some(&tx),
        last_block: DashMap::new(),
    };
    let chain = ChainConfig::from_name("base").unwrap();
    let id_hex = format!("{pos:#x}");
    let pool_hex = format!("{pool:#x}");

    // Live stream: opened at 105, rebalanced to [1200,1800] at 700, swap at 1500.
    handle(&ctx, rpc_log(hook, opened.clone(), 105))
        .await
        .unwrap();
    feed(&tracker, &pool_hex, 1500);
    let rebalanced = Rebalanced {
        positionId: pos,
        oldTickLower: I24::try_from(-600).unwrap(),
        oldTickUpper: I24::try_from(600).unwrap(),
        newTickLower: I24::try_from(1200).unwrap(),
        newTickUpper: I24::try_from(1800).unwrap(),
        oldLiquidity: 1_000_000u128,
        newLiquidity: 1_000_000u128,
    }
    .encode_log_data();
    handle(&ctx, rpc_log(hook, rebalanced, 700)).await.unwrap();
    handle(&ctx, swap(pool, 1500, 701)).await.unwrap();
    let p = tracker.get_position(&id_hex).unwrap().unwrap();
    assert_eq!((p.tick_lower, p.tick_upper, p.in_range), (1200, 1800, true));

    for pass in 0..3 {
        let r = backfill(&provider, &chain, &ctx, Some(hook), false).await;
        let p = tracker.get_position(&id_hex).unwrap().unwrap();
        let wm = tracker.last_indexed_block("8453").unwrap();
        println!(
            "pass {pass}: backfill err = {:?}; watermark = {wm:?}; tracked range = [{}, {}], in_range = {}",
            r.as_ref().err().map(|e| e.to_string()),
            p.tick_lower,
            p.tick_upper,
            p.in_range
        );
        // Fixed: refused ranges are split down to single blocks and skipped, so
        // the watermark reaches head; the replayed PositionOpened is ignored.
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(wm, Some(1000), "watermark reaches head");
        assert_eq!(
            (p.tick_lower, p.tick_upper),
            (1200, 1800),
            "the rebalanced range survives replay"
        );
    }

    // Next live swap: the position is in range on-chain at 1500, but the
    // tracker now judges it against [-600, 600].
    handle(&ctx, swap(pool, 1500, 702)).await.unwrap();
    // What `sweep_out_of_range` does for each row (called row by row here so
    // this test does not advance the shared OOR_CURSOR that ds4 depends on).
    for p in tracker.out_of_range_positions().unwrap() {
        propose_rebalance(&ctx, &p.pool_id, p.current_tick.unwrap(), &p.position_id).await;
    }
    assert!(
        rx.try_recv().is_err(),
        "no rebalance proposed for a position in range on-chain"
    );
    automation().forget(&id_hex);
}

/// LV-5: `propose_rebalance` and `sweep_idle` call `try_send` and only then
/// `mark_queued`. The executor (another task, possibly on another worker
/// thread) calls `mark_dequeued` as soon as it receives. When it wins that race
/// the in-flight marker is inserted after it was removed and is never removed
/// again (`prune` does not touch `in_flight`): the position is "blocked" for
/// good and never proposed again until a restart or the position closes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn lv5_in_flight_marker_leaks_when_executor_wins_the_race() {
    use std::sync::atomic::AtomicBool;
    let tracker = Arc::new(Tracker::open_in_memory().unwrap());
    let pool = "0x1eaf";
    let id = "0x1eaf0000000000000000000000000000000000000000000000000000000000aa";
    tracker
        .register(&PositionRow {
            position_id: id.into(),
            owner: "0x1111111111111111111111111111111111111111".into(),
            pool_id: pool.into(),
            chain_id: "8453".into(),
            tick_lower: 5000,
            tick_upper: 6000,
            current_tick: Some(0),
            in_range: false,
            entry_tick: Some(5500),
            fee: Some(3000),
            tick_spacing: Some(60),
        })
        .unwrap();
    feed(&tracker, pool, 0);
    let (tx, mut rx) =
        mpsc::channel::<crate::exec::RebalanceIntent>(crate::exec::AUTO_INTENT_CHANNEL_CAP);
    let received = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    // The executor's first act on every intent (exec/mod.rs run_executor_loop).
    let (r2, s2) = (received.clone(), stop.clone());
    let exec = std::thread::spawn(move || {
        while !s2.load(Ordering::Relaxed) {
            if let Ok(i) = rx.try_recv() {
                automation().mark_dequeued(&i.position_id);
                r2.fetch_add(1, Ordering::SeqCst);
            }
        }
    });
    let engine = StrategyEngine::default();
    let cfg = default_config();
    let ctx = Ctx {
        tracker: &tracker,
        engine: &engine,
        cost: &EstimateCostModel,
        config: &cfg,
        chain_id: 8453,
        reader: None,
        intent_tx: Some(&tx),
        last_block: DashMap::new(),
    };
    let (mut sent, mut leaked) = (0u64, 0u64);
    for _ in 0..20_000 {
        automation().forget(id);
        propose_rebalance(&ctx, pool, 0, id).await;
        sent += 1;
        while received.load(Ordering::SeqCst) < sent {
            std::hint::spin_loop();
        }
        // Nothing is queued now; a position still "in flight" has leaked.
        if automation().is_blocked(id, Instant::now()) {
            leaked += 1;
        }
    }
    stop.store(true, Ordering::Relaxed);
    exec.join().unwrap();
    println!("intents sent: {sent}; in-flight markers leaked after dequeue: {leaked}");
    // Fixed: marked before the send, so a fast executor cannot dequeue first.
    assert_eq!(leaked, 0, "no in-flight marker outlives its intent");
    automation().forget(id);
}

/// LV-6: the out-of-range sweep is not batched like the idle sweep. Every
/// out-of-range position that is not blocked costs four sequential RPCs
/// (`position_value_usd`, when LPA_TOKEN1_USD is set) before the strategy or the
/// queue capacity is consulted, and positions the EV gate declines, or whose
/// intent is dropped on a full queue, are never suppressed. Enough of them
/// (dust deposits) push every pass past SWEEP_TIMEOUT, and `sweep_idle`, which
/// runs after it in the same pass, never runs at all.
#[tokio::test]
#[ignore = "takes ~40 s (two sweep timeouts)"]
async fn lv6_out_of_range_dust_starves_the_idle_sweep() {
    std::env::set_var("LPA_TOKEN1_USD", "1");
    let seen = Arc::new(Mutex::new(Vec::new()));
    let zeros = format!("\"result\":\"0x{}\"", "0".repeat(512));
    let handler: Handler = Arc::new(move |_, _| zeros.clone());
    let url = mock(Duration::from_millis(20), seen.clone(), handler).await;
    let reader = ChainReader::connect(&url, Address::repeat_byte(0x11), Address::repeat_byte(0x22))
        .await
        .unwrap();
    let tracker = Arc::new(Tracker::open_in_memory().unwrap());
    let dust_pool = format!("{:#066x}", 0xa77ac4e7u64);
    feed(&tracker, &dust_pool, 0);
    for i in 1..=320u64 {
        tracker
            .register(&PositionRow {
                position_id: format!("{:#066x}", i),
                owner: "0x1111111111111111111111111111111111111111".into(),
                pool_id: dust_pool.clone(),
                chain_id: "8453".into(),
                tick_lower: 600_000,
                tick_upper: 600_060,
                current_tick: Some(0),
                in_range: false,
                entry_tick: Some(600_030),
                fee: Some(3000),
                tick_spacing: Some(60),
            })
            .unwrap();
    }
    // An honest in-range position: the idle sweep's only job here.
    let honest = format!("{:#066x}", 0xdead_beefu64);
    tracker
        .register(&PositionRow {
            position_id: honest.clone(),
            owner: "0x2222222222222222222222222222222222222222".into(),
            pool_id: format!("{:#066x}", 0x40e57u64),
            chain_id: "8453".into(),
            tick_lower: -600,
            tick_upper: 600,
            current_tick: Some(0),
            in_range: true,
            entry_tick: Some(0),
            fee: Some(3000),
            tick_spacing: Some(60),
        })
        .unwrap();
    let (tx, _rx) = mpsc::channel(crate::exec::AUTO_INTENT_CHANNEL_CAP);
    let engine = StrategyEngine::default();
    let cfg = default_config();
    let ctx = Ctx {
        tracker: &tracker,
        engine: &engine,
        cost: &EstimateCostModel,
        config: &cfg,
        chain_id: 8453,
        reader: Some(&reader),
        intent_tx: Some(&tx),
        last_block: DashMap::new(),
    };
    let needle = honest.trim_start_matches("0x").to_string();
    for pass in 0..2 {
        let before = seen.lock().unwrap().len();
        // The watch loop's pass, minus the backfill (watch_once).
        let r = timeout(SWEEP_TIMEOUT, async {
            sweep_out_of_range(&ctx).await;
            sweep_idle(&ctx).await;
        })
        .await;
        let calls = seen.lock().unwrap()[before..].to_vec();
        let idle_reached = calls.iter().any(|b| b.contains(&needle));
        println!(
            "pass {pass}: timed out = {}; RPCs = {}; honest position's idle balance checked = {idle_reached}",
            r.is_err(),
            calls.len()
        );
        // Fixed: the out-of-range sweep is batched, so the pass finishes well
        // inside the timeout and the idle sweep runs every pass.
        assert!(r.is_ok(), "the pass finishes inside SWEEP_TIMEOUT");
        assert!(
            idle_reached,
            "sweep_idle runs and reaches the honest position"
        );
    }
    std::env::remove_var("LPA_TOKEN1_USD");
}

alloy::sol! {
    #[sol(rpc)]
    interface IHookSend {
        function rebalance(bytes32 positionId, int24 newTickLower, int24 newTickUpper, uint128 minLiquidity) external returns (uint128);
    }
}

/// LV-7 — kept as a record of the library behaviour the executor no longer
/// relies on: it builds its providers without alloy's fillers and sets the
/// nonce itself (see `audit_dm2_*`, now a regression).
/// LV-7: the executor's `submit` provider is `ProviderBuilder::new().wallet(..)`,
/// whose recommended fillers include alloy's `CachedNonceManager`. Gas and nonce
/// are filled concurrently (`JoinFill::prepare` is a `try_join!`), and the cached
/// nonce is bumped before anything is sent. A send whose gas estimate (or
/// `eth_sendRawTransaction`) fails therefore consumes a nonce that never reaches
/// the chain; every later transaction carries a future nonce, sits in the
/// node's queued pool, and is reported `Unconfirmed` after the receipt timeout.
/// Nothing re-syncs the cache, so automation is dead until the daemon restarts.
/// `execute` sends with exactly this call (`hook.rebalance(..).send()`), with no
/// explicit gas, so the filler re-estimates (at `latest`) on every send.
#[tokio::test]
async fn lv7_failed_send_burns_a_cached_nonce_and_wedges_every_later_tx() {
    use alloy::consensus::{Transaction, TxEnvelope};
    use alloy::eips::eip2718::Decodable2718;
    use alloy::network::EthereumWallet;
    use alloy::signers::local::PrivateKeySigner;
    use std::sync::atomic::AtomicUsize;

    let estimates = Arc::new(AtomicUsize::new(0));
    let raw_txs = Arc::new(Mutex::new(Vec::<String>::new()));
    let unknown = Arc::new(Mutex::new(Vec::<String>::new()));
    let (e2, r2, u2) = (estimates.clone(), raw_txs.clone(), unknown.clone());
    let handler: Handler = Arc::new(move |method, body| {
        match method {
        "eth_chainId" => "\"result\":\"0x2105\"".into(),
        "eth_getTransactionCount" => "\"result\":\"0x0\"".into(), // chain nonce stays 0
        "eth_estimateGas" => {
            // The second send's estimate reverts (state moved since preflight:
            // a swap, a competing rebalance, a transient RPC error).
            if e2.fetch_add(1, Ordering::SeqCst) == 1 {
                "\"error\":{\"code\":3,\"message\":\"execution reverted\",\"data\":\"0x1782bd94\"}".into()
            } else {
                "\"result\":\"0x50000\"".into()
            }
        }
        "eth_gasPrice" | "eth_maxPriorityFeePerGas" => "\"result\":\"0x3b9aca00\"".into(),
        "eth_feeHistory" => "\"result\":{\"oldestBlock\":\"0x1\",\"baseFeePerGas\":[\"0x3b9aca00\",\"0x3b9aca00\"],\"gasUsedRatio\":[0.5],\"reward\":[[\"0x3b9aca00\"]]}".into(),
        "eth_sendRawTransaction" => {
            let raw = body
                .split("\"params\":[\"")
                .nth(1)
                .unwrap()
                .split('"')
                .next()
                .unwrap();
            r2.lock().unwrap().push(raw.to_string());
            format!("\"result\":\"0x{}\"", "ab".repeat(32))
        }
        m => {
            u2.lock().unwrap().push(m.to_string());
            "\"error\":{\"code\":-32601,\"message\":\"unsupported\"}".into()
        }
    }
    });
    let url = mock(Duration::ZERO, Arc::new(Mutex::new(Vec::new())), handler).await;

    // As Executor::connect builds `submit`.
    let signer: PrivateKeySigner =
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
            .parse()
            .unwrap();
    let submit = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(url.parse().unwrap())
        .erased();
    let hook = IHookSend::new(Address::repeat_byte(0x44), &submit);
    let l = I24::try_from(-600).unwrap();
    let u = I24::try_from(600).unwrap();

    let nonce_of_last = || {
        let raw = raw_txs.lock().unwrap().last().unwrap().clone();
        let bytes = alloy::primitives::hex::decode(raw.trim_start_matches("0x")).unwrap();
        TxEnvelope::decode_2718(&mut bytes.as_slice())
            .unwrap()
            .nonce()
    };
    // 1: a normal rebalance, mined with nonce 0; the chain's next nonce is 1.
    let _ = hook
        .rebalance(B256::repeat_byte(1), l, u, 0)
        .send()
        .await
        .expect("sent");
    println!("send 1: nonce {} (mined)", nonce_of_last());
    // 2: the filler's gas estimate reverts; nothing reaches the chain.
    let second = hook.rebalance(B256::repeat_byte(2), l, u, 0).send().await;
    println!(
        "send 2: {:?}; raw txs broadcast so far: {}",
        second.as_ref().err().map(|e| e.to_string()),
        raw_txs.lock().unwrap().len()
    );
    assert!(second.is_err());
    assert_eq!(
        raw_txs.lock().unwrap().len(),
        1,
        "nothing broadcast for send 2"
    );
    // 3 and 4: every later tx skips nonce 1 and can never be mined.
    for i in 3u8..=4 {
        let _ = hook
            .rebalance(B256::repeat_byte(i), l, u, 0)
            .send()
            .await
            .expect("sent");
        println!(
            "send {i}: nonce {} (chain's next nonce is 1: queued forever)",
            nonce_of_last()
        );
        assert!(nonce_of_last() >= 2, "nonce 1 was burned");
    }
    println!("unhandled methods: {:?}", unknown.lock().unwrap());
}
