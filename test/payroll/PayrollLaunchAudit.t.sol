// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PayrollSetup} from "./PayrollSetup.sol";
import {Payroll} from "../../src/payroll/Payroll.sol";

/// @dev An NFT escrow with no way to release ERC-20 funds.
contract PassiveSeatEscrow {
    function isEscrow() external pure returns (bool) {
        return true;
    }
}

/// @dev A contract wallet deliberately accepting payment can initiate each kind of claim.
contract ClaimingSeatWallet {
    function claimSeat(Payroll payroll, uint256 id) external returns (uint256) {
        return payroll.claimSeat(id);
    }

    function claimSeats(Payroll payroll, uint256[] calldata list) external returns (uint256) {
        return payroll.claimSeats(list);
    }

    function claimTip(Payroll payroll, uint256 agent) external returns (uint256) {
        return payroll.claimTip(agent);
    }
}

/// @notice 4e16393fe68c: an observer must not force accrued IMD into a passive NFT escrow.
contract PayrollLaunchAuditTest is PayrollSetup {
    uint256 internal constant SEAT = 7;
    uint256 internal constant AGENT = 52211;
    uint256 internal constant SHARE = 0.015e18;
    address internal escrow;
    address internal seatOwner;

    function setUp() public override {
        super.setUp();
        pay(100e18);
        escrow = address(new PassiveSeatEscrow());
        seatOwner = seats.ownerOf(SEAT);
        seats.setOwner(SEAT, escrow);
        adapter.bind(AGENT, address(seats), SEAT);
    }

    function test_audit_observerCannotForceSeatShareIntoEscrow() public {
        vm.prank(keeper);
        (bool ok,) = address(payroll).call(abi.encodeCall(payroll.claimSeat, (SEAT)));
        assertFalse(ok, "observer forced a payment to escrow");
        assertEq(imd.balanceOf(escrow), 0);
        assertEq(payroll.seatClaimable(SEAT), SHARE);
        seats.setOwner(SEAT, seatOwner);
        assertEq(payroll.claimSeat(SEAT), SHARE);
        assertEq(imd.balanceOf(seatOwner), SHARE);
        assertBooksBalance();
    }

    function test_audit_batchSkipsEscrowAndPaysOtherSeats() public {
        uint256 paid = payroll.claimSeats(ids(SEAT, 8, SEAT));
        assertEq(paid, SHARE, "batch forced a payment to escrow");
        assertEq(imd.balanceOf(escrow), 0);
        assertEq(payroll.seatClaimable(SEAT), SHARE);
        assertEq(imd.balanceOf(seats.ownerOf(8)), SHARE);
        assertBooksBalance();
    }

    function test_audit_observerCannotForceAgentTipIntoEscrow() public {
        tipTo(ids(AGENT), 5e18);
        vm.prank(keeper);
        (bool ok,) = address(payroll).call(abi.encodeCall(payroll.claimTip, (AGENT)));
        assertFalse(ok, "observer forced a tip to escrow");
        assertEq(imd.balanceOf(escrow), 0);
        assertEq(payroll.tipOwed(AGENT), 5e18);
        seats.setOwner(SEAT, seatOwner);
        assertEq(payroll.claimTip(AGENT), 5e18);
        assertEq(imd.balanceOf(seatOwner), 5e18);
        assertBooksBalance();
    }

    function test_audit_contractWalletCanClaimItsOwnShareAndTip() public {
        ClaimingSeatWallet wallet = new ClaimingSeatWallet();
        seats.setOwner(SEAT, address(wallet));
        tipTo(ids(AGENT), 5e18);
        assertEq(wallet.claimSeat(payroll, SEAT), SHARE);
        assertEq(wallet.claimTip(payroll, AGENT), 5e18);
        assertEq(imd.balanceOf(address(wallet)), SHARE + 5e18);
        assertBooksBalance();
    }

    function test_audit_contractWalletBatchSkipsAnotherContractsSeat() public {
        ClaimingSeatWallet wallet = new ClaimingSeatWallet();
        seats.setOwner(8, address(wallet));
        seats.setOwner(9, address(wallet));
        assertEq(wallet.claimSeats(payroll, ids(8, SEAT, 9)), 2 * SHARE);
        assertEq(imd.balanceOf(address(wallet)), 2 * SHARE);
        assertEq(imd.balanceOf(escrow), 0);
        assertEq(payroll.seatClaimable(SEAT), SHARE);
        assertBooksBalance();
    }

    function test_audit_escrowedTipCannotBeSweptWhileWaitingForItsOwner() public {
        tipTo(ids(AGENT), 5e18);
        skip(400 days);
        vm.expectRevert(abi.encodeWithSelector(Payroll.TipStillClaimable.selector, AGENT, SEAT));
        payroll.sweepTip(AGENT);
        assertEq(payroll.tipOwed(AGENT), 5e18);
        seats.setOwner(SEAT, seatOwner);
        assertEq(payroll.claimTip(AGENT), 5e18);
        assertBooksBalance();
    }
}
