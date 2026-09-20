# AutopilotHook — Weird-ERC20 Findings

**Scope:** `contracts/src/AutopilotHook.sol` against the weird-ERC20 checklist. Supporting reads: `uniswap-hooks/src/utils/CurrencySettler.sol`, v4-core `types/Currency.sol`, v4-core `PoolManager.sol` (`sync` / `_settle` / `take`), OpenZeppelin `SafeERC20` v5.5.0.

**Summary.** The hook never custodies ERC-20 balances — `CurrencySettler.settle()` pulls `transferFrom(owner → PoolManager)` and `CurrencySettler.take()` pushes `PoolManager → owner`, so all tokens sit in the v4 `PoolManager` and the hook stores only a geometric liquidity value `L`. That neutralises much of the weird-token surface: missing-return-value tokens (USDT) are safe on both legs, zero-amount transfers are double-guarded, the Q96 helpers in `_swapToRatio()` cannot overflow because v4 deltas are `int128`-bounded, and `currency1 == address(0)` is genuinely unreachable so the `currency0`-only native check is sufficient.

One premise in the brief should be corrected up front: fee-on-transfer tokens do **not** silently corrupt the stored `liquidity` — `PoolManager._settle()` credits `balanceAfter - balanceBefore`, so a short settle leaves a non-zero delta and the entire `unlock()` reverts with `CurrencyNotSettled`. The two real problems are (a) the withdrawal path hard-codes the recipient to `pos.owner` with no alternative and no ERC-6909 escape hatch, so a USDC/USDT blacklisting of one owner permanently strands **both** tokens of that position including the non-blacklisted one, and (b) the contract enforces **no token restriction whatsoever** beyond rejecting native ETH — every "we don't support weird tokens" assumption is unwritten and unenforced, while the target chains host PAXG, USDC, USDT, stETH and AMPL.

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 1 |
| Medium | 2 |
| Low | 3 |
| Info | 5 |
| **Total** | **11** |

| ID | Title | Severity |
| --- | --- | --- |
| T-1 | Blacklisted/frozen owner permanently bricks `withdraw()` and strands the paired token | High |
| T-2 | Fee-on-transfer tokens make `deposit()` revert unconditionally; no rejection, no documentation | Medium |
| T-3 | Rebasing tokens desync `PoolManager` reserves — stranded yield, and last-withdrawer insolvency on negative rebases | Medium |
| T-4 | No token allowlist: every weird-token restriction is assumed, none is enforced | Low |
| T-5 | Standing unbounded allowance granted directly to the hook; USDT non-zero→non-zero approve reverts | Low |
| T-6 | `_swapToRatio()` values everything in token1 units — 6-decimal token1 rounds small rebalances to a no-op swap and then reverts | Low |
| T-7 | `currency1 == address(0)` is unreachable — the `currency0`-only native check is sufficient | Info |
| T-8 | Missing-return-value tokens (USDT) are correctly handled on both settle and take legs | Info |
| T-9 | All zero-amount transfer paths are guarded (twice) | Info |
| T-10 | ERC-777 / ERC-677 callback tokens: no exploitable reentrancy window | Info |
| T-11 | Tests exercise only solmate `MockERC20`; zero weird-token coverage | Info |

---

## [T-1] Blacklisted/frozen owner permanently bricks `withdraw()` and strands the paired token

**Severity**: High
**Category**: erc20
**Location**: `_doWithdraw()` — AutopilotHook.sol:315-320; `_doRebalance()` — AutopilotHook.sol:371-376; `withdraw()` — AutopilotHook.sol:191-223

**Description**: `withdraw()` is the only exit and it hard-codes the payout recipient to the position owner: the callback is built with `owner: msg.sender` and `_doWithdraw()` calls `cb.key.currency0.take(poolManager, cb.owner, ...)` / `currency1.take(..., cb.owner, ...)`. `CurrencySettler.take()` with `claims = false` forwards to `poolManager.take(currency, to, amount)`, which performs a real `CurrencyLibrary.transfer()` — a raw `token.transfer(owner, amount)` from the PoolManager. USDC's `transfer` carries `notBlacklisted(msg.sender) notBlacklisted(to)`; USDT's carries the same via `blackListed[]`; both are also globally pausable, and both are upgradeable proxies on Ethereum and Base, so the predicate can change after deposit. If the owner is blacklisted (or the token is paused), that transfer reverts, the revert propagates out of `unlockCallback` through `poolManager.unlock()`, and the whole `withdraw()` transaction reverts.

The damage is not confined to the frozen asset. A position is two-sided: `_doWithdraw()` takes currency0 **and** currency1 in the same atomic unlock. A USDC blacklisting therefore permanently freezes the position's WETH/cbBTC leg as well — value the owner is otherwise fully entitled to. There is no mitigation in the contract: no recipient parameter, no position-ownership transfer, no partial withdrawal, and no `claims = true` variant that would mint ERC-6909 credit (which would succeed, because ERC-6909 minting never touches the underlying token).

