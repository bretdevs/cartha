// CARTHA keeper. Runs harvest() on the CarthaHarvester every INTERVAL_SEC when there is ETH to spend.
// Anyone can call harvest(); this just does it on a schedule with a sane minCarthaOut.
//
// Env: RPC_URL, PRIVATE_KEY, HARVESTER, INTERVAL_SEC (default 300), SLIPPAGE_BPS (default 300), DRY_RUN (optional)

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseAbi,
  formatEther,
  formatUnits,
  keccak256,
  encodePacked,
  hexToBigInt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const env = (k, d) => process.env[k] ?? d;
const RPC_URL = env("RPC_URL", "https://rpc.mainnet.chain.robinhood.com");
const HARVESTER = env("HARVESTER");
const INTERVAL_SEC = Number(env("INTERVAL_SEC", "300"));
const SLIPPAGE_BPS = BigInt(env("SLIPPAGE_BPS", "300"));
const DRY_RUN = env("DRY_RUN", "") === "1";
// Not configured yet: stay up and say so, so the service can be deployed before the contracts exist.
// Railway restarts the service when variables change, so setting HARVESTER and PRIVATE_KEY is enough.
if (!HARVESTER || (!process.env.PRIVATE_KEY && !DRY_RUN)) {
  const missing = [!HARVESTER && "HARVESTER", !process.env.PRIVATE_KEY && !DRY_RUN && "PRIVATE_KEY"].filter(Boolean).join(" and ");
  const say = () => console.log(new Date().toISOString(), `waiting: set ${missing} in the service variables, then the keeper starts on its own`);
  say();
  setInterval(say, 10 * 60 * 1000);
} else {
  main().catch((e) => {
    console.error("keeper failed to start:", e.shortMessage ?? e.message);
    process.exit(1);
  });
}

const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

const pub = createPublicClient({ chain: robinhood, transport: http(RPC_URL) });
const account = DRY_RUN || !process.env.PRIVATE_KEY ? null : privateKeyToAccount(process.env.PRIVATE_KEY);
const wallet = account ? createWalletClient({ account, chain: robinhood, transport: http(RPC_URL) }) : null;

const harvesterAbi = parseAbi([
  "function still() view returns (address)",
  "function vault() view returns (address)",
  "function factory() view returns (address)",
  "function curve() view returns (address)",
  "function poolManager() view returns (address)",
  "function maxBuyPerHarvest() view returns (uint256)",
  "function pending() view returns (uint256 claimable, uint256 held)",
  "function canBuy() view returns (bool)",
  "function phase() view returns (uint8)",
  "function poolId() view returns (bytes32)",
  "function harvest(uint256 minCarthaOut) returns (uint256 ethSpent, uint256 carthaBought)",
]);
const curveAbi = parseAbi([
  "function getReserves() view returns (uint256 quoteReserve, uint256 tokenReserve)",
  "function sellableTokens() view returns (uint256)",
  "function feeBps() view returns (uint256)",
  "function creatorTaxBps() view returns (uint256)",
  "function currentSnipeTaxBps(address recipient) view returns (uint256)",
]);
const factoryAbi = parseAbi([
  "struct FeePolicy { address protocolFeeRecipient; uint16 protocolFeeShareBps; uint16 buybackBurnBps; uint16 hookFeeBps; uint16 maxInternalPriceImpactBps; }",
  "function getLaunchFeePolicy(address token) view returns (FeePolicy)",
  "struct LaunchedToken { address token; address curve; address deployer; address creatorFeeRecipient; address pairToken; uint256 graduationThreshold; uint24 poolFee; int24 tickSpacing; uint16 creatorTaxBps; bool buybackEnabled; uint8 phase; uint256 sweptQuote; uint256 sweptTokens; uint256 sweptAt; bool exists; }",
  "function getLaunchedToken(address token) view returns (LaunchedToken)",
]);
const pmAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);
const vaultAbi = parseAbi(["function convertToAssets(uint256 shares) view returns (uint256)"]);

const BPS = 10_000n;
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
const log = (...a) => console.log(new Date().toISOString(), ...a);

// The curve's own integer arithmetic, per docs.ponsfamily.com/v2 "Getting a quote".
async function quoteCurve(curve, quoteIn, recipient) {
  const [[quoteReserve, tokenReserve], sellable, feeBps, taxBps, rawSnipe] = await Promise.all([
    read(curve, curveAbi, "getReserves"),
    read(curve, curveAbi, "sellableTokens"),
    read(curve, curveAbi, "feeBps"),
    read(curve, curveAbi, "creatorTaxBps"),
    read(curve, curveAbi, "currentSnipeTaxBps", [recipient]),
  ]);
  let snipe = rawSnipe;
  if (snipe > 0n) {
    const max = BPS - feeBps - taxBps - 100n;
    if (snipe > max) snipe = max;
  }
  const fee = (quoteIn * feeBps) / BPS;
  const tax = (quoteIn * taxBps) / BPS;
  const snipeTax = (quoteIn * snipe) / BPS;
  const net = quoteIn - fee - tax - snipeTax;
  let out = (net * tokenReserve) / (quoteReserve + net);
  if (out > sellable) out = sellable; // clamped final buy; the harvester records the refund correctly
  return out;
}

