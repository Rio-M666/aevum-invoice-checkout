// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InvoiceCheckout} from "../../src/InvoiceCheckout.sol";
import {Signing} from "../Signing.sol";

interface ITUSD8 is IERC20 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address, bytes32) external view returns (bool);
}

/// @notice Runs InvoiceCheckout against the REAL tUSD8 on a local fork of Aevum testnet.
///         Run with: make test-fork
contract InvoiceForkTest is Test {
    ITUSD8 constant TUSD8 = ITUSD8(0x456569838f1d43009A91ebA4263147Afd7233483);

    bytes32 constant INV = keccak256("fork-invoice-1");
    uint256 constant AMOUNT = 25e6; // 25 tUSD8

    function test_realTusd8_createAndPayInvoice() public {
        address merchant = makeAddr("merchant");
        address buyer = makeAddr("buyer");
        InvoiceCheckout invoices = new InvoiceCheckout(TUSD8, merchant);
        deal(address(TUSD8), buyer, 100e6);

        vm.prank(merchant);
        invoices.createInvoice(INV, AMOUNT, 0);

        vm.startPrank(buyer);
        TUSD8.approve(address(invoices), AMOUNT);
        invoices.pay(INV);
        vm.stopPrank();

        assertEq(TUSD8.balanceOf(merchant), AMOUNT);
        assertTrue(invoices.isPaid(INV));
    }

    function test_realTusd8_payInvoiceWithAuthorization() public {
        address merchant = makeAddr("merchant");
        (address buyer, uint256 key) = makeAddrAndKey("buyer");
        InvoiceCheckout invoices = new InvoiceCheckout(TUSD8, merchant);
        deal(address(TUSD8), buyer, 100e6);

        vm.prank(merchant);
        invoices.createInvoice(INV, AMOUNT, 0);

        uint256 deadline = block.timestamp + 1 hours;
        Signing.Auth memory a = Signing.Auth({
            from: buyer,
            to: address(invoices),
            value: AMOUNT,
            validAfter: 0,
            validBefore: deadline,
            nonce: invoices.authorizationNonce(INV)
        });
        (uint8 v, bytes32 r, bytes32 s) = Signing.signReceive(vm, key, TUSD8.DOMAIN_SEPARATOR(), a);

        vm.prank(makeAddr("relayer"));
        invoices.payWithAuthorization(INV, buyer, 0, deadline, v, r, s);

        assertEq(TUSD8.balanceOf(merchant), AMOUNT);
        assertTrue(TUSD8.authorizationState(buyer, invoices.authorizationNonce(INV)));
        assertTrue(invoices.isPaid(INV));
    }
}
