// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQuestions} from "src/interfaces/IQuestions.sol";
import {Payroll} from "src/payroll/Payroll.sol";
import {JobsReport} from "src/payroll/JobsReport.sol";
import {LaunchStateSetup} from "../LaunchStateSetup.sol";
import {LaunchLifecycleHandler} from "./LaunchLifecycleHandler.sol";

/// @notice Cross-contract conservation, finality and report liveness with the exact launch feeds.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchLifecycleInvariantTest is LaunchStateSetup {
    LaunchLifecycleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LaunchLifecycleHandler(
            LaunchLifecycleHandler.Environment({
                token: token,
                intake: intake,
                questions: questions,
                report: report,
                payroll: payroll,
                seats: seats,
                wallet: wallet,
                escrow: address(escrow),
                writer: writer,
                signerKey: signerKey,
                feeds: feeds,
                actors: actors
            })
        );
        handler.pay(0, 100e18, false);
        handler.topUp();
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = handler.pay.selector;
        selectors[1] = handler.book.selector;
        selectors[2] = handler.tip.selector;
        selectors[3] = handler.topUp.selector;
        selectors[4] = handler.sponsor.selector;
        selectors[5] = handler.defund.selector;
        selectors[6] = handler.request.selector;
        selectors[7] = handler.answer.selector;
        selectors[8] = handler.rejectAnswer.selector;
        selectors[9] = handler.abandon.selector;
        selectors[10] = handler.collect.selector;
        selectors[11] = handler.advance.selector;
        selectors[12] = handler.changePrice.selector;
        selectors[13] = handler.moveSeat.selector;
        selectors[14] = handler.claim.selector;
        selectors[15] = handler.drip.selector;
        selectors[16] = handler.printReport.selector;
        selectors[17] = handler.crown.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_externalMoneyEqualsCustodyPlusVerifiedExits() public view {
        uint256 custody = token.balanceOf(address(payroll)) + token.balanceOf(address(questions));
        assertEq(handler.entered(), custody + handler.exited() + handler.intakePaid(), "money lost across contracts");
        assertEq(token.balanceOf(feePayee), handler.intakePaid());
        assertEq(token.balanceOf(address(simd)), STAKED + handler.dripped());
        for (uint256 i; i < 3; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]));
        }
        assertEq(token.balanceOf(address(wallet)), handler.expectedBalance(address(wallet)));
        assertEq(token.balanceOf(address(escrow)), 0, "observer forced payment into passive escrow");
        assertEq(token.allowance(address(payroll), address(questions)), 0);
        assertEq(token.allowance(address(questions), address(intake)), 0);

        Payroll.Ledger memory l = payroll.ledger();
        assertEq(l.feedsFunded, handler.payrollFunded());
        assertEq(l.dripped, handler.dripped());
        assertEq(l.received, l.toStakers + l.toSeats + l.toFeeds);
        (uint256 stakerOwed, uint256 seatsOwed, uint256 tipsOwed, uint256 feedsOwed, uint256 total) = payroll.owed();
        assertEq(total, stakerOwed + seatsOwed + tipsOwed + feedsOwed);
        assertEq(token.balanceOf(address(payroll)), total + payroll.unbooked());
        uint256 agentsOwed;
        uint256 seatPayments;
        for (uint256 i; i < 4; ++i) {
            assertEq(payroll.tipOwed(i), handler.unpaidTips(i));
            agentsOwed += handler.unpaidTips(i);
            seatPayments += payroll.seatPaid(i == 3 ? 1999 : i);
        }
        assertEq(tipsOwed, agentsOwed);
        assertEq(l.seatClaimed, seatPayments);
        assertEq(payroll.seatAccrued() * SEAT_COUNT + payroll.seatCarry(), l.toSeats + l.tipsToSeats);
    }

    function invariant_metersAndKeeperLiabilitiesRemainCovered() public view {
        uint256 metered;
        uint256 tips;
        for (uint256 i; i < 3; ++i) {
            (uint256 balance, uint256 shares) = questions.meterOf(feeds[i]);
            metered += balance;
            uint256 claims = questions.redeemable(feeds[i], address(payroll));
            uint256 ownedShares = questions.sharesOf(feeds[i], address(payroll));
            for (uint256 j; j < 3; ++j) {
                claims += questions.redeemable(feeds[i], actors[j]);
                ownedShares += questions.sharesOf(feeds[i], actors[j]);
            }
            assertLe(claims, balance);
            assertLe(ownedShares, shares);
            assertGe(shares, balance);
            (uint256 earned, uint256 pending) = questions.tipsOf(actors[i]);
            assertEq(earned, handler.earned(actors[i]));
            assertEq(pending, handler.pendingTips(actors[i]));
            tips += earned + pending;
        }
        assertEq(metered, questions.totalMetered());
        assertEq(tips, questions.totalTips());
        assertEq(token.balanceOf(address(questions)), metered + tips);
        handler.checkRounds();
    }

    function invariant_reportContainsOnlyAnsweredRoundsAndUniquePairs() public view {
        uint256 amount;
        uint256 count;
        uint256 previousTo;
        for (uint256 i; i < report.printCount(); ++i) {
            JobsReport.Print memory p = report.printAt(i);
            (IQuestions.RoundStatus status, uint256 value, uint64 from, uint64 to,) =
                questions.roundOf(feeds[0], p.payrollsRound);
            assertEq(uint256(status), uint256(IQuestions.RoundStatus.Answered));
            assertEq(p.amount, value);
            assertEq(p.fromBlock, from);
            assertEq(p.toBlock, to);
            if (i != 0) assertGt(p.fromBlock, previousTo);
            previousTo = p.toBlock;
            amount += p.amount;
        }
        previousTo = 0;
        for (uint256 i; i < report.countsRecorded(); ++i) {
            JobsReport.Count memory c = report.countAt(i);
            (IQuestions.RoundStatus status, uint256 value, uint64 from, uint64 to,) =
                questions.roundOf(feeds[1], c.hiresRound);
            assertEq(uint256(status), uint256(IQuestions.RoundStatus.Answered));
            assertEq(c.count, value);
            assertEq(c.fromBlock, from);
            assertEq(c.toBlock, to);
            if (i != 0) assertGt(c.fromBlock, previousTo);
            previousTo = c.toBlock;
            count += c.count;
            if (c.print != 0) {
                JobsReport.Print memory p = report.printAt(c.print - 1);
                assertEq(p.hiresRound, c.hiresRound, "a print reused another count");
                assertEq(p.count, c.count);
                uint256 overlapFrom = p.fromBlock > c.fromBlock ? p.fromBlock : c.fromBlock;
                uint256 overlapTo = p.toBlock < c.toBlock ? p.toBlock : c.toBlock;
                assertGe(overlapTo, overlapFrom);
                uint256 shared = overlapTo - overlapFrom + 1;
                assertGt(2 * shared, uint256(p.toBlock) - p.fromBlock + 1);
                assertGt(2 * shared, uint256(c.toBlock) - c.fromBlock + 1);
            }
        }
        assertEq(report.total(), amount);
        assertEq(report.totalCount(), count);
    }

    function afterInvariant() public {
        handler.finish();
        invariant_externalMoneyEqualsCustodyPlusVerifiedExits();
        invariant_metersAndKeeperLiabilitiesRemainCovered();
        invariant_reportContainsOnlyAnsweredRoundsAndUniquePairs();
    }

    /// @dev Exercise every handler deterministically so early returns cannot conceal a vacuous campaign.
    function test_lifecycleHandlerReachesSuccessFailureRecoveryAndEscrow() public {
        handler.pay(1, 10e18, true);
        handler.book();
        handler.tip(0, 9e18, 6);
        handler.sponsor(1, 2, 0, 1e18);
        handler.request(0, 0);
        for (uint8 fault; fault < 6; ++fault) {
            handler.rejectAnswer(0, 42, fault);
        }
        handler.answer(0, 42, true);
        handler.collect(0);
        handler.request(1, 1);
        handler.abandon(1, false);
        handler.abandon(1, true);
        handler.request(2, 2);
        handler.answer(2, 3, false);
        handler.crown(0, true);
        handler.crown(0, false);
        handler.crown(0, false);
        handler.moveSeat(0, 4); // Passive escrow refuses third-party payment.
        handler.claim(0, false);
        handler.moveSeat(0, 3); // Contract wallet refuses observers, but can initiate a claim.
        handler.claim(0, false);
        handler.claim(0, true);
        handler.moveSeat(1, 5); // Payroll can recycle its own seat's share.
        handler.claim(1, false);
        handler.book();
        handler.advance(4);
        handler.drip();
        handler.drip(); // The second attempt must hit the cooldown.
        handler.changePrice(0);
        handler.topUp();
        handler.request(1, 1); // An unsold action must not spend the meter.
        handler.changePrice(2);
        handler.topUp();
        handler.defund(2, 0, 0, true);
        handler.printReport();
        assertEq(handler.requests(), 3);
        assertEq(handler.failures(), 1);
        assertEq(handler.rejectedAnswers(), 6);
        assertEq(handler.recoveries(), 1);
        assertEq(report.crownCount(), 1);
        assertGt(token.balanceOf(address(wallet)), 0);
        assertGt(handler.dripped(), 0);
        afterInvariant();
    }
}