Note this is distinct from the pause question settled elsewhere — `withdraw()` is correctly non-pausable and pause cannot trap funds; the trap here comes from the token, not the hook's own pause. `rebalance()` is blocked identically — lines 372/375 take to `cb.owner` — so the position cannot even be moved out of the way. The funds are irrecoverable for the lifetime of the contract.

The same mechanism bites in the other direction for deposits: because `CurrencySettler.settle()` executes `IERC20(currency).safeTransferFrom(payer, address(poolManager), amount)` with **the hook as `msg.sender`**, the hook contract is itself a blacklist target. USDC's `transferFrom` is `notBlacklisted(msg.sender) notBlacklisted(from) notBlacklisted(to)`. If Circle ever blacklists the hook address, every USDC deposit for every user fails permanently, for a contract that is non-upgradeable and has no migration path.

**Proof of Concept**:

1. Alice opens a position in the USDC/WETH pool (Ethereum: `currency0 = USDC 0xA0b8…` at 6 decimals, `currency1 = WETH 0xC02a…`), depositing 50,000 USDC and 15 WETH worth of liquidity. `positions[id].active = true`.
2. Later, Circle adds Alice to the USDC blacklist — an OFAC-driven action, exactly what happened to the Tornado Cash addresses in August 2022, and irreversible from the user's side.
3. Alice calls `withdraw(id)`. `_doWithdraw()` removes the liquidity (both `delta.amount0()` and `delta.amount1()` positive), then line 316 calls `take(poolManager, Alice, 50_000e6, false)` → `PoolManager.take` → `USDC.transfer(Alice, 50_000e6)` → reverts `Blacklistable: account is blacklisted`.
4. The revert unwinds `modifyLiquidity`, `unlock()`, and the `pos.active = false` / `pos.liquidity = 0` writes at lines 202-203. State is restored; the call reverts.
5. Alice's 15 WETH — an asset with no blacklist at all — is now permanently locked inside the v4 `PoolManager` under `salt = positionId`, reachable only through this hook, which will never pay it out.

Variant: Tether freezes an address holding a USDT/WETH position — identical outcome. Variant: Circle pauses USDC during an incident — every USDC-paired position is un-withdrawable for the duration.

**Recommendation**: Give the exit path an escape hatch that cannot be censored, and decouple the two legs.

```solidity
// 1. Let the caller redirect the payout, and let them take ERC-6909 credit
//    instead of the underlying (minting ERC-6909 never calls the token).
function withdraw(bytes32 positionId, address recipient, bool asClaims) external nonReentrant {
    ...
    if (recipient == address(0)) revert ZeroRecipient();
    // pack `recipient` and `asClaims` into Callback
}

function _doWithdraw(Callback memory cb) internal {
    (BalanceDelta delta,) = poolManager.modifyLiquidity(...);
    if (delta.amount0() > 0) {
        cb.key.currency0.take(poolManager, cb.recipient, uint256(uint128(delta.amount0())), cb.asClaims);
    }
    if (delta.amount1() > 0) {
        cb.key.currency1.take(poolManager, cb.recipient, uint256(uint128(delta.amount1())), cb.asClaims);
    }
}
```

`asClaims = true` mints ERC-6909 claim tokens inside the PoolManager, rescuing the non-blacklisted leg unconditionally and preserving a transferable claim on the frozen leg. Also make `rebalance()`'s surplus `take()` target a recipient rather than `pos.owner`, or route dust to ERC-6909, so a frozen owner cannot grief keeper transactions.

---

## [T-2] Fee-on-transfer tokens make `deposit()` revert unconditionally; no rejection, no documentation

**Severity**: Medium
**Category**: erc20
**Location**: `_doDeposit()` — AutopilotHook.sol:296-301; `deposit()` — AutopilotHook.sol:178-186

**Description**: The brief hypothesised that `deposit()` records `liquidity` as the requested amount and would therefore silently over-credit a fee-on-transfer depositor. Tracing the accounting shows that is **not** what happens, and the real outcome should be recorded correctly. v4's `PoolManager._settle()` measures what actually arrived:

```solidity
uint256 reservesBefore = CurrencyReserves.getSyncedReserves();
uint256 reservesNow    = currency.balanceOfSelf();
paid = reservesNow - reservesBefore;
_accountDelta(currency, paid.toInt128(), recipient);
```

`CurrencySettler.settle()` calls `poolManager.sync(currency)` immediately before the `safeTransferFrom`, so `reservesBefore` is exact. With a fee-on-transfer token the PoolManager receives `amount - fee`, credits the hook only `amount - fee`, and the hook's currency delta is left at `-fee`. `PoolManager.unlock()` then hits `if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith()` and the entire `deposit()` reverts. There is no silent desync and no free liquidity: `positions[positionId]` at line 178 is written only after a successful `unlock()`, and the `liquidity` it stores is the same `L` the PoolManager minted, not a token amount.

