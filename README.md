# Cartha

A vault on Robinhood Chain (chain id 4663) launched through pons v2. The share token, vCARTHA, is a plain ERC-20. Trading fees on CARTHA buy CARTHA into the vault, no shares are minted for it, and CARTHA per vCARTHA rises. No claim step, no rebase, no epochs, no queue, no owner.

```
buy CARTHA on pons  ->  deposit  ->  vCARTHA
      |
      v  every trade pays a fee in ETH (pons standard fee share + creator tax)
CarthaHarvester (no owner)  ->  claims ETH from the pons escrow  ->  buys CARTHA  ->  sends it to CarthaVault
                                                                                       |
                                                                     totalAssets up, totalSupply unchanged
                                                                                       |
                                                                       CARTHA per vCARTHA only turns one way
```

## What is in here

- `src/CarthaVault.sol`: OpenZeppelin ERC-4626 over CARTHA, plus ERC20Permit. No other code.
- `src/CarthaHarvester.sol`: the creator fee recipient. Permissionless `harvest(minCarthaOut)`. Capped per call, cooldown between buys. Buys on the pons curve before graduation, on the Uniswap v4 pool after. Keeps a small on-chain ledger for the site.
- `src/interfaces/`: the slice of pons v2 and Uniswap v4 this touches.
- `test/`: 30 unit tests plus 8 fork tests. `testFuzz_ratioNeverDecreases` is the one the site quotes. `test_inflationAttackIsUnprofitableAfterSeed` shows why the deploy script seeds the vault. `Fork.t.sol` runs the harvester against the real pons v2 stack on a fork of Robinhood Chain.
- `script/Deploy.s.sol`: launch, deploy, redirect fees, seed. One broadcast.
- `keeper/`: Node keeper for Railway. Quotes the buy, calls `harvest`.
- `site/index.html`: single file. Runs in demo mode until `CONFIG` has the addresses.
- `brand/`: banner, avatar, OG card, wordmark, mark, and `x-kit.md`.
- `deployments/`: the deploy script writes `robinhood-4663.json` here.

## Why this is not just Kynix on pons

Kynix is an ETH-USDC LP vault with nothing to buy and, by their own account, no fees flowing. Same skeleton here, different feed:

- The yield source is CARTHA's own trading on pons, both directions, curve and pool, from the first block.
- The vault holds only CARTHA, so CARTHA per vCARTHA is monotonic. Kynix's share price moves with its LP position.
- Deposits are isolated from anything that touches a DEX. The vault talks only to the CARTHA token. The harvester holds fee ETH in transit and nothing else.
- The fee destination is verifiable on the pons factory record and the harvester cannot point fees anywhere else.

## Verified on chain, 31 Aug 2026

Read directly from Robinhood Chain and exercised by `test/Fork.t.sol` against a fork at block 50.9M:

- Factory `launchFee()` is 0.0005 ETH. `maxCreatorTaxBps()` is 1000, so 3% is fine. `canLaunch()` is open to any address.
- Launch config 0: 1B supply, 1% curve fee, 1.68 ETH phantom reserve, 4.2 ETH graduation threshold, pool fee 0, tick spacing 200. The harvester reads pool fee and tick spacing from the launch record, so nothing is hardcoded.
- The hook exposes `poolManager()`: `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- `transferCreatorFeeRecipient(token, newRecipient)` is on the factory and reverts with `NotCreatorFeeRecipient()` from anyone else.
- `claim()` on the escrow, `sweepFees(uint256)` on curves and `sweepPoolFees(bytes32,uint256,uint256)` on the hook all exist with the documented signatures.
- The harvester bought on a live curve. The docs quote is an upper bound and the fill was within 3% of it.
- The harvester bought on a live graduated pool (GHOST) through the real PoolManager and the pons hook: exact input fully spent, tokens landed in the vault, nothing left in the harvester. The pool key with fee 0 is correct and the keeper's slot0 read via `extsload` agrees with the trade.
- Cap and cooldown hold against the live pool.

Re-run it before you deploy; it takes about half a minute on the public RPC:

```bash
FORK=1 forge test --match-contract ForkTest -vv
```

If the default tokens in the test have since moved phase, pass `FORK_POOL_TOKEN` (a graduated native launch) and `FORK_CURVE_TOKEN` (a native launch still on its curve). Native launches with `phase == 2` are rare; scan `TokenLaunched` events on the factory and read `getLaunchedToken` to find one.

## Before you deploy

1. Run the fork tests above. If pons has replaced the stack, the addresses in `.env.example` are stale and the tests will say so.
2. Decide the harvester bounds. `MAX_BUY_WEI` and `COOLDOWN_SEC` are immutable. 0.1 ETH every 5 minutes is 28.8 ETH a day of buying capacity; fees above that simply wait.
3. Have the logo on IPFS and the X account and site URL ready; they go into the launch record and cannot be changed later.

## Deploy

```bash
# toolchain
curl -L https://foundry.paradigm.xyz | bash && foundryup
cp .env.example .env   # fill PRIVATE_KEY, TOKEN_LOGO, TOKEN_TWITTER, TOKEN_WEBSITE

forge install
forge test

source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

The script does, in order: launch CARTHA with your wallet as fee recipient, deploy `CarthaVault`, deploy `CarthaHarvester`, move the fee recipient to the harvester, buy `SEED_ETH_WEI` of CARTHA on the curve, deposit `SEED_CARTHA_WEI` of it and park the vCARTHA at `0x...dEaD`.

