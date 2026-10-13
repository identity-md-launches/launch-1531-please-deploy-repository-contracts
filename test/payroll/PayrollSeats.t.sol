// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Payroll} from "../../src/payroll/Payroll.sol";
import {PayrollSetup} from "./PayrollSetup.sol";
import {RawResponder} from "./mocks/MockSeats.sol";

/// @dev The seat pool: an equal share per seat, paid to whoever owns the seat when the claim is made.
contract PayrollSeatsTest is PayrollSetup {
    event SeatClaimed(uint256 indexed tokenId, address indexed owner, uint256 amount);

    uint256 internal constant PER_SEAT = 3e18; // 30% of 20,000 IMD over 2,000 seats

    function setUp() public override {
        super.setUp();
        pay(20_000e18);
    }

    function test_claimSeat_paysTheOwnerWhoeverCalls() public {
        address owner = seats.ownerOf(7);
        assertEq(payroll.seatClaimable(7), PER_SEAT);

        vm.expectEmit(address(payroll));
        emit SeatClaimed(7, owner, PER_SEAT);
        vm.prank(keeper);
        uint256 paid = payroll.claimSeat(7);

        assertEq(paid, PER_SEAT);
        assertEq(imd.balanceOf(owner), PER_SEAT);
        assertEq(imd.balanceOf(keeper), 0);
        assertEq(payroll.seatClaimable(7), 0);
        assertEq(payroll.ledger().seatClaimed, PER_SEAT);
        assertBooksBalance();
    }

    function test_claimSeat_secondClaimPaysNothing() public {
        payroll.claimSeat(7);
        vm.recordLogs();
        assertEq(payroll.claimSeat(7), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(imd.balanceOf(seats.ownerOf(7)), PER_SEAT);
    }

    function test_claimSeat_followsTheSeatWhenItChangesHands() public {
        address seller = seats.ownerOf(7);
        address buyer = makeAddr("buyer");

        // Unclaimed money travels with the seat: the owner at the time of the claim is paid.
        seats.setOwner(7, buyer);
        assertEq(payroll.claimSeat(7), PER_SEAT);
        assertEq(imd.balanceOf(buyer), PER_SEAT);
        assertEq(imd.balanceOf(seller), 0);

        pay(20_000e18);
        assertEq(payroll.claimSeat(7), PER_SEAT);
        assertEq(imd.balanceOf(buyer), 2 * PER_SEAT);
    }

    function test_claimSeat_revertsForAnIdThatIsNotASeat() public {
        vm.expectRevert(abi.encodeWithSelector(Payroll.UnknownSeat.selector, SEAT_COUNT));
        payroll.claimSeat(SEAT_COUNT);
        vm.expectRevert(abi.encodeWithSelector(Payroll.UnknownSeat.selector, type(uint256).max));
        payroll.claimSeat(type(uint256).max);
        assertEq(payroll.seatClaimable(SEAT_COUNT), 0);
    }

    /// @dev An ordinary wallet can still be paid by a keeper while it owns the seat.
    function test_claimSeat_paysTheCurrentWalletOwner() public {
        uint256 seat = 42;
        address owner = seats.ownerOf(seat);
        address buyer = makeAddr("temporary wallet owner");
        seats.setOwner(seat, buyer);
        vm.prank(makeAddr("anyone"));
        payroll.claimSeat(seat);
        seats.setOwner(seat, owner);
        assertEq(imd.balanceOf(buyer), PER_SEAT);
        assertEq(imd.balanceOf(owner), 0);
        assertEq(payroll.seatClaimable(seat), 0);
    }

    /// @dev A seat whose `ownerOf` reverts cannot be claimed yet and loses nothing.
    function test_claimSeat_waitsWhileOwnerOfReverts() public {
        seats.setReverting(9, true);
        vm.expectRevert(abi.encodeWithSelector(Payroll.SeatHasNoOwner.selector, 9));
        payroll.claimSeat(9);
        assertEq(payroll.seatClaimable(9), PER_SEAT);

        pay(20_000e18);
        seats.setReverting(9, false);
        assertEq(payroll.claimSeat(9), 2 * PER_SEAT, "the whole share, including what accrued while it waited");
        assertBooksBalance();
    }

    function test_claimSeat_rejectsAnOwnerThatIsNotAnAddress() public {
        RawResponder odd = new RawResponder();
        Payroll p = payrollWithSeats(address(odd));

        odd.program(abi.encode(address(0)), false);
        vm.expectRevert(abi.encodeWithSelector(Payroll.SeatHasNoOwner.selector, 1));
        p.claimSeat(1);

        odd.program(abi.encode(uint256(1) << 160 | uint160(address(this))), false);
        vm.expectRevert(abi.encodeWithSelector(Payroll.SeatHasNoOwner.selector, 1));
        p.claimSeat(1);

        odd.program(new bytes(31), false);
        vm.expectRevert(abi.encodeWithSelector(Payroll.SeatHasNoOwner.selector, 1));
        p.claimSeat(1);

        odd.program("", false);
        vm.expectRevert(abi.encodeWithSelector(Payroll.SeatHasNoOwner.selector, 1));
        p.claimSeat(1);

        // A clean answer (with extra bytes after the first word) is accepted.
        address owner = makeAddr("owner");
        odd.program(abi.encode(owner, uint256(123)), false);
        assertEq(p.claimSeat(1), PER_SEAT);
        assertEq(imd.balanceOf(owner), PER_SEAT);
    }

    function test_claimSeat_whenTheSeatTokenHasNoCode() public {
        Payroll p = payrollWithSeats(address(0xC0DE1E55));
        vm.expectRevert(abi.encodeWithSelector(Payroll.SeatHasNoOwner.selector, 1));
        p.claimSeat(1);
        assertEq(p.seatClaimable(1), PER_SEAT);
    }

    /// @dev No call lets one seat take another seat's share.
    function test_claimSeat_cannotTouchAnotherSeatsShare() public {
        for (uint256 i; i < 5; ++i) {
            payroll.claimSeat(7);
        }
        assertEq(payroll.seatClaimable(8), PER_SEAT);
        assertEq(imd.balanceOf(seats.ownerOf(7)), PER_SEAT);
        assertEq(payroll.claimSeat(8), PER_SEAT);
        assertEq(payroll.ledger().seatClaimed, 2 * PER_SEAT);
    }

    function test_everySeatGetsTheSameAndThePoolIsNeverOverpaid() public {
        uint256 total;
        uint256[] memory batch = new uint256[](200);
        for (uint256 start; start < SEAT_COUNT; start += 200) {
            for (uint256 i; i < 200; ++i) {
                batch[i] = start + i;
            }
            total += payroll.claimSeats(batch);
        }
        assertEq(total, 6_000e18);
        Payroll.Ledger memory l = payroll.ledger();
        assertEq(l.seatClaimed, l.toSeats);
        assertEq(imd.balanceOf(seats.ownerOf(0)), PER_SEAT);
        assertEq(imd.balanceOf(seats.ownerOf(1999)), PER_SEAT);
        assertBooksBalance();
    }

    // ---- claimSeats

    function test_claimSeats_skipsWhatItCannotPayAndPaysTheRest() public {
        seats.setReverting(3, true);
        uint256[] memory list = new uint256[](6);
        list[0] = 1;
        list[1] = SEAT_COUNT + 5; // not a seat
        list[2] = 3; // owner cannot be read
        list[3] = 1; // repeated
        list[4] = 4;
        list[5] = type(uint256).max;

        vm.prank(keeper);
        uint256 paid = payroll.claimSeats(list);

        assertEq(paid, 2 * PER_SEAT);
        assertEq(imd.balanceOf(seats.ownerOf(1)), PER_SEAT);
        assertEq(imd.balanceOf(seats.ownerOf(4)), PER_SEAT);
        assertEq(payroll.seatClaimable(3), PER_SEAT, "the seat that could not be paid keeps its share");
        assertBooksBalance();
    }

    function test_claimSeats_paysNeighboursWithOneOwnerInOneTransfer() public {
        address whale = makeAddr("whale");
        seats.setOwner(10, whale);
        seats.setOwner(11, whale);
        seats.setOwner(12, whale);
        uint256[] memory list = new uint256[](4);
        list[0] = 10;
        list[1] = 11;
        list[2] = 12;
        list[3] = 13;

        vm.recordLogs();
        assertEq(payroll.claimSeats(list), 4 * PER_SEAT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 transfers;
        uint256 claims;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) ++transfers;
            if (logs[i].topics[0] == SeatClaimed.selector) ++claims;
        }
        assertEq(transfers, 2, "three seats of one owner are one transfer, the fourth is another");
        assertEq(claims, 4, "every seat still gets its own event");
        assertEq(imd.balanceOf(whale), 3 * PER_SEAT);
        assertEq(imd.balanceOf(seats.ownerOf(13)), PER_SEAT);
    }

    function test_claimSeats_emptyAndAllSkippedListsPayNothing() public {
        assertEq(payroll.claimSeats(new uint256[](0)), 0);
        payroll.claimSeat(5);
        assertEq(payroll.claimSeats(ids(5, 5, SEAT_COUNT)), 0);
        assertEq(payroll.ledger().seatClaimed, PER_SEAT);
    }

    function test_claimSeats_revertsAboveTheListLimit() public {
        uint256[] memory list = new uint256[](201);
        vm.expectRevert(abi.encodeWithSelector(Payroll.TooManySeats.selector, 201, 200));
        payroll.claimSeats(list);
        payroll.claimSeats(new uint256[](200));
    }

    /// @dev A seat owned by Payroll itself: its share comes back as unbooked revenue for everyone.
    function test_seatOwnedByPayrollRecyclesItsShare() public {
        seats.setOwner(20, address(payroll));
        assertEq(payroll.claimSeat(20), PER_SEAT);
        assertEq(payroll.unbooked(), PER_SEAT);
        assertEq(payroll.book(), PER_SEAT);
        assertBooksBalance();
    }

    function payrollWithSeats(address seatToken) internal returns (Payroll p) {
        p = new Payroll(
            address(imd),
            address(simd),
            seatToken,
            SEAT_COUNT,
            address(adapter),
            address(questions),
            FEED_A,
            FEED_B,
            FEED_C
        );
        vm.startPrank(payer);
        imd.approve(address(p), type(uint256).max);
        p.pay(20_000e18, bytes32(0));
        vm.stopPrank();
    }
}

