# InvoiceCheckout — exact-amount invoice payments in tUSD8

**Aevum Builder Challenge #1** (QDay / DoraHacks) · **Invoice Payments track**
Submission deadline: **11 Dec 2026, 08:00 UTC** · Prizes: $1,500 USDT (800 / 500 / 200)

Built on the official [Aevum Starter Kit](https://github.com/qday-io/aevum-starter-kit) (MIT).
Everything below the "What we added" section is our work; the rest of this repo is the kit.

## The problem

The kit's `Checkout` contract deliberately leaves pricing to the app: `pay(orderId, amount)`
accepts **any** amount, and the kit's own docs warn about it — `pay(orderId, 1)` marks an
order as paid for 0.000001 tUSD8, so an app must never trust `isPaid` alone and has to compare
amounts off-chain forever.

That trade-off is fine for a shopping cart. It is wrong for an **invoice**: the amount is part
of the bill itself. A payer who underpays by one base unit has not paid the invoice.

## The fix: `InvoiceCheckout`

`contracts/src/InvoiceCheckout.sol` moves the amount on-chain:

- The **merchant** creates an invoice: `createInvoice(invoiceId, amount, dueAt)`. Only the
  merchant can issue invoices, ids can't be reused, amount must be non-zero.
- `pay(invoiceId)` takes **no amount at all** — the contract pulls exactly the invoice amount
  from the payer to the merchant. Underpaying is impossible by construction, not by app checks.
- `payWithAuthorization(invoiceId, …)` is the gasless EIP-3009 path: the payer signs for the
  invoice's exact amount (any other value fails signature verification against the token),
  the nonce is bound to the invoice, and a relayer submits. Same rails as the kit's Checkout.
- `cancelInvoice(invoiceId)` lets the merchant void an unpaid invoice. Paid is final.
- `invoiceOf` / `isPaid` give apps and judges the full state; the `Paid` event is the receipt.

The web app gains an **Invoices page** (`web/src/app/invoices`): the merchant issues an
invoice and gets a shareable payment link (`/invoices?id=…`); the payer opens it, sees the
amount **read from the chain** (never from the URL), approves the exact amount and pays.
Merchant can cancel an open invoice from the same page.

## What we added

| File | What |
| --- | --- |
| `contracts/src/InvoiceCheckout.sol` | The invoice contract (create / pay / gasless pay / cancel) |
| `contracts/test/InvoiceCheckout.t.sol` | 19 unit tests incl. wrong-amount-signature, replay, cancel, fuzz |
| `contracts/test/fork/InvoiceFork.t.sol` | 2 fork tests against the **real** tUSD8 |
| `contracts/script/DeployInvoice.s.sol` | Deploy script (anvil / fork / Aevum testnet), same safety guards as the kit's |
| `Makefile` | `deploy-invoice-local`, `deploy-invoice-fork`, `deploy-invoice-aevum` targets |
| `packages/aevum/src/contracts.ts` | `invoiceCheckoutAbi` |
| `web/src/app/invoices/page.tsx` | Issue + pay UI, payment links |
| `web/src/lib/env.ts`, `web/.env.example` | `NEXT_PUBLIC_INVOICE_{AEVUM,FORK,LOCAL}` config |
| `web/src/components/Header.tsx`, `web/src/lib/errors.ts` | Nav link, invoice-specific error messages |

## Verified (2026-11-21)

- `make check` — **exit 0**: Shanghai-safe build, 30 unit tests (19 new), 5 fork tests against
  real tUSD8, typecheck across the monorepo.
- `pnpm build` (web) — **exit 0**, `/invoices` prerenders as a static route.
- **Live fork demo** (local fork of Aevum testnet, chain 440050, real tUSD8 contract):
  `InvoiceCheckout` deployed at `0xA186c1Df5FBb7DfCa063EcA9866a3A8c9c8c32c9`, then
  - create invoice (25 tUSD8): tx `0x94f4b3ad35e62425c90003bb78b11bbbf8efb2f1267178428062a913d350eb75`
  - approve: tx `0xf5ed945c756107f4f721b545a28bf3ec2923e30a15cea1b11134c147a8600d9e`
  - pay: tx `0x6b29e3393b1b1dececa6f52835ad8cf683abb36f88b4789281714e2c411a71f9`
  - result: merchant balance +25.000000 tUSD8 exactly, invoice status `Paid`, payer recorded.
  - the web UI was served against this deployment (`/invoices` returned 200 with both panels).

## Live on the real Aevum testnet (2026-11-21)

Deployed and exercised end-to-end on chain 44005 (explorer: https://explorer-test.qday.info):

- **InvoiceCheckout: `0x2C321B7e9ba4CA72fE7834c1647dA470368689a6`**
  deploy tx `0xbba02edb34d5cc296510b5fb3cb89d9844f409ab5d30a9cb24c2da32d1f875eb`
  (token = real tUSD8 `0x456569838f1d43009A91ebA4263147Afd7233483`, merchant = deployer)
- Faucet funding of the deployer (1 tQDAY + 5 tUSD8, QDay Discord faucet):
  tQDAY tx `0xf5cb59b977e8f7f98be4c4cb608786f0ee20a4e937913120ca89f03b9e91bd09`,
  tUSD8 tx `0x6418714848e66e131fc1ea63ce2551a06b026d59a1a73fc8a4e77cb62bea441d`
- **Live demo**: https://aevum-invoice-checkout.vercel.app/invoices
  (Vercel production, `NEXT_PUBLIC_NETWORKS=aevum`, `NEXT_PUBLIC_INVOICE_AEVUM` set to the
  contract above; loads without login)
- **Public repo**: https://github.com/Rio-M666/aevum-invoice-checkout
- **Real create → pay cycle** (invoice `0xedae67042e8f99ea57c8a50407483633d9d189d00e1a330662337c1225bb0363`, 2 tUSD8):
  - create: tx `0x1f8e43b4f18d86fdacb92f96186ca0ccb1feba9a8c5493fd5c59e3d270b4863b`
  - approve: tx `0xb21dc03753b8af6a451393e2b4fb88682d8f23786a1eec1ecf00d6f1150ea6e1`
  - pay: tx `0x95ec708347a4fba65709a84ab66ed0d66de14cc24ba1005c4155e331c005c19f`
  - verified on-chain afterwards: `isPaid = true`, status `Paid`, payer recorded
    (`0x49f6aFA013CBE16e1c93158452e3d936f2A0Ee19`), merchant balance +2.000000 tUSD8 exactly.

## Run the demo locally (no funds needed)

```bash
make install && make check          # everything above, from a cold clone

# terminal 1: local copy of Aevum testnet with the real tUSD8
make fork
# terminal 2:
make deploy-invoice-fork            # prints the InvoiceCheckout address (merchant = anvil account 0)
make deal TO=<your wallet address>  # 100 tUSD8 + 10 tQDAY on the fork only

cp web/.env.example web/.env.local  # set NEXT_PUBLIC_NETWORKS=fork,aevum
                                    # and NEXT_PUBLIC_INVOICE_FORK=<address from deploy>
make dev                            # http://localhost:3000/invoices
```

Connect the merchant wallet (anvil account 0) to issue an invoice, then open the payment
link from any other wallet to pay it. Anvil's default accounts are public test accounts —
local chains only.

## The one manual step: testnet funds (Discord faucet) — ✅ done 2026-11-21

Deploying to the **real** Aevum testnet needs tQDAY for gas. A fresh **testnet-only burner
wallet** has already been generated locally for this:

- **Address: `0xc907D056a61E31ED055D7b075392084B5C83dC6A`**
- Its private key is in `BURNER-WALLET-TESTNET-ONLY.txt` in this folder (gitignored, never
  commit it, never send mainnet funds to this address).

Fund it from the QDay Discord faucet — this needs **your own Discord account**:

1. Join the QDay Discord: https://discord.gg/bYPhjmrSfK
2. In `#verify`, react with ✅ to get the **Verified** role.
3. Type `/faucet`, paste the address `0xc907D056a61E31ED055D7b075392084B5C83dC6A`, and send.
   The bot replies privately with the transaction links.
4. You receive **1 tQDAY + 5 tUSD8** (deploying costs well under 0.01 tQDAY, so this is
   plenty). One claim per Discord account and per address; the Discord account must not be
   brand new. Help channel hours: Mon–Fri 10:00–18:00 HKT.
   (Alternative: the web faucet at https://faucet.qday.info — check its rules, it may require
   an Ethereum mainnet balance, which the Discord faucet does not.)

Then deploy (from this folder):

```bash
cast wallet import aevum-deployer --interactive   # paste the burner private key once
make deploy-invoice-aevum ACCOUNT=aevum-deployer  # MERCHANT defaults to the burner address
# set NEXT_PUBLIC_NETWORKS=aevum and NEXT_PUBLIC_INVOICE_AEVUM=<printed address> in web/.env.local
```

After deploying, re-run one create → pay cycle on the real testnet from the web UI and record
the contract address + transaction hashes here for the judges (explorer:
https://explorer-test.qday.info). Contract verification on the explorer isn't working yet —
the challenge asks for addresses + a link to the exact commit instead.

## Remaining submission steps (DoraHacks)

Deadline **11 Dec 2026 08:00 UTC (17:00 JST)** — submit early, the portal slows down at the end.

1. **Public GitHub repo**: ✅ done 2026-11-21 — https://github.com/Rio-M666/aevum-invoice-checkout
   (public snapshot of this tree; secrets verified absent — the burner file and `.env.local`
   are gitignored and were never staged. The kit's MIT license is in `LICENSE`.)
2. **Testnet deployment**: ✅ done 2026-11-21 — see "Live on the real Aevum testnet" above
   for the contract address and the real-testnet create / pay transaction hashes.
3. **Live demo**: ✅ done 2026-11-21 — https://aevum-invoice-checkout.vercel.app
   (Vercel production with `NEXT_PUBLIC_NETWORKS=aevum` and `NEXT_PUBLIC_INVOICE_AEVUM` set;
   `/` and `/invoices` return 200 without login, contract address confirmed in the client bundle.)
4. **Submit the BUIDL** at https://dorahacks.io/hackathon/qday with: project name, the problem
   and architecture (this README has both), repo link, demo link, contract address, tx hashes.
5. **Demo Day (15 Dec)**: the **top 5 projects present a 3–5 minute live walkthrough** on a
   video call. Prepare to show: issue an invoice as merchant → open the payment link →
   pay the exact amount → show the `Paid` receipt and the explorer page. Judging is 12–14 Dec,
   winners announced 15 Dec 2026, 14:00 HKT.