The issue is the resulting behaviour, not corruption: the hook accepts an arbitrary `PoolKey` (it validates only `key.hooks == address(this)` at line 150 and `currency0 != address(0)` at line 151), so a user can drive a position-opening flow against a fee-on-transfer pair that is guaranteed to revert with an opaque `CurrencyNotSettled` from deep inside v4. The token class is never rejected, never allowlisted, never documented. The failure is asymmetric and can appear mid-life: `_doWithdraw()` and `_doRebalance()` only ever `take()`, never `settle()`, so existing positions continue to close normally (the owner simply receives `amount - fee`), but new deposits stop working the moment a fee is switched on.

**Proof of Concept**:

- *Permanent case:* PAXG (`0x45804880De22913dAFE09f4980848ECE6EcbAf78`, Paxos Gold) charges a transfer fee via its `feeRate`. Alice approves the hook and calls `deposit()` for liquidity requiring 10 PAXG in a PAXG/USDC pool. `settle()` does `PAXG.transferFrom(Alice, poolManager, 10e18)`; PAXG delivers `10e18 - fee`. `_settle()` credits `10e18 - fee`; the hook's delta is `-fee`; `unlock()` reverts `CurrencyNotSettled`. Every deposit into any PAXG pair fails, forever.
- *Latent case:* USDT (`0xdAC17F958D2ee523a2206206994597C13D831ec7`) has a dormant fee: `basisPointsRate` is currently `0`, but Tether's owner can call `setParams(basisPointsRate ≤ 20, maximumFee)` at any time. The instant that happens, every existing USDT-paired position stops accepting deposits while remaining withdrawable — a silent, third-party-triggered feature outage.

**Recommendation**: Enforce the restriction or make it impossible to hit silently:

```solidity
error FeeOnTransferNotSupported(Currency currency);

// inside deposit(), before unlock():
if (!allowedPair[keccak256(abi.encode(key.currency0, key.currency1))]) revert PairNotAllowed();
```

If an allowlist is undesirable, at minimum catch the condition explicitly: measure `IERC20(...).balanceOf(address(poolManager))` around the settle inside `_doDeposit()` and `revert FeeOnTransferNotSupported(currency)` on a shortfall. Do not attempt to "support" fee-on-transfer by re-deriving `L` from the received amount — that needs a second `modifyLiquidity` round trip and still leaves dust unsettled. Either way, state the restriction in NatSpec on `deposit()`.

---

## [T-3] Rebasing tokens desync `PoolManager` reserves — stranded yield, and last-withdrawer insolvency on negative rebases

**Severity**: Medium
**Category**: erc20
**Location**: `Position.liquidity` — AutopilotHook.sol:40, 184; `_doWithdraw()` — AutopilotHook.sol:315-320

**Description**: Answering the brief's question directly: the hook's stored `Position.liquidity` does **not** desync on a rebase. `liquidity` is the v4 geometric quantity `L`, not a token balance, and the PoolManager stores the identical `L` under `(address(this), tickLower, tickUpper, salt = positionId)`. A rebase changes neither. The desync is one level down — between the PoolManager's `CurrencyReserves`/delta accounting and the token's actual `balanceOf(poolManager)` — and because this hook is a custody product that never re-reads `balanceOf`, its users absorb the consequences with no way to detect or correct them.

Two failure modes:

1. **Positive rebase (stETH, AMPL expansion, aTokens, OHM).** `stETH.balanceOf(poolManager)` grows daily, but v4 attributes deltas only through `modifyLiquidity`/`swap`/`settle`. The surplus belongs to no position. It is not claimable by the hook — `take()` requires a positive delta the hook does not have — nor freely sweepable by a third party, because `PoolManager.sync()` resets `reservesBefore` to the already-inflated balance so a later `settle()` credits `0`. The rebase yield is permanently stranded. A user who deposits 100 stETH of liquidity and withdraws a year later forfeits ~3%/yr of staking yield they would have kept holding the token directly.

2. **Negative rebase (AMPL contraction, a stETH slashing event).** A contraction reduces `balanceOf(poolManager)` while v4 still owes LPs the full pre-rebase amounts, leaving the PoolManager under-collateralised in that currency. Withdrawals are served first-come-first-served until the balance runs out: `PoolManager.take` → `CurrencyLibrary.transfer` → `AMPL.transfer` reverts on insufficient balance and the whole `withdraw()` unlock reverts. The last LPs out cannot exit at all.

Confidence note: mode 1 was confirmed by reading `sync`/`_settle`/`take` directly. Mode 2 follows from the same accounting but was not fork-tested against a live v4 pool with an actual negative rebase, so treat the exact insolvency ordering as reasoned rather than demonstrated — this is part of why the finding is Medium and not High.

