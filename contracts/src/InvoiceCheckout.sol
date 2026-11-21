// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3009} from "./Checkout.sol";

/// @title InvoiceCheckout
/// @notice Invoice payments in tUSD8 on Aevum testnet (Invoice Payments track).
/// @dev The kit's `Checkout` deliberately leaves pricing to the app: `pay(orderId, amount)`
///      accepts any amount, so a dust payment can mark an order as paid. An invoice is
///      different — the amount is part of the bill. Here the merchant fixes the amount
///      on-chain when the invoice is created, and neither `pay` nor `payWithAuthorization`
///      takes an amount from the payer at all. Paying the wrong amount is not a case the
///      app has to check for; it is impossible by construction.
///
///      Two ways to pay, same as `Checkout`:
///      1. `pay`: the payer approves this contract, then calls `pay` (two transactions).
///      2. `payWithAuthorization`: the payer signs an EIP-3009 message off-chain for the
///         exact invoice amount and anyone submits it. The payer needs no native gas.
///         The signed nonce is `authorizationNonce(invoiceId)`, binding the signature to
///         this one invoice, and `receiveWithAuthorization` ensures only this contract
///         can pull the funds.
contract InvoiceCheckout {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Paid,
        Cancelled
    }

    struct Invoice {
        uint256 amount;
        uint64 dueAt; // 0 = no due date
        uint64 paidAt;
        address payer;
        Status status;
    }

    IERC20 public immutable token;
    address public immutable merchant;

    mapping(bytes32 invoiceId => Invoice) private _invoices;

    event InvoiceCreated(bytes32 indexed invoiceId, uint256 amount, uint64 dueAt);
    event Paid(bytes32 indexed invoiceId, address indexed payer, uint256 amount);
    event InvoiceCancelled(bytes32 indexed invoiceId);

    error ZeroAddress();
    error ZeroAmount();
    error NotMerchant();
    error InvoiceExists(bytes32 invoiceId);
    error UnknownInvoice(bytes32 invoiceId);
    error InvoiceNotOpen(bytes32 invoiceId);

    modifier onlyMerchant() {
        if (msg.sender != merchant) revert NotMerchant();
        _;
    }

    constructor(IERC20 token_, address merchant_) {
        if (address(token_) == address(0) || merchant_ == address(0)) revert ZeroAddress();
        token = token_;
        merchant = merchant_;
    }

    /// @notice Create an invoice for a fixed `amount`. Only the merchant can issue invoices.
    /// @param dueAt Payment deadline as a unix timestamp, or 0 for none. Informational:
    ///        an open invoice can still be paid after it, but the merchant may cancel it.
    function createInvoice(bytes32 invoiceId, uint256 amount, uint64 dueAt) external onlyMerchant {
        if (amount == 0) revert ZeroAmount();
        if (_invoices[invoiceId].status != Status.None) revert InvoiceExists(invoiceId);
        _invoices[invoiceId] = Invoice({amount: amount, dueAt: dueAt, paidAt: 0, payer: address(0), status: Status.Open});
        emit InvoiceCreated(invoiceId, amount, dueAt);
    }

    /// @notice Cancel an unpaid invoice. Paid invoices can never be cancelled.
    function cancelInvoice(bytes32 invoiceId) external onlyMerchant {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice(invoiceId);
        if (inv.status != Status.Open) revert InvoiceNotOpen(invoiceId);
        inv.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId);
    }

    /// @notice Pay an open invoice. The amount is read from the invoice, never from the caller.
    function pay(bytes32 invoiceId) external {
        Invoice memory inv = _recordPayment(invoiceId, msg.sender);
        token.safeTransferFrom(msg.sender, merchant, inv.amount);
    }

    /// @notice Pay an open invoice with an EIP-3009 `ReceiveWithAuthorization` signed by `from`.
    /// @dev The signature must be over the invoice's exact amount: this function passes
    ///      `inv.amount` to the token, so a signature over any other value does not verify.
    function payWithAuthorization(
        bytes32 invoiceId,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        Invoice memory inv = _recordPayment(invoiceId, from);
        IERC3009(address(token)).receiveWithAuthorization(
            from, address(this), inv.amount, validAfter, validBefore, authorizationNonce(invoiceId), v, r, s
        );
        token.safeTransfer(merchant, inv.amount);
    }

    /// @notice The EIP-3009 nonce a payer must sign to pay `invoiceId` through this contract.
    function authorizationNonce(bytes32 invoiceId) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), invoiceId));
    }

    function invoiceOf(bytes32 invoiceId) external view returns (Invoice memory) {
        return _invoices[invoiceId];
    }

    function isPaid(bytes32 invoiceId) external view returns (bool) {
        return _invoices[invoiceId].status == Status.Paid;
    }

    function _recordPayment(bytes32 invoiceId, address payer) private returns (Invoice memory inv) {
        inv = _invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice(invoiceId);
        if (inv.status != Status.Open) revert InvoiceNotOpen(invoiceId);
        inv.payer = payer;
        inv.paidAt = uint64(block.timestamp);
        inv.status = Status.Paid;
        _invoices[invoiceId] = inv;
        emit Paid(invoiceId, payer, inv.amount);
    }
}
