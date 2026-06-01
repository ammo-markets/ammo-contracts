# Resolve repo root: works whether invoked from root (make -C) or locally
CONTRACTS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(CONTRACTS_DIR)/../..)

-include $(ROOT_DIR)/.env

fuji_check:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployFuji.s.sol:DeployFuji \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) -vv

fuji_deploy:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployFuji.s.sol:DeployFuji \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify --slow \
		--verifier-url "https://api.avascan.info/v2/network/testnet/evm/43113/etherscan" \
		--etherscan-api-key $(SNOWTRACE_API_KEY) -vv

# ── Fuji exchange dev stack ──────────────────────

fuji_exchange_check:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployFujiExchange.s.sol:DeployFujiExchange \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) -vv

fuji_exchange_deploy:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployFujiExchange.s.sol:DeployFujiExchange \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify --slow \
		--verifier-url "https://api.avascan.info/v2/network/testnet/evm/43113/etherscan" \
		--etherscan-api-key $(SNOWTRACE_API_KEY) -vv

# ── Fuji full dev stack: exchange + Ammo + seeded pools ──

fuji_full_dev_check:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployFujiFullDev.s.sol:DeployFujiFullDev \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) -vv

fuji_full_dev_deploy:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployFujiFullDev.s.sol:DeployFujiFullDev \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify --slow \
		--verifier-url "https://api.avascan.info/v2/network/testnet/evm/43113/etherscan" \
		--etherscan-api-key $(SNOWTRACE_API_KEY) -vv

# ── Mainnet deployment ──────────────────────────

mainnet_check:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployMainnet.s.sol:DeployMainnet \
		--rpc-url $(AVALANCHE_RPC_URL) \
		--private-key $(PRIVATE_KEY) -vv

mainnet_deploy:
	@cd $(CONTRACTS_DIR) && forge clean
	@cd $(CONTRACTS_DIR) && forge script script/DeployMainnet.s.sol:DeployMainnet \
		--rpc-url $(AVALANCHE_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify --slow \
		--verifier-url "https://api.avascan.info/v2/network/mainnet/evm/43114/etherscan" \
		--etherscan-api-key $(SNOWTRACE_API_KEY) -vv

# ── Keeper management ────────────────────────────
MANAGER := 0x74994498D05358502C56e491A1fd68bdC3F5177c

# Usage: make add_keeper 0x... / make remove_keeper 0x...
KEEPER_ADDR := $(word 2,$(MAKECMDGOALS))

add_keeper:
	cast send $(MANAGER) "setKeeper(address,bool)" $(KEEPER_ADDR) true \
		--rpc-url $(FUJI_RPC_URL) --private-key $(PRIVATE_KEY)

remove_keeper:
	cast send $(MANAGER) "setKeeper(address,bool)" $(KEEPER_ADDR) false \
		--rpc-url $(FUJI_RPC_URL) --private-key $(PRIVATE_KEY)

# Authorize the worker keeper (derived from KEEPER_PRIVATE_KEY) on the
# shared AmmoManager. Broadcaster (PRIVATE_KEY) must be the manager owner.
add_keeper_shared_check:
	@cd $(CONTRACTS_DIR) && forge script script/AddKeeper.s.sol:AddKeeper \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) -vv

add_keeper_shared:
	@cd $(CONTRACTS_DIR) && forge script script/AddKeeper.s.sol:AddKeeper \
		--rpc-url $(FUJI_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --slow -vv

# ── Market addresses ─────────────────────────────
MARKET_9MM_PRACTICE := 0xC2a1D88A13539eBd62C481F7Abe5366A6c780670
MARKET_9MM_SELF_DEFENSE := 0xD33B1c993d7958EaF5bf81Ec88ec6D5Ae757adf4
MARKET_556_SELF_DEFENSE := 0x0A461cf5C3c9437FDE6416BA45f50C0236aef04d
MARKET_556_NATO_PRACTICE := 0x6855E5F296b24e9FA49524bf59A4326a952A8a82

# ── Fee management ───────────────────────────────

# Set redeem fee to zero on all caliber markets
set_redeem_fee_zero:
	@echo "Setting redeem fee to 0 on all markets..."
	cast send $(MARKET_9MM_PRACTICE) "setRedeemFee(uint256)" 0 \
		--rpc-url $(FUJI_RPC_URL) --private-key $(PRIVATE_KEY)
	@echo "  9MM_PRACTICE done"
	cast send $(MARKET_9MM_SELF_DEFENSE) "setRedeemFee(uint256)" 0 \
		--rpc-url $(FUJI_RPC_URL) --private-key $(PRIVATE_KEY)
	@echo "  9MM_SELF_DEFENSE done"
	cast send $(MARKET_556_SELF_DEFENSE) "setRedeemFee(uint256)" 0 \
		--rpc-url $(FUJI_RPC_URL) --private-key $(PRIVATE_KEY)
	@echo "  556_SELF_DEFENSE done"
	cast send $(MARKET_556_NATO_PRACTICE) "setRedeemFee(uint256)" 0 \
		--rpc-url $(FUJI_RPC_URL) --private-key $(PRIVATE_KEY)
	@echo "  556_NATO_PRACTICE done"
	@echo "All redeem fees set to 0."

# Check current redeem fees on all markets
check_redeem_fees:
	@echo "=== Current Redeem Fees (BPS) ==="
	@echo -n "9MM_PRACTICE: " && cast call $(MARKET_9MM_PRACTICE) "redeemFeeBps()(uint256)" --rpc-url $(FUJI_RPC_URL)
	@echo -n "9MM_SELF_DEFENSE: " && cast call $(MARKET_9MM_SELF_DEFENSE) "redeemFeeBps()(uint256)" --rpc-url $(FUJI_RPC_URL)
	@echo -n "556_SELF_DEFENSE: " && cast call $(MARKET_556_SELF_DEFENSE) "redeemFeeBps()(uint256)" --rpc-url $(FUJI_RPC_URL)
	@echo -n "556_NATO_PRACTICE: " && cast call $(MARKET_556_NATO_PRACTICE) "redeemFeeBps()(uint256)" --rpc-url $(FUJI_RPC_URL)

# Silently ignore address args passed to add_keeper / remove_keeper
0x%:
	@:
