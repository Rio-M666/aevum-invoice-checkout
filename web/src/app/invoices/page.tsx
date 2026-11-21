"use client";

import { erc20Abi, invoiceCheckoutAbi, TUSD8_ADDRESS, txUrl } from "@aevum-kit/aevum";
import { useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { formatUnits, isHex, parseUnits, type Address, type Hash, type Hex } from "viem";
import { useAccount, useConfig, useReadContract, useReadContracts } from "wagmi";
import { readContract, simulateContract, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { useNetwork } from "@/lib/network";
import { explain } from "@/lib/errors";
import { newOrderId, orderLabel, short } from "@/lib/order";

const STATUS_LABEL = ["Not created", "Open", "Paid", "Cancelled"] as const;
type Phase = "idle" | "working" | "done" | "error";

/** The token InvoiceCheckout settles in: read from the contract, tUSD8 as the fallback. */
function useInvoiceToken(invoiceAddress: Address | undefined, isLocal: boolean) {
  const { net } = useNetwork();
  const chainId = net.chain.id;
  const fromContract = useReadContract({
    address: invoiceAddress,
    abi: invoiceCheckoutAbi,
    functionName: "token",
    chainId,
    query: { enabled: Boolean(invoiceAddress) },
  });
  const address: Address | undefined = fromContract.data ?? (isLocal ? undefined : TUSD8_ADDRESS);
  const meta = useReadContracts({
    contracts: address
      ? [
          { address, abi: erc20Abi, functionName: "decimals", chainId },
          { address, abi: erc20Abi, functionName: "symbol", chainId },
        ]
      : [],
    query: { enabled: Boolean(address) },
  });
  return {
    address,
    decimals: (meta.data?.[0]?.result as number | undefined) ?? 6,
    symbol: (meta.data?.[1]?.result as string | undefined) ?? "tUSD8",
  };
}

function fmtTime(unixSeconds: bigint): string {
  return unixSeconds === 0n ? "—" : new Date(Number(unixSeconds) * 1000).toLocaleString();
}

export default function InvoicesPage() {
  // useSearchParams (payment links carry ?id=) needs a Suspense boundary on this static route.
  return (
    <Suspense
      fallback={
        <main className="shell">
          <p className="fine">Loading…</p>
        </main>
      }
    >
      <InvoicesInner />
    </Suspense>
  );
}

function InvoicesInner() {
  const { net } = useNetwork();
  const appChain = net.chain;
  const invoiceAddress = net.invoice;
  const hasExplorer = net.hasExplorer;
  const config = useConfig();
  const { address, isConnected, chainId } = useAccount();
  const onChain = isConnected && chainId === appChain.id;
  const search = useSearchParams();
  const token = useInvoiceToken(invoiceAddress, net.key === "local");

  const merchant = useReadContract({
    address: invoiceAddress,
    abi: invoiceCheckoutAbi,
    functionName: "merchant",
    chainId: appChain.id,
    query: { enabled: Boolean(invoiceAddress) },
  });
  const isMerchant = Boolean(address && merchant.data && address.toLowerCase() === merchant.data.toLowerCase());

  // ---------- issue an invoice ----------
  const [memo, setMemo] = useState("");
  const [amountText, setAmountText] = useState("25.00");
  const [dueText, setDueText] = useState("");
  const [createdId, setCreatedId] = useState<Hex | null>(null);
  const [createPhase, setCreatePhase] = useState<Phase>("idle");
  const [createError, setCreateError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  async function onCreate() {
    if (!address || !invoiceAddress || !token.address) return;
    setCreateError(null);
    setCreatePhase("working");
    try {
      const amount = parseUnits(amountText.trim(), token.decimals);
      if (amount <= 0n) throw new Error("The amount must be more than zero.");
      const dueAt = dueText ? BigInt(Math.floor(new Date(dueText).getTime() / 1000)) : 0n;
      const id = newOrderId(); // a fresh, unguessable invoice id; the memo stays in the app
      const { request } = await simulateContract(config, {
        account: address,
        address: invoiceAddress,
        abi: invoiceCheckoutAbi,
        functionName: "createInvoice",
        args: [id, amount, dueAt],
        chainId: appChain.id,
      });
      const hash = await writeContract(config, request);
      const receipt = await waitForTransactionReceipt(config, { hash, chainId: appChain.id });
      if (receipt.status !== "success") throw new Error("The transaction reverted on chain.");
      setCreatedId(id);
      setPayId(id);
      setCreatePhase("done");
    } catch (e) {
      setCreateError(explain(e));
      setCreatePhase("error");
    }
  }

  // ---------- pay an invoice ----------
  const [payId, setPayId] = useState<Hex | null>(null);
  const [payIdText, setPayIdText] = useState("");
  useEffect(() => {
    const fromUrl = search.get("id");
    if (fromUrl && isHex(fromUrl) && fromUrl.length === 66) {
      setPayId(fromUrl);
      setPayIdText(fromUrl);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const validPayId = payId !== null && isHex(payId) && payId.length === 66;
  const invoice = useReadContract({
    address: invoiceAddress,
    abi: invoiceCheckoutAbi,
    functionName: "invoiceOf",
    args: validPayId ? [payId] : undefined,
    chainId: appChain.id,
    query: { enabled: Boolean(invoiceAddress) && validPayId },
  });
  const inv = invoice.data;
  const status = inv ? inv.status : 0;

  const balance = useReadContract({
    address: token.address,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: appChain.id,
    query: { enabled: onChain && Boolean(token.address) },
  });

  const [payPhase, setPayPhase] = useState<Phase>("idle");
  const [payError, setPayError] = useState<string | null>(null);
  const [payTx, setPayTx] = useState<Hash | null>(null);
  const busy = payPhase === "working" || createPhase === "working";

  async function onPay() {
    if (!address || !invoiceAddress || !token.address || !validPayId || !inv) return;
    setPayError(null);
    setPayPhase("working");
    try {
      const amount = inv.amount; // the amount comes from the invoice on chain, never from this page's inputs
      const allowance = await readContract(config, {
        address: token.address,
        abi: erc20Abi,
        functionName: "allowance",
        args: [address, invoiceAddress],
        chainId: appChain.id,
      });
      if (allowance < amount) {
        const approveHash = await writeContract(config, {
          address: token.address,
          abi: erc20Abi,
          functionName: "approve",
          args: [invoiceAddress, amount],
          chainId: appChain.id,
        });
        await waitForTransactionReceipt(config, { hash: approveHash, chainId: appChain.id });
      }
      const { request } = await simulateContract(config, {
        account: address,
        address: invoiceAddress,
        abi: invoiceCheckoutAbi,
        functionName: "pay",
        args: [payId],
        chainId: appChain.id,
      });
      const hash = await writeContract(config, request);
      const receipt = await waitForTransactionReceipt(config, { hash, chainId: appChain.id });
      if (receipt.status !== "success") throw new Error("The transaction reverted on chain. Nothing was charged.");
      setPayTx(hash);
      setPayPhase("done");
      invoice.refetch();
      balance.refetch();
    } catch (e) {
      setPayError(explain(e));
      setPayPhase("error");
    }
  }

  async function onCancel() {
    if (!address || !invoiceAddress || !validPayId) return;
    setPayError(null);
    setPayPhase("working");
    try {
      const { request } = await simulateContract(config, {
        account: address,
        address: invoiceAddress,
        abi: invoiceCheckoutAbi,
        functionName: "cancelInvoice",
        args: [payId],
        chainId: appChain.id,
      });
      const hash = await writeContract(config, request);
      await waitForTransactionReceipt(config, { hash, chainId: appChain.id });
      setPayPhase("done");
      invoice.refetch();
    } catch (e) {
      setPayError(explain(e));
      setPayPhase("error");
    }
  }

  function loadFromText() {
    const t = payIdText.trim();
    if (isHex(t) && t.length === 66) {
      setPayId(t);
      setPayPhase("idle");
      setPayTx(null);
    }
  }

  const shareLink = createdId && typeof window !== "undefined" ? `${window.location.origin}/invoices?id=${createdId}` : null;
  const enoughBalance = !inv || balance.data === undefined || balance.data >= inv.amount;

  return (
    <main className="shell">
      <div className="page-head">
        <div>
          <p className="eyebrow">Builder Challenge · InvoiceCheckout.sol</p>
          <h1>Invoice payments</h1>
          <p className="lede">
            The merchant fixes the amount on chain when the invoice is created. The payer can only pay exactly that amount — a dust
            payment can never mark an invoice as paid.
          </p>
        </div>
      </div>

      {!invoiceAddress && (
        <div className="notice warn" role="status" style={{ marginBottom: 16 }}>
          <strong>InvoiceCheckout is not deployed on {net.label} yet</strong>
          <span>
            Run <span className="mono">make deploy-invoice-{net.key === "aevum" ? "aevum" : net.key}</span> and set{" "}
            <span className="mono">NEXT_PUBLIC_INVOICE_{net.key.toUpperCase()}</span> in web/.env.local.
          </span>
        </div>
      )}

      <div className="row">
        <section className="card stack" aria-label="Issue an invoice" style={{ flex: "1 1 340px" }}>
          <h2>Issue an invoice</h2>
          <label className="stack" style={{ gap: 4 }}>
            <span className="fine">Memo (stays in the app, shown to you only)</span>
            <input value={memo} onChange={(e) => setMemo(e.target.value)} placeholder="Design work, November" disabled={busy} />
          </label>
          <label className="stack" style={{ gap: 4 }}>
            <span className="fine">Amount ({token.symbol})</span>
            <input value={amountText} onChange={(e) => setAmountText(e.target.value)} inputMode="decimal" disabled={busy} />
          </label>
          <label className="stack" style={{ gap: 4 }}>
            <span className="fine">Due date (optional)</span>
            <input type="datetime-local" value={dueText} onChange={(e) => setDueText(e.target.value)} disabled={busy} />
          </label>
          <dl className="kv" style={{ fontSize: 13 }}>
            <dt>Merchant</dt>
            <dd>{merchant.data ? short(merchant.data) : "—"}</dd>
            <dt>Contract</dt>
            <dd>{invoiceAddress ? short(invoiceAddress) : "not deployed"}</dd>
          </dl>
          {isConnected && !isMerchant && merchant.data && (
            <div className="notice warn" role="status">
              <strong>Connected wallet is not the merchant</strong>
              <span>Only {short(merchant.data)} can issue invoices on this contract.</span>
            </div>
          )}
          {createError && (
            <div className="notice bad" role="alert">
              <strong>Invoice wasn&apos;t created</strong>
              <span>{createError}</span>
            </div>
          )}
          {createPhase === "done" && shareLink && (
            <div className="notice good" role="status">
              <strong>Invoice created. Send this link to the payer:</strong>
              <span className="mono" style={{ wordBreak: "break-all" }}>{shareLink}</span>
              <button
                type="button"
                className="btn"
                onClick={() => {
                  navigator.clipboard.writeText(shareLink).then(() => setCopied(true));
                }}
              >
                {copied ? "Copied" : "Copy link"}
              </button>
            </div>
          )}
          <button type="button" className="btn big block" disabled={!onChain || !invoiceAddress || !isMerchant || busy} onClick={onCreate}>
            {createPhase === "working" ? "Check your wallet…" : `Create invoice`}
          </button>
          <p className="fine">The amount is written into the contract. Neither the payer nor this page can change it afterwards.</p>
        </section>

        <section className="card stack" aria-label="Pay an invoice" style={{ flex: "1.3 1 420px" }}>
          <h2>Pay an invoice</h2>
          <div className="stack" style={{ gap: 4 }}>
            <span className="fine">Invoice id (from the payment link)</span>
            <div style={{ display: "flex", gap: 8 }}>
              <input
                value={payIdText}
                onChange={(e) => setPayIdText(e.target.value)}
                placeholder="0x…"
                className="mono"
                style={{ flex: 1 }}
                disabled={busy}
              />
              <button type="button" className="btn" onClick={loadFromText} disabled={busy}>
                Load
              </button>
            </div>
          </div>

          {validPayId && invoice.isLoading && <p className="fine">Loading invoice…</p>}
          {validPayId && inv && status === 0 && (
            <div className="notice warn" role="status">
              <strong>No such invoice</strong>
              <span>Invoice {orderLabel(payId)} doesn&apos;t exist on this contract and network.</span>
            </div>
          )}
          {validPayId && inv && status > 0 && (
            <>
              <div className="lines">
                <div className="line">
                  <span>Invoice</span>
                  <span className="mono">{orderLabel(payId)}</span>
                </div>
                <div className="line" style={{ alignItems: "baseline" }}>
                  <span style={{ fontWeight: 600 }}>Amount due</span>
                  <span className="total">
                    {formatUnits(inv.amount, token.decimals)} <small>{token.symbol}</small>
                  </span>
                </div>
              </div>
              <dl className="kv" style={{ fontSize: 13 }}>
                <dt>Status</dt>
                <dd>{STATUS_LABEL[status]}</dd>
                <dt>Due</dt>
                <dd>{fmtTime(inv.dueAt)}</dd>
                {status === 2 && (
                  <>
                    <dt>Paid by</dt>
                    <dd>{short(inv.payer)}</dd>
                    <dt>Paid at</dt>
                    <dd>{fmtTime(inv.paidAt)}</dd>
                  </>
                )}
                <dt>Your balance</dt>
                <dd>{balance.data !== undefined ? `${formatUnits(balance.data, token.decimals)} ${token.symbol}` : "—"}</dd>
              </dl>

              {status === 1 && !enoughBalance && (
                <div className="notice warn" role="status">
                  <strong>Not enough {token.symbol}</strong>
                  <span>This invoice needs {formatUnits(inv.amount, token.decimals)} {token.symbol}. See the Setup page for how to get test tokens.</span>
                </div>
              )}
              {status === 2 && (
                <div className="notice good" role="status">
                  <strong>Paid</strong>
                  <span>
                    The Paid event on chain is the receipt.
                    {payTx && hasExplorer && (
                      <>
                        {" "}
                        <a href={txUrl(payTx)} target="_blank" rel="noreferrer">
                          View transaction
                        </a>
                      </>
                    )}
                  </span>
                </div>
              )}
              {status === 3 && (
                <div className="notice warn" role="status">
                  <strong>Cancelled by the merchant</strong>
                  <span>This invoice can no longer be paid.</span>
                </div>
              )}
              {payError && (
                <div className="notice bad" role="alert">
                  <strong>Something didn&apos;t go through</strong>
                  <span>{payError}</span>
                </div>
              )}
              {status === 1 && (
                <div style={{ display: "flex", gap: 8 }}>
                  <button type="button" className="btn big block" disabled={!onChain || busy || !enoughBalance} onClick={onPay} style={{ flex: 1 }}>
                    {payPhase === "working" ? "Check your wallet…" : `Approve & pay ${formatUnits(inv.amount, token.decimals)} ${token.symbol}`}
                  </button>
                  {isMerchant && (
                    <button type="button" className="btn big" disabled={!onChain || busy} onClick={onCancel}>
                      Cancel invoice
                    </button>
                  )}
                </div>
              )}
              <p className="fine">The approval is for the exact invoice amount, never unlimited. Gasless payment (EIP-3009) is supported by the contract and covered by its tests.</p>
            </>
          )}
        </section>
      </div>
    </main>
  );
}
