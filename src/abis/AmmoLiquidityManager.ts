export const AmmoLiquidityManagerAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "router_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "receive",
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "addLiquidity",
    "inputs": [
      {
        "name": "tokenA",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "tokenB",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "stable",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "amountADesired",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountBDesired",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountAMin",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountBMin",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amountA",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountB",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "liquidity",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "addLiquidityETH",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "stable",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "amountTokenDesired",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountTokenMin",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountETHMin",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amountToken",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountETH",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "liquidity",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "removeLiquidityETH",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "stable",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "liquidity",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountTokenMin",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountETHMin",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amountToken",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amountETH",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "router",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IDexRouter"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "wavax",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "error",
    "name": "InvalidAmount",
    "inputs": []
  },
  {
    "type": "error",
    "name": "TransferFailed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;