**Proof of Concept**:

- *Stranded yield:* stETH (`0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`) in a stETH/WETH pool. Alice deposits liquidity requiring 100 stETH. Over twelve months Lido rebases the PoolManager's stETH balance up by roughly 3 stETH attributable to her share. On withdrawal `_doWithdraw()` takes exactly what v4's delta math computes from `L` and the tick range — the extra 3 stETH is never part of any delta and stays in the PoolManager permanently.
- *Insolvency:* AMPL (`0xD46bA6D942050d489DBd938a2C909A5d5039A161`) in an AMPL/WETH pool. AMPL rebases negatively whenever it trades below target — a routine daily occurrence during downtrends, historically as much as ~10% in one rebase. After a 10% contraction the PoolManager holds 90 AMPL against 100 AMPL of LP claims. The first nine withdrawers are paid in full; Alice hits `AMPL.transfer(Alice, 10e9)` with 1 AMPL remaining → revert → her position, including its WETH leg in the same atomic unlock, is stuck.

**Recommendation**: This is a v4-wide property, not a bug this hook introduces, but the hook chooses to custody arbitrary pairs and should be the party that restricts them. Add the pair allowlist from T-4 and exclude rebasing assets; for stETH require the wrapped non-rebasing variant (wstETH, `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`), and document that raw stETH, AMPL, aTokens and OHM are unsupported. The ERC-6909 exit from T-1 also helps here: claim credit is minted from PoolManager accounting and does not require the token balance to be present. If a rebasing pair must be supported, account positions in the token's share unit (wstETH, `scaledBalanceOf` for aTokens) rather than the rebasing unit.

---

## [T-4] No token allowlist: every weird-token restriction is assumed, none is enforced

**Severity**: Low
**Category**: erc20
**Location**: `deposit()` — AutopilotHook.sol:148-154

**Description**: `deposit()` performs exactly three validations on the pool it is about to custody: `liquidity != 0` (line 149), `address(key.hooks) == address(this)` (line 150), and `Currency.unwrap(key.currency0) != address(0)` (line 151). Ticks are then checked. Nothing else about the pair is constrained — not decimals, not the token's code, not an allowlist. Any address on Ethereum or Base can open a position in any pool that names this hook, with any two ERC-20s.

That matters because every restriction this report relies on — "we don't support fee-on-transfer" (T-2), "we don't support rebasing" (T-3) — exists only in commentary, not in code. The contract has no way to stop a bad pair being onboarded other than `pause()`, a blunt global switch that blocks all deposits and rebalances at once. Answering the brief's question plainly: **no token restriction is enforced anywhere; all of them are assumed.**

Checklist items that are correctly *not* exploitable, but only because the hook's shape happens to avoid them — an allowlist would make this robust rather than accidental: `decimals()` is never called (zero-address-`decimals()` DoS N/A), `name()`/`symbol()` never read (MKR's `bytes32` metadata N/A), `totalSupply()` never used for pricing (DAI flash-minting N/A), `type(uint256).max` never passed as an amount (cUSDCv3 "transfer-all" N/A), and no amount can exceed `uint128.max` because it derives from an `int128` v4 delta (UNI/COMP's `uint96` ceiling unreachable — and `uint96.max ≈ 7.9e28` exceeds UNI's entire `1e27` supply anyway).

**Proof of Concept**: Any pool on Base whose key names this hook is depositable today: a `PAXG/USDC` pool (reverts, T-2), an `AMPL/WETH` pool (insolvency risk, T-3), or a pool with an arbitrary user-deployed token whose `transfer` returns `false` on success (OZ `SafeERC20` reverts the settle with `SafeERC20FailedOperation`). Nothing in `deposit()` distinguishes these from `USDC/WETH`.

**Recommendation**: Add an owner-curated pair allowlist checked in `deposit()` only. Rebalancing and withdrawal must remain permitted for already-open positions even if a pair is later de-listed, so de-listing never becomes a fund trap:

```solidity
mapping(bytes32 => bool) public allowedPair;
event PairAllowed(Currency indexed currency0, Currency indexed currency1, bool allowed);

function setAllowedPair(Currency c0, Currency c1, bool allowed) external onlyOwner {
    allowedPair[keccak256(abi.encode(c0, c1))] = allowed;
    emit PairAllowed(c0, c1, allowed);
}

// in deposit(), alongside the existing checks:
if (!allowedPair[keccak256(abi.encode(key.currency0, key.currency1))]) revert PairNotAllowed();
// deliberately NOT checked in withdraw() or rebalance()
```

---

## [T-5] Standing unbounded allowance granted directly to the hook; USDT non-zero→non-zero approve reverts