If it reverts after the launch step, nothing is lost. The token exists and fees go to your wallet until you move them. Deploy the vault and harvester by hand and call `transferCreatorFeeRecipient` yourself. Claim any fees already credited to your wallet first, then forward that ETH to the harvester; the next harvest picks it up.

The vault and harvester deploy without `--verify` too. Verify later on Blockscout with the same compiler settings from `foundry.toml`. Verification is the whole point of the "no owner" claim, so do it before you post.

## Where it is deployed

- Site: https://cartha-phi.vercel.app (Vercel project `cartha`, same account as ponspot and betonpons; the earlier `holdstill` project still exists and can be deleted). Demo mode until `CONFIG` is filled. To redeploy from your machine: `cd site && vercel link --project cartha && vercel deploy --prod`. Point a real domain at it the way you did for betonpons.com.
- Keeper: Railway service `cartha-keeper` inside the existing `ponsbid-keeper` project (the free plan refused a new project). It is running and idling. It starts on its own once `HARVESTER` and `PRIVATE_KEY` are set in the service variables; `RPC_URL`, `INTERVAL_SEC` and `SLIPPAGE_BPS` are already set. To push a new version: `cd keeper && railway link --project ponsbid-keeper --service cartha-keeper && railway up`.

## Wire the site

Open `site/index.html`, fill `CONFIG` from `deployments/robinhood-4663.json` (`token`, `vault`, `harvester`, `curve`) and set `x`. Redeploy. The page polls the vault every 15 seconds and reads the last 12 harvests from `harvester.recent(12)`. There is no backend.

The OG card is served at `/og.png` and already referenced in the meta tags with the Vercel URL. Change those two tags when the real domain is live.

## Keeper

```bash
cd keeper && npm i
cp .env.example .env   # RPC_URL, PRIVATE_KEY, HARVESTER
npm run dry            # simulates only
npm start
```

The keeper wallet only needs gas; harvest is permissionless. Use a dedicated RPC for anything past light use, the public one rate limits.

Every tick it reads `pending()`, quotes the buy (curve maths before graduation, pool slot0 after), applies `SLIPPAGE_BPS`, simulates, then sends. If the quote fails it still harvests with `minCarthaOut = 0`, which is safe because of the per-call cap. Without `HARVESTER` and `PRIVATE_KEY` it stays up and logs that it is waiting, so it can be deployed before the contracts exist.

## What to publish, in this order

1. Verified source for the vault and harvester on Blockscout.
2. The site with real addresses.
3. The pinned thread from `brand/x-kit.md`. Post 6, the unflattering one, is not optional.

## Honest list, for the site and for you

- Unaudited. The vault is stock OpenZeppelin, which helps, but the harvester and the deployment are ours and nobody has reviewed them.
- pons can redirect creator fees through its CTO mechanism with a three day timelock. If that ever happened, harvests stop. The harvester cannot fix it.
- Post-graduation sweeps that need an internal swap are operator-only on pons' side. Fees are earned but wait for their sweep.
- Every harvest is a pons trade and pays the pons fee.
- The pool swap path was exercised against a live graduated pons v2 pool on a fork, not on mainnet with our own token. Run the fork tests again on deploy day, because the fee recipient cannot be moved back once the harvester holds it.
- Phase 3 (rescued launch) has no pool to buy from. ETH claimed after a rescue stays in the harvester.

## Design notes

Finance blue, not paper. Background `#f4f7fb`, deep water `#0a2540`, ink `#0f1f33`, muted `#5b6b80`, line `#d3dbe6`, surface `#ffffff`, accent `#1f5fff` for the primary button, focus ring and chart. IBM Plex Sans for everything, Plex Mono for addresses and code. The one signature element is the ratio sitting on the water line with its reflection beneath it; the reflection ripples once when a harvest lands. Everything else is quiet on purpose. No dashes in copy anywhere.

The site has three review states while the contracts are not wired: `?demo=launch`, `?demo=live` (default) and `?demo=months`. `?motion=0` switches the scroll motion off, which is useful for screenshots.

Motion: GSAP with ScrollTrigger from cdnjs. A canvas of slow water lines under the hero, a typewriter on the headline, the ratio and the stat tiles count up, the reflection lags the number on scroll and ripples on a harvest, the statement paragraph brightens word by word as you scroll through it, the "What happens to a fee" section pins a device mock that changes scene with each step, sections reveal once as they enter, both charts draw themselves, and the header blurs with a progress line. Two layers of slow drifting light sit behind the page and inside the water block. All of it is off under `prefers-reduced-motion`. The announcement bar at the top reads from the audit slot.

Sections beyond the vault itself: a position card and a vault card next to the deposit panel, an illustrative projection driven by volume, market value and deposit share, a comparison of the yield shapes launchpad tokens use, a status board that reads the audit slot, a questions list and a listing checklist for integrators.

Security review: an independent, unattributed review of commit 6b1ae81 (31 Aug 2026) is published at `/security-review-v1.pdf` and summarised in the site's security section. Its own attribution disclaimer says it is not an audit by Hashlock or any named firm and may only be described as an independent smart contract security review, so that is exactly how the site describes it. Findings: 0 critical, 0 high, 1 medium (M-01, bounded MEV on permissionless harvests, disclosed in the risks), 2 low (L-01 seed now mandatory in the deploy script, L-02 acknowledged), 4 QA. The audit slot is unchanged by this.

Audit slot: `CONFIG.audit` in `site/index.html`. `status` is `none`, `scheduled`, `review` or `complete`; the footer, the first risk item and the line under the addresses all read from it. It only says "Audited by" when `status` is `complete` and `reportUrl` points at the published report. Currently `scheduled` with Hashlock.
