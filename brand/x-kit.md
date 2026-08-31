# Cartha on X

Assets in this folder: `x-banner-1500x500.png`, `x-avatar-400x400.png`, `og-1200x630.png` (site preview card), `wordmark.png`, `mark.svg`, `mark-light.svg`. Sources are in `src/` if you want to re-render at a different size.

Replace `[TOKEN]`, `[VAULT]`, `[HARVESTER]` and `[SITE]` before posting.

## Display name and bio

Name: cartha

Bio (pick one, all under 160 characters):

A, the balanced one, use this: The vault on Robinhood Chain. Every $CARTHA trade buys CARTHA into the vault. Nothing to claim, no rebase, no owner. Independently reviewed, audit scheduled.

B, mechanism first: Fees buy $CARTHA into an ERC-4626 vault. vCARTHA never rebases and never needs claiming, it just redeems for more. No owner, no admin keys. Robinhood Chain.

C, trader voice: One number, one direction. Trading fees buy $CARTHA into the vault and CARTHA per vCARTHA only steps up. Nothing to claim, nobody to trust. Robinhood Chain.

D, integrator voice: A price-accruing ERC-4626 share over launchpad fees. Priced by one view call. No rebase, no claim step, no admin surface. Read the review, then the code.

Profile fields: Website cartha-phi.vercel.app. Location: Robinhood Chain, 4663. Category: if offered, Financial services or none.

When the Hashlock report is published, swap "Independently reviewed, audit scheduled" for "Audited by Hashlock" in whichever bio is live, and pin the report.

When the Hashlock report is published, change "Unaudited, Hashlock audit scheduled" to "Audited by Hashlock" and pin the report link. Not before.

Link: [SITE]

## Pinned thread

1.
CARTHA is live on Robinhood Chain.

A vault whose share is a plain ERC-20. Every CARTHA trade pays a fee, the fee buys CARTHA, the CARTHA goes into the vault. Your vCARTHA balance never moves. What it redeems for does.

Token [TOKEN]
Vault [VAULT]
Chain 4663

[SITE]

2.
How it works.

Deposit 10 CARTHA, get 10 vCARTHA. Ratio 1.00.
Fees buy 1 CARTHA into the vault. Ratio 1.10.
Supply is still 10. Your balance did not move. Each unit just redeems for more.

Burn vCARTHA to leave. Same block, no queue, no exit fee.

3.
Things vCARTHA never does: rebase, claim, epoch, queue, receipt NFT, transfer hook.

Things the vault never has: owner, pause, upgrade, fee switch.

The functions are not there to find. Read the bytecode: [VAULT]

4.
The ratio only turns one way.

The vault holds CARTHA and nothing else. Harvest can only add. Redeem only removes in proportion to the shares it burns. Rounding favours the vault.

So CARTHA per vCARTHA cannot go down, in any block. That is a fuzz test in the repository, not a promise.

5.
What feeds it.

pons v2 charges a fee on every CARTHA trade, in ETH. It is owed to a contract with no owner. Anyone can call harvest() on it. Our keeper does, every few minutes.

Each harvest is capped and spaced out, so a bad caller can only ever act on a small slice.

6.
The unflattering part.

Unaudited. pons can redirect creator fees through its takeover mechanism, behind a three day timelock, and we cannot switch that off. Some post-graduation fees wait on pons to sweep. Nothing accepts vCARTHA as collateral today. Ratio up is not value up.

All of it is on the site, above the deposit button.

7.
If you run risk or integrations at a market on Robinhood Chain: we are asking for a design review while it runs, not a listing. Nobody should list unaudited code.

Source, tests and the deploy script that set the fee recipient: [SITE]

## Launch day, single post

Most tokens on pons pay you fees to claim. This one buys itself into a vault and makes the share you already hold worth more.

Buy CARTHA on pons. Deposit on the site. Capital. Intelligently allocated.

[SITE]

## Harvest posts

Post these by hand or from the keeper log, one line, no hype:

Harvest. 0.084 ETH bought 79,120 CARTHA into the vault. CARTHA per vCARTHA is now 1.0047. Block 18402113.

## Replies you will need

Where does the yield come from?
From CARTHA's own trading on pons. Every buy and sell pays a fee in ETH. That fee is owed to a contract with no owner, which buys CARTHA and sends it to the vault.

What is the APY?
There is no APY to quote. The number that matters is CARTHA per vCARTHA, and it is on the site, read from the vault. It rises when people trade and stops when they do not.

Can the ratio go down?
Not in CARTHA terms. The vault never sells, never lends, never provides liquidity. In ETH terms CARTHA does whatever the market decides.

Is it audited?
No. Size any deposit as if the code could be wrong.

Who can pause it?
Nobody. There is no pause, no owner, no upgrade. Check the verified source.

Why should I deposit instead of just holding CARTHA?
Holding CARTHA gives you the token. Holding vCARTHA gives you the token plus every harvest since you deposited, and it is still a token you can move.

## Vocabulary

Say: ratio, CARTHA per vCARTHA, harvest, vault share, no claim step, no owner.

Colors: navy #0a2540 on #f4f7fb, accent #1f5fff. Type: IBM Plex Sans.

Do not say: APY, yield farm, guaranteed, only goes up (without "in CARTHA terms"), staking rewards, passive income.

No dashes of any kind in copy. Sentence case. Numbers with four decimals for the ratio.

Collateral + vault set (also under 160):

E1: Turn $CARTHA into collateral that compounds. Deposit for vCARTHA, a vault share trading fees keep buying into. No claim step, no owner. Robinhood Chain.

E2: An ERC-4626 vault where fees buy $CARTHA and vCARTHA just redeems for more. Fungible, priced by one view call, collateral-ready by design. No rebase, no owner.

E3: One deposit, two jobs: vCARTHA earns from every $CARTHA trade and stays a plain ERC-20 you can post as collateral. Nothing to claim. Robinhood Chain.

E4: The vault that makes launchpad fees compound. $CARTHA in, vCARTHA out, a collateral-ready share whose value only steps up. No claim, no rebase, no admin keys.

E5: Deposit $CARTHA, hold vCARTHA, a vault share fees keep buying into that any market can price and take as collateral. One number, one direction. Robinhood Chain.

Note: "collateral-ready" describes the design (fungible ERC-20, priced by convertToAssets); nothing lists vCARTHA as collateral yet, so keep the wording to what the share can be, not a live integration.