**Severity**: Low
**Category**: erc20
**Location**: `_doDeposit()` → `CurrencySettler.settle(..., cb.owner, ..., false)` — AutopilotHook.sol:297, 300

**Description**: `CurrencySettler.settle()` executes `IERC20(currency).safeTransferFrom(payer, address(poolManager), amount)` with the hook as caller, so depositors must grant their allowance to the **hook address**, not to Permit2 and not to a v4 router. The tests reflect the expected UX: `MockERC20(...).approve(address(hook), type(uint256).max)` (AutopilotHook.t.sol:45-46). Two consequences.

First, USDT's approve race guard. USDT's `approve` carries `require(!((_value != 0) && (allowances[msg.sender][_spender] != 0)))`, so a user with a non-zero, non-infinite USDT allowance to the hook who tries to raise it has the transaction revert. Any front-end doing a naive `approve(hook, newAmount)` fails for USDT specifically and works for everything else — the classic hard-to-diagnose integration break. BNB conversely reverts on `approve(spender, 0)`, so the usual reset-to-zero workaround is not universally safe either.

Second, the standing allowance is a durable authority surface. Every path reaching a `settle()` was traced and it is **not** currently exploitable: `settle()` is reached only from `_doDeposit()`; `_doDeposit()` only from `unlockCallback`, gated by `if (msg.sender != address(poolManager)) revert NotPoolManager()`; and `PoolManager.unlock()` calls back into `IUnlockCallback(msg.sender)`, so only the hook's own `unlock()` can reach the hook's `unlockCallback`. The `Callback.owner` used as settle payer is set to `msg.sender` at line 173 and nowhere else. `withdraw()` and `rebalance()` carry an `owner` field too but never settle — they only `take()`. So the hook cannot be made to spend a third party's allowance today. The risk is latent: any future function that settles with a caller-supplied payer converts every outstanding infinite approval into an immediate drain.

**Proof of Concept**: Alice has approved the hook for 1,000 USDT (`0xdAC17F958D2ee523a2206206994597C13D831ec7`) and wants to deposit 5,000. The front-end calls `USDT.approve(hook, 5000e6)`; USDT reverts because `allowances[Alice][hook] == 1000e6 != 0`. Alice must first send `USDT.approve(hook, 0)` — a second transaction with no error explaining why. The same sequence on USDC, WETH or DAI succeeds.

**Recommendation**: Integrate Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) for the pull leg so users approve the canonical contract once rather than granting a bespoke allowance to a new, non-upgradeable one; v4 periphery already assumes this pattern. If direct approvals are kept, use `forceApprove` semantics in every off-chain client (reset-to-zero then set) and document the USDT quirk. Add NatSpec on `deposit()` stating the approval target is the hook, since that differs from the v4 norm.

---

## [T-6] `_swapToRatio()` values everything in token1 units — 6-decimal token1 rounds small rebalances to a no-op swap and then reverts

**Severity**: Low
**Category**: erc20
**Location**: `_swapToRatio()` — AutopilotHook.sol:403-421; `_inToken1()` / `_inToken0()` — AutopilotHook.sol:436-444

**Description**: The straddling branch converts both holdings into token1 terms (`haveValue = _inToken1(have0, sqrtPriceX96) + have1`), computes `target1 = FullMath.mulDiv(haveValue, want1, wantValue)` and trades the difference. Every intermediate is denominated in token1's *smallest unit*. When token1 has 6 decimals (USDC, USDT) that unit is a million times coarser, and `mulDiv` truncates toward zero at each step.

First the negative result, because it is the more commonly alleged issue: **these helpers cannot overflow**. `_inToken1` computes `amount0 · (sqrtP/Q96)²` in two `FullMath.mulDiv` steps, and `mulDiv` reverts only if the quotient exceeds `uint256`. `sqrtPriceX96 ≤ TickMath.MAX_SQRT_PRICE ≈ 2¹⁶⁰`, so `(sqrtP/Q96)² ≤ 2¹²⁸`; `amount0` always originates from a v4 `int128` delta so `amount0 < 2¹²⁷`; the product is bounded by `2²⁵⁵`. The intermediate `half < 2¹⁹¹` is likewise safe. `_inToken0` is symmetric with `sqrtP ≥ MIN_SQRT_PRICE ≈ 2³²`, same bound. Non-18-decimal tokens do not change this, because decimals enter only through the price and the price is clamped by the tick range. No overflow finding.

