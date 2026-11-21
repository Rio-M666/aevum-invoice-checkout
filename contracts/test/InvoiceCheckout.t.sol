// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InvoiceCheckout} from "../src/InvoiceCheckout.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";
import {Signing} from "./Signing.sol";

contract InvoiceCheckoutTest is Test {
    MockUSD8 token;
    InvoiceCheckout invoices;
    address merchant = makeAddr("merchant");
    address buyer;
    uint256 buyerKey;
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");

    bytes32 constant INV = keccak256("invoice-1");
    uint256 constant AMOUNT = 25e6; // 25 tUSD8

    function setUp() public {
        (buyer, buyerKey) = makeAddrAndKey("buyer");
        token = new MockUSD8();
        invoices = new InvoiceCheckout(IERC20(address(token)), merchant);
        token.mint(buyer, 100e6);
        vm.prank(merchant);
        invoices.createInvoice(INV, AMOUNT, 0);
    }

    // ---------- createInvoice ----------

    function test_createInvoice_recordsTerms() public view {
        InvoiceCheckout.Invoice memory inv = invoices.invoiceOf(INV);
        assertEq(inv.amount, AMOUNT);
        assertEq(uint8(inv.status), uint8(InvoiceCheckout.Status.Open));
        assertEq(inv.payer, address(0));
        assertFalse(invoices.isPaid(INV));
    }

    function test_createInvoice_onlyMerchant() public {
        vm.prank(stranger);
        vm.expectRevert(InvoiceCheckout.NotMerchant.selector);
        invoices.createInvoice(keccak256("invoice-2"), AMOUNT, 0);
    }

    function test_createInvoice_revertsOnDuplicate() public {
        vm.prank(merchant);
        vm.expectRevert(abi.encodeWithSelector(InvoiceCheckout.InvoiceExists.selector, INV));
        invoices.createInvoice(INV, AMOUNT, 0);
    }

    function test_createInvoice_revertsOnZeroAmount() public {
        vm.prank(merchant);
        vm.expectRevert(InvoiceCheckout.ZeroAmount.selector);
        invoices.createInvoice(keccak256("invoice-3"), 0, 0);
    }

    // ---------- pay (approve + call) ----------

    function test_pay_movesExactInvoiceAmount() public {
        vm.startPrank(buyer);
        token.approve(address(invoices), 100e6); // approved more than the invoice
        vm.expectEmit(true, true, false, true, address(invoices));
        emit InvoiceCheckout.Paid(INV, buyer, AMOUNT);
        invoices.pay(INV);
        vm.stopPrank();

        // Exactly the invoice amount moved — the approval size is irrelevant.
        assertEq(token.balanceOf(merchant), AMOUNT);
        assertEq(token.balanceOf(buyer), 100e6 - AMOUNT);
        assertEq(token.balanceOf(address(invoices)), 0);
        InvoiceCheckout.Invoice memory inv = invoices.invoiceOf(INV);
        assertEq(uint8(inv.status), uint8(InvoiceCheckout.Status.Paid));
        assertEq(inv.payer, buyer);
        assertEq(inv.paidAt, block.timestamp);
        assertTrue(invoices.isPaid(INV));
    }

    function test_pay_revertsOnSecondPayment() public {
        vm.startPrank(buyer);
        token.approve(address(invoices), 2 * AMOUNT);
        invoices.pay(INV);
        vm.expectRevert(abi.encodeWithSelector(InvoiceCheckout.InvoiceNotOpen.selector, INV));
        invoices.pay(INV);
        vm.stopPrank();
    }

    function test_pay_revertsOnUnknownInvoice() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceCheckout.UnknownInvoice.selector, keccak256("nope")));
        invoices.pay(keccak256("nope"));
    }

    function test_pay_revertsWithoutApproval() public {
        vm.prank(buyer);
        vm.expectRevert();
        invoices.pay(INV);
        assertFalse(invoices.isPaid(INV));
    }

    function test_pay_revertsWithInsufficientApproval() public {
        vm.startPrank(buyer);
        token.approve(address(invoices), AMOUNT - 1); // one base unit short: no dust payments
        vm.expectRevert();
        invoices.pay(INV);
        vm.stopPrank();
        assertFalse(invoices.isPaid(INV));
    }

    // ---------- cancelInvoice ----------

    function test_cancel_blocksPayment() public {
        vm.prank(merchant);
        invoices.cancelInvoice(INV);

        vm.startPrank(buyer);
        token.approve(address(invoices), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(InvoiceCheckout.InvoiceNotOpen.selector, INV));
        invoices.pay(INV);
        vm.stopPrank();
    }

    function test_cancel_onlyMerchant() public {
        vm.prank(stranger);
        vm.expectRevert(InvoiceCheckout.NotMerchant.selector);
        invoices.cancelInvoice(INV);
    }

    function test_cancel_revertsOncePaid() public {
        vm.startPrank(buyer);
        token.approve(address(invoices), AMOUNT);
        invoices.pay(INV);
        vm.stopPrank();

        vm.prank(merchant);
        vm.expectRevert(abi.encodeWithSelector(InvoiceCheckout.InvoiceNotOpen.selector, INV));
        invoices.cancelInvoice(INV);
    }

    // ---------- payWithAuthorization (EIP-3009, gasless for the payer) ----------

    function _sign(bytes32 invoiceId, uint256 value, uint256 validBefore)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        Signing.Auth memory a = Signing.Auth({
            from: buyer,
            to: address(invoices),
            value: value,
            validAfter: 0,
            validBefore: validBefore,
            nonce: invoices.authorizationNonce(invoiceId)
        });
        return Signing.signReceive(vm, buyerKey, token.DOMAIN_SEPARATOR(), a);
    }

    function test_payWithAuthorization_relayerSubmits() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(INV, AMOUNT, deadline);

        vm.prank(relayer); // the payer never sends a transaction
        invoices.payWithAuthorization(INV, buyer, 0, deadline, v, r, s);

        assertEq(token.balanceOf(merchant), AMOUNT);
        assertEq(token.balanceOf(buyer), 100e6 - AMOUNT);
        assertEq(invoices.invoiceOf(INV).payer, buyer);
        assertTrue(invoices.isPaid(INV));
    }

    function test_payWithAuthorization_signatureForWrongAmountFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        // A signature over 1 base unit cannot pay a 25 tUSD8 invoice: the contract
        // asks the token for the invoice amount, so the signature does not verify.
        (uint8 v, bytes32 r, bytes32 s) = _sign(INV, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(MockUSD8.InvalidSignature.selector);
        invoices.payWithAuthorization(INV, buyer, 0, deadline, v, r, s);
        assertFalse(invoices.isPaid(INV));
    }

    function test_payWithAuthorization_signatureIsBoundToInvoice() public {
        bytes32 other = keccak256("invoice-2");
        vm.prank(merchant);
        invoices.createInvoice(other, AMOUNT, 0);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(INV, AMOUNT, deadline);

        vm.prank(relayer);
        vm.expectRevert(MockUSD8.InvalidSignature.selector);
        invoices.payWithAuthorization(other, buyer, 0, deadline, v, r, s);
    }

    function test_payWithAuthorization_noReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(INV, AMOUNT, deadline);
        invoices.payWithAuthorization(INV, buyer, 0, deadline, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(InvoiceCheckout.InvoiceNotOpen.selector, INV));
        invoices.payWithAuthorization(INV, buyer, 0, deadline, v, r, s);
    }

    function test_payWithAuthorization_expired() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(INV, AMOUNT, deadline);
        vm.warp(deadline);

        vm.expectRevert(MockUSD8.AuthorizationExpired.selector);
        invoices.payWithAuthorization(INV, buyer, 0, deadline, v, r, s);
    }

    // ---------- misc ----------

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(InvoiceCheckout.ZeroAddress.selector);
        new InvoiceCheckout(IERC20(address(0)), merchant);
        vm.expectRevert(InvoiceCheckout.ZeroAddress.selector);
        new InvoiceCheckout(IERC20(address(token)), address(0));
    }

    function testFuzz_createAndPay(uint256 amount) public {
        amount = bound(amount, 1, 100e6);
        bytes32 id = keccak256(abi.encode(amount));
        vm.prank(merchant);
        invoices.createInvoice(id, amount, 0);

        vm.startPrank(buyer);
        token.approve(address(invoices), amount);
        invoices.pay(id);
        vm.stopPrank();

        assertEq(token.balanceOf(merchant), amount);
        assertEq(invoices.invoiceOf(id).amount, amount);
        assertTrue(invoices.isPaid(id));
    }
}
