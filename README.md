# Ammo Markets — Smart Contracts

DeFi protocol for tokenized ammunition trading on Avalanche C-Chain. Users escrow USDC in a keeper-finalized mint flow to receive per-caliber ammo tokens (e.g., 9mm Practice, 5.56 NATO), redeem tokens for real-world ammo fulfillment, or request a USDC exit through a shared liquidity pool. The protocol includes fee-on-transfer taxes for DEX trades and a keeper-updated on-chain price oracle.

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

No environment variables are needed to build or run most tests — they use local mocks. The exception is `CaliberTokenTaxFork.t.sol`, which forks Avalanche mainnet to test tax behavior against a real DEX. These 5 tests are skipped automatically if `AVALANCHE_RPC_URL` is not set.

### Environment Variables

Copy `.env.example` to `.env`:

| Variable            | Required For   | Description                               |
| ------------------- | -------------- | ----------------------------------------- |
| `FUJI_RPC_URL`      | Testnet deploy | Avalanche Fuji C-Chain RPC                |
| `AVALANCHE_RPC_URL` | Mainnet deploy | Avalanche Mainnet C-Chain RPC             |
| `PRIVATE_KEY`       | All deploys    | Deployer EOA private key                  |
| `SNOWTRACE_API_KEY` | Verification   | Avascan API key for contract verification |

## Core Contracts

```
AmmoManager                          Central admin — roles, tax config, denylist
  │
  ├── AmmoFactory                    Deploys per-caliber market + token pairs
  │     └── CaliberMarket            Mint/redeem/exit order book per caliber
  │           └── CaliberToken          ERC20 with fee-on-transfer tax
  │
  ├── PriceOracle                    Per-market price storage (keeper-updated)
  │
  └── AmmoLiquidityManager           Tax-exempt DEX liquidity helper
```

The most important files for understanding the protocol:

| Contract                       | File                                 | What It Does                                                                                                                                                                                     |
| ------------------------------ | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **AmmoManager**                | `src/AmmoManager.sol`                | Global config hub. All contracts read roles (owner, keeper, guardian), tax rates, and the transfer denylist from here.                                                                           |
| **CaliberMarket**              | `src/CaliberMarket.sol`              | Where users interact. 2-step mint (USDC escrow → keeper finalizes), 2-step redeem for real-world ammo fulfillment, and 2-step exit (tokens locked → keeper pays USDC/USDT directly on finalize). |
| **CaliberToken**               | `src/CaliberToken.sol`               | Per-caliber ERC20 with buy/sell tax on DEX trades. Taxes accumulate and auto-swap to WAVAX → treasury. Only its CaliberMarket can mint/burn.                                                     |
| **PriceOracle**                | `src/PriceOracle.sol`                | Stores per-market prices at 1e18 scale. An off-chain keeper (worker) batches updates via `setBatchPrices`. CaliberMarket rejects prices older than 6 hours.                                      |
| **AmmoLiquidityManager**       | `src/AmmoLiquidityManager.sol`       | Tax-exempt helper for adding and removing DEX liquidity.                                                                                                                                          |

## Deployment

Contracts must be deployed in a specific order due to cross-references and one-time wiring calls (`setFactory`). See the full deployment scripts:

- **Testnet:** `script/DeployFuji.s.sol`
- **Mainnet:** `script/DeployMainnet.s.sol`

Deploy commands use the `Makefile`:

```bash
make fuji_check        # Dry-run testnet deploy
make fuji_deploy       # Deploy + verify on Fuji
make mainnet_check     # Dry-run mainnet deploy
make mainnet_deploy    # Deploy + verify on mainnet
```

## For Auditors

### Security Patterns

| Pattern                 | Where                           | Purpose                                        |
| ----------------------- | ------------------------------- | ---------------------------------------------- |
| Reentrancy guard        | CaliberMarket                   | `_locked` flag on state-changing user calls    |
| 2-step ownership        | AmmoManager                     | Pending owner must `acceptOwnership()`         |
| Set-once initialization | AmmoFactory                     | Prevents re-wiring after deploy                |
| Denylist                | CaliberToken                    | Blocks bridging/export of tokens               |
| Price staleness         | CaliberMarket                   | Rejects oracle prices older than 6 hours       |
| Safe ERC20 transfers    | CaliberMarket, CaliberToken     | Low-level call pattern for non-standard tokens |
| Try/catch tax swap      | CaliberToken                    | DEX failures never revert user transfers       |

### Dependencies

| Dependency                                           | Purpose                |
| ---------------------------------------------------- | ---------------------- |
| [forge-std](https://github.com/foundry-rs/forge-std) | Foundry test framework |

### Chain Info

|          | Fuji (Testnet)                                       | Mainnet                              |
| -------- | ---------------------------------------------------- | ------------------------------------ |
| Chain ID | 43113                                                | 43114                                |
| Explorer | [testnet.avascan.info](https://testnet.avascan.info) | [avascan.info](https://avascan.info) |
| USDC     | Testnet MockUSDC                                     | Native USDC                          |