The real effect is low-end truncation. For a DAI/USDC pool on Base (`currency0 = DAI 0x50c5…` 18 dec, `currency1 = USDC 0x8335…` 6 dec) the price is ~1e-12, so `sqrtP/Q96 ≈ 1e-6` and `_inToken1` divides `have0` by ~1e12 across its two steps. A `have0` below ~1e12 wei of DAI maps to `0`. When `haveValue`/`wantValue` collapse, line 408 returns `ZERO_DELTA`; when `surplus1 == 0`, line 419 does the same; when `sell0` truncates to `0`, line 415 does the same. The swap is skipped, `getLiquidityForAmounts` is called on an unbalanced pair, and — in exactly the out-of-range case the comment at lines 338-341 says the swap exists to handle — `newLiquidity` comes out `0` and line 354 reverts `ZeroLiquidity()`. Nothing is lost (the unlock reverts atomically), but a dust-sized position in a 6-decimal-token1 pool becomes permanently un-rebalanceable and the keeper burns gas discovering it.

Note also line 414, a convoluted no-op: `if (sell0 == 0 || sell0 > have0) sell0 = sell0 > have0 ? have0 : sell0;` reduces to `sell0 = min(sell0, have0)`; the `sell0 == 0` disjunct does nothing.

**Proof of Concept**: A DAI/USDC pool on Base at 1:1. A position whose removal frees `freed0 = 5e11` wei DAI and `freed1 = 0`, targeting a range straddling spot. `_inToken1(5e11, sqrtP)`: `half = mulDiv(5e11, sqrtP, Q96) = 5e5`; `result = 5e5 / 1e6 = 0`. So `haveValue = 0`, line 408 returns `ZERO_DELTA`, no swap, `getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, 5e11, 0)` for a straddling range floors to `0`, and line 354 reverts `ZeroLiquidity()`. The same position in a WETH/DAI pool (both 18 decimals) rebalances fine.

**Recommendation**: Enforce a minimum position size at deposit so sub-dust positions cannot be created, and make the truncation failure legible:

```solidity
error PositionTooSmall();
// in deposit():
if (liquidity < minLiquidityFloor) revert PositionTooSmall();
```

Simplify line 414 to `if (sell0 > have0) sell0 = have0;`, and consider valuing in token0 terms when `sqrtPriceX96 < FixedPoint96.Q96` so the coarser unit is never the accumulator.

---

## [T-7] `currency1 == address(0)` is unreachable — the `currency0`-only native check is sufficient

**Severity**: Info
**Category**: erc20
**Location**: `deposit()` — AutopilotHook.sol:151

**Description**: `deposit()` rejects native ETH with `if (Currency.unwrap(key.currency0) == address(0)) revert NativeNotSupported();` and never inspects `key.currency1`. This is sufficient rather than an oversight. `PoolManager.initialize` enforces strict ordering:

```solidity
if (key.currency0 >= key.currency1) {
    CurrenciesOutOfOrderOrEqual.selector.revertWith(...);
}
```

`Currency` comparisons are `address` comparisons and `address(0)` is the minimum of that domain, so `currency1 == address(0)` would require `currency0 < address(0)` — impossible. A pool with native ETH always carries it as `currency0`, which line 151 catches. A caller hand-crafting an out-of-order `PoolKey` to evade the check gets a different `key.toId()`, whose pool was never initialised, so `modifyLiquidity` reverts on `pool.checkPoolInitialized()`.

Consequence worth noting: because native ETH is excluded, the `currency.isAddressZero()` branch of `CurrencySettler.settle()` (which does `poolManager.settle{value: amount}()`) is dead code here, and the hook correctly has no `receive()`/`payable` surface.

**Proof of Concept**: N/A — a confirmation, not a vulnerability. Attempted evasion: call `deposit()` with `currency0 = USDC`, `currency1 = address(0)`. `key.toId()` hashes to a pool `PoolManager.initialize` could never have created, so `_doDeposit`'s `modifyLiquidity` reverts `PoolNotInitialized`.

**Recommendation**: No change required. Optionally record *why* the single check is complete so a future refactor does not weaken it:

```solidity
// v4 enforces currency0 < currency1 at initialize(), and address(0) is the
// minimum address, so native ETH can only ever appear as currency0.
if (Currency.unwrap(key.currency0) == address(0)) revert NativeNotSupported();
```

---

## [T-8] Missing-return-value tokens (USDT) are correctly handled on both settle and take legs

**Severity**: Info
**Category**: erc20
**Location**: `_doDeposit()` — AutopilotHook.sol:297, 300; `_doWithdraw()` — AutopilotHook.sol:316, 319

**Description**: USDT on Ethereum declares `transfer`/`transferFrom` with no `bool` return, breaking callers with a strict `IERC20` interface. Both legs here are safe, for different reasons, both confirmed in the vendored sources.

Inbound (`settle`): `CurrencySettler.settle()` uses `SafeERC20.safeTransferFrom` from OpenZeppelin v5.5.0, whose `_callOptionalReturn` treats empty return data as success and additionally requires `address(token).code.length != 0`, so a non-contract "token" address is rejected rather than silently succeeding. This is stricter than solmate's `SafeTransferLib`, which the checklist flags for succeeding against EOAs.

