# Ammo Markets — Smart Contracts

DeFi protocol for tokenized ammunition trading on Avalanche C-Chain. Users deposit USDC to mint per-caliber ammo tokens (e.g., 9mm Practice, 5.56 NATO) at oracle prices, and redeem tokens back through a keeper-finalized flow. The protocol includes fee-on-transfer taxes for DEX trades, Chainlink-powered price feeds, and a capped emission system for LP farming incentives.

- **Solidity:** 0.8.24
- **Framework:** [Foundry](https://book.getfoundry.sh/)
- **EVM Target:** Cancun
- **Optimizer:** Enabled, 200 runs

## Quick Start

```bash
# Install Foundry (https://book.getfoundry.sh/getting-started/installation)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and build
git clone https://github.com/ammo-markets/ammo-contracts.git
cd ammo-contracts
forge build

# Run tests
forge test
```

No environment variables are needed to build or run most tests — they use local mocks. The exception is `AmmoTokenTaxFork.t.sol`, which forks Avalanche mainnet to test tax behavior against a real DEX. These 5 tests are skipped automatically if `AVALANCHE_RPC_URL` is not set.

### Environment Variables

Copy `.env.example` to `.env`:

| Variable | Required For | Description |
|----------|-------------|-------------|
| `FUJI_RPC_URL` | Testnet deploy | Avalanche Fuji C-Chain RPC |
| `AVALANCHE_RPC_URL` | Mainnet deploy | Avalanche Mainnet C-Chain RPC |
| `PRIVATE_KEY` | All deploys | Deployer EOA private key |
| `SNOWTRACE_API_KEY` | Verification | Avascan API key for contract verification |

## Core Contracts

```
AmmoManager                          Central admin — roles, tax config, denylist
  │
  ├── AmmoFactory                    Deploys per-caliber market + token pairs
  │     └── CaliberMarket            Mint/redeem order book per caliber
  │           └── AmmoToken          ERC20 with fee-on-transfer tax
  │
  ├── PriceOracle                    Per-market price storage (keeper-updated)
  │     └── AmmoPriceFunctions       Chainlink Functions consumer (auto-updates oracle)
  │
  ├── ProtocolToken                  Protocol incentive token
  │     └── ProtocolEmissionController   Supply cap + emission logic
  │           └── AmmoMarketLPFarm       Equal-weight LP farming
  │
  └── AmmoLiquidityManager           Tax-exempt DEX liquidity helper
```

The most important files for understanding the protocol:

| Contract | File | What It Does |
|----------|------|-------------|
| **AmmoManager** | `src/AmmoManager.sol` | Global config hub. All contracts read roles (owner, keeper, guardian), tax rates, and the transfer denylist from here. |
| **CaliberMarket** | `src/CaliberMarket.sol` | Where users interact. 1-step instant mint (USDC → tokens), 2-step redeem (tokens locked → keeper finalizes or user self-cancels after deadline). |
| **AmmoToken** | `src/AmmoToken.sol` | Per-caliber ERC20 with buy/sell tax on DEX trades. Taxes accumulate and auto-swap to WAVAX → treasury. Only its CaliberMarket can mint/burn. |
| **PriceOracle** | `src/PriceOracle.sol` | Stores per-market prices at 1e18 scale. Keepers update manually or via Chainlink automation. CaliberMarket rejects prices older than 6 hours. |
| **ProtocolEmissionController** | `src/ProtocolEmissionController.sol` | Caps and controls all protocol token emissions — farm rewards (time-decaying) and treasury rewards (volume-based). |
| **AmmoMarketLPFarm** | `src/AmmoMarketLPFarm.sol` | Equal-weight LP staking with linearly decaying emissions. Based on SushiSwap MasterChef v1 — see details below. |

## Deployment

Contracts must be deployed in a specific order due to cross-references and one-time wiring calls (`setMinterOnce`, `setEmissionControllerOnce`, `setFactory`). See the full deployment scripts:

- **Testnet:** `script/DeployFuji.s.sol`
- **Mainnet:** `script/DeployMainnet.s.sol`
- **Chainlink Functions:** `script/DeployChainlinkFunctions.s.sol`

Deploy commands use the `Makefile`:

```bash
make fuji_check        # Dry-run testnet deploy
make fuji_deploy       # Deploy + verify on Fuji
make mainnet_check     # Dry-run mainnet deploy
make mainnet_deploy    # Deploy + verify on mainnet
```

## LP Farm (`AmmoMarketLPFarm.sol`)

Based on [SushiSwap MasterChef v1](https://github.com/sushiswap/sushiswap/blob/master/protocols/masterchef/contracts/MasterChef.sol), with two key differences: equal-weight pool distribution and linearly decaying emissions.

### Equal-Weight Pools

Unlike MasterChef's `allocPoint` system where governance assigns multipliers per pool, every active pool with non-zero stake receives `1/N` of the total emission rate (where N = number of active pools with stakers). A pool with $100 staked gets the same reward budget as one with $1M staked.

### Decaying Emission Schedule

Rewards follow a linearly decaying curve from `startRewardPerDay` down to 0 over `duration`. The `_emitted(from, to)` function computes the exact area under this line between two timestamps:

```
reward = (R × elapsed × (2D - x1 - x2)) / (2D × 1 day)

R  = startRewardPerDay
D  = duration (total program length)
x1 = from - startTime
x2 = to - startTime
```

This is the integral of the linear function `f(t) = R × (1 - t/D)`. Total program rewards = `R × D / 2` (area of a triangle), hard-capped by `farmMintCap`.

### Reward Accounting

Uses the standard MasterChef `accRewardPerShare` / `rewardDebt` pattern:

- On each pool update, accumulated rewards per share increases proportional to emissions since `lastRewardTime`
- Each user's `rewardDebt` is snapshotted on deposit/withdraw as `amount × accRewardPerShare`
- Pending rewards = `(amount × accRewardPerShare) - rewardDebt`

### Lifecycle

- **Lazy start:** Farming clock begins on the first deposit, not at construction
- **Shutdown:** Owner can permanently stop the farm. All pools deactivate, but users can still withdraw and harvest accrued rewards
- **Emergency withdraw:** Users can exit immediately and forfeit pending rewards

## For Auditors

### Security Patterns

| Pattern | Where | Purpose |
|---------|-------|---------|
| Reentrancy guard | CaliberMarket, AmmoMarketLPFarm | `_locked` flag on state-changing user calls |
| 2-step ownership | AmmoManager | Pending owner must `acceptOwnership()` |
| Set-once initialization | ProtocolToken, AmmoFactory | Prevents re-wiring after deploy |
| Denylist | AmmoToken | Blocks bridging/export of tokens |
| Price staleness | CaliberMarket | Rejects oracle prices older than 6 hours |
| Safe ERC20 transfers | CaliberMarket, AmmoToken | Low-level call pattern for non-standard tokens |
| Try/catch tax swap | AmmoToken | DEX failures never revert user transfers |
| Graceful oracle errors | AmmoPriceFunctions | Chainlink DON failures emit events, don't revert |

### Dependencies

| Dependency | Purpose |
|------------|---------|
| [forge-std](https://github.com/foundry-rs/forge-std) | Foundry test framework |
| [chainlink-brownie-contracts](https://github.com/smartcontractkit/chainlink-brownie-contracts) | Chainlink Functions + Automation interfaces |

### Chain Info

| | Fuji (Testnet) | Mainnet |
|---|---|---|
| Chain ID | 43113 | 43114 |
| Explorer | [testnet.avascan.info](https://testnet.avascan.info) | [avascan.info](https://avascan.info) |
| USDC | Testnet MockUSDC | Native USDC |
