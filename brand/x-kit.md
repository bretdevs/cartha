# STILL on X

Assets in this folder: `x-banner-1500x500.png`, `x-avatar-400x400.png`, `og-1200x630.png` (site preview card), `wordmark.png`, `mark.svg`, `mark-light.svg`. Sources are in `src/` if you want to re-render at a different size.

Replace `[TOKEN]`, `[VAULT]`, `[HARVESTER]` and `[SITE]` before posting.

## Display name and bio

Name: still

Bio: A vault on Robinhood Chain. Fees buy STILL into the vault, vSTILL just gets worth more. No claim step. No owner. Unaudited.

Link: [SITE]

## Pinned thread

1.
STILL is live on Robinhood Chain.

A vault whose share is a plain ERC-20. Every STILL trade pays a fee, the fee buys STILL, the STILL goes into the vault. Your vSTILL balance never moves. What it redeems for does.

Token [TOKEN]
Vault [VAULT]
Chain 4663

[SITE]

2.
How it works.

Deposit 10 STILL, get 10 vSTILL. Ratio 1.00.
Fees buy 1 STILL into the vault. Ratio 1.10.
Supply is still 10. Your balance did not move. Each unit just redeems for more.

Burn vSTILL to leave. Same block, no queue, no exit fee.

3.
Things vSTILL never does: rebase, claim, epoch, queue, receipt NFT, transfer hook.

Things the vault never has: owner, pause, upgrade, fee switch.

The functions are not there to find. Read the bytecode: [VAULT]

4.
The ratio only turns one way.

The vault holds STILL and nothing else. Harvest can only add. Redeem only removes in proportion to the shares it burns. Rounding favours the vault.

So STILL per vSTILL cannot go down, in any block. That is a fuzz test in the repository, not a promise.

5.
What feeds it.

pons v2 charges a fee on every STILL trade, in ETH. It is owed to a contract with no owner. Anyone can call harvest() on it. Our keeper does, every few minutes.

Each harvest is capped and spaced out, so a bad caller can only ever act on a small slice.

6.
The unflattering part.

Unaudited. pons can redirect creator fees through its takeover mechanism, behind a three day timelock, and we cannot switch that off. Some post-graduation fees wait on pons to sweep. Nothing accepts vSTILL as collateral today. Ratio up is not value up.

All of it is on the site, above the deposit button.

7.
If you run risk or integrations at a market on Robinhood Chain: we are asking for a design review while it runs, not a listing. Nobody should list unaudited code.

Source, tests and the deploy script that set the fee recipient: [SITE]

## Launch day, single post

Most tokens on pons pay you fees to claim. This one buys itself into a vault and makes the share you already hold worth more.

Buy STILL on pons. Deposit on the site. Hold still.

[SITE]

## Harvest posts

Post these by hand or from the keeper log, one line, no hype:

Harvest. 0.084 ETH bought 79,120 STILL into the vault. STILL per vSTILL is now 1.0047. Block 18402113.

## Replies you will need

Where does the yield come from?
From STILL's own trading on pons. Every buy and sell pays a fee in ETH. That fee is owed to a contract with no owner, which buys STILL and sends it to the vault.

What is the APY?
There is no APY to quote. The number that matters is STILL per vSTILL, and it is on the site, read from the vault. It rises when people trade and stops when they do not.

Can the ratio go down?
Not in STILL terms. The vault never sells, never lends, never provides liquidity. In ETH terms STILL does whatever the market decides.

Is it audited?
No. Size any deposit as if the code could be wrong.

Who can pause it?
Nobody. There is no pause, no owner, no upgrade. Check the verified source.

Why should I deposit instead of just holding STILL?
Holding STILL gives you the token. Holding vSTILL gives you the token plus every harvest since you deposited, and it is still a token you can move.

## Vocabulary

Say: ratio, STILL per vSTILL, harvest, vault share, no claim step, no owner.

Do not say: APY, yield farm, guaranteed, only goes up (without "in STILL terms"), staking rewards, passive income.

No dashes of any kind in copy. Sentence case. Numbers with four decimals for the ratio.