Outbound (`take`): `CurrencySettler.take()` forwards to `PoolManager.take` → `CurrencyLibrary.transfer`, whose assembly accepts a call as successful when it either returned exactly `1` or returned nothing:

```solidity
or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize()))
```

USDT's zero-length return satisfies `iszero(returndatasize())`. Failures bubble up as `ERC20TransferFailed` via ERC-7751.

The related "returns `false` on success" item behaves correctly-but-strictly: `SafeERC20` reverts the deposit and v4's assembly reverts the take — a safe failure, not a loss. Chain-specific variance (USDT returning `bool` on Polygon but not Ethereum) is irrelevant because neither path type-checks the return.

**Proof of Concept**: N/A — verification item. A USDT/WETH position deposits via `USDT.transferFrom(owner, poolManager, amount)` returning zero bytes; `_callOptionalReturn` sees `returndata.length == 0` and `poolManager.code.length != 0` and succeeds. On withdrawal `USDT.transfer(owner, amount)` returns zero bytes and the `iszero(returndatasize())` branch marks it successful.

**Recommendation**: No change. Keep the OZ `SafeERC20` dependency pinned — do not swap `CurrencySettler` for a solmate-based variant, which would lose the `code.length` check and let a deposit against a non-existent token address succeed silently.

---

## [T-9] All zero-amount transfer paths are guarded (twice)

**Severity**: Info
**Category**: erc20
**Location**: `_doDeposit()` — AutopilotHook.sol:296, 299; `_doWithdraw()` — AutopilotHook.sol:315, 318; `_doRebalance()` — AutopilotHook.sol:371, 374

**Description**: LEND, BNB and others revert on zero-value transfers, turning an unconditional `transfer(x, 0)` into a DoS. All six transfer sites are guarded at the call site, and `CurrencySettler` guards them again internally.

Call-site guards: `_doDeposit` settles only `if (delta.amount0() < 0)` / `if (delta.amount1() < 0)`; `_doWithdraw` takes only `if (delta.amount0() > 0)` / `if (delta.amount1() > 0)`; `_doRebalance` takes the surplus only `if (net.amount0() > 0)` / `if (net.amount1() > 0)`. Library guards: both `CurrencySettler.settle` and `take` open with `if (amount == 0) return;`, commented "Early return when amount is 0 given that some tokens may revert in this case". A zero-amount `transfer` is unreachable.

One-sided cases behave correctly: a range entirely above or below spot produces a zero delta on one currency, which the strict inequalities skip — the normal out-of-range case, handled. `deposit()` also rejects `liquidity == 0` at line 149, so at least one side is always non-zero. The unhandled sign combinations (`delta.amount0() > 0` during a deposit, `< 0` during a withdraw) are unreachable for a fresh `salt` and, if they occurred, would leave a non-zero delta and revert the unlock with `CurrencyNotSettled` rather than losing funds.

**Proof of Concept**: N/A — verification item. A position opened entirely above spot in a hypothetical BNB pair funds only `currency0`; `delta.amount1()` is `0`, line 299's `< 0` test is false, `settle` is never called, and no `BNB.transferFrom(owner, pm, 0)` is issued.

**Recommendation**: No change. If `_doRebalance`'s net-delta arithmetic is refactored, preserve the strict `> 0` tests rather than switching to `>=`.

---

## [T-10] ERC-777 / ERC-677 callback tokens: no exploitable reentrancy window

**Severity**: Info
**Category**: erc20
**Location**: `unlockCallback()` — AutopilotHook.sol:271-283; `deposit()` / `withdraw()` / `rebalance()` — AutopilotHook.sol:148, 191, 228

**Description**: ERC-777 tokens masquerading as ERC-20 (imBTC `0x3212b29E33587A00FB1C83346f5dBFA69A458923`, pNetwork PNT) fire a `tokensToSend` hook on the *sender* during `transferFrom`, handing the depositor control mid-settle. No exploitable window was found; the reasoning is recorded because the conclusion is non-obvious and a refactor could break it.

The callback fires inside `CurrencySettler.settle()`, between `poolManager.sync(currency)` and `poolManager.settle()`, while the PoolManager is unlocked. What the attacker can reach:

