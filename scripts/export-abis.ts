import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";

const OUT_DIR = resolve(import.meta.dirname ?? ".", "../out");
const ABI_DIR = resolve(import.meta.dirname ?? ".", "../src/abis");

const CONTRACTS_TO_EXPORT = [
  "AmmoManager",
  "AmmoFactory",
  "CaliberMarket",
  "CaliberToken",
  "AmmoLiquidityManager",
  "MockUSDC",
  "PriceOracle",
  "AmmoMarketLPFarm",
  "ProtocolToken",
  "ProtocolEmissionController",
];

if (!existsSync(ABI_DIR)) {
  mkdirSync(ABI_DIR, { recursive: true });
}

const exports: string[] = [];

for (const name of CONTRACTS_TO_EXPORT) {
  const artifactPath = resolve(OUT_DIR, `${name}.sol`, `${name}.json`);

  if (!existsSync(artifactPath)) {
    console.warn(`⚠ Artifact not found: ${artifactPath}`);
    continue;
  }

  const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
  const abi = JSON.stringify(artifact.abi, null, 2);

  const tsContent = `export const ${name}Abi = ${abi} as const;\n`;
  const outPath = resolve(ABI_DIR, `${name}.ts`);

  writeFileSync(outPath, tsContent);
  console.log(`✓ Exported ${name} ABI → src/abis/${name}.ts`);

  exports.push(`export { ${name}Abi } from "./${name}.js";`);
}

// Write barrel export
const indexContent = exports.length
  ? exports.join("\n") + "\n"
  : "// No ABIs exported yet — run `forge build` first\nexport {};\n";

writeFileSync(resolve(ABI_DIR, "index.ts"), indexContent);
console.log("✓ Updated src/abis/index.ts");
