// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQuestions} from "../../src/interfaces/IQuestions.sol";
import {OracleAttestation} from "../../src/questions/OracleAttestation.sol";
import {Questions} from "../../src/questions/Questions.sol";
import {QuestionsFixture} from "./QuestionsFixture.sol";
import {OddIntake} from "./mocks/Oddities.sol";
import {QuestionsHarness} from "./mocks/QuestionsHarness.sol";

/// @notice `abandon`: the way out of a round that will get no answer. Questions asks with plain
/// `request`, which names no failure function, so the Intake (either version) completes a refused
/// or unanswered request with no call and it is only ever noticed here.
contract QuestionsAbandonTest is QuestionsFixture {
    event RoundFailed(
        bytes32 indexed feedId, uint64 indexed round, bytes32 intakeRequestId, bool completed, uint8 failStreak
    );
    event CompletionSeen(bytes32 indexed feedId, uint64 indexed round, bytes32 intakeRequestId, uint64 closableAt);

    bytes32 internal feedId;

    function setUp() public override {
        super.setUp();
        feedId = _createDefault();
        _fund(alice, feedId, 100e18);
    }

    function _expectTooEarly(uint256 notBefore) internal {
        vm.expectRevert(abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, notBefore));
    }

    /// @dev The view and the transaction must agree on what `abandon` would do now.
    function _assertStep(bytes32 id, Questions.AbandonStep step, uint256 closableAt) internal view {
        (Questions.AbandonStep got, uint256 at) = q.canAbandon(id);
        assertEq(uint8(got), uint8(step), "canAbandon names another step");
        assertEq(at, closableAt, "canAbandon names another time");
    }

    /// @notice The three waits are fixed at launch, and these are their values. The other tests
    /// name the rule they wait out, through the figures the fixture reads from the contract.
    function test_waits_areTheValuesFixedAtLaunch() public view {
        assertEq(q.SUBMIT_AFTER_SILENCE(), 30 minutes);
        assertEq(q.ABANDON_AFTER_COMPLETED(), 30 minutes);
        assertEq(q.ABANDON_AFTER_SILENCE(), 12 hours);
        assertEq(submitAfterSilence, q.SUBMIT_AFTER_SILENCE());
        assertEq(abandonAfterCompleted, q.ABANDON_AFTER_COMPLETED());
        assertEq(abandonAfterSilence, 36 hours + 5 minutes + 1);
        // `submit` opens long before a round can be closed.
        assertLt(submitAfterSilence, abandonAfterSilence);
    }

    /// @notice The Intake never completed the request: the round can be closed after the full silence deadline,
    /// and not one second sooner.
    function test_abandon_afterTheFullSilenceDeadline() public {
        bytes32 intakeId = _request(feedId);
        uint256 askedAt = vm.getBlockTimestamp();
        _assertStep(feedId, Questions.AbandonStep.Wait, askedAt + abandonAfterSilence);

        // Half way through nothing can be closed.
        skip(abandonAfterSilence / 2);
        _assertStep(feedId, Questions.AbandonStep.Wait, askedAt + abandonAfterSilence);
        _expectTooEarly(askedAt + abandonAfterSilence);
        q.abandon(feedId);

        // Nor one second before the end.
        skip(abandonAfterSilence - abandonAfterSilence / 2 - 1);
        assertEq(vm.getBlockTimestamp(), askedAt + abandonAfterSilence - 1);
        _assertStep(feedId, Questions.AbandonStep.Wait, askedAt + abandonAfterSilence);
        _expectTooEarly(askedAt + abandonAfterSilence);
        q.abandon(feedId);
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Pending));

        skip(1);
        assertEq(vm.getBlockTimestamp(), askedAt + abandonAfterSilence);
        _assertStep(feedId, Questions.AbandonStep.Close, askedAt + abandonAfterSilence);
        vm.expectEmit(address(q));
        emit RoundFailed(feedId, 1, intakeId, false, 1);
        vm.prank(bob);
        assertTrue(q.abandon(feedId));
        _assertStep(feedId, Questions.AbandonStep.Wait, 0);

        (IQuestions.RoundStatus status, uint256 value,,, uint64 updatedAt) = q.roundOf(feedId, 1);
        assertEq(uint8(status), uint8(IQuestions.RoundStatus.Failed));
        assertEq(value, 0);
        assertEq(updatedAt, vm.getBlockTimestamp());
        Questions.FeedView memory v = q.feedState(feedId);
        assertFalse(v.pending);
        assertEq(v.pendingRequestId, bytes32(0));
        assertEq(v.failStreak, 1);
        assertEq(v.latestRound, 0);
        assertEq(v.rounds, 1);
        assertEq(q.feedOfRequest(intakeId), bytes32(0));
        (,,, uint64 latestRound,) = q.latest(feedId);
        assertEq(latestRound, 0, "a failed round is not an answer");
        // The price was spent and is not coming back. The tip that was set aside for the keeper
        // is back on the meter: nobody is paid for a round that got no answer.
        (uint256 balance,) = q.meterOf(feedId);
        assertEq(balance, 100e18 - PRICE);
        (uint256 earned, uint256 pending) = q.tipsOf(keeper);
        assertEq(earned + pending, 0);
        assertEq(q.totalTips(), 0);
    }

    /// @notice The Intake completed the request as refused (status 1) or unanswered (status 2): no
    /// callback ever comes. The first `abandon` records that the request is completed and starts
    /// thirty minutes; the second, after them, closes the round.
    function test_abandon_thirtyMinutesAfterCompletionIsSeen() public {
        for (uint8 status = 1; status <= 2; ++status) {
            bytes32 intakeId = _request(feedId);
            uint256 askedAt = vm.getBlockTimestamp();
            skip(4 minutes);
            _assertStep(feedId, Questions.AbandonStep.Wait, askedAt + abandonAfterSilence);
            _completeWithoutAnswer(intakeId, status);

            // Nobody has told the contract yet. Whenever somebody does, the wait starts there.
            skip(3 minutes);
            uint256 seenAt = vm.getBlockTimestamp();
            _assertStep(feedId, Questions.AbandonStep.StartWait, seenAt + abandonAfterCompleted);
            vm.expectEmit(address(q));
            emit CompletionSeen(feedId, status, intakeId, uint64(seenAt + abandonAfterCompleted));
            vm.prank(bob);
            assertFalse(q.abandon(feedId), "the first call closed the round");
            assertEq(uint8(_status(feedId, status)), uint8(IQuestions.RoundStatus.Pending));
            assertTrue(q.feedState(feedId).pending);
            assertEq(q.feedOfRequest(intakeId), feedId);

            // A second call inside the wait does not start it again and does not close the round.
            skip(abandonAfterCompleted - 1);
            _assertStep(feedId, Questions.AbandonStep.Wait, seenAt + abandonAfterCompleted);
            _expectTooEarly(seenAt + abandonAfterCompleted);
            q.abandon(feedId);

            skip(1);
            _assertStep(feedId, Questions.AbandonStep.Close, seenAt + abandonAfterCompleted);
            vm.expectEmit(address(q));
            emit RoundFailed(feedId, status, intakeId, true, status);
            assertTrue(q.abandon(feedId));
            assertEq(uint8(_status(feedId, status)), uint8(IQuestions.RoundStatus.Failed));

            vm.roll(vm.getBlockNumber() + (uint256(CADENCE) << status));
        }
    }

    /// @notice An answer whose callback failed can be submitted during the thirty minutes; once
    /// they have passed with nothing stored, the round can be closed.
    function test_abandon_afterACallbackThatFailed() public {
        bytes32 intakeId = _request(feedId);
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(1)));
        a.agreed = 1;
        assertFalse(_complete(intakeId, a, _sign(a)), "an answer below the quorum was accepted");

        uint256 seenAt = vm.getBlockTimestamp();
        assertFalse(q.abandon(feedId));
        skip(abandonAfterCompleted - 1 minutes);
        _expectTooEarly(seenAt + abandonAfterCompleted);
        q.abandon(feedId);
        skip(1 minutes);
        assertTrue(q.abandon(feedId));
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Failed));
        assertFalse(q.consumed(a.requestId));
    }

    /// @notice The oracle often takes longer than half an hour. An answer that arrives late and
    /// misses its callback still has thirty minutes to be handed in: nobody can close the round in
    /// the block the answer arrived, because the wait is counted from when the completion is first
    /// seen here, not from the request.
    function test_abandon_aLateAnswerThatMissedItsCallbackCanStillBeSubmitted() public {
        bytes32 intakeId = _request(feedId);
        skip(40 minutes);
        vm.roll(vm.getBlockNumber() + 200);
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(321)));
        bytes memory signature = _sign(a);
        _completeWithMissedCallback(intakeId, a, signature);

        // In the same block somebody tries to close the round. All that does is start the wait.
        vm.prank(bob);
        assertFalse(q.abandon(feedId));
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Pending));
        skip(abandonAfterCompleted - 1);
        _expectTooEarly(vm.getBlockTimestamp() + 1);
        vm.prank(bob);
        q.abandon(feedId);

        vm.prank(alice);
        q.submit(feedId, a, signature);
        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(round, 1);
        assertEq(value, 321);
        assertEq(q.feedState(feedId).failStreak, 0);

        // The round is answered, and no later call can turn it into a failed one.
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(Questions.NoPendingRound.selector, feedId));
        q.abandon(feedId);
    }

    /// @notice Seeing the completion never makes a round wait longer than the full silence deadline from its
    /// request, and after the full silence deadline one call is enough whether or not anything was recorded.
    function test_abandon_theFullSilenceDeadlineIsAlwaysEnough() public {
        bytes32 intakeId = _request(feedId);
        uint256 askedAt = vm.getBlockTimestamp();
        skip(abandonAfterSilence - 10 minutes);
        _completeWithoutAnswer(intakeId, 1);

        // Seen ten minutes before the the full silence deadline are up: closable at the full silence deadline, not thirty
        // minutes on.
        assertLt(10 minutes, abandonAfterCompleted);
        _assertStep(feedId, Questions.AbandonStep.StartWait, askedAt + abandonAfterSilence);
        vm.expectEmit(address(q));
        emit CompletionSeen(feedId, 1, intakeId, uint64(askedAt + abandonAfterSilence));
        assertFalse(q.abandon(feedId));
        skip(10 minutes - 1);
        _expectTooEarly(askedAt + abandonAfterSilence);
        q.abandon(feedId);
        skip(1);
        assertTrue(q.abandon(feedId));

        // A completed request nobody looked at for the full silence deadline is closed by a single call, and
        // one second sooner the same call would only have started the thirty minutes.
        vm.roll(vm.getBlockNumber() + 2 * uint256(CADENCE));
        intakeId = _request(feedId);
        askedAt = vm.getBlockTimestamp();
        _completeWithoutAnswer(intakeId, 2);
        skip(abandonAfterSilence - 1);
        _assertStep(feedId, Questions.AbandonStep.StartWait, askedAt + abandonAfterSilence);
        skip(1);
        _assertStep(feedId, Questions.AbandonStep.Close, askedAt + abandonAfterSilence);
        vm.expectEmit(address(q));
        emit RoundFailed(feedId, 2, intakeId, true, 2);
        assertTrue(q.abandon(feedId));
    }

    /// @notice What was seen for one round says nothing about the next: each round's wait starts
    /// when its own completion is seen.
    function test_abandon_theWaitIsNotCarriedIntoTheNextRound() public {
        bytes32 intakeId = _request(feedId);
        _completeWithoutAnswer(intakeId, 1);
        assertFalse(q.abandon(feedId));
        skip(abandonAfterCompleted);
        assertTrue(q.abandon(feedId));

        vm.roll(vm.getBlockNumber() + 2 * uint256(CADENCE));
        intakeId = _request(feedId);
        uint256 askedAt = vm.getBlockTimestamp();
        _assertStep(feedId, Questions.AbandonStep.Wait, askedAt + abandonAfterSilence);
        // Some time later, well inside the the full silence deadline.
        skip(2 hours);
        _completeWithoutAnswer(intakeId, 1);
        _assertStep(feedId, Questions.AbandonStep.StartWait, vm.getBlockTimestamp() + abandonAfterCompleted);
        assertFalse(q.abandon(feedId), "the earlier round's wait closed this one at once");

        // An answered round clears it as well.
        skip(abandonAfterCompleted);
        assertTrue(q.abandon(feedId));
        vm.roll(vm.getBlockNumber() + 4 * uint256(CADENCE));
        intakeId = _request(feedId);
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(5)));
        bytes memory signature = _sign(a);
        _completeWithMissedCallback(intakeId, a, signature);
        assertFalse(q.abandon(feedId));
        q.submit(feedId, a, signature);
        vm.roll(vm.getBlockNumber() + CADENCE);
        intakeId = _request(feedId);
        _completeWithoutAnswer(intakeId, 2);
        assertFalse(q.abandon(feedId), "the answered round's wait closed this one at once");
    }

    function test_abandon_withNothingPending_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Questions.NoPendingRound.selector, feedId));
        q.abandon(feedId);

        _answer(feedId, abi.encode(uint256(1)));
        skip(abandonAfterSilence + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(Questions.NoPendingRound.selector, feedId));
        q.abandon(feedId);

        vm.roll(vm.getBlockNumber() + CADENCE);
        _request(feedId);
        skip(abandonAfterSilence);
        q.abandon(feedId);
        vm.expectRevert(abi.encodeWithSelector(Questions.NoPendingRound.selector, feedId));
        q.abandon(feedId);
    }

    /// @notice An answered round stays answered: nobody can turn it into a failed one later.
    function test_abandon_cannotUndoAnAnswer() public {
        _answer(feedId, abi.encode(uint256(55)));
        skip(30 days);
        vm.expectRevert(abi.encodeWithSelector(Questions.NoPendingRound.selector, feedId));
        q.abandon(feedId);
        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(value, 55);
        assertEq(round, 1);
    }

    /// @notice After a failure the feed asks again, later, and an answer heals it.
    function test_abandon_thenTheFeedAsksAgain() public {
        _request(feedId);
        skip(abandonAfterSilence);
        q.abandon(feedId);
        assertEq(q.feedState(feedId).nextRequestBlock, START_BLOCK + 2 * uint256(CADENCE));

        vm.roll(START_BLOCK + 2 * uint256(CADENCE));
        _answer(feedId, abi.encode(uint256(9)));
        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(value, 9);
        assertEq(round, 2);
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Failed));
        assertEq(uint8(_status(feedId, 2)), uint8(IQuestions.RoundStatus.Answered));
        assertEq(q.feedState(feedId).failStreak, 0);
    }

    /// @notice An Intake whose `requests` getter reverts, mumbles, lies with a value that is not a
    /// bool, or burns its gas is read as "not completed": the twelve-hour rule still closes the
    /// round, and the call cannot be made to run out of gas.
    function test_abandon_doesNotDependOnTheIntakeBehaving() public {
        OddIntake odd = new OddIntake();
        QuestionsHarness oddQ = new QuestionsHarness(address(odd), address(imd), oracle);
        Questions.FeedParams memory p = _params();
        p.cadenceBlocks = 1;
        p.maxWindowBlocks = 100;
        bytes32 id = oddQ.createFeed(p, _prefix("uint256"), _tail(7, 5, 86_400));
        vm.startPrank(alice);
        imd.approve(address(oddQ), type(uint256).max);
        oddQ.fund(id, 50e18);
        vm.stopPrank();

        OddIntake.Read[4] memory modes =
            [OddIntake.Read.Revert, OddIntake.Read.ShortReturn, OddIntake.Read.Garbage, OddIntake.Read.BurnGas];
        for (uint256 i; i < modes.length; ++i) {
            odd.setRequestsMode(OddIntake.Read.Normal);
            vm.roll(vm.getBlockNumber() + 64);
            oddQ.newTransaction();
            oddQ.request(id);
            uint256 askedAt = vm.getBlockTimestamp();
            odd.setCompleted(true);
            odd.setRequestsMode(modes[i]);

            // "Completed" cannot be read, so the thirty-minute rule does not apply and nothing is
            // recorded.
            skip(abandonAfterCompleted + 1 minutes);
            (Questions.AbandonStep step, uint256 closableAt) = oddQ.canAbandon(id);
            assertEq(uint8(step), uint8(Questions.AbandonStep.Wait));
            assertEq(closableAt, askedAt + abandonAfterSilence);
            _expectTooEarly(askedAt + abandonAfterSilence);
            oddQ.abandon(id);

            // One second before the the full silence deadline are up it is still too early; at the full silence deadline
            // one call closes the round.
            skip(abandonAfterSilence - abandonAfterCompleted - 1 minutes - 1);
            _expectTooEarly(askedAt + abandonAfterSilence);
            oddQ.abandon(id);
            skip(1);
            uint256 before = gasleft();
            oddQ.abandon(id);
            assertLt(before - gasleft(), 200_000, "abandon was made to burn gas");
            (IQuestions.RoundStatus status,,,,) = oddQ.roundOf(id, uint64(i + 1));
            assertEq(uint8(status), uint8(IQuestions.RoundStatus.Failed));
            odd.setCompleted(false);
        }

        // With a getter that answers, the thirty-minute rule works on the same contract.
        odd.setRequestsMode(OddIntake.Read.Normal);
        vm.roll(vm.getBlockNumber() + 64);
        oddQ.newTransaction();
        oddQ.request(id);
        uint256 lastAskedAt = vm.getBlockTimestamp();
        odd.setCompleted(true);
        skip(10 minutes);
        assertFalse(oddQ.abandon(id));

        // An Intake that takes its word back is believed: the recorded completion counts only
        // while the Intake still reports the request completed.
        odd.setCompleted(false);
        skip(abandonAfterCompleted);
        _expectTooEarly(lastAskedAt + abandonAfterSilence);
        oddQ.abandon(id);
        odd.setCompleted(true);
        assertTrue(oddQ.abandon(id));
    }

    /// @notice The streak of failures stops counting at 255 and the wait stays at 32 cadences.
    function test_abandon_failStreakSaturates() public {
        Questions.FeedParams memory p = _params();
        p.cadenceBlocks = 1;
        p.maxWindowBlocks = 10;
        p.tip = 0;
        bytes32 id = _create(p);
        _fund(alice, id, 200e18);
        for (uint256 i; i < 260; ++i) {
            vm.roll(vm.getBlockNumber() + 32);
            _request(id);
            skip(abandonAfterSilence);
            q.abandon(id);
        }
        Questions.FeedView memory v = q.feedState(id);
        assertEq(v.failStreak, 255);
        assertEq(v.rounds, 260);
        assertEq(v.nextRequestBlock, v.lastRequestBlock + 32);
        // Funders are not trapped by a feed that never answers.
        vm.prank(alice);
        assertEq(q.defund(id, type(uint256).max), 200e18 - 260 * PRICE);
    }
}