- **Re-entering the hook.** `deposit()`, `withdraw()` and `rebalance()` all carry `nonReentrant`, and OZ's `ReentrancyGuard` uses a single shared `_status` slot, so the guard engaged by the outer `deposit()` blocks all three. `unlockCallback` is gated by `msg.sender != address(poolManager)`, and `PoolManager.unlock()` dispatches to `IUnlockCallback(msg.sender)` — only the hook's own `unlock()` reaches the hook's `unlockCallback`, and a nested `unlock()` reverts `AlreadyUnlocked`.
- **Calling the PoolManager directly.** `take`, `swap`, `modifyLiquidity`, `mint` are `onlyWhenUnlocked` and reachable by any address at this moment. But v4 keys deltas by `msg.sender`, so an attacker calling `take` creates a negative delta against *themselves*, and `unlock()`'s closing `NonzeroDeltaCount.read() != 0` check reverts the whole transaction unless they settle it. The hook's positive deltas are not addressable by anyone else.
- **Calling `poolManager.sync()`.** `sync` is external and ungated, so the attacker can re-point `CurrencyReserves` to a different currency mid-settle. The subsequent `settle()` then credits `paid` for the wrong currency, leaving the hook's real delta negative → `CurrencyNotSettled` → revert. The attacker donates their own tokens and the transaction unwinds: self-griefing, not theft.
- **Observing half-written state.** `deposit()` writes `positions[positionId]` only *after* `unlock()` returns (line 178), so during the callback the position reads `active = false`. `nonReentrant` makes that non-actionable, but it is a check-effects-interactions inversion.

ERC-677 tokens (LINK `0x514910771AF9Ca656af840dff83E8264EcF986CA`) are a non-issue on both legs: the callback lives in `transferAndCall`, while `settle` uses `transferFrom` and `take` uses `transfer`, neither of which invokes a hook. ERC-1363 likewise only calls back through `transferAndCall`/`approveAndCall`. The historical Gnosis Chain USDC/WETH/WBTC post-transfer callbacks are out of scope for Ethereum and Base.

**Proof of Concept**: N/A — verification item. Attempt: Alice is a contract holding imBTC with a registered `tokensToSend` implementation. She calls `deposit()` for an imBTC pair. During `settle`'s `safeTransferFrom` her hook fires and calls `hook.withdraw(otherPositionId)` → reverts `ReentrancyGuardReentrantCall`. She instead calls `poolManager.take(currency1, Alice, X)` → succeeds locally but leaves her own delta at `-X`, so `unlock()` reverts `CurrencyNotSettled` and the deposit fails atomically.

**Recommendation**: No change required, but preserve the invariants that make this safe: keep `nonReentrant` on all three external entry points, keep the `msg.sender != address(poolManager)` gate on `unlockCallback`, and add no external entry point that settles without the guard. As defence in depth, move the `positions[positionId]` write in `deposit()` to before `poolManager.unlock()` so the contract is CEI-compliant rather than relying solely on the reentrancy guard.

---

## [T-11] Tests exercise only solmate `MockERC20`; zero weird-token coverage

**Severity**: Info
**Category**: erc20
**Location**: `contracts/test/AutopilotHook.t.sol:17, 37, 45-46`

**Description**: The suite builds its currencies with `deployMintAndApprove2Currencies()` and casts them to solmate's `MockERC20` — a maximally well-behaved token: 18 decimals, returns `true`, no fee, no blacklist, no pause, no rebase, no callbacks. Every behaviour in this report is therefore untested. Nothing covers: a fee-on-transfer `settle` shortfall and the resulting `CurrencyNotSettled` (T-2); a `take` to a recipient whose `transfer` reverts, and the fact that it strands the paired token (T-1); a balance that changes without a transfer (T-3); a 6-decimal `currency1` meeting `_swapToRatio`'s token1-denominated value math (T-6); a token with no `bool` return (T-8); or a token reverting on zero-value transfers (T-9).

This is the gap that makes T-1 easy to miss: a test asserting "owner gets their tokens back" passes trivially against `MockERC20` and says nothing about the one-recipient-only exit design.

**Proof of Concept**: N/A — coverage observation.

**Recommendation**: Add a small mock family and a test per behaviour:

```solidity
contract FeeOnTransferERC20 is MockERC20 {            // T-2
    uint256 public feeBps = 20;
    function transferFrom(address f, address t, uint256 a) public override returns (bool) {
        uint256 fee = a * feeBps / 10_000;
        super.transferFrom(f, address(0xdead), fee);
        return super.transferFrom(f, t, a - fee);
    }
}

contract BlacklistERC20 is MockERC20 {                // T-1
    mapping(address => bool) public blocked;
    function block_(address a) external { blocked[a] = true; }
    function transfer(address t, uint256 a) public override returns (bool) {
        require(!blocked[t], "blacklisted");
        return super.transfer(t, a);
    }
}

contract RebasingERC20 is MockERC20 { /* owner-callable balance scaler */ }   // T-3
contract NoReturnERC20  { /* transfer/transferFrom with no return value */ }  // T-8
contract RevertOnZeroERC20 is MockERC20 { /* require(a > 0) */ }             // T-9
```

The T-1 test is the important one and should assert the loss explicitly: blacklist the owner on `currency0`, call `withdraw()`, expect a revert, and assert the owner's `currency1` balance is unchanged — i.e. that the clean asset is stranded. Add a 6-decimal `MockERC20("USDC", "USDC", 6)` fixture and run the existing rebalance tests against it (T-6).
