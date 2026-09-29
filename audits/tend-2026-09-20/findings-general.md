# AutopilotHook — General Solidity/EVM Checklist Findings

Scope: `/Users/prazw/Desktop/Web3/Tend/contracts/src/AutopilotHook.sol` (Solidity 0.8.26, optimizer on, 200 runs, evm_version `cancun`), reviewed against the `evm-audit-general` checklist. Supporting files read: `contracts/test/AutopilotHook.t.sol`, `contracts/script/DeployAutopilotHook.s.sol`, and the vendored `v4-core` (`PoolManager.sol`, `Pool.sol`, `SqrtPriceMath.sol`, `BalanceDelta.sol`), `v4-periphery` (`LiquidityAmounts.sol`, `HookMiner.sol`) and `uniswap-hooks` (`BaseHook.sol`, `CurrencySettler.sol`) sources. The classic checklist categories — force-feeding, `msg.value` in loops, `delegatecall`, Merkle proofs, unbounded loops, low-level `.call()`, ETH `transfer()` — genuinely do not apply here: the contract is not payable, rejects native currency in `deposit()`, makes no low-level calls, and contains no loops. The material findings all cluster around two things the checklist *does* reach: the **reveal-gap / mutable-state-between-broadcast-and-execution** class (the new `_swapToRatio()` executes a price-moving swap through the pool it is rebalancing, with the price limit pinned to the absolute min/max and no value-denominated slippage bound), and **"deployment scripts not checked"** (the CREATE2 deployment path assigns `owner()` to the deterministic-deployer proxy, permanently disabling `pause()` and `setRebalancer()`). Together these falsify the stated "trusted but bounded — cannot withdraw funds" trust model: the tick envelope bounds *where the position sits*, not *at what price its tokens get converted*, and there is no working emergency control to fall back on.

| Severity | Count | IDs |
| --- | --- | --- |
| Critical | 0 | — |
| High | 2 | G-1, G-2 |
| Medium | 4 | G-3, G-4, G-5, G-6 |
| Low | 6 | G-7, G-8, G-9, G-10, G-11, G-12 |
| Info | 1 | G-13 |

---

## [G-1] `_swapToRatio()` executes an unbounded-price swap through the pool being rebalanced; `minLiquidity` is not a value guard
**Severity**: High
**Category**: general
**Location**: `_swapToRatio()` — `AutopilotHook.sol:425-433`; guard at `_doRebalance()` — `AutopilotHook.sol:355`
**Description**: The re-ratio swap is submitted with

```solidity
sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
```

i.e. the swap will accept *any* execution price the pool offers, all the way to the end of the curve. There is no `amountOutMinimum`, no TWAP/oracle reference, and no comparison against a pre-swap `sqrtPriceX96`. The contract reads spot price fresh at `_swapToRatio()` line 385 and again at `_doRebalance()` line 346 — both reads are of whatever state the transaction was placed into.

The only bound the code offers is `cb.minLiquidity` (line 355), and it is weak for three separate reasons:

1. **It is chosen by the party being bounded.** `minLiquidity` is the 4th argument of `rebalance()` (line 225), supplied by the allowlisted rebalancer. A malicious or compromised rebalancer hot wallet simply passes `0` — which is exactly what every non-slippage test in `AutopilotHook.t.sol` does (`hook.rebalance(pid, -1200, 1200, 0)`).
2. **It is denominated in liquidity at the post-manipulation price, not in value.** `newLiquidity` is `LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, ...)` with `sqrtPriceX96` read *after* the manipulated swap (line 346). For a range that sits entirely above spot the result is `getLiquidityForAmount0(A, B, freed0)` (verified in `lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol`) — an attacker who depresses the price so the position converts into a *larger nominal count* of token0 makes `newLiquidity` go **up**, so the floor passes while the owner's position is worth less at the restored price. The guard is directionally perverse in one of the two branches. (In the opposite direction — the hook selling token0 for token1 — a tight `minLiquidity` genuinely does bind, so this is a partial, not total, failure of the guard; it is total against a malicious rebalancer, who sets it to zero.)
3. **It only exists on `rebalance()`.** `deposit()`/`withdraw()` have no analogue at all (see G-3).

This directly contradicts the documented trust model. The tick envelope (`boundLower`/`boundUpper`, checked at line 240) constrains where the position is *parked*; it places no constraint whatsoever on the exchange rate at which `_swapToRatio()` converts the position's holdings. The rebalancer never calls `take()` to itself, so it cannot literally transfer funds out — but it can force the position's tokens through the pool at a price it controls and collect the difference on the other side of its own sandwich. Functionally that is withdrawal.

This is the checklist's "reveal-gap steering" item: the outcome of step 2 (the swap) depends on mutable state (pool price) that any actor can change in the gap between broadcast and execution, and a smooth amount guard (`minLiquidity`) is being trusted to protect it.

**Proof of Concept**:

Malicious/compromised rebalancer, single bundle, no mempool race needed:

1. Owner holds position `P` over `[-600, 600]`, `L = 1e18`, with a wide envelope (`boundLower = minUsableTick`, `boundUpper = maxUsableTick` — the default in the repo's own test helper `_deposit`).
2. Price has drifted below `-600`, so `P` is 100% token0. The bot wants to recentre to a range below spot.
3. Rebalancer tx #1 (own capital): swap `zeroForOne` hard into the pool, driving the price far below fair. Token0 is now cheap.
4. Rebalancer tx #2: `rebalance(P, newLo, newHi, 0)` with `[newLo, newHi]` below spot. Inside `_doRebalance`, `modifyLiquidity(-L)` frees `have0`. Because `sqrtPriceX96 >= sqrtB`, `_swapToRatio` takes the branch at lines 396-399 and sets `(zeroForOne, amountIn) = (true, have0)` — it dumps **the entire position** into token1 at the depressed price, with `sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1`. `minLiquidity = 0`, so line 355 never binds.
5. Rebalancer tx #3: swap back `oneForZero`. Because the hook's own sell pushed the price further down, the buy-back returns more token0 than tx #1 sold. Net profit ≈ the hook's realised price impact − 2× the pool LP fee on the attacker's own round trip.
6. Repeat after `minRebalanceInterval` (default 3600s per `DeployAutopilotHook.s.sol`; can be `0` — see G-6).

A third party can run the same sandwich from the mempool whenever the bot submits `minLiquidity = 0` or a loose floor; this requires no privileged role.

Not covered by the test suite: `test_rebalance_out_of_range_respects_slippage_floor` only proves the floor reverts when set to `type(uint128).max`. There is no test where the pool price is moved between the bot's decision and `rebalance()` executing.

**Recommendation**: The swap must be bounded in price, not in post-swap liquidity, and the bound must not be settable to a no-op by the rebalancer.

```solidity
// 1. Store a max deviation, owner-set (not rebalancer-set).
uint16 public maxSwapDeviationBps; // e.g. 50 = 0.5%

// 2. In _swapToRatio, clamp the price the swap may reach, derived from the
//    pre-swap spot, so the executed price cannot run away.
uint160 limit = zeroForOne
    ? uint160(FullMath.mulDiv(sqrtPriceX96, 10_000 - maxSwapDeviationBps, 10_000))
    : uint160(FullMath.mulDiv(sqrtPriceX96, 10_000 + maxSwapDeviationBps, 10_000));
return poolManager.swap(
    cb.key,
    SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
    ""
);
```

Additionally, reject a rebalance whose pre-swap spot deviates from a reference TWAP by more than a tolerance, so step 3 above cannot set up the trade at all:

```solidity
int24 spotTick = ...;            // from getSlot0 at the top of _doRebalance
int24 refTick  = _twapTick(cb.key, 600);
if (_absDiff(spotTick, refTick) > maxTickDeviation) revert PriceManipulated();
```

And enforce a non-zero floor on `minLiquidity` computed on-chain (e.g. `>= 95%` of the liquidity the pre-swap holdings could have funded) rather than trusting the caller's value.

---

## [G-2] Deployment via the CREATE2 proxy sets `owner()` to the deployer proxy, permanently bricking `pause()` and `setRebalancer()`
**Severity**: High
**Category**: general
**Location**: `constructor()` — `AutopilotHook.sol:113`; `contracts/script/DeployAutopilotHook.s.sol:24`
**Description**: The constructor is

```solidity
constructor(IPoolManager pm, address initialRebalancer, uint64 cooldown) BaseHook(pm) Ownable(msg.sender) {
```

`Ownable(msg.sender)` is only correct if the EOA deploys directly. It does not. A v4 hook address must encode its permission flags, so the deploy script mines a salt against the deterministic CREATE2 deployer and deploys with a salted `new`:

```solidity
address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
(address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(AutopilotHook).creationCode, args);
hook = new AutopilotHook{salt: salt}(IPoolManager(manager), rebalancer, cooldown);
require(address(hook) == predicted, "hook address mismatch");
```

The vendored `HookMiner` is explicit about the semantics (`lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol`, `find` NatSpec): *"In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)"*, and `computeAddress` hashes `(0xFF, deployer, salt, keccak(initcode))` with `deployer = CREATE2_DEPLOYER`. Forge routes salted `new` through that proxy precisely so the mined address is reproducible. The `require(address(hook) == predicted)` line confirms this is the intent — if the script contract itself were the deployer, that assertion would fail.

Consequence: inside the constructor, `msg.sender` is `0x4e59b448...`, the Arachnid deterministic-deployment proxy. `_owner` is set to that address. The proxy's only function is to CREATE2-deploy and return; it can never be made to call `setRebalancer()`, `setMinRebalanceInterval()`, `pause()`, `unpause()`, or `transferOwnership()`. `renounceOwnership()` is overridden to revert (line 473), so ownership can never be cleared either. The hook ships with **no functioning admin at all**.

The hook still works in the happy path — `initialRebalancer` is set inside the constructor (line 115), and `deposit`/`withdraw`/`rebalance` need no owner. That is what makes this dangerous: it will pass a smoke test and only surface during an incident. Combined with G-1 and G-6, a compromised rebalancer hot wallet can never be revoked and the contract can never be paused; the only recourse is for every owner to individually `withdraw()`, racing the attacker.

Confidence note: I verified the address-derivation semantics from the vendored `HookMiner` source and the script's own `require`, but I did not execute `forge script --broadcast` against a live chain to observe the resulting `owner()`. The conclusion rests on Forge routing salted `new` through the CREATE2 proxy, which is what `HookMiner`'s NatSpec and the mined-address assertion both require. Verify with step 2 of the PoC before acting.

**Proof of Concept**:
1. `forge script script/DeployAutopilotHook.s.sol --broadcast --rpc-url $BASE_RPC`.
2. `cast call $HOOK "owner()(address)"` → expected `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
3. From the deployer EOA: `cast send $HOOK "pause()"` → reverts `OwnableUnauthorizedAccount(<EOA>)`.
4. `cast send $HOOK "setRebalancer(address,bool)" $NEW false` → same revert. No path exists to recover.

There is no test for this: `AutopilotHookTest.setUp()` uses `deployCodeTo(...)`, which etches the runtime code at a chosen address and runs the constructor with `msg.sender = address(this)`, so `hook.owner() == address(this)` in tests and every owner-gated test passes. The test harness structurally cannot catch this bug.

**Recommendation**: Take the owner as an explicit constructor argument and never derive it from `msg.sender` in a CREATE2-deployed contract.

```solidity
constructor(IPoolManager pm, address initialOwner, address initialRebalancer, uint64 cooldown)
    BaseHook(pm)
    Ownable(initialOwner)
{
    if (initialOwner == address(0)) revert ZeroAddress();
    ...
}
```

and in `DeployAutopilotHook.s.sol` pass `vm.envAddress("HOOK_OWNER")` into `args` so it is folded into the mined initcode hash. Add a post-deploy assertion to the script:

```solidity
require(hook.owner() == expectedOwner, "owner mismatch");
```

---

## [G-3] `deposit()` and `withdraw()` accept no amount bounds and are sandwichable by any third party
**Severity**: Medium
**Category**: general
**Location**: `deposit()` — `AutopilotHook.sol:141-189`; `withdraw()` — `AutopilotHook.sol:191-223`
**Description**: `deposit()` takes a target `liquidity` (line 145) but never lets the caller bound the token amounts that will be pulled. The split between token0 and token1 for a fixed `L` is a pure function of the pool's spot price at execution time (`Pool.modifyLiquidity`, `lib/uniswap-hooks/lib/v4-core/src/libraries/Pool.sol:206-236`), and `_doDeposit()` settles whatever the pool asks for straight out of the user's wallet:

```solidity
cb.key.currency0.settle(poolManager, cb.owner, uint256(uint128(-delta.amount0())), false);  // line 297
cb.key.currency1.settle(poolManager, cb.owner, uint256(uint128(-delta.amount1())), false);  // line 300
```

`CurrencySettler.settle` does `safeTransferFrom(payer, poolManager, amount)`, so the ceiling on what can be pulled is the user's ERC20 allowance — and the repo's own test setup grants `type(uint256).max` (`AutopilotHook.t.sol` `setUp`). Every standard Uniswap periphery add-liquidity entrypoint carries `amount0Max`/`amount1Max` for exactly this reason; this one has none. There is also no `deadline` on any of the three externals.

`withdraw()` has the mirror-image gap: it removes `pos.liquidity` and `take()`s whatever comes out (lines 315-320) with no `amount0Min`/`amount1Min`.

An attacker front-runs the pending `deposit()`, pushes the spot price so the appreciating token dominates the required mix, lets the victim mint at the skewed ratio, then reverts the price. The victim's LP position is worth less than the tokens they paid in; the difference (minus the attacker's round-trip LP fee) is the attacker's. The same sandwich applies in reverse to `withdraw()`.

Rated Medium rather than High because the loss is capped by the depth the attacker is willing to move and by their own fee cost — this is ordinary AMM sandwich economics rather than an unconditional drain. But it is a real, unpermissioned third-party value extraction on the two functions end users call directly.

**Proof of Concept**:
1. Victim broadcasts `deposit(key, -600, 600, 1e18, minB, maxB)` with spot at tick 0. Fair cost: ~`x` token0 + ~`y` token1.
2. Attacker front-runs with a `oneForZero` swap moving spot to tick +400.
3. Victim's tx mints `L = 1e18` over `[-600, 600]` at tick 400 — `Pool.modifyLiquidity` now charges mostly token1 (`getAmount1Delta(sqrtLower, sqrtPrice=+400, L, roundUp=true)`), pulling far more token1 than the victim modelled. `_doDeposit` settles it unconditionally; no bound reverts.
4. Attacker back-runs `zeroForOne` to tick 0, restoring the price and closing the sandwich.

No test exercises a price move between the caller's decision and `deposit()`/`withdraw()` executing.

**Recommendation**: Add caller-supplied bounds and enforce them inside the callback, where the actual deltas are known.

```solidity
struct Callback { ...; uint128 amount0Max; uint128 amount1Max; }

function deposit(..., uint128 amount0Max, uint128 amount1Max, uint256 deadline) external {
    if (block.timestamp > deadline) revert Expired();
    ...
}

function _doDeposit(Callback memory cb) internal {
    (BalanceDelta delta,) = poolManager.modifyLiquidity(...);
    uint256 owed0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
    uint256 owed1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
    if (owed0 > cb.amount0Max || owed1 > cb.amount1Max) revert SlippageExceeded();
    ...
}
```

Mirror with `amount0Min`/`amount1Min` in `withdraw()`/`_doWithdraw()`.

---

## [G-4] One-sided branches of `_swapToRatio()` route 100% of the position through the pool in a single unsplit swap
**Severity**: Medium
**Category**: general
**Location**: `_swapToRatio()` — `AutopilotHook.sol:392-399`
**Description**: When the new range does not straddle spot, the function swaps the *entire* freed balance:

```solidity
if (sqrtPriceX96 <= sqrtA) {
    if (have1 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
    (zeroForOne, amountIn) = (false, have1);       // sell ALL token1
} else if (sqrtPriceX96 >= sqrtB) {
    if (have0 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
    (zeroForOne, amountIn) = (true, have0);        // sell ALL token0
}
```

Two problems, both independent of any attacker:

1. **Self-inflicted price impact.** The position has just been fully removed from the pool by `modifyLiquidity(-cb.liquidity)` at line 324, so the pool is *thinner* at the moment of the swap than the bot's off-chain sizing would have seen. The swap then moves the price against itself across the whole notional, and the position pays the pool's LP fee (30 bps at `fee = 3000`) on 100% of its value — every single rebalance. On a thin pool or a large position this is a materially worse execution than routing externally or splitting the trade.
2. **The branch decision is not re-evaluated after the swap moves the price.** The branch is chosen from the *pre-swap* price, but the swap itself moves the price. Selling all of `have1` in the `sqrtPriceX96 <= sqrtA` branch pushes `sqrtPrice` **up** — potentially past `sqrtA`, at which point the range no longer sits above spot and the correct answer was to swap less than everything. The code over-swaps and the surplus is then handed back as "dust" at lines 371-376, having paid a full LP fee to get there. The comment at lines 379-383 ("exactness is not required because any residual is returned to the owner") understates this: the residual is returned *after* being round-tripped through a fee-charging swap.

This is the checklist's "documentation-code mismatch" and boundary-comparison class — the branch boundary is evaluated against a price the branch's own action invalidates.

**Proof of Concept**: Not an exploit; a deterministic value leak.
1. Deposit `L = 1e18` over `[-600, 600]`; let price drift out of range so the position is 100% one token (this is exactly `test_rebalance_after_price_exits_range`).
2. Call `rebalance(pid, lo, hi, 0)` with a target range that does not straddle spot. `_swapToRatio` takes a one-sided branch and sets `amountIn` to the full freed balance.
3. The pool charges `fee` bps on the entire notional plus the price impact of a single unsplit market order into a book that was just thinned by step 1's own removal. Measured as `newLiq` versus a fair-price reconstruction, the loss is `≈ fee + impact(full notional)` per rebalance.

`test_rebalance_after_price_exits_range` and `test_rebalance_out_of_range_onto_straddling_range` both assert only `newLiq > 0`; neither asserts anything about how much value survived.

**Recommendation**: Never swap the whole balance blindly. Swap only the amount needed to reach the target ratio at the *new* range boundary, and cap the fraction:

```solidity
// Range entirely above spot: we need token0 only, but only enough to fund
// the target liquidity — solve for the amount, don't dump the balance.
uint256 needed0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, targetLiquidity, true);
uint256 sell1 = have1 > _inToken1(needed0 - have0, sqrtPriceX96)
    ? _inToken1(needed0 - have0, sqrtPriceX96)
    : have1;
```

Also bound `amountIn` as a fraction of the pool's in-range liquidity (readable via `poolManager.getLiquidity(id)`) and revert if the required swap exceeds it, forcing the bot to split the rebalance across blocks rather than eating the impact in one shot. Combine with the price limit from G-1.

---

## [G-5] Rounding-direction mismatch can leave a ≤2 wei token0 debt and revert the whole rebalance with `CurrencyNotSettled`
**Severity**: Medium
**Category**: general
**Location**: `_doRebalance()` — `AutopilotHook.sol:347-376`
**Description**: `newLiquidity` is derived from the freed amounts with round-**down** maths, but the pool charges for adding that liquidity with round-**up** maths, and `_doRebalance()` has no external funding source to cover the gap.

Verified in the vendored sources:
- `LiquidityAmounts.getLiquidityForAmount0` = `FullMath.mulDiv(amount0, mulDiv(sqrtA, sqrtB, Q96), sqrtB - sqrtA)` — two nested floors (`lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol`).
- `SqrtPriceMath.getAmount0Delta(a, b, int128 liquidity)` for `liquidity > 0` calls the unsigned overload with `roundUp = true` (`lib/uniswap-hooks/lib/v4-core/src/libraries/SqrtPriceMath.sol:261-271`), which is itself a nested double-ceiling.
- `Pool.modifyLiquidity` uses that signed overload for the add (`Pool.sol:213, 220`).

Composing `L = floor(floor(...))` then `required0 = ceil(ceil(L · …))` gives `required0 ≤ freed0 + 2`, i.e. the token0 leg can demand up to **2 wei more than was freed**. (The token1 leg is provably safe: `L1 = floor(a1·Q96/d)` then `ceil(L1·d/Q96) ≤ a1`.)

When that happens, `net = removed + swapped + added` (line 370) has `net.amount0() < 0`. The code only handles the positive case:

```solidity
if (net.amount0() > 0) { cb.key.currency0.take(...); }   // line 371
if (net.amount1() > 0) { cb.key.currency1.take(...); }   // line 374
```

There is no `settle()` path for a negative net. `PoolManager.unlock` then hits `if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();` (`PoolManager.sol:112`) and the entire `rebalance()` reverts with an opaque error.

The exposure is worst in the one-sided branches: after `_swapToRatio` converts everything to token0, `getLiquidityForAmounts` takes the `sqrtPriceX96 <= sqrtPriceAX96` path and consumes the *entire* `freed0` with zero slack, so there is nothing to absorb the 1-2 wei. In the straddle case `min(L0, L1)` usually leaves slack on one side, which is why the existing tests happen to pass.

Confidence note: the rounding-direction asymmetry and the missing negative-`net` settle path are both confirmed from source. I derived the ≤2 wei bound analytically but did not produce a concrete failing `(sqrtPrice, tickLower, tickUpper, freed0)` instance — the failure is input-dependent. Severity kept at Medium (degraded behaviour, retryable with different ticks; funds are never stuck because `withdraw()` always works).

**Proof of Concept**: Deterministic failure mode rather than a single reproducible tx. To surface it, fuzz the rebalance path:

```solidity
function testFuzz_rebalance_never_reverts_on_rounding(uint128 liq, int24 lo, int24 hi, int256 driftSwap) public {
    // bound inputs to aligned, in-range ticks; drive price out of range with driftSwap;
    // then rebalance onto [lo, hi] with minLiquidity = 0 and assert no revert.
}
```

Expect sporadic `CurrencyNotSettled`. The existing suite only ever rebalances from `[-600,600]` to `[-1200,1200]`, `[-540,540]`, `[600,1200]` or `[-1800,-600]` at fixed prices.

**Recommendation**: Deliberately under-fund the add by a couple of wei, so the ceiling always has slack, and add a defensive settle path for any residual debt.

```solidity
// Shave the inputs so the pool's round-up can never exceed what we hold.
uint256 fund0 = freed0 > 2 ? freed0 - 2 : 0;
uint256 fund1 = freed1 > 2 ? freed1 - 2 : 0;
newLiquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, fund0, fund1);
...
BalanceDelta net = removed + swapped + added;
if (net.amount0() > 0) cb.key.currency0.take(poolManager, cb.owner, uint256(uint128(net.amount0())), false);
else if (net.amount0() < 0) cb.key.currency0.settle(poolManager, address(this), uint256(uint128(-net.amount0())), false);
// same for amount1
```

The shaved wei simply flow back to the owner via the existing dust `take()`.

---

## [G-6] Unbounded rebalance repetition bleeds a position through LP fees; `minRebalanceInterval` may be zero and no-op rebalances are permitted
**Severity**: Medium
**Category**: general
**Location**: `rebalance()` — `AutopilotHook.sol:235-236, 239-240`; `setMinRebalanceInterval()` — `AutopilotHook.sol:467-471`; `constructor()` — `AutopilotHook.sol:118`
**Description**: Nothing establishes a lower bound on the rebalance cadence or requires a rebalance to be useful:

- `setMinRebalanceInterval(uint64 interval)` only checks the *upper* bound (`interval > MAX_REBALANCE_INTERVAL`, line 468). `0` is accepted, as it is in the constructor (line 118). With `minRebalanceInterval == 0`, `readyAt = pos.lastRebalanceAt + 0` and the check `block.timestamp < readyAt` never trips — every block is eligible.
- `rebalance()` never checks that `newTickLower != pos.tickLower || newTickUpper != pos.tickUpper`. Re-submitting the current range is legal and still executes a full remove → `_swapToRatio` → re-add cycle.
- The tick envelope is the only constraint on *where* the position may go, and a user who supplies `minUsableTick`/`maxUsableTick` (the pattern in the repo's own `_deposit` helper, `AutopilotHook.t.sol`) has no constraint at all.

Each cycle burns the pool's LP fee on whatever `_swapToRatio` moves — up to 100% of the position in the one-sided branches (G-4) — plus the price impact. An allowlisted rebalancer can therefore alternate a position between one range above spot and one range below spot, forcing a full-notional swap each time, and grind the position toward zero at roughly `fee + impact` per iteration. No funds leave to the attacker in this variant, but the owner's capital is destroyed; combined with G-2 the owner cannot `pause()` to stop it.

This falsifies the "trusted but bounded — cannot withdraw funds" claim in the weaker sense as well: the rebalancer cannot move funds to itself, but it can unilaterally destroy them.

**Proof of Concept**:
1. Owner deposits with a wide envelope (or the operator sets `minRebalanceInterval = 0`).
2. Attacker holding the rebalancer key loops: `rebalance(pid, A_lo, A_hi, 0)` where `[A_lo, A_hi]` is entirely above spot, then `rebalance(pid, B_lo, B_hi, 0)` where `[B_lo, B_hi]` is entirely below spot.
3. Each call takes the `sqrtPriceX96 <= sqrtA` or `sqrtPriceX96 >= sqrtB` branch of `_swapToRatio` and swaps the whole balance, paying `key.fee` each time. At `fee = 3000`, ~30 bps per call; ~230 calls halve the position.
4. The owner's only defence is to notice and `withdraw()`.

Untested: there is no test asserting value conservation across repeated rebalances, and no test with `minRebalanceInterval == 0`.

**Recommendation**:

```solidity
uint64 public constant MIN_REBALANCE_INTERVAL = 1 hours;

function setMinRebalanceInterval(uint64 interval) external onlyOwner {
    if (interval > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
    if (interval < MIN_REBALANCE_INTERVAL) revert IntervalTooShort();
    ...
}

// in rebalance():
if (newTickLower == pos.tickLower && newTickUpper == pos.tickUpper) revert NoOpRebalance();
```

Additionally, enforce a per-position monotonic value floor: record the liquidity-equivalent value at deposit and revert any rebalance that would take cumulative realised decay past an owner-set tolerance. Consider making the cooldown per-position and owner-settable, so an owner can throttle the bot on their own position rather than relying on a global admin.

---

## [G-7] `_add()` silently clamps an underflow to zero instead of reverting
**Severity**: Low
**Category**: general
**Location**: `_add()` — `AutopilotHook.sol:446-450`
**Description**:

```solidity
function _add(uint256 base, int128 delta) private pure returns (uint256) {
    if (delta >= 0) return base + uint256(uint128(delta));
    uint256 sub = uint256(uint128(-delta));
    return base > sub ? base - sub : 0;      // silent clamp
}
```

When the swap consumed more of a token than was freed, the helper returns `0` rather than reverting. This is the checklist's "semantic overloading" pattern: `0` now means both "genuinely nothing left" and "the accounting disagreed with itself". Downstream, `freed0`/`freed1` feed `getLiquidityForAmounts` at line 347 while the `net` reconciliation at line 370 uses the *real* deltas, so a clamp would desynchronise the two and surface as an opaque `CurrencyNotSettled` (or an under-sized `newLiquidity`) rather than as the actual invariant break.

I believe this is not currently reachable: in the one-sided branches `amountIn == have0`/`have1` exactly and the swap is exact-input, so `-swapped.amountX() <= have`; in the straddle branch `sell0` is clamped to `have0` at line 414 and `surplus1 = have1 - target1 <= have1`. Low severity on that basis — a latent-bug / defensive-coding issue, not an exploitable one.

**Proof of Concept**: Not exploitable as written. Failure mode: any future change to the swap sizing (for example the split-swap fix recommended in G-4) that lets the consumed amount exceed the freed amount would be masked here and re-emerge as an unrelated revert deep inside `PoolManager.unlock`.

**Recommendation**: Fail loudly.

```solidity
function _add(uint256 base, int128 delta) private pure returns (uint256) {
    if (delta >= 0) return base + uint256(uint128(delta));
    uint256 sub = uint256(uint128(-delta));
    if (sub > base) revert AccountingUnderflow();   // was: silent 0
    return base - sub;
}
```

---

## [G-8] Dead disjunct in the `sell0` clamp obscures the intended bound
**Severity**: Low
**Category**: general
**Location**: `_swapToRatio()` — `AutopilotHook.sol:414`
**Description**:

```solidity
if (sell0 == 0 || sell0 > have0) sell0 = sell0 > have0 ? have0 : sell0;
```

The `sell0 == 0` disjunct is inert: when `sell0 == 0`, the ternary evaluates `0 > have0` as false and assigns `sell0 = sell0`, a no-op. The statement is exactly equivalent to `if (sell0 > have0) sell0 = have0;`. The following line (415) then handles the zero case independently. This is the checklist's "incorrect logical operators" / complex-conditional item — the compound condition reads as if zero is being special-cased when it is not, which is precisely the kind of line a future edit gets wrong.

**Proof of Concept**: Not exploitable — the behaviour is correct today. Failure mode is maintainability: a reader (or a future patch) may believe a zero-guard lives here and remove line 415, at which point `amountIn == 0` would reach `poolManager.swap` and revert with `SwapAmountCannotBeZero` (`PoolManager.sol:193`).

**Recommendation**:

```solidity
if (sell0 > have0) sell0 = have0;
if (sell0 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
(zeroForOne, amountIn) = (true, sell0);
```

---

## [G-9] `withdraw()` does not undo all of `deposit()`'s state, and the tick envelope is immutable and unconstrained in width
**Severity**: Low
**Category**: general
**Location**: `deposit()` — `AutopilotHook.sol:154, 158-159`; `withdraw()` — `AutopilotHook.sol:202-204`
**Description**: Two related issues, both from the checklist's "withdraw should undo ALL deposit state changes" item.

`deposit()` writes five pieces of state: `boundLower[positionId]` (158), `boundUpper[positionId]` (159), `positions[positionId]` (178), `poolPositionCount[id]` (187), and `depositNonce` (157). `withdraw()` reverses only two fields of `positions` (`active`, `liquidity`) and `poolPositionCount` (202-204). `boundLower`/`boundUpper` and the `owner`/`key`/`tickLower`/`tickUpper` fields are left populated forever. This is harmless *today* only because `positionId = keccak256(abi.encode(msg.sender, id, depositNonce++))` (line 157, correctly using `abi.encode` not `abi.encodePacked`, so the checklist's hash-collision item does not apply) can never repeat — but it is an asymmetry that makes the storage state a misleading source of truth for indexers and for any future code that reads `boundLower[id]` without first checking `positions[id].active`.

Separately, the envelope is validated at deposit time only (`_validateTicks(key, minBound, maxBound)` at line 153, `tickLower < minBound || tickUpper > maxBound` at line 154) and can never be changed afterwards. There is no function to tighten it, and no minimum tightness: `deposit(key, lo, hi, L, TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing))` — verbatim the repo's own `_deposit` test helper — grants the rebalancer the entire tick space. The "bounded" half of the trust model is therefore a front-end convention, not an on-chain guarantee, and an owner who realises the bot is misbehaving cannot narrow the envelope; their only move is a full `withdraw()`.

**Proof of Concept**: Not exploitable directly.
1. `pid = deposit(key, -600, 600, 1e18, minUsable, maxUsable)` → the envelope is the whole tick space.
2. `withdraw(pid)` → `positions[pid].active == false`, but `boundLower(pid)`/`boundUpper(pid)` still return `minUsable`/`maxUsable`, and `positions(pid)` still returns the old owner, key and ticks.
3. An off-chain consumer reading `boundLower`/`boundUpper` alone sees a live envelope for a closed position.

**Recommendation**:

```solidity
function withdraw(bytes32 positionId) external nonReentrant {
    ...
    delete positions[positionId];
    delete boundLower[positionId];
    delete boundUpper[positionId];
    poolPositionCount[id] -= 1;
    ...
}
```

(Capture `key`/`ticks`/`liquidity` into memory before the `delete`, as the current code already does.) Additionally add an owner-only `tightenBounds(bytes32 positionId, int24 newLower, int24 newUpper)` that may only shrink the envelope, and consider an on-chain maximum envelope width so "bounded" means something without front-end cooperation.

---

## [G-10] ~~The hook's own re-ratio swap re-enters `_afterSwap`~~ — RETRACTED, v4 has a self-call guard
**Severity**: Info (retracted — the reentry premise is false)

> **Corrected during synthesis.** Two agents (general, access-control) reported
> that the hook's own `poolManager.swap` calls back into its `_afterSwap`. The
> `defi-amm` agent reported the opposite. The conflict was resolved by reading
> the vendored source, and `defi-amm` is correct.
>
> `Hooks.sol:217` short-circuits before dispatching to the hook:
>
> ```solidity
> if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);
> ```
>
> Because `_swapToRatio` calls `poolManager.swap` with the hook as `msg.sender`,
> `afterSwap` is **never invoked** for the hook's own re-ratio swap. Consequence 1
> below (the off-chain self-triggering feedback loop) therefore does not exist,
> and consequence 2 (mid-flight state read) does not arise.
>
> The real consequence is the **inverse**: the rebalance swap is invisible to the
> hook's own `AutopilotCheck` telemetry, so the off-chain daemon never observes an
> event for the large price move its own rebalance just caused — which matters
> given A-1/F-1, where that move is exactly what an attacker backruns.
>
> The final paragraph below stands on its own and is unaffected: a 1-wei position
> does impose a permanent per-swap cost on every unrelated user of the pool.

### Original text, retained for the record

**Original severity**: Low
**Category**: general
**Location**: `_afterSwap()` — `AutopilotHook.sol:127-139`; `_swapToRatio()` — `AutopilotHook.sol:425`
**Description**: `getHookPermissions()` sets `afterSwap = true` (line 124), and `PoolManager.swap` calls `key.hooks.afterSwap(...)` unconditionally (`PoolManager.sol:220` — confirmed in the vendored source). Because `_swapToRatio()` swaps through **the same pool whose hook this is**, every rebalance causes the PoolManager to call back into `AutopilotHook._afterSwap` mid-`unlock`, which reads `poolPositionCount[id]`, reads `getSlot0`, and emits `AutopilotCheck`.

Two consequences:
1. **Off-chain feedback loop.** `AutopilotCheck` is the trigger the bot watches to decide whether a rebalance is needed. A rebalance now emits one, at a price the rebalance itself just moved. Naive bot logic will re-arm on its own action; with `minRebalanceInterval == 0` (G-6) that is an unbounded self-driving loop.
2. **State read mid-flight.** At the moment `_afterSwap` runs, the position has been removed but not yet re-added. Nothing is corrupted — the callback is read-only and `onlyPoolManager`, the `HOOK_RETURNS_DELTA` flag is not set so the returned `int128(0)` is ignored, and `nonReentrant` plus the PoolManager `Lock` (`AlreadyUnlocked`, `PoolManager.sol:105`) block any re-entry into `deposit`/`withdraw`/`rebalance` — but the emitted `tick` is a price the hook itself created, a stale-read pattern for anyone consuming the event.

Separately and minor: the `count > 0` gate means a single 1-wei position makes every unrelated swap on that pool pay an extra `SLOAD`, an `extsload` and a `LOG` forever. Cheap, but an externality a griefer can switch on for the cost of one dust deposit.

**Proof of Concept**:
1. `_deposit(-600, 600, 1e18)`; drift the price out of range.
2. `vm.recordLogs(); vm.prank(rebalancer); hook.rebalance(pid, -1800, -600, 0);`
3. Scan the logs for `AutopilotCheck(bytes32,int24,uint256)` emitted by `address(hook)` — one is present, produced by the hook's own `_swapToRatio` swap. No existing test checks this.

**Recommendation**: Suppress the event while the hook is the one swapping. The `sender` argument to `_afterSwap` is `address(this)` for the internal swap, so no extra storage is needed:

```solidity
function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
    internal override returns (bytes4, int128)
{
    if (sender == address(this)) return (BaseHook.afterSwap.selector, int128(0));
    ...
}
```

---

## [G-11] `_inToken0()` / `_inToken1()` intermediates can revert at price or decimal extremes, blocking rebalance
**Severity**: Low
**Category**: general
**Location**: `_inToken1()` — `AutopilotHook.sol:436-439`; `_inToken0()` — `AutopilotHook.sol:441-444`; `haveValue` — `AutopilotHook.sol:406`
**Description**: Both helpers apply `FullMath.mulDiv` twice with no bound on the result:

```solidity
function _inToken1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
    uint256 half = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
    return FullMath.mulDiv(half, sqrtPriceX96, FixedPoint96.Q96);
}
```

`FullMath.mulDiv` reverts when the quotient exceeds `uint256`. `sqrtPriceX96 / Q96` can reach ~`2^64` at `MAX_SQRT_PRICE`, so `_inToken1` multiplies by up to `2^128`; with `amount0` near `2^127` (the `int128` ceiling on a `BalanceDelta` leg) the product approaches `2^255`. The subsequent `haveValue = _inToken1(have0, sqrtPriceX96) + have1` at line 406 is a checked addition on top of that and can itself overflow. `_inToken0` has the mirror problem at `MIN_SQRT_PRICE`, where `Q96 / sqrtPriceX96` is also ~`2^64`.

Confidence note: this is an analytical bound, not a demonstrated failure. Reaching it requires a genuinely extreme pool — a price ratio near the tick-space limits *and* a position large enough in raw units, realistically a token with very unusual decimals paired against a very high- or low-priced asset. I did not construct a concrete reachable instance. Severity is Low on that basis, and the failure is a revert rather than silent corruption: funds are not at risk and the owner can always `withdraw()`.

**Proof of Concept**: Failure mode, not an exploit. Initialise a pool near `MAX_SQRT_PRICE`, deposit a position whose `amount0` leg is large in raw units, drift the price so the rebalance takes the straddle branch (line 400), and call `rebalance`. `_inToken1` at line 406 reverts inside `FullMath.mulDiv`, and no rebalance of that position onto a straddling range is ever possible.

**Recommendation**: Since only the *ratio* `want1 / wantValue` is used (line 410), scale both `want0` and `want1` down by a common factor before valuing them, keeping the intermediates bounded regardless of position size. Add a fuzz test over `sqrtPriceX96` across the full `[MIN_SQRT_PRICE, MAX_SQRT_PRICE]` range and over token decimals, and document the supported price/decimal envelope.

---

## [G-12] State is written after the external `poolManager.unlock()` call in `deposit()` and `rebalance()`
**Severity**: Low
**Category**: general
**Location**: `deposit()` — `AutopilotHook.sol:161-188`; `rebalance()` — `AutopilotHook.sol:246-267`
**Description**: Both functions perform the external call first and update storage afterwards, inverting checks-effects-interactions:

- `deposit()` calls `poolManager.unlock(...)` at line 161 and only writes `positions[positionId]` and `poolPositionCount[id]` at lines 178-187. During the unlock, `_doDeposit` → `CurrencySettler.settle` → `IERC20.safeTransferFrom(cb.owner, poolManager, amount)` hands control to the token contract while `positions[positionId]` is still entirely zero.
- `rebalance()` calls `unlock` at line 246 and writes `pos.tickLower`/`tickUpper`/`liquidity`/`lastRebalanceAt` at lines 264-267. During the unlock, `_doRebalance` → `take()` → `poolManager.take` → `IERC20.transfer(cb.owner, …)` hands control to the token while `positions[positionId]` still describes the *old* range and *old* liquidity — which no longer exist in the PoolManager.

`withdraw()`, by contrast, is written correctly (state cleared at 202-204 before the unlock at 206).

I verified this is **not currently exploitable**: OpenZeppelin `ReentrancyGuard` is contract-wide, so `deposit`/`withdraw`/`rebalance` share one lock; `unlockCallback` is gated on `msg.sender == address(poolManager)` (line 272); `PoolManager.unlock` reverts with `AlreadyUnlocked` on any nested unlock (`PoolManager.sol:105`); and the only owner-gated functions reachable during the window are `setRebalancer`/`pause`, which an arbitrary token cannot reach. The residual exposure is read-only: the auto-generated `positions()` getter is observable mid-flight. Low severity as a latent-bug / defence-in-depth issue.

Separately, from the checklist's "nonReentrant must be FIRST" item: `deposit()` and `rebalance()` declare `whenNotPaused nonReentrant` (lines 148, 227-228), so `whenNotPaused` runs first. `Pausable._requireNotPaused` only reads a storage bool and makes no external call, so the ordering is benign here — worth fixing for consistency, not for security.

**Proof of Concept**: Not exploitable as written. Failure mode: an ERC20 with a transfer callback (ERC777-style, or any token with a hook on `transfer`) can, during a `rebalance()`, call `positions(positionId)` on the hook and receive `tickLower`/`tickUpper`/`liquidity` describing a position that no longer exists in the PoolManager. Any integrator that prices against that getter reads a stale value. Reachable today because the hook accepts arbitrary ERC20 pairs.

**Recommendation**: Move the state writes ahead of the unlock, using the values already known, and reconcile afterwards only where the unlock returns new information.

```solidity
// deposit(): write the position before unlocking. No rollback is needed because
// a revert inside unlock reverts the whole transaction.
positions[positionId] = Position({owner: msg.sender, key: key, tickLower: tickLower,
    tickUpper: tickUpper, liquidity: liquidity, active: true, lastRebalanceAt: 0});
