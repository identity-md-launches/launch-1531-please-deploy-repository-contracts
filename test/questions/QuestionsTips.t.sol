// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQuestions} from "../../src/interfaces/IQuestions.sol";
import {OracleAttestation} from "../../src/questions/OracleAttestation.sol";
import {Questions} from "../../src/questions/Questions.sol";
import {QuestionsFixture} from "./QuestionsFixture.sol";

/// @notice The keeper tip from the moment a round is opened to the moment it is paid or given
/// back. The rule: asking earns nothing. `request` takes the tip off the meter and sets it aside;
/// an answer earns it for the keeper that opened the round, however it is delivered; a round closed without an answer gives it back to
/// the meter. Earned tips leave only through `collectTips`.
contract QuestionsTipsTest is QuestionsFixture {
    event TipsCollected(address indexed keeper, uint256 amount);

    bytes32 internal feedId;

    function setUp() public override {
        super.setUp();
        feedId = _createDefault();
        _fund(alice, feedId, 10e18);
    }

    function _tips(address who) internal view returns (uint256 earned, uint256 pending) {
        return q.tipsOf(who);
    }

    function _meter(bytes32 id) internal view returns (uint256 balance, uint256 totalShares) {
        return q.meterOf(id);
    }

    /// @dev Every IMD the contract holds is on a meter or is a keeper tip: nothing else.
    function _assertCovered() internal view {
        assertEq(imd.balanceOf(address(q)), q.totalMetered() + q.totalTips(), "balance != meters + tips");
    }

    /// @dev Moves to the first block at which the feed's cadence allows another request.
    function _rollToDue(bytes32 id) internal {
        uint256 due = q.feedState(id).nextRequestBlock;
        if (due > vm.getBlockNumber()) vm.roll(due);
    }

    function _assertTips(address who, uint256 earned, uint256 pending) internal view {
        (uint256 gotEarned, uint256 gotPending) = _tips(who);
        assertEq(gotEarned, earned, "earned");
        assertEq(gotPending, pending, "pending");
    }

    // ---- set aside ------------------------------------------------------------------------------

    /// @notice Opening a round moves the tip off the meter and into the contract's keeping. The
    /// keeper is not paid and has nothing to collect.
    function test_tip_isSetAsideWhenARoundOpens() public {
        uint256 keeperBefore = imd.balanceOf(keeper);
        _request(feedId);

        (uint256 balance,) = _meter(feedId);
        assertEq(balance, 10e18 - COST, "the meter is charged the price and the tip");
        assertEq(q.totalTips(), TIP);
        _assertTips(keeper, 0, TIP);
        assertEq(imd.balanceOf(keeper), keeperBefore);
        _assertCovered();

        vm.prank(keeper);
        assertEq(q.collectTips(), 0, "a tip that is only set aside was paid out");
        assertEq(imd.balanceOf(keeper), keeperBefore);
        _assertTips(keeper, 0, TIP);
    }

    // ---- earned by an answer --------------------------------------------------------------------

    /// @notice The Intake delivers the answer: the keeper that opened the round has earned the tip
    /// and takes it out when it likes.
    function test_tip_isEarnedWhenTheIntakeDeliversTheAnswer() public {
        uint256 keeperBefore = imd.balanceOf(keeper);
        _answer(feedId, abi.encode(uint256(42)));

        _assertTips(keeper, TIP, 0);
        assertEq(q.totalTips(), TIP, "an earned tip stays held until it is collected");
        assertEq(imd.balanceOf(keeper), keeperBefore);
        _assertCovered();

        vm.expectEmit(address(q));
        emit TipsCollected(keeper, TIP);
        vm.prank(keeper);
        assertEq(q.collectTips(), TIP);
        assertEq(imd.balanceOf(keeper), keeperBefore + TIP);
        _assertTips(keeper, 0, 0);
        assertEq(q.totalTips(), 0);
        _assertCovered();

        // Nothing is paid twice.
        vm.prank(keeper);
        assertEq(q.collectTips(), 0);
        assertEq(imd.balanceOf(keeper), keeperBefore + TIP);
    }

    /// @notice The keeper's own request was served but the callback did not run to the end. The
    /// keeper hands the answer in itself and is paid as usual.
    function test_tip_isEarnedByTheKeeperThatHandsItsOwnAnswerIn() public {
        bytes32 intakeId = _request(feedId);
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(7)));
        bytes memory signature = _sign(a);
        _completeWithMissedCallback(intakeId, a, signature);
        _assertTips(keeper, 0, TIP);

        vm.prank(keeper);
        q.submit(feedId, a, signature);
        _assertTips(keeper, TIP, 0);
        assertEq(q.totalTips(), TIP);
        _assertCovered();
    }

    /// @notice An observer can deliver the answer but cannot take the opener's reserved tip.
    function test_tip_staysWithTheOpenerWhenAnotherAccountSubmits() public {
        bytes32 intakeId = _request(feedId);
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(7)));
        bytes memory signature = _sign(a);
        _completeWithMissedCallback(intakeId, a, signature);

        vm.prank(bob);
        q.submit(feedId, a, signature);
        _assertTips(keeper, TIP, 0);
        _assertTips(bob, 0, 0);
        assertEq(q.totalTips(), TIP);
        _assertCovered();

        uint256 keeperBefore = imd.balanceOf(keeper);
        vm.prank(keeper);
        assertEq(q.collectTips(), TIP);
        assertEq(imd.balanceOf(keeper), keeperBefore + TIP);
        vm.prank(bob);
        assertEq(q.collectTips(), 0);
    }

    /// @notice The Intake's writer is late. The oracle's signed answer to the round's own request
    /// is public, and from thirty minutes after the request anyone may hand it in. The opener
    /// keeps the tip. One second sooner nobody can, and a delivery by the Intake
    /// in that time pays the keeper as usual.
    function test_tip_ofARoundWhoseCallbackIsLateStaysWithTheOpener() public {
        bytes32 intakeId = _request(feedId);
        uint256 askedAt = vm.getBlockTimestamp();
        // The oracle signs two minutes after the request.
        skip(2 minutes);
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(7)));
        bytes memory signature = _sign(a);

        // To the last second of the half hour the answer can only come through the Intake, and
        // then the tip is the keeper's.
        skip(submitAfterSilence - 2 minutes - 1);
        assertEq(vm.getBlockTimestamp(), askedAt + submitAfterSilence - 1);
        vm.expectRevert(abi.encodeWithSelector(Questions.SubmitTooEarly.selector, askedAt + submitAfterSilence));
        vm.prank(bob);
        q.submit(feedId, a, signature);
        uint256 snapshot = vm.snapshotState();
        assertTrue(_complete(intakeId, a, signature), "a delivery inside the half hour was refused");
        _assertTips(keeper, TIP, 0);
        _assertTips(bob, 0, 0);
        vm.revertToState(snapshot);

        // One second later the Intake has still not delivered. Somebody else hands the same
        // answer in; the keeper that opened the round still receives the tip.
        skip(1);
        _assertTips(keeper, 0, TIP);
        vm.prank(bob);
        q.submit(feedId, a, signature);
        _assertTips(bob, 0, 0);
        _assertTips(keeper, TIP, 0);
        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(round, 1);
        assertEq(value, 7);
        assertEq(q.totalTips(), TIP);
        _assertCovered();

        // The writer's call, when it comes, finds the round settled and changes nothing.
        assertFalse(_complete(intakeId, a, signature));
        _assertTips(bob, 0, 0);
        _assertTips(keeper, TIP, 0);
        assertEq(q.feedState(feedId).failStreak, 0);
    }

    // ---- given back by a failed round -----------------------------------------------------------

    /// @notice A round closed without an answer gives its tip back to the meter. The meter has
    /// lost the Intake price and nothing else; the keeper has nothing, now or later.
    function test_tip_goesBackToTheMeterWhenTheRoundFails() public {
        uint256 keeperBefore = imd.balanceOf(keeper);
        _request(feedId);
        (, uint256 sharesBefore) = _meter(feedId);

        skip(abandonAfterSilence);
        assertTrue(q.abandon(feedId));

        (uint256 balance, uint256 totalShares) = _meter(feedId);
        assertEq(balance, 10e18 - PRICE, "the meter lost more than the price");
        assertEq(totalShares, sharesBefore, "no share was minted or burned for the returned tip");
        assertEq(q.totalMetered(), 10e18 - PRICE);
        assertEq(q.totalTips(), 0);
        _assertTips(keeper, 0, 0);
        _assertCovered();
        vm.prank(keeper);
        assertEq(q.collectTips(), 0);
        assertEq(imd.balanceOf(keeper), keeperBefore);

        // The funder owns the returned tip like the rest of the meter.
        assertEq(q.redeemable(feedId, alice), 10e18 - PRICE);
        vm.prank(alice);
        assertEq(q.defund(feedId, type(uint256).max), 10e18 - PRICE);
        assertEq(imd.balanceOf(address(q)), 0);
    }

    /// @notice The same through the two-step close after the Intake refused the request.
    function test_tip_goesBackWhenARefusedRequestIsClosedInTwoSteps() public {
        bytes32 intakeId = _request(feedId);
        _completeWithoutAnswer(intakeId, 1);
        assertFalse(q.abandon(feedId), "the first call only starts the wait");
        _assertTips(keeper, 0, TIP);
        (uint256 balance,) = _meter(feedId);
        assertEq(balance, 10e18 - COST, "the tip went back before the round was closed");

        skip(abandonAfterCompleted);
        assertTrue(q.abandon(feedId));
        (balance,) = _meter(feedId);
        assertEq(balance, 10e18 - PRICE);
        _assertTips(keeper, 0, 0);
        _assertCovered();
    }

    /// @notice Failing rounds cost the keeper that opened them every tip. Five failures and one
    /// answer leave it with one tip, and the meter with six prices and one tip less.
    function test_tip_onlyAnsweredRoundsPay() public {
        for (uint256 i; i < 5; ++i) {
            _rollToDue(feedId);
            _request(feedId);
            skip(abandonAfterSilence);
            assertTrue(q.abandon(feedId));
        }
        _assertTips(keeper, 0, 0);
        _rollToDue(feedId);
        _answer(feedId, abi.encode(uint256(1)));

        _assertTips(keeper, TIP, 0);
        (uint256 balance,) = _meter(feedId);
        assertEq(balance, 10e18 - 6 * PRICE - TIP);
        assertEq(imd.balanceOf(PAY_TO), 6 * PRICE);
        _assertCovered();
    }

    // ---- several rounds, several feeds, several keepers ------------------------------------------

    /// @notice A keeper's tips from different feeds add up, each with its own outcome: one answered,
    /// one failed, one still pending. Collecting takes the earned part and leaves the pending part.
    function test_tip_eachRoundHasItsOwnOutcome() public {
        Questions.FeedParams memory p = _params();
        p.tip = 0.03e18;
        p.cadenceBlocks = 100;
        bytes32 second = _create(p);
        p.tip = 0.07e18;
        p.cadenceBlocks = 200;
        bytes32 third = _create(p);
        _fund(alice, second, 5e18);
        _fund(alice, third, 5e18);

        bytes32 firstId = _request(feedId);
        _request(second);
        _request(third);
        _assertTips(keeper, 0, uint256(TIP) + 0.03e18 + 0.07e18);
        assertEq(q.totalTips(), uint256(TIP) + 0.03e18 + 0.07e18);

        // The first is answered, the second fails, the third stays pending.
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(11)));
        assertTrue(_complete(firstId, a, _sign(a)));
        skip(abandonAfterSilence);
        assertTrue(q.abandon(second));
        _assertTips(keeper, TIP, 0.07e18);
        assertEq(q.totalTips(), uint256(TIP) + 0.07e18);
        (uint256 secondBalance,) = _meter(second);
        assertEq(secondBalance, 5e18 - PRICE);
        _assertCovered();

        uint256 keeperBefore = imd.balanceOf(keeper);
        vm.prank(keeper);
        assertEq(q.collectTips(), TIP);
        assertEq(imd.balanceOf(keeper), keeperBefore + TIP);
        _assertTips(keeper, 0, 0.07e18);
        assertEq(q.totalTips(), 0.07e18);
        _assertCovered();
    }

    /// @notice Two keepers: each is credited for the rounds it opened and no other.
    function test_tip_twoKeepersAreKeptApart() public {
        _answer(feedId, abi.encode(uint256(1))); // opened by `keeper`
        _rollToDue(feedId);
        q.newTransaction();
        intake.newTransaction();
        vm.prank(bob);
        bytes32 intakeId = q.request(feedId);
        _assertTips(keeper, TIP, 0);
        _assertTips(bob, 0, TIP);

        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(2)));
        assertTrue(_complete(intakeId, a, _sign(a)));
        _assertTips(keeper, TIP, 0);
        _assertTips(bob, TIP, 0);
        assertEq(q.totalTips(), 2 * uint256(TIP));

        vm.prank(bob);
        assertEq(q.collectTips(), TIP);
        _assertTips(keeper, TIP, 0);
        _assertCovered();
    }

    /// @notice A feed with no tip sets nothing aside and credits nobody.
    function test_tip_aFeedWithoutATipHoldsNothing() public {
        Questions.FeedParams memory p = _params();
        p.tip = 0;
        bytes32 free = _create(p);
        _fund(alice, free, 2e18);
        _answer(free, abi.encode(uint256(3)));
        assertEq(q.totalTips(), 0);
        _assertTips(keeper, 0, 0);
        _rollToDue(free);
        _request(free);
        skip(abandonAfterSilence);
        assertTrue(q.abandon(free));
        (uint256 balance,) = _meter(free);
        assertEq(balance, 2e18 - 2 * PRICE);
        assertEq(q.totalTips(), 0);
        _assertCovered();
    }

    // ---- the returned tip and the meter's shares --------------------------------------------------

    /// @notice A meter that has been spent from has more shares than wei, so the returned tip is
    /// simply shared by the funders in proportion: nobody's share of the meter changes.
    function test_returnedTip_isSharedByTheFundersInProportion() public {
        _fund(bob, feedId, 5e18);
        _answer(feedId, abi.encode(uint256(1))); // spends from the meter: a share is now under a wei
        _rollToDue(feedId);
        _request(feedId);
        uint256 aliceBefore = q.redeemable(feedId, alice);
        uint256 bobBefore = q.redeemable(feedId, bob);
        (uint256 balanceBefore, uint256 sharesBefore) = _meter(feedId);

        skip(abandonAfterSilence);
        assertTrue(q.abandon(feedId));

        (uint256 balance, uint256 totalShares) = _meter(feedId);
        assertEq(balance, balanceBefore + TIP);
        assertEq(totalShares, sharesBefore);
        assertGe(totalShares, balance, "a share is worth more than a wei");
        uint256 aliceGain = q.redeemable(feedId, alice) - aliceBefore;
        uint256 bobGain = q.redeemable(feedId, bob) - bobBefore;
        assertApproxEqAbs(aliceGain + bobGain, TIP, 2, "the funders together got the tip back");
        assertApproxEqAbs(aliceGain, 2 * bobGain, 2, "in proportion to their shares (10 to 5)");
    }

    /// @notice A limit, pinned here with its size (docs/THREATS.md, Q5). The returned tip is shared
    /// by whoever holds the meter's shares when the round is closed, so a funder that arrives while
    /// the round is pending, and leaves once it has failed, takes part of a tip the earlier funder
    /// paid for. It takes its proportion of the tip and never more than the tip; the earlier funder
    /// loses the price and at most the tip, which is what the round would have cost it had the
    /// round been answered.
    function test_returnedTip_aFunderThatArrivesWhileTheRoundIsPendingSharesIt() public {
        _request(feedId);
        uint256 aliceBefore = q.redeemable(feedId, alice);
        assertEq(aliceBefore, 10e18 - COST);

        // Ninety-nine times what the meter holds, put in after the tip was set aside.
        uint256 late = 99 * aliceBefore;
        _fund(bob, feedId, late);
        assertEq(q.redeemable(feedId, bob), late);

        skip(abandonAfterSilence);
        assertTrue(q.abandon(feedId));

        uint256 aliceGain = q.redeemable(feedId, alice) - aliceBefore;
        uint256 bobGain = q.redeemable(feedId, bob) - late;
        assertApproxEqAbs(aliceGain + bobGain, TIP, 2, "the tip did not come back in full");
        assertApproxEqAbs(bobGain, (uint256(TIP) * 99) / 100, 2, "in proportion to the shares held: 99 in 100");
        assertLe(bobGain, TIP, "more than the tip was taken");
        // The earlier funder is out the price and, at most, the tip: never more.
        assertGe(q.redeemable(feedId, alice), 10e18 - COST);
        _assertCovered();

        // Both can take out what the meter says is theirs.
        vm.prank(bob);
        assertEq(q.defund(feedId, type(uint256).max), late + bobGain);
        vm.prank(alice);
        assertEq(q.defund(feedId, type(uint256).max), aliceBefore + aliceGain);
    }

    /// @notice Every funder leaves while the round is pending, then the round fails. The returned
    /// tip has no owner. It must not become a windfall for whoever funds next, and it must not
    /// lift a share above one wei: it stays on the meter and pays for later requests.
    function test_returnedTip_withEveryFunderGone_belongsToNobody() public {
        _request(feedId);
        vm.prank(alice);
        q.defund(feedId, type(uint256).max);
        (uint256 balance, uint256 totalShares) = _meter(feedId);
        assertEq(balance, 0);
        assertEq(totalShares, 0);

        skip(abandonAfterSilence);
        assertTrue(q.abandon(feedId));
        (balance, totalShares) = _meter(feedId);
        assertEq(balance, TIP, "the tip is back on the meter");
        assertEq(totalShares, TIP, "counted by shares nobody holds, one per wei");
        assertEq(q.redeemable(feedId, alice), 0);
        _assertCovered();

        // The next funder gets one share per wei and can take out exactly what it put in.
        vm.prank(bob);
        uint256 minted = q.fund(feedId, 1e18);
        assertEq(minted, 1e18);
        assertEq(q.redeemable(feedId, bob), 1e18, "the next funder was handed the orphaned tip");
        (balance, totalShares) = _meter(feedId);
        assertEq(balance, 1e18 + TIP);
        assertGe(totalShares, balance);

        // A one-wei funder cannot be used to price later funders out either.
        vm.prank(alice);
        assertEq(q.fund(feedId, 1), 1);
        assertEq(q.redeemable(feedId, alice), 1);

        // The orphaned tip is spent like the rest of the meter.
        _rollToDue(feedId);
        _answer(feedId, abi.encode(uint256(5)));
        (balance,) = _meter(feedId);
        assertEq(balance, 1e18 + 1 + TIP - COST);
        _assertCovered();
    }

    /// @notice The meter is spent to exactly zero by the request and refilled by a new funder
    /// while the round is pending; the old shares are retired by that refill. When the round then
    /// fails, the new funder still holds exactly what it paid in.
    function test_returnedTip_afterTheMeterWasRefilledFromZero() public {
        Questions.FeedParams memory p = _params();
        p.cadenceBlocks = 300;
        bytes32 id = _create(p);
        _fund(alice, id, COST);
        _request(id);
        (uint256 balance,) = _meter(id);
        assertEq(balance, 0);

        _fund(bob, id, 3e18);
        assertEq(q.sharesOf(id, alice), 0, "shares of a meter spent to zero are retired by the refill");
        skip(abandonAfterSilence);
        assertTrue(q.abandon(id));

        uint256 totalShares;
        (balance, totalShares) = _meter(id);
        assertEq(balance, 3e18 + TIP);
        assertGe(totalShares, balance, "a share is worth more than a wei");
        assertEq(q.redeemable(id, bob), 3e18, "the refill gained or lost from a tip it never paid");
        assertEq(q.redeemable(id, alice), 0);
        _assertCovered();
    }

    /// @notice Most of the meter is taken out while the round is pending: the funder that stayed
    /// gets back at most one wei per share, never more.
    function test_returnedTip_neverLiftsAShareAboveOneWei() public {
        _fund(bob, feedId, 0.01e18);
        _request(feedId);
        vm.prank(alice);
        q.defund(feedId, type(uint256).max);
        uint256 bobShares = q.sharesOf(feedId, bob);

        skip(abandonAfterSilence);
        assertTrue(q.abandon(feedId));
        (uint256 balance, uint256 totalShares) = _meter(feedId);
        assertGe(totalShares, balance, "a share is worth more than a wei");
        assertLe(q.redeemable(feedId, bob), bobShares, "a share pays out more than one wei");
        assertLe(q.redeemable(feedId, bob), balance);
        _assertCovered();
    }

    /// @notice Whatever funders do around a failed round, the tip comes back to the meter in
    /// full, a share never rises above a wei, nobody can take out more than the meter holds, and
    /// a funder that arrives afterwards can take out what it put in, less a wei of rounding.
    function testFuzz_returnedTip_keepsEveryMeterRuleIntact(
        uint256 aliceIn,
        uint256 bobIn,
        uint256 aliceOut,
        uint256 bobOut,
        uint256 lateIn,
        bool spendFirst
    ) public {
        Questions.FeedParams memory p = _params();
        p.cadenceBlocks = 50;
        p.maxWindowBlocks = 500;
        bytes32 id = _create(p);
        aliceIn = bound(aliceIn, COST, 50e18);
        bobIn = bound(bobIn, 1, 50e18);
        _fund(alice, id, aliceIn);
        _fund(bob, id, bobIn);
        if (spendFirst && aliceIn + bobIn >= 2 * COST) {
            _answer(id, abi.encode(uint256(1)));
            _rollToDue(id);
        }
        _request(id);

        // Funders take out any part of what they hold while the round is pending.
        uint256 aliceShares = q.sharesOf(id, alice);
        aliceOut = bound(aliceOut, 1, aliceShares);
        vm.prank(alice);
        q.defund(id, aliceOut);
        uint256 bobShares = q.sharesOf(id, bob);
        if (bobShares != 0 && bobOut % 3 != 0) {
            bobOut = bound(bobOut, 1, bobShares);
            vm.prank(bob);
            q.defund(id, bobOut);
        }
        (uint256 balanceBefore,) = q.meterOf(id);

        skip(abandonAfterSilence);
        assertTrue(q.abandon(id));
        (uint256 balance, uint256 totalShares) = q.meterOf(id);
        assertEq(balance, balanceBefore + TIP, "the tip did not come back in full");
        assertGe(totalShares, balance, "a share is worth more than a wei");
        assertLe(q.redeemable(id, alice) + q.redeemable(id, bob), balance);
        assertLe(q.sharesOf(id, alice) + q.sharesOf(id, bob), totalShares);
        assertEq(imd.balanceOf(address(q)), q.totalMetered() + q.totalTips());

        // A funder that arrives after the tip came back gets its money's worth.
        address late = makeAddr("late funder");
        lateIn = bound(lateIn, 1e6, 50e18);
        imd.mint(late, lateIn);
        vm.startPrank(late);
        imd.approve(address(q), lateIn);
        q.fund(id, lateIn);
        vm.stopPrank();
        assertGe(q.redeemable(id, late) + 1, lateIn, "a later funder was rounded out of its money");
        assertLe(q.redeemable(id, late), lateIn, "a later funder was handed somebody else's IMD");
    }

    // ---- what a reader sees -----------------------------------------------------------------------

    /// @notice The status of the round and the tip book move together.
    function test_tip_followsTheRoundsStatus() public {
        bytes32 intakeId = _request(feedId);
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Pending));
        _assertTips(keeper, 0, TIP);

        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(9)));
        // A callback that reverts (here: a wrong signature) earns nothing and leaves the tip aside.
        bytes memory wrong = _signWith(uint256(keccak256("not the oracle")), a);
        vm.prank(WRITER);
        intake.complete(intakeId, 0, keccak256("result"), "uri", abi.encode(intakeId, a, wrong));
        assertFalse(intake.lastDelivered());
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Pending));
        _assertTips(keeper, 0, TIP);

        bytes memory signature = _sign(a);
        vm.prank(keeper);
        q.submit(feedId, a, signature);
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Answered));
        _assertTips(keeper, TIP, 0);
    }
}
