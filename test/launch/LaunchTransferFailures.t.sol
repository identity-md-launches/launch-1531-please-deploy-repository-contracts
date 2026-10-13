// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Payroll} from "src/payroll/Payroll.sol";
import {Questions} from "src/questions/Questions.sol";
import {OracleAttestation} from "src/questions/OracleAttestation.sol";
import {LaunchStateSetup, LaunchFaultToken} from "./LaunchStateSetup.sol";

/// @notice A rejected transfer must restore liabilities as well as token balances, and permit retry.
/// forge-config: default.fuzz.runs = 512
contract LaunchTransferFailuresTest is LaunchStateSetup {
    function _failure(address from, address to, bool returnsFalse) internal {
        token.failTransfer(from, to, returnsFalse ? 2 : 1);
        if (returnsFalse) {
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        } else {
            vm.expectRevert(LaunchFaultToken.TransferRefused.selector);
        }
    }

    function _clearFailure() internal {
        token.failTransfer(address(0), address(0), 0);
    }

    function _payrollState() internal view returns (bytes32) {
        (uint64 end, uint64 cursor, uint64 last, uint64 period) = payroll.clock();
        return keccak256(
            abi.encode(
                payroll.ledger(),
                end,
                cursor,
                last,
                period,
                payroll.streamUnvested(),
                payroll.dripCap(),
                payroll.seatAccrued(),
                payroll.seatCarry(),
                payroll.feedBudgetOld(),
                payroll.feedBudgetDue(),
                payroll.seatPaid(0),
                payroll.seatPaid(1),
                payroll.seatPaid(2),
                payroll.tipOwed(0)
            )
        );
    }

    function _questionsState(uint256 index, address keeper) internal view returns (bytes32) {
        (uint256 balance, uint256 shares) = questions.meterOf(feeds[index]);
        (uint256 earned, uint256 pending) = questions.tipsOf(keeper);
        return keccak256(
            abi.encode(
                balance,
                shares,
                earned,
                pending,
                questions.totalMetered(),
                questions.totalTips(),
                questions.sharesOf(feeds[index], actors[0]),
                questions.sharesOf(feeds[index], actors[1])
            )
        );
    }

    function testFuzz_failedPayAndTipDoNotConsumeAllowanceOrBookRevenue(uint96 seed, bool returnsFalse) public {
        uint256 amount = bound(seed, 1, 100e18);
        vm.prank(actors[0]);
        token.approve(address(payroll), amount);
        bytes32 beforeState = _payrollState();
        uint256 beforeBalance = token.balanceOf(actors[0]);

        _failure(actors[0], address(payroll), returnsFalse);
        vm.prank(actors[0]);
        payroll.pay(amount, bytes32("failed"));
        assertEq(_payrollState(), beforeState);
        assertEq(token.balanceOf(actors[0]), beforeBalance);
        assertEq(token.balanceOf(address(payroll)), 0);
        assertEq(token.allowance(actors[0], address(payroll)), amount);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        _failure(actors[0], address(payroll), returnsFalse);
        vm.prank(actors[0]);
        payroll.tip(ids, amount);
        assertEq(_payrollState(), beforeState);
        assertEq(token.balanceOf(actors[0]), beforeBalance);
        assertEq(token.allowance(actors[0], address(payroll)), amount);

        _clearFailure();
        vm.prank(actors[0]);
        payroll.tip(ids, amount);
        assertEq(payroll.tipOwed(0), amount);
        assertEq(payroll.ledger().received, 0);
        assertEq(token.balanceOf(address(payroll)), amount);
    }

    function testFuzz_failedGiftFundingLeavesBeneficiaryAndPayerUntouched(uint96 seed, bool returnsFalse) public {
        uint256 amount = bound(seed, 1, 100e18);
        vm.prank(actors[0]);
        token.approve(address(questions), amount);
        bytes32 beforeState = _questionsState(0, actors[0]);
        _failure(actors[0], address(questions), returnsFalse);
        vm.prank(actors[0]);
        questions.fundFor(feeds[0], amount, actors[1]);
        assertEq(_questionsState(0, actors[0]), beforeState);
        assertEq(token.balanceOf(actors[0]), INITIAL);
        assertEq(token.balanceOf(address(questions)), 0);
        assertEq(token.allowance(actors[0], address(questions)), amount);

        _clearFailure();
        vm.prank(actors[0]);
        questions.fundFor(feeds[0], amount, actors[1]);
        assertEq(questions.redeemable(feeds[0], actors[1]), amount);
        assertEq(questions.sharesOf(feeds[0], actors[0]), 0);
    }

    function testFuzz_failedSeatBatchRestoresEarlierTransfersAndEveryClaim(bool returnsFalse) public {
        _pay(100e18);
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (0, 1, 0, 2);
        bytes32 beforeState = _payrollState();
        uint256 firstBefore = token.balanceOf(actors[0]);
        uint256 due = payroll.seatClaimable(0);
        assertGt(due, 0);
        // Owner 0's transfer succeeds before owner 1's transfer refuses the batch.
        _failure(address(payroll), actors[1], returnsFalse);
        payroll.claimSeats(ids);
        assertEq(_payrollState(), beforeState);
        assertEq(token.balanceOf(actors[0]), firstBefore);
        assertEq(token.balanceOf(actors[1]), INITIAL);
        assertEq(token.balanceOf(address(payroll)), 100e18);

        _clearFailure();
        assertEq(payroll.claimSeats(ids), 3 * due);
        assertEq(payroll.claimSeats(ids), 0, "retry or repeated id paid twice");
        assertEq(token.balanceOf(actors[0]), firstBefore + due);
        assertEq(token.balanceOf(actors[1]), INITIAL + due);
        assertEq(token.balanceOf(actors[2]), INITIAL + due);
    }

    function testFuzz_failedSingleSeatClaimStillFollowsTheNextOwner(bool returnsFalse) public {
        _pay(100e18);
        uint256 due = payroll.seatClaimable(0);
        bytes32 beforeState = _payrollState();
        _failure(address(payroll), actors[0], returnsFalse);
        payroll.claimSeat(0);
        assertEq(_payrollState(), beforeState);
        seats.setOwner(0, actors[1]);
        assertEq(payroll.claimSeat(0), due);
        assertEq(token.balanceOf(actors[1]), INITIAL + due);
        assertEq(payroll.claimSeat(0), 0);
    }

    function testFuzz_failedTipClaimRestoresAllAgeTranches(bool returnsFalse) public {
        _tip(0, 7e18);
        vm.warp(vm.getBlockTimestamp() + 181 days);
        _tip(0, 3e18);
        vm.warp(vm.getBlockTimestamp() + 181 days);
        _tip(0, 1);
        (uint256 unpaid, uint256 sweepable, uint256 next) = payroll.tipOf(0);
        assertGt(sweepable, 0);
        assertGt(unpaid, sweepable);
        bytes32 beforeState = _payrollState();
        _failure(address(payroll), actors[0], returnsFalse);
        payroll.claimTip(0);
        assertEq(_payrollState(), beforeState);
        (uint256 afterUnpaid, uint256 afterSweepable, uint256 afterNext) = payroll.tipOf(0);
        assertEq(afterUnpaid, unpaid);
        assertEq(afterSweepable, sweepable);
        assertEq(afterNext, next);
        _clearFailure();
        assertEq(payroll.claimTip(0), unpaid);
        assertEq(payroll.claimTip(0), 0);
    }

    function testFuzz_failedDripDoesNotAdvanceVestingOrStartCooldown(bool returnsFalse) public {
        _pay(100e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 beforeState = _payrollState();
        (,,,,, uint256 due) = payroll.stream();
        assertGt(due, 0);
        _failure(address(payroll), address(simd), returnsFalse);
        payroll.drip();
        assertEq(_payrollState(), beforeState);
        assertEq(token.balanceOf(address(simd)), STAKED);
        assertEq(token.balanceOf(address(payroll)), 100e18);
        _clearFailure();
        assertEq(payroll.drip(), due, "failed drip consumed the cooldown");
        assertEq(token.balanceOf(address(simd)), STAKED + due);
    }

    function testFuzz_failedDefundDuringPendingRoundPreservesShares(bool returnsFalse) public {
        vm.prank(actors[0]);
        questions.fund(feeds[0], 5e18);
        bytes32 requestId = _request(0, actors[2]);
        uint256 redeemable = questions.redeemable(feeds[0], actors[0]);
        bytes32 beforeState = _questionsState(0, actors[2]);
        uint256 balanceBefore = token.balanceOf(address(questions));
        _failure(address(questions), actors[0], returnsFalse);
        vm.prank(actors[0]);
        questions.defund(feeds[0], type(uint256).max);
        assertEq(_questionsState(0, actors[2]), beforeState);
        assertEq(token.balanceOf(address(questions)), balanceBefore);
        assertEq(questions.feedOfRequest(requestId), feeds[0]);

        _clearFailure();
        vm.prank(actors[0]);
        assertEq(questions.defund(feeds[0], type(uint256).max), redeemable);
        assertEq(questions.sharesOf(feeds[0], actors[0]), 0);
        assertEq(token.balanceOf(address(questions)), questions.totalTips());
        assertTrue(questions.feedState(feeds[0]).pending);
    }

    function testFuzz_failedKeeperCollectionPreservesEarnedAndPendingTips(bool returnsFalse) public {
        _pay(100e18);
        payroll.fundFeeds();
        bytes32 requestId = _request(0, actors[2]);
        _request(1, actors[2]);
        OracleAttestation.Attestation memory a = _attestation(0, abi.encode(uint256(12e18)));
        _deliver(requestId, a, _signature(a));
        (uint256 earned, uint256 pending) = questions.tipsOf(actors[2]);
        assertGt(earned, 0);
        assertGt(pending, 0);
        bytes32 beforeState = _questionsState(0, actors[2]);
        _failure(address(questions), actors[2], returnsFalse);
        vm.prank(actors[2]);
        questions.collectTips();
        assertEq(_questionsState(0, actors[2]), beforeState);
        assertEq(token.balanceOf(actors[2]), INITIAL);
        _clearFailure();
        vm.prank(actors[2]);
        assertEq(questions.collectTips(), earned);
        vm.prank(actors[2]);
        assertEq(questions.collectTips(), 0);
        assertEq(questions.totalTips(), pending);
        assertEq(token.balanceOf(actors[2]), INITIAL + earned);
    }

    function test_tokenWithoutReturnDataCanPayAndRedeem() public {
        token.failTransfer(actors[0], address(payroll), 3);
        _pay(100e18);
        assertEq(payroll.ledger().received, 100e18);
        token.failTransfer(address(payroll), actors[0], 3);
        uint256 due = payroll.seatClaimable(0);
        assertEq(payroll.claimSeat(0), due);
        token.failTransfer(actors[0], address(questions), 3);
        vm.prank(actors[0]);
        questions.fund(feeds[0], 1);
        token.failTransfer(address(questions), actors[0], 3);
        vm.prank(actors[0]);
        assertEq(questions.defund(feeds[0], 1), 1);
    }

    function testFuzz_payrollRejectsEveryNestedMoneyEntryPoint(uint8 seed) public {
        _pay(100e18);
        uint256[] memory empty = new uint256[](0);
        bytes[9] memory calls = [
            abi.encodeCall(payroll.pay, (0, bytes32(0))),
            abi.encodeCall(payroll.tip, (empty, 0)),
            abi.encodeCall(payroll.book, ()),
            abi.encodeCall(payroll.drip, ()),
            abi.encodeCall(payroll.claimSeat, (0)),
            abi.encodeCall(payroll.claimSeats, (empty)),
            abi.encodeCall(payroll.claimTip, (0)),
            abi.encodeCall(payroll.sweepTip, (0)),
            abi.encodeCall(payroll.fundFeeds, ())
        ];
        token.armCallback(address(payroll), calls[seed % calls.length]);
        uint256 due = payroll.seatClaimable(0);
        assertEq(payroll.claimSeat(0), due);
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(payroll.ledger().seatClaimed, due);
        assertEq(token.balanceOf(address(payroll)), 100e18 - due);
    }

    function testFuzz_questionsRejectsEveryNestedMoneyEntryPoint(uint8 seed) public {
        OracleAttestation.Attestation memory empty;
        bytes[8] memory calls = [
            abi.encodeCall(questions.fund, (feeds[0], 1)),
            abi.encodeCall(questions.fundFor, (feeds[0], 1, actors[1])),
            abi.encodeCall(questions.defund, (feeds[0], 1)),
            abi.encodeCall(questions.request, (feeds[0])),
            abi.encodeCall(questions.onOracleResult, (bytes32(0), empty, bytes(""))),
            abi.encodeCall(questions.submit, (feeds[0], empty, bytes(""))),
            abi.encodeCall(questions.abandon, (feeds[0])),
            abi.encodeCall(questions.collectTips, ())
        ];
        token.armCallback(address(questions), calls[seed % calls.length]);
        vm.prank(actors[0]);
        questions.fundFor(feeds[0], 1e18, actors[1]);
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(questions.redeemable(feeds[0], actors[1]), 1e18);
        assertEq(questions.sharesOf(feeds[0], actors[0]), 0);
        assertEq(questions.totalMetered(), 1e18);
        assertEq(token.balanceOf(address(questions)), 1e18);
    }
}