poolPositionCount[id] += 1;
poolManager.unlock(abi.encode(Callback({...})));
emit PositionOpened(...);
```

For `rebalance()`, `newLiquidity` is only known after the callback, so mark the position transiently as "rebalancing" before the unlock (so getter consumers can detect the window) and commit the final values after. Also reorder the modifiers to `nonReentrant whenNotPaused`.

---

## [G-13] Non-standard ERC20 behaviours and admin ergonomics
**Severity**: Info
**Category**: general
**Location**: `_doDeposit()` — `AutopilotHook.sol:296-301`; `_doWithdraw()` — `AutopilotHook.sol:315-320`; `_doRebalance()` — `AutopilotHook.sol:371-376`; `renounceOwnership()` — `AutopilotHook.sol:473-475`; `setRebalancer()` — `AutopilotHook.sol:462-465`
**Description**: A collection of observations with no direct exploit, recorded for completeness against the checklist.

- **Fee-on-transfer tokens cannot be deposited.** `CurrencySettler.settle` does `sync()` → `safeTransferFrom(payer, poolManager, amount)` → `settle()`, and `PoolManager.settle` credits the *actually received* balance delta. An FoT token delivers less than `amount`, leaving a residual delta, and `PoolManager.unlock` reverts with `CurrencyNotSettled` (`PoolManager.sol:112`). A clean revert rather than a loss, but undocumented: `deposit()` will simply always fail for such pairs.
- **Blocklist tokens can strand a position.** `_doWithdraw` (lines 316/319) and `_doRebalance` (lines 372/375) `take()` directly to `cb.owner`. If the owner is later blocklisted by a token like USDC, every `withdraw()` and `rebalance()` for that position reverts permanently — there is no `recipient` parameter and no ERC-6909 claim path (`take(..., claims: false)` is hardcoded).
- **Rebasing tokens** are safe here: the hook stores `liquidity`, never raw balances, and never reads `balanceOf(address(this))` as a source of truth. The checklist's "mixed accounting" and "direct token transfers bypass accounting" items do not apply.
- **`renounceOwnership()` error is misleading for non-owners.** The override at line 473 keeps `onlyOwner`, so a non-owner calling it gets `OwnableUnauthorizedAccount` rather than `RenounceDisabled`. Dropping `onlyOwner` makes the intent unambiguous. (The `public view override` mutability restriction over `Ownable`'s non-view declaration is legal and compiles; no issue.)
- **`setRebalancer()` has no timelock and no zero-address guard**, and takes effect in the same block. Given G-1, rebalancer allowlisting is a value-bearing privilege. The checklist's "pause front-running" item also applies: an attacker who sees `pause()` in the mempool can front-run it with a final malicious `rebalance()`.
- **Solidity 0.8.26 / `evm_version = cancun`** is appropriate for both target chains; Base and Ethereum mainnet are both post-Cancun, so `PUSH0` and transient storage are available and the checklist's PUSH0-on-alt-L2 concern does not apply. No 0.8.26-specific compiler bug affecting this code was identified. There are no `unchecked` blocks in the contract.

**Proof of Concept**: None — informational.

**Recommendation**: Document the FoT/blocklist token limitations in the deployment runbook and gate which pools the front end offers. Add an optional `recipient` parameter to `withdraw()` and a `claims`-based fallback so a blocklisted owner is not permanently stranded. Remove `onlyOwner` from the `renounceOwnership()` override. Consider routing `setRebalancer(addr, true)` through a short timelock while leaving `setRebalancer(addr, false)` instant.