/// @dev Seven seats, so that amounts rarely divide evenly and the carry is exercised.
contract PayrollSeatCarryTest is PayrollSetup {
    function seatCount() internal pure override returns (uint256) {
        return 7;
    }

    function test_carry_weiThatDoNotDivideWaitForTheNextCredit() public {
        pay(100); // seats get 30 wei: 4 each, 2 carried
        assertEq(payroll.seatAccrued(), 4);
        assertEq(payroll.seatCarry(), 2);
        assertEq(payroll.seatClaimable(0), 4);

        pay(20); // seats get 6 more: 8 with the carry, one each, 1 carried
        assertEq(payroll.seatAccrued(), 5);
        assertEq(payroll.seatCarry(), 1);
        assertBooksBalance();
    }

    function test_carry_poolSmallerThanTheSeatCountPaysNobodyYet() public {
        pay(10); // 3 wei for 7 seats
        assertEq(payroll.seatAccrued(), 0);
        assertEq(payroll.seatCarry(), 3);
        assertEq(payroll.claimSeat(0), 0);
        (, uint256 seatPool,,,) = payroll.owed();
        assertEq(seatPool, 3, "still owed to the seats");
        assertBooksBalance();
    }

    function test_carry_claimsNeverExceedWhatThePoolWasGiven() public {
        uint256[] memory all = new uint256[](7);
        for (uint256 i; i < 7; ++i) {
            all[i] = i;
        }
        uint256 claimed;
        for (uint256 round = 1; round <= 40; ++round) {
            pay(round * 37 + 1);
            claimed += payroll.claimSeats(all);
            Payroll.Ledger memory l = payroll.ledger();
            assertEq(l.seatClaimed, claimed);
            assertEq(l.toSeats - l.seatClaimed, payroll.seatCarry(), "only the carry is left unclaimed");
            assertLt(payroll.seatCarry(), 7);
        }
        assertBooksBalance();
    }
}
