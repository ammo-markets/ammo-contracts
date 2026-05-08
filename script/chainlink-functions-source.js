// Chainlink Functions source code — executed by the DON
// args[0] = API base URL (e.g., "https://www.ammomarkets.com")
// args[1..N] = caliber keys (e.g., "9MM_PRACTICE", "9MM_SELF_DEFENSE", ...)
// Returns: ABI-encoded uint256[] of prices in the same order as the caliber keys

const ethers = await import("npm:ethers@6.10.0");
const apiBaseUrl = args[0];
const caliberKeys = args.slice(1);

const response = await Functions.makeHttpRequest({
  url: `${apiBaseUrl}/api/prices`,
  timeout: 9000,
});

if (response.error) {
  throw Error(`HTTP request failed: ${response.message}`);
}

const prices = response.data.prices;
const result = [];

for (const key of caliberKeys) {
  const price = prices[key];
  if (!price) {
    throw Error(`Missing price for caliber: ${key}`);
  }
  // Convert string to BigInt for encoding
  result.push(BigInt(price));
}

// ABI-encode as uint256[] using ethers
const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
  ["uint256[]"],
  [result],
);
return ethers.getBytes(encoded);
