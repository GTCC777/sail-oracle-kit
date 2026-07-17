# sail-oracle-kit

Open-source [`IOracle`](src/interfaces/IOracle.sol) adapters for [Sail Protocol](https://github.com/sail-money/Protocol)'s oracle-gated permission templates (`SwapPermission`, `BorrowPermission`), built to the semantic contract in Sail's [`oracle-adapters.md`](https://github.com/sail-money/Protocol/blob/main/docs/oracle-adapters.md).

Sail ships the oracle *interface* and the consuming templates, but no blessed adapter — every operator must supply one. This kit is a reference implementation family that covers all three adapter roles with Chainlink-backed pricing, ERC-4626 vault-share resolution, and rebasing-receipt (aToken-style) aliasing.

**Status: unaudited.** Reviewed and tested, but no third-party security audit. Operators allowlist oracles at their own risk — read the Trust Model section before configuring a mandate against these contracts.

## Contracts

| Contract | Sail role(s) | What it does |
|---|---|---|
| `PriceRouter` | (shared core) | Token → USD8 valuation: Chainlink USD feeds, ERC-4626 shares via `convertToAssets` → underlying feed, 1:1 aliases (aUSDC → USDC). Sequencer-uptime gated on L2s. |
| `SailOracle` | Swap + Borrow | `getPrice(tokenIn, tokenOut)` cross-rates in Sail's exact native-units convention (18-dec mantissa); `getPrice(asset, address(0))` per-unit USD value (decimals = 8 + token decimals). |
| `SailCollateralOracle` | Collateral | `getPrice(account, address(0))` aggregate portfolio value in USD8 over an operator-registered position list (plain ERC-20s, aTokens, ERC-4626 shares). |

The borrow and collateral roles share the **USD numeraire** — the hard requirement of `BorrowPermission`'s LTV check. `test_ltv_formula_end_to_end` replicates the template's exact `mulDiv` ceiling formula against both roles.

## Design decisions

- **Fail-closed everywhere.** Every failure path — unregistered token, negative/zero answer, reverting metadata, sequencer down or in grace period, vault-of-vault nesting, one unpriceable collateral leg — returns `(0, 0, 0)`. Sail templates treat `updatedAt == 0` as stale and deny. The kit never returns a partial portfolio value: one bad leg poisons the total, because silently under- or over-reporting collateral is how LTV checks get quietly defeated.
- **`updatedAt` is never fabricated.** It is always the *oldest* feed timestamp involved in the answer, passed through honestly — freshness enforcement stays fully in the template's `maxPriceAgeSec` where Sail's docs put it. A stale feed produces a stale timestamp, not a refusal dressed up as fresh data.
- **Sequencer gating is the adapter's job** (per Sail's spec, the templates don't do it). `PriceRouter` takes the Chainlink L2 sequencer-uptime feed at deploy; `answer != 0` or an unexpired grace period gates every read. Pass `address(0)` on chains without one.
- **Gas fits the budget — with one measured exclusion.** Sail evaluates permissions under a 150k-gas staticcall cap that the oracle read shares with template logic. Measured: feed-pair swap reads ≈ 39k and simple collateral portfolios ≈ 54k (forge gas-report, warm) — comfortable. But **multi-market MetaMorpho shares cost ~318k cold** (Base fork, Gauntlet USDC Prime): MetaMorpho's `totalAssets()` loops its withdrawQueue over Morpho Blue markets, blowing the entire budget on its own. **Do not register multi-market MetaMorpho vaults for mandate-gated paths** — single-market/simple ERC-4626 vaults are fine (measure first; `test_fork_gas_measured` shows how). `MAX_POSITIONS = 6`, but keep collateral lists to 3–4 positions to leave the template headroom.
- **No external dependencies.** Zero OZ/solmate imports in `src/` (forge-std in tests only); a local minimal `mulDiv` for full-precision math.

## Trust model

Sail's docs are explicit that the oracle is **operator-supplied** and that "an adapter that lies about freshness defeats the check." Accordingly:

- `PriceRouter` and `SailCollateralOracle` are **operator-owned** (`onlyOwner` feed registry and position lists). The operator can change what a token is priced by, and which positions count as collateral. **The Permission Signer should treat allowlisting these contracts as trusting the operator's key** — the same trust already placed in the operator's choice of oracle under Sail's model.
- For stricter setups: deploy, configure, then `transferOwnership` to the Permission Signer or a multisig/timelock, freezing the registry from the manager side.
- Manipulation resistance is inherited from Chainlink; ERC-4626 share prices use `convertToAssets`, which for honest vaults reflects exchange rate, not spot-manipulable pool state. Do not register vaults whose `convertToAssets` can be flash-manipulated.

## Live deployment — Base mainnet (chainId 8453)

Deployed 2026-07-17, Sourcify-verified, configured with the canonical Chainlink Base feed set (ETH, USDC, cbBTC, cbETH, EURC), the aBasUSDC alias, and four MetaMorpho USDC vaults (off-mandate reads only — see the gas exclusion above):

| Contract | Address |
|---|---|
| `PriceRouter` | `0x63C3821aC8F06E9eaCB03F867206f44b1dafFa44` |
| `SailOracle` | `0x160D80840bDA05ebff57EA9d9E6124D5738533ef` |
| `SailCollateralOracle` | `0xb85815a5a7287d3934F36D499130502bbDB1a80d` |

Live sanity read (try it): `cast call 0x160D…33ef "getPrice(address,address)(uint256,uint8,uint256)" <WETH> <USDC> --rpc-url https://mainnet.base.org`

These instances are **operator-owned by the deployer** — treat them as a working demo of the kit. For production mandates, deploy your own instance so *you* control the feed registry (or ask us to transfer a configured instance: info@theaslangroupllc.com).

## Usage

```bash
forge build && forge test
```

Deploy (Base example — addresses in `script/Deploy.s.sol`):

```bash
BASE_RPC_URL=https://mainnet.base.org \
forge script script/Deploy.s.sol --rpc-url base --broadcast --private-key $DEPLOYER_KEY
```

Then, as the operator:

1. `router.setFeed(USDC, <Chainlink USDC/USD>)`, `setFeed(WETH, <ETH/USD>)`, …
2. `router.setAlias(aBasUSDC, USDC)` for rebasing receipts; `router.setVault(<MetaMorpho vault>)` for ERC-4626 shares.
3. `collateral.setPositions(<sail account>, [aBasUSDC, WETH, …])` (≤ 6, keep it short).
4. Configure the mandate: `SailOracle` as swap/borrow oracle, `SailCollateralOracle` as collateral oracle, with a sane `maxPriceAgeSec` (Chainlink Base USD feeds heartbeat at 24h with deviation triggers — set the bound to your feed set's slowest heartbeat plus margin).

## License

MIT. `src/interfaces/IOracle.sol` is Sail Protocol's interface (MIT), vendored unmodified.

---

Built by [The Aslan Group LLC](https://pulsenetwork.theaslangroupllc.com) — operators of PulseNetwork, x402-native data APIs on Base. Contact: info@theaslangroupllc.com