// Spot from the pool's slot0 via extsload. StateLibrary: pools mapping at slot 6,
// Slot0 packs sqrtPriceX96 in the low 160 bits. ETH is currency0, so CARTHA per ETH = price^2 / 2^192.
async function quotePool(poolManager, poolId, token, factory, quoteIn) {
  const stateSlot = keccak256(encodePacked(["bytes32", "bytes32"], [poolId, `0x${(6).toString(16).padStart(64, "0")}`]));
  const raw = await read(poolManager, pmAbi, "extsload", [stateSlot]);
  const sqrtPriceX96 = hexToBigInt(raw) & ((1n << 160n) - 1n);
  if (sqrtPriceX96 === 0n) throw new Error("slot0 read is zero");
  const gross = (quoteIn * sqrtPriceX96 * sqrtPriceX96) >> 192n;
  const [policy, launch] = await Promise.all([
    read(factory, factoryAbi, "getLaunchFeePolicy", [token]),
    read(factory, factoryAbi, "getLaunchedToken", [token]),
  ]);
  const feeBps = BigInt(policy.hookFeeBps) + BigInt(launch.creatorTaxBps);
  // Spot ignores price impact; the slippage allowance below covers a small buy.
  return (gross * (BPS - feeBps)) / BPS;
}

async function tick(ctx) {
  const [[claimable, held], canBuy, phase] = await Promise.all([
    read(HARVESTER, harvesterAbi, "pending"),
    read(HARVESTER, harvesterAbi, "canBuy"),
    read(HARVESTER, harvesterAbi, "phase"),
  ]);
  const total = claimable + held;
  log(`phase=${phase} claimable=${formatEther(claimable)} held=${formatEther(held)} canBuy=${canBuy}`);
  if (total === 0n) return;
  if (!canBuy && claimable === 0n) return;

  const budget = total > ctx.maxBuy ? ctx.maxBuy : total;
  let minOut = 0n;
  try {
    if (phase === 0) {
      minOut = await quoteCurve(ctx.curve, budget, ctx.vault);
    } else if (phase === 2) {
      minOut = await quotePool(ctx.poolManager, ctx.poolId, ctx.token, ctx.factory, budget);
    } else {
      log("nothing to buy from in this phase; claiming only");
    }
    minOut = (minOut * (BPS - SLIPPAGE_BPS)) / BPS;
  } catch (e) {
    log(`quote failed, harvesting with minCarthaOut=0 (bounded by maxBuyPerHarvest): ${e.message}`);
    minOut = 0n;
  }
  if (!canBuy) minOut = 0n; // this call only claims

  const args = [minOut];
  const sim = await pub.simulateContract({
    address: HARVESTER,
    abi: harvesterAbi,
    functionName: "harvest",
    args,
    account: account ?? "0x0000000000000000000000000000000000000001",
  });
  const [ethSpent, bought] = sim.result;
  log(`simulated harvest: spend=${formatEther(ethSpent)} ETH buy=${formatUnits(bought, 18)} CARTHA minOut=${formatUnits(minOut, 18)}`);
  if (DRY_RUN) return;

  const hash = await wallet.writeContract(sim.request);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  const ratio = await read(ctx.vault, vaultAbi, "convertToAssets", [10n ** 18n]);
  log(`harvest ${receipt.status} ${hash} ratio=${formatUnits(ratio, 18)} CARTHA per vCARTHA`);
}

async function main() {
  const [token, vault, factory, curve, poolManager, maxBuy, poolId] = await Promise.all([
    read(HARVESTER, harvesterAbi, "still"),
    read(HARVESTER, harvesterAbi, "vault"),
    read(HARVESTER, harvesterAbi, "factory"),
    read(HARVESTER, harvesterAbi, "curve"),
    read(HARVESTER, harvesterAbi, "poolManager"),
    read(HARVESTER, harvesterAbi, "maxBuyPerHarvest"),
    read(HARVESTER, harvesterAbi, "poolId"),
  ]);
  const ctx = { token, vault, factory, curve, poolManager, maxBuy, poolId };
  log(`keeper up. harvester=${HARVESTER} token=${token} vault=${vault} cap=${formatEther(maxBuy)} ETH every ${INTERVAL_SEC}s`);
  for (;;) {
    try {
      await tick(ctx);
    } catch (e) {
      log(`tick failed: ${e.shortMessage ?? e.message}`);
    }
    await new Promise((r) => setTimeout(r, INTERVAL_SEC * 1000));
  }
}

