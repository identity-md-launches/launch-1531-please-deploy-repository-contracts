// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IQuestions} from "../../src/interfaces/IQuestions.sol";
import {OracleAttestation} from "../../src/questions/OracleAttestation.sol";
import {Questions} from "../../src/questions/Questions.sol";
import {QuestionsFixture} from "./QuestionsFixture.sol";
import {BundledAsker, DoubleAsker, GateTarget, GreedyIMD, OddIntake} from "./mocks/Oddities.sol";
import {QuestionsHarness} from "./mocks/QuestionsHarness.sol";

/// @notice `request`: who may ask, when, what is sent, what is paid, and everything that blocks it.
contract QuestionsRequestTest is QuestionsFixture {
    event RoundOpened(
        bytes32 indexed feedId,
        uint64 indexed round,
        bytes32 indexed intakeRequestId,
        uint64 fromBlock,
        uint64 toBlock,
        bytes32 questionHash,
        bytes32 blockHash,
        uint256 price,
        uint256 tip,
        address keeper
    );

    bytes32 internal feedId;

    function setUp() public override {
        super.setUp();
        feedId = _createDefault();
    }

    function _expectBlocked(Questions.Blocker why) internal {
        vm.expectRevert(_blocked(why));
    }

    /// @dev The view and the transaction must give the same reason.
    function _assertBlocked(bytes32 id, Questions.Blocker why) internal {
        q.newTransaction();
        (bool ok, Questions.Blocker got,,,) = q.canRequest(id);
        assertFalse(ok);
        assertEq(uint8(got), uint8(why), "canRequest names another reason");
        assertEq(uint8(q.feedState(id).blocker), uint8(why));
        _expectBlocked(why);
        vm.prank(keeper);
        q.request(id);
    }

    function _assertOpen(bytes32 id) internal {
        q.newTransaction();
        (bool ok, Questions.Blocker got,,,) = q.canRequest(id);
        assertTrue(ok);
        assertEq(uint8(got), uint8(Questions.Blocker.None));
    }

    function _window(bytes32 id, uint64 round) internal view returns (uint64 fromBlock, uint64 toBlock) {
        (,, fromBlock, toBlock,) = q.roundOf(id, round);
    }

    // ---- what a request does --------------------------------------------------------------------

    function test_request_buysOneAnswerFromTheMeter() public {
        _fund(alice, feedId, 2e18);
        uint64 toBlock = uint64(vm.getBlockNumber() - LAG);
        uint64 fromBlock = toBlock - CADENCE + 1;
        bytes memory body = bytes.concat(
            _prefix("uint256"),
            bytes(vm.toString(fromBlock)),
            ',"toBlock":',
            bytes(vm.toString(toBlock)),
            "}",
            _tail(7, 5, 86_400)
        );
        bytes32 questionHash = keccak256(
            bytes.concat(
                _prefix("uint256"), bytes(vm.toString(fromBlock)), ',"toBlock":', bytes(vm.toString(toBlock)), "}}"
            )
        );
        bytes32 expectedId = keccak256(abi.encode(vm.getChainId(), address(intake), uint256(1)));

        uint256 keeperBefore = imd.balanceOf(keeper);
        q.newTransaction();
        vm.expectEmit(address(q));
        emit RoundOpened(
            feedId, 1, expectedId, fromBlock, toBlock, questionHash, _blockhash(toBlock), PRICE, TIP, keeper
        );
        vm.prank(keeper);
        bytes32 intakeId = q.request(feedId);

        // The Intake got the feed's action, the body built on chain, exactly the price, and this
        // contract's callback.
        assertEq(intakeId, expectedId);
        assertEq(intake.lastBody(), body);
        assertEq(intake.lastAction(), ACTION);
        assertEq(intake.lastAmount(), PRICE);
        (address payer, address target, bytes4 selector, bool completed) = intake.requests(intakeId);
        assertEq(payer, address(q));
        assertEq(target, address(q));
        assertEq(selector, q.onOracleResult.selector);
        assertEq(selector, bytes4(0x510379c7), "the selector the protocol's documentation gives");
        assertFalse(completed);

        // Money: the price to the Intake's payee and the tip set aside for the keeper, both off the
        // meter, and no allowance left behind. Asking pays the keeper nothing: the tip stays in the
        // contract until the round has an outcome.
        assertEq(imd.balanceOf(PAY_TO), PRICE);
        assertEq(imd.balanceOf(keeper), keeperBefore, "the keeper was paid for asking");
        (uint256 balance,) = q.meterOf(feedId);
        assertEq(balance, 2e18 - COST);
        assertEq(q.totalMetered(), 2e18 - COST);
        assertEq(q.totalTips(), TIP);
        (uint256 earned, uint256 pending) = q.tipsOf(keeper);
        assertEq(earned, 0);
        assertEq(pending, TIP);
        assertEq(imd.balanceOf(address(q)), 2e18 - PRICE);
        assertEq(imd.balanceOf(address(q)), q.totalMetered() + q.totalTips());
        assertEq(imd.allowance(address(q), address(intake)), 0);

        // The round, as stored.
        assertEq(q.roundCount(feedId), 1);
        (IQuestions.RoundStatus status, uint256 value, uint64 gotFrom, uint64 gotTo, uint64 updatedAt) =
            q.roundOf(feedId, 1);
        assertEq(uint8(status), uint8(IQuestions.RoundStatus.Pending));
        assertEq(value, 0);
        assertEq(gotFrom, fromBlock);
        assertEq(gotTo, toBlock);
        assertEq(updatedAt, 0);
        (bytes32 storedId, bytes32 storedHash, bytes32 storedBlockHash, uint64 requestedAt) = q.roundRequest(feedId, 1);
        assertEq(storedId, intakeId);
        assertEq(storedHash, questionHash);
        assertEq(storedBlockHash, _blockhash(toBlock));
        assertTrue(storedBlockHash != bytes32(0));
        assertEq(requestedAt, vm.getBlockTimestamp());
        assertEq(q.feedOfRequest(intakeId), feedId);
        Questions.FeedView memory v = q.feedState(feedId);
        assertTrue(v.pending);
        assertEq(v.pendingRequestId, intakeId);
        assertEq(v.lastRequestBlock, vm.getBlockNumber());
        assertEq(v.nextRequestBlock, vm.getBlockNumber() + CADENCE);

        // No answer yet: `latest` still reads empty.
        (,,, uint64 latestRound,) = q.latest(feedId);
        assertEq(latestRound, 0);
    }

    /// @notice Anyone may ask. The tip is not paid for asking: it is the caller's once the round
    /// is answered, and then only when the caller takes it out.
    function test_request_anyoneMayCall_andEarnsTheTipWhenTheRoundIsAnswered() public {
        _fund(alice, feedId, 2e18);
        address stranger = makeAddr("stranger");
        q.newTransaction();
        intake.newTransaction();
        vm.prank(stranger);
        bytes32 intakeId = q.request(feedId);
        assertEq(imd.balanceOf(stranger), 0);
        vm.prank(stranger);
        assertEq(q.collectTips(), 0, "a tip was collected before the round had an answer");

        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(5)));
        assertTrue(_complete(intakeId, a, _sign(a)));
        (uint256 earned, uint256 pending) = q.tipsOf(stranger);
        assertEq(earned, TIP);
        assertEq(pending, 0);
        assertEq(imd.balanceOf(stranger), 0, "earned tips wait to be collected");
        vm.prank(stranger);
        assertEq(q.collectTips(), TIP);
        assertEq(imd.balanceOf(stranger), TIP);
        assertEq(q.totalTips(), 0);
        assertEq(imd.balanceOf(address(q)), q.totalMetered());
    }

    function test_request_withNoTip_paysOnlyTheIntake() public {
        Questions.FeedParams memory p = _params();
        p.tip = 0;
        bytes32 id = _create(p);
        _fund(alice, id, PRICE);
        uint256 keeperBefore = imd.balanceOf(keeper);
        _request(id);
        assertEq(imd.balanceOf(keeper), keeperBefore);
        (uint256 balance,) = q.meterOf(id);
        assertEq(balance, 0);
        assertEq(q.costOf(id), PRICE);
        (uint256 earned, uint256 pending) = q.tipsOf(keeper);
        assertEq(earned + pending, 0);
        assertEq(q.totalTips(), 0);
        assertEq(imd.balanceOf(address(q)), 0);
    }

    /// @notice The price is the Intake's at the moment of asking, not a number fixed in the feed.
    function test_request_paysTheLivePrice() public {
        _fund(alice, feedId, 3e18);
        intake.setPrice(ACTION, address(imd), 0.8e18);
        assertEq(q.costOf(feedId), 0.8e18 + TIP);
        _request(feedId);
        assertEq(intake.lastAmount(), 0.8e18);
        assertEq(imd.balanceOf(PAY_TO), 0.8e18);
        (uint256 balance,) = q.meterOf(feedId);
        assertEq(balance, 3e18 - 0.8e18 - TIP);
    }

    function test_nextBody_isExactlyWhatRequestSends() public {
        _fund(alice, feedId, 2e18);
        (bytes memory body, bytes32 questionHash, uint64 fromBlock, uint64 toBlock) = q.nextBody(feedId);
        (,,, uint64 canFrom, uint64 canTo) = q.canRequest(feedId);
        _request(feedId);
        assertEq(intake.lastBody(), body);
        (, bytes32 stored,,) = q.roundRequest(feedId, 1);
        assertEq(stored, questionHash);
        (uint64 gotFrom, uint64 gotTo) = _window(feedId, 1);
        assertEq(gotFrom, fromBlock);
        assertEq(gotTo, toBlock);
        assertEq(canFrom, fromBlock);
        assertEq(canTo, toBlock);
    }

    // ---- windows --------------------------------------------------------------------------------

    /// @notice Contiguous windows tile: each starts at the block after the last answered one ends.
    function test_windows_contiguous_tileExactly() public {
        _fund(alice, feedId, 10e18);
        _answer(feedId, abi.encode(uint256(1)));
        (uint64 from1, uint64 to1) = _window(feedId, 1);
        assertEq(to1, START_BLOCK - LAG);
        assertEq(to1 - from1 + 1, CADENCE, "the first window covers one cadence");

        vm.roll(START_BLOCK + CADENCE + 37);
        _answer(feedId, abi.encode(uint256(2)));
        (uint64 from2, uint64 to2) = _window(feedId, 2);
        assertEq(from2, to1 + 1);
        assertEq(to2, START_BLOCK + CADENCE + 37 - LAG);

        vm.roll(vm.getBlockNumber() + CADENCE);
        _answer(feedId, abi.encode(uint256(3)));
        (uint64 from3, uint64 to3) = _window(feedId, 3);
        assertEq(from3, to2 + 1);
        assertEq(to3, vm.getBlockNumber() - LAG);
    }

    /// @notice A window is cut at `maxWindowBlocks`, oldest blocks first, and the feed catches up
    /// in later rounds without skipping a block.
    function test_windows_contiguous_areCutAtTheMaximumAndCatchUp() public {
        _fund(alice, feedId, 10e18);
        _answer(feedId, abi.encode(uint256(1)));
        (, uint64 to1) = _window(feedId, 1);

        vm.roll(START_BLOCK + 3 * uint256(MAX_WINDOW));
        _answer(feedId, abi.encode(uint256(2)));
        (uint64 from2, uint64 to2) = _window(feedId, 2);
        assertEq(from2, to1 + 1);
        assertEq(to2 - from2 + 1, MAX_WINDOW);

        vm.roll(vm.getBlockNumber() + CADENCE);
        _answer(feedId, abi.encode(uint256(3)));
        (uint64 from3, uint64 to3) = _window(feedId, 3);
        assertEq(from3, to2 + 1);
        assertEq(to3 - from3 + 1, MAX_WINDOW);
    }

    /// @notice A failed round moves nothing: the next round starts at the same block.
    function test_windows_contiguous_afterAFailedRound_startAtTheSameBlock() public {
        _fund(alice, feedId, 10e18);
        _answer(feedId, abi.encode(uint256(1)));
        (, uint64 to1) = _window(feedId, 1);

        vm.roll(vm.getBlockNumber() + CADENCE);
        _request(feedId);
        (uint64 from2,) = _window(feedId, 2);
        skip(abandonAfterSilence);
        q.abandon(feedId);

        vm.roll(vm.getBlockNumber() + 2 * uint256(CADENCE));
        _request(feedId);
        (uint64 from3, uint64 to3) = _window(feedId, 3);
        assertEq(from2, to1 + 1);
        assertEq(from3, from2, "the failed window's blocks were skipped");
        assertEq(to3, vm.getBlockNumber() - LAG);
    }

    /// @notice A feed that is not contiguous always asks about the newest `maxWindowBlocks`.
    function test_windows_rolling_alwaysTheNewestBlocks() public {
        Questions.FeedParams memory p = _params();
        p.contiguous = false;
        (p.cadenceBlocks, p.maxWindowBlocks) = (100, 5000);
        bytes32 id = _create(p);
        _fund(alice, id, 10e18);

        _answer(id, abi.encode(uint256(1)));
        (uint64 from1, uint64 to1) = _window(id, 1);
        assertEq(to1, vm.getBlockNumber() - LAG);
        assertEq(to1 - from1 + 1, 5000);

        vm.roll(vm.getBlockNumber() + 100);
        _answer(id, abi.encode(uint256(2)));
        (uint64 from2, uint64 to2) = _window(id, 2);
        assertEq(to2, to1 + 100);
        assertEq(from2, from1 + 100, "a rolling window overlaps the one before it by design");
    }

    function test_windows_onAYoungChain_startAtBlockZeroOrWait() public {
        Questions.FeedParams memory p = _params();
        bytes32 id = _create(p);
        _fund(alice, id, 10e18);

        // No block is far enough behind the head yet.
        vm.roll(LAG);
        _assertBlocked(id, Questions.Blocker.NoBlocks);
        (bytes memory body,,, uint64 noTo) = q.nextBody(id);
        assertEq(body.length, 0);
        assertEq(noTo, 0);

        // Fewer blocks exist than one cadence: the window starts at block zero.
        vm.roll(LAG + 40);
        _request(id);
        (uint64 fromBlock, uint64 toBlock) = _window(id, 1);
        assertEq(fromBlock, 0);
        assertEq(toBlock, 40);
    }

    /// @notice The closing block's hash is read when the round opens: from BLOCKHASH within 256
    /// blocks, from the EIP-2935 history contract up to 8,191, and left unpinned beyond that.
    function test_request_recordsTheClosingBlockHash() public {
        address history = 0x0000F90827F1C53a10cb7A02335B175320002935;
        _fund(alice, feedId, 10e18);
        _answer(feedId, abi.encode(uint256(1)));
        (, uint64 to1) = _window(feedId, 1);

        // Far behind: the next window ends 3,000 blocks back, out of BLOCKHASH's reach.
        vm.roll(uint256(to1) + MAX_WINDOW + 3000);
        uint256 closing = uint256(to1) + MAX_WINDOW;
        assertEq(_blockhash(closing), bytes32(0));
        bytes32 fromHistory = keccak256("a hash only the history contract has");
        vm.mockCall(history, abi.encode(closing), abi.encode(fromHistory));
        _request(feedId);
        (,, bytes32 pinned,) = q.roundRequest(feedId, 2);
        assertEq(pinned, fromHistory);

        // An answer carrying another hash for that block is refused; the right one is taken.
        bytes32 intakeId = q.feedState(feedId).pendingRequestId;
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(2)));
        a.blockHash = keccak256("another fork");
        bytes memory signature = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(Questions.WrongBlockHash.selector, fromHistory, a.blockHash));
        _callback(intakeId, a, signature);
        a.blockHash = fromHistory;
        _callback(intakeId, a, _sign(a));

        // Further behind than the history contract reaches: nothing to pin, and a long-final block
        // is accepted with whatever hash the oracle signed.
        vm.clearMockedCalls();
        vm.roll(uint256(to1) + 2 * uint256(MAX_WINDOW) + 9000);
        _request(feedId);
        (,, pinned,) = q.roundRequest(feedId, 3);
        assertEq(pinned, bytes32(0));
        a = _attestation(feedId, abi.encode(uint256(3)));
        a.blockHash = keccak256("whatever the oracle saw");
        _callback(q.feedState(feedId).pendingRequestId, a, _sign(a));
        assertEq(uint8(_status(feedId, 3)), uint8(IQuestions.RoundStatus.Answered));
    }

    // ---- what blocks a request ------------------------------------------------------------------

    function test_blocked_whileARoundIsPending() public {
        _fund(alice, feedId, 10e18);
        _request(feedId);
        vm.roll(vm.getBlockNumber() + 10 * uint256(CADENCE));
        _assertBlocked(feedId, Questions.Blocker.RoundPending);
    }

    function test_blocked_untilTheCadenceHasElapsed() public {
        _fund(alice, feedId, 10e18);
        _answer(feedId, abi.encode(uint256(1)));
        assertEq(q.feedState(feedId).nextRequestBlock, START_BLOCK + CADENCE);

        vm.roll(START_BLOCK + CADENCE - 1);
        _assertBlocked(feedId, Questions.Blocker.TooSoon);
        vm.roll(START_BLOCK + CADENCE);
        _assertOpen(feedId);
        _request(feedId);
    }

    /// @notice After each failed round in a row the wait doubles: 2, 4, 8, 16, 32 times the
    /// cadence, and no further. One answer brings it back to the cadence.
    function test_blocked_backsOffAfterFailedRounds() public {
        _fund(alice, feedId, 100e18);
        uint256[7] memory factors = [uint256(2), 4, 8, 16, 32, 32, 32];
        _request(feedId);
        for (uint256 i; i < factors.length; ++i) {
            uint256 askedAt = vm.getBlockNumber();
            skip(abandonAfterSilence);
            q.abandon(feedId);
            Questions.FeedView memory v = q.feedState(feedId);
            assertEq(v.failStreak, i + 1);
            assertEq(v.nextRequestBlock, askedAt + factors[i] * CADENCE, "wrong back-off");

            vm.roll(askedAt + factors[i] * CADENCE - 1);
            _assertBlocked(feedId, Questions.Blocker.TooSoon);
            vm.roll(askedAt + factors[i] * CADENCE);
            _request(feedId);
        }
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(9)));
        assertTrue(_complete(q.feedState(feedId).pendingRequestId, a, _sign(a)));
        Questions.FeedView memory healed = q.feedState(feedId);
        assertEq(healed.failStreak, 0);
        assertEq(healed.nextRequestBlock, healed.lastRequestBlock + CADENCE);
    }

    function test_blocked_whenTheMeterCannotPay() public {
        _assertBlocked(feedId, Questions.Blocker.MeterTooLow);
        _fund(alice, feedId, COST - 1);
        _assertBlocked(feedId, Questions.Blocker.MeterTooLow);
        _fund(alice, feedId, 1);
        _assertOpen(feedId);
        _request(feedId);
        (uint256 balance,) = q.meterOf(feedId);
        assertEq(balance, 0);
    }

    function test_blocked_whenThePriceIsAboveTheFeedsCap() public {
        _fund(alice, feedId, 10e18);
        intake.setPrice(ACTION, address(imd), 1e18 + 1);
        _assertBlocked(feedId, Questions.Blocker.PriceAboveCap);
        (,, uint256 price,,) = q.canRequest(feedId);
        assertEq(price, 1e18 + 1);
        // No request can be bought at that price, so there is no cost to state.
        assertEq(q.costOf(feedId), 0);
        assertEq(q.feedState(feedId).cost, 0);
        // Exactly at the cap is fine.
        intake.setPrice(ACTION, address(imd), 1e18);
        assertEq(q.costOf(feedId), 1e18 + TIP);
        _assertOpen(feedId);
        _request(feedId);
        assertEq(intake.lastAmount(), 1e18);
    }

    /// @notice An Intake price so large that adding the tip to it would overflow blocks requests
    /// and breaks no view: the page still loads and still says why.
    function test_blocked_whenThePriceIsAbsurd_theViewsStillAnswer() public {
        _fund(alice, feedId, 10e18);
        intake.setPrice(ACTION, address(imd), type(uint256).max);
        assertEq(q.costOf(feedId), 0);
        Questions.FeedView memory v = q.feedState(feedId);
        assertEq(v.cost, 0);
        assertEq(uint8(v.blocker), uint8(Questions.Blocker.PriceAboveCap));
        (bool ok, Questions.Blocker why, uint256 price,,) = q.canRequest(feedId);
        assertFalse(ok);
        assertEq(uint8(why), uint8(Questions.Blocker.PriceAboveCap));
        assertEq(price, type(uint256).max);
        _assertBlocked(feedId, Questions.Blocker.PriceAboveCap);
    }

    function test_blocked_whenTheIntakeDoesNotSellTheAction() public {
        _fund(alice, feedId, 10e18);
        intake.setPrice(ACTION, address(imd), 0);
        _assertBlocked(feedId, Questions.Blocker.NotSold);
        assertEq(q.costOf(feedId), 0);
        assertEq(q.feedState(feedId).cost, 0);
    }

    /// @notice An Intake whose price cannot be read blocks requests and loses nobody anything.
    function test_blocked_whenThePriceCannotBeRead() public {
        OddIntake odd = new OddIntake();
        QuestionsHarness oddQ = new QuestionsHarness(address(odd), address(imd), oracle);
        bytes32 id = oddQ.createFeed(_params(), _prefix("uint256"), _tail(7, 5, 86_400));
        vm.startPrank(alice);
        imd.approve(address(oddQ), type(uint256).max);
        oddQ.fund(id, 5e18);
        vm.stopPrank();

        OddIntake.Read[3] memory modes = [OddIntake.Read.Revert, OddIntake.Read.ShortReturn, OddIntake.Read.BurnGas];
        for (uint256 i; i < modes.length; ++i) {
            odd.setPriceMode(modes[i]);
            uint256 before = gasleft();
            (bool ok, Questions.Blocker why,,,) = oddQ.canRequest(id);
            assertLt(before - gasleft(), 200_000, "the price read was given more than its cap");
            assertFalse(ok);
            assertEq(uint8(why), uint8(Questions.Blocker.NotSold));
            assertEq(oddQ.costOf(id), 0);
        }
        odd.setPriceMode(OddIntake.Read.Revert);
        vm.expectRevert(_blocked(Questions.Blocker.NotSold));
        oddQ.request(id);

        // The funder is not stuck behind the broken Intake.
        vm.prank(alice);
        assertEq(oddQ.defund(id, type(uint256).max), 5e18);
    }

    /// @notice One request per transaction, because the Intake serves one: a second `request` in
    /// the same transaction is refused, for the same feed or any other.
    function test_blocked_secondRequestInOneTransaction() public {
        Questions.FeedParams memory p = _params();
        p.tip = 0;
        bytes32 other = _create(p);
        _fund(alice, feedId, 10e18);
        _fund(alice, other, 10e18);
        DoubleAsker asker = new DoubleAsker();

        q.newTransaction();
        vm.expectRevert(_blocked(Questions.Blocker.AlreadyAskedThisTransaction));
        asker.askTwice(q, feedId, other);
        assertEq(q.roundCount(feedId), 0, "the first request of the reverted transaction stood");

        // One request in a transaction of its own goes through, and so does the next transaction.
        q.newTransaction();
        asker.askOnce(q, feedId);
        q.newTransaction();
        asker.askOnce(q, other);
        assertEq(q.roundCount(feedId), 1);
        assertEq(q.roundCount(other), 1);
        assertEq(intake.nonce(), 2);
    }

    /// @notice The same on the contract as deployed, with no test door: two requests in one call.
    function test_blocked_secondRequestInOneTransaction_unmodifiedContract() public {
        Questions plain = new Questions(address(intake), address(imd), oracle);
        Questions.FeedParams memory p = _params();
        bytes32 a = plain.createFeed(p, _prefix("uint256"), _tail(7, 5, 86_400));
        p.tip = 0;
        bytes32 b = plain.createFeed(p, _prefix("uint256"), _tail(7, 5, 86_400));
        vm.startPrank(alice);
        imd.approve(address(plain), type(uint256).max);
        plain.fund(a, 5e18);
        plain.fund(b, 5e18);
        vm.stopPrank();

        DoubleAsker asker = new DoubleAsker();
        vm.expectRevert(_blocked(Questions.Blocker.AlreadyAskedThisTransaction));
        asker.askTwice(plain, a, b);
        vm.expectRevert(_blocked(Questions.Blocker.AlreadyAskedThisTransaction));
        asker.askTwice(plain, a, a);
    }

    // ---- the WHEN gate --------------------------------------------------------------------------

    function _gated(GateTarget gate, uint8 cmp, uint256 threshold, bytes memory data) internal returns (bytes32) {
        Questions.FeedParams memory p = _params();
        p.gateTarget = address(gate);
        p.gateCmp = cmp;
        p.gateThreshold = threshold;
        p.gateData = data;
        p.cadenceBlocks = 1;
        return _create(p);
    }

    /// @notice WHEN a view call crosses a line, THEN buy the answer: the feed asks only while its
    /// gate is true, and the cadence still applies.
    function test_gate_opensWhenTheLineIsCrossed() public {
        GateTarget gate = new GateTarget();
        bytes32 id = _gated(gate, 1, 100, abi.encodeCall(GateTarget.value, ()));
        _fund(alice, id, 10e18);

        gate.set(99);
        assertFalse(q.gateOpen(id));
        _assertBlocked(id, Questions.Blocker.GateClosed);

        gate.set(100);
        assertTrue(q.gateOpen(id));
        _assertOpen(id);
        _answer(id, abi.encode(uint256(1)));

        // Still open, but the cadence has not elapsed: the gate does not override it.
        _assertBlocked(id, Questions.Blocker.TooSoon);
        vm.roll(vm.getBlockNumber() + 1);
        _assertOpen(id);
        gate.set(0);
        _assertBlocked(id, Questions.Blocker.GateClosed);
    }

    function testFuzz_gate_everyComparison(uint256 word, uint256 threshold, uint8 cmpSeed) public {
        uint8 cmp = uint8(bound(cmpSeed, 1, 6));
        GateTarget gate = new GateTarget();
        gate.set(word);
        bytes32 id = _gated(gate, cmp, threshold, abi.encodeCall(GateTarget.value, ()));
        bool expected = cmp == 1
            ? word >= threshold
            : cmp == 2
                ? word <= threshold
                : cmp == 3
                    ? word > threshold
                    : cmp == 4 ? word < threshold : cmp == 5 ? word == threshold : word != threshold;
        assertEq(q.gateOpen(id), expected);
    }

    function test_gate_passesItsStoredArguments() public {
        GateTarget gate = new GateTarget();
        gate.set(10);
        bytes32 one = _gated(gate, 5, 17, abi.encodeCall(GateTarget.plus, (7)));
        bytes32 two = _gated(gate, 5, 30, abi.encodeCall(GateTarget.plus2, (7, 13)));
        assertTrue(q.gateOpen(one));
        assertTrue(q.gateOpen(two));
        gate.set(11);
        assertFalse(q.gateOpen(one));
        assertFalse(q.gateOpen(two));
    }

    /// @notice A gate that reverts, returns too little, has no code or tries to use more than its
    /// 100,000 gas is closed. None of them can make `request` revert in any other way or cost the
    /// caller more than the cap.
    function test_gate_thatMisbehaves_isClosed() public {
        GateTarget gate = new GateTarget();
        gate.set(1);
        bytes32 id = _gated(gate, 1, 1, abi.encodeCall(GateTarget.value, ()));
        _fund(alice, id, 10e18);
        assertTrue(q.gateOpen(id));

        gate.setMode(GateTarget.Mode.Revert);
        assertFalse(q.gateOpen(id));
        _assertBlocked(id, Questions.Blocker.GateClosed);

        gate.setMode(GateTarget.Mode.ShortReturn);
        assertFalse(q.gateOpen(id));

        gate.setMode(GateTarget.Mode.BurnGas);
        uint256 before = gasleft();
        assertFalse(q.gateOpen(id));
        assertLt(before - gasleft(), 150_000, "the gate was given more than its cap");
        _assertBlocked(id, Questions.Blocker.GateClosed);

        // A target with no code answers nothing.
        bytes32 hollow = _gated(GateTarget(address(0xD00D)), 6, 5, abi.encodeCall(GateTarget.value, ()));
        assertFalse(q.gateOpen(hollow));
    }

    /// @notice Only the first word of a long reply is read.
    function test_gate_longReply_readsOneWord() public {
        GateTarget gate = new GateTarget();
        gate.set(5);
        gate.setMode(GateTarget.Mode.LongReturn);
        bytes32 id = _gated(gate, 5, 5, abi.encodeCall(GateTarget.value, ()));
        assertTrue(q.gateOpen(id));
        _fund(alice, id, 10e18);
        _request(id);
    }

    // ---- an Intake or a token that misbehaves ---------------------------------------------------

    function _withOddIntake(address token) internal returns (QuestionsHarness oddQ, OddIntake odd, bytes32 id) {
        odd = new OddIntake();
        oddQ = new QuestionsHarness(address(odd), token, oracle);
        id = oddQ.createFeed(_params(), _prefix("uint256"), _tail(7, 5, 86_400));
    }

    /// @notice Nothing can run inside `request`: a call back into any entry point reverts the
    /// whole request.
    function test_request_cannotBeReentered() public {
        (QuestionsHarness oddQ, OddIntake odd, bytes32 id) = _withOddIntake(address(imd));
        vm.startPrank(alice);
        imd.approve(address(oddQ), type(uint256).max);
        oddQ.fund(id, 5e18);
        vm.stopPrank();
        OracleAttestation.Attestation memory a;

        bytes[7] memory calls = [
            abi.encodeCall(Questions.request, (id)),
            abi.encodeCall(Questions.fund, (id, 1)),
            abi.encodeCall(Questions.fundFor, (id, 1, alice)),
            abi.encodeCall(Questions.defund, (id, 1)),
            abi.encodeCall(Questions.abandon, (id)),
            abi.encodeCall(Questions.onOracleResult, (bytes32(0), a, "")),
            abi.encodeCall(Questions.collectTips, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            odd.setReenterWith(calls[i]);
            oddQ.newTransaction();
            vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
            oddQ.request(id);
        }
        odd.setReenterWith(abi.encodeCall(Questions.submit, (id, a, "")));
        oddQ.newTransaction();
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        oddQ.request(id);

        odd.setReenterWith("");
        oddQ.newTransaction();
        oddQ.request(id);
        assertEq(oddQ.roundCount(id), 1);
    }

    /// @notice An Intake that hands out an id it has handed out before is refused: one pending
    /// request per id, always.
    function test_request_refusesAReusedRequestId() public {
        (QuestionsHarness oddQ, OddIntake odd, bytes32 id) = _withOddIntake(address(imd));
        Questions.FeedParams memory p = _params();
        p.tip = 0;
        bytes32 other = oddQ.createFeed(p, _prefix("uint256"), _tail(7, 5, 86_400));
        vm.startPrank(alice);
        imd.approve(address(oddQ), type(uint256).max);
        oddQ.fund(id, 5e18);
        oddQ.fund(other, 5e18);
        vm.stopPrank();

        odd.setFixedId(true);
        oddQ.newTransaction();
        bytes32 first = oddQ.request(id);
        oddQ.newTransaction();
        vm.expectRevert(abi.encodeWithSelector(Questions.RequestIdReused.selector, first));
        oddQ.request(other);
        assertEq(oddQ.feedOfRequest(first), id);
        assertEq(oddQ.roundCount(other), 0);
    }

    /// @notice If paying would leave the contract holding less than its meters add up to, the
    /// request reverts: here a token that takes more from the sender than the transfer says.
    function test_request_revertsRatherThanLeaveTheMetersShort() public {
        GreedyIMD greedy = new GreedyIMD();
        (QuestionsHarness oddQ,, bytes32 id) = _withOddIntake(address(greedy));
        greedy.mint(alice, 10e18);
        vm.startPrank(alice);
        greedy.approve(address(oddQ), type(uint256).max);
        oddQ.fund(id, 5e18);
        vm.stopPrank();

        greedy.setGreedy(true);
        oddQ.newTransaction();
        vm.expectRevert(Questions.MetersNotCovered.selector);
        oddQ.request(id);
        (uint256 balance,) = oddQ.meterOf(id);
        assertEq(balance, 5e18);

        greedy.setGreedy(false);
        oddQ.newTransaction();
        oddQ.request(id);
        assertEq(oddQ.totalMetered() + oddQ.totalTips(), greedy.balanceOf(address(oddQ)));
        assertEq(oddQ.totalTips(), TIP);
    }

    /// @notice The meter is charged the whole price, so the Intake must take the whole price. An
    /// Intake that takes none of it, or part of it, makes the request revert: no meter pays for
    /// IMD that stayed in the contract, and no allowance is left standing.
    function test_request_revertsWhenTheIntakeTakesLessThanThePrice() public {
        (QuestionsHarness oddQ, OddIntake odd, bytes32 id) = _withOddIntake(address(imd));
        vm.startPrank(alice);
        imd.approve(address(oddQ), type(uint256).max);
        oddQ.fund(id, 5e18);
        vm.stopPrank();

        odd.setSkipPayment(true);
        oddQ.newTransaction();
        vm.expectRevert(Questions.PriceNotTaken.selector);
        oddQ.request(id);

        odd.setSkipPayment(false);
        odd.setShortBy(1);
        oddQ.newTransaction();
        vm.expectRevert(Questions.PriceNotTaken.selector);
        oddQ.request(id);

        // Nothing moved and nothing was approved.
        assertEq(oddQ.roundCount(id), 0);
        assertEq(oddQ.totalMetered(), 5e18);
        assertEq(imd.balanceOf(address(oddQ)), 5e18);
        assertEq(imd.allowance(address(oddQ), address(odd)), 0);

        // An Intake that takes exactly the price is paid, and leaves no allowance behind either.
        // The tip is off the meter and still in the contract, set aside.
        odd.setShortBy(0);
        oddQ.newTransaction();
        oddQ.request(id);
        assertEq(oddQ.totalMetered(), 5e18 - COST);
        assertEq(oddQ.totalTips(), TIP);
        assertEq(imd.balanceOf(address(oddQ)), 5e18 - PRICE);
        assertEq(imd.allowance(address(oddQ), address(odd)), 0);
    }

    // ---- a caller that asks elsewhere first ------------------------------------------------------

    /// @dev A caller buys an Intake request of its own and then presses the feed's `request`, in
    /// one transaction. The protocol serves the first Intake request of a transaction only, so the
    /// feed's request is paid for and never served.
    function _unservedRound() internal returns (BundledAsker bundle, bytes32 feedRequestId) {
        _fund(alice, feedId, 10e18);
        bundle = new BundledAsker();
        imd.mint(address(bundle), PRICE);
        q.newTransaction();
        intake.newTransaction();
        bytes32 ownId;
        (ownId, feedRequestId) = bundle.buyThenAsk(intake, q, feedId, ACTION, bytes('{"v":1}'));
        // The caller's request is the one the plane serves; the feed's is recorded and left alone.
        assertFalse(intake.notFirstInTransaction(ownId));
        assertTrue(intake.notFirstInTransaction(feedRequestId));
    }

    /// @notice A disclosed limit, shown with its numbers. The contract cannot see the caller's
    /// earlier request, so the round opens and the meter pays the Intake for a request that is
    /// never served. The caller is paid nothing for it: the tip is only set aside, and when the
    /// round is closed it goes back onto the meter. The caller's cost is a whole Intake price of
    /// its own; the meter's is one price. If nobody does anything about it, the round can only be
    /// closed after the full silence deadline, and the feed then waits two cadences.
    function test_request_afterTheCallersOwnIntakeRequest_isNeverServedAndEarnsTheCallerNothing() public {
        (BundledAsker bundle,) = _unservedRound();
        uint256 askedAt = vm.getBlockTimestamp();
        uint256 askedBlock = vm.getBlockNumber();

        assertEq(imd.balanceOf(address(bundle)), 0, "the caller was paid for a round it left unserved");
        (uint256 earned, uint256 pending) = q.tipsOf(address(bundle));
        assertEq(earned, 0);
        assertEq(pending, TIP);
        (uint256 balance,) = q.meterOf(feedId);
        assertEq(balance, 10e18 - COST);
        assertEq(uint8(_status(feedId, 1)), uint8(IQuestions.RoundStatus.Pending));

        // The Intake never completes it. Nobody can ask again while it is pending, and it cannot
        // be closed until the full silence deadline has passed.
        vm.roll(askedBlock + 10 * uint256(CADENCE));
        skip(abandonAfterSilence - 1);
        _assertBlocked(feedId, Questions.Blocker.RoundPending);
        vm.expectRevert(abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, askedAt + abandonAfterSilence));
        q.abandon(feedId);
        skip(1);
        assertTrue(q.abandon(feedId));
        Questions.FeedView memory v = q.feedState(feedId);
        assertEq(v.failStreak, 1);
        assertEq(v.nextRequestBlock, askedBlock + 2 * uint256(CADENCE));

        // The failed round gave its tip back to the meter: the feed lost the price and no more,
        // and the caller has nothing to collect, now or later.
        (balance,) = q.meterOf(feedId);
        assertEq(balance, 10e18 - PRICE);
        (earned, pending) = q.tipsOf(address(bundle));
        assertEq(earned + pending, 0);
        assertEq(q.totalTips(), 0);
        vm.prank(address(bundle));
        assertEq(q.collectTips(), 0);
        assertEq(imd.balanceOf(address(bundle)), 0);
        assertEq(imd.balanceOf(address(q)), q.totalMetered());

        // An honest keeper's request, in a transaction of its own, is the first and is served.
        bytes32 next = _request(feedId);
        assertFalse(intake.notFirstInTransaction(next));
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(uint256(9)));
        assertTrue(_complete(next, a, _sign(a)));
        assertEq(q.feedState(feedId).failStreak, 0);
    }

    /// @notice What can be done about it: thirty minutes after the request, anyone who has bought
    /// the same question from the oracle for this contract hands the answer in. The round is answered,
    /// the cadence is not doubled, and the feed asks again when it would have anyway. The tip goes
    /// to the opener: the protocol cannot identify which purchase produced a matching attestation.
    function test_request_anUnservedRoundCanBeAnsweredThroughSubmit() public {
        (BundledAsker bundle,) = _unservedRound();
        uint256 askedAt = vm.getBlockTimestamp();
        uint256 askedBlock = vm.getBlockNumber();
        OracleAttestation.Attestation memory bought = _attestation(feedId, abi.encode(uint256(77)));
        bytes memory signature = _sign(bought);

        bytes memory tooEarly = abi.encodeWithSelector(Questions.SubmitTooEarly.selector, askedAt + submitAfterSilence);
        vm.expectRevert(tooEarly);
        q.submit(feedId, bought, signature);
        // To the last second of the wait; then it is open.
        skip(submitAfterSilence - 1);
        vm.expectRevert(tooEarly);
        q.submit(feedId, bought, signature);
        skip(1);
        vm.roll(askedBlock + submitAfterSilence / 12);
        vm.prank(bob);
        q.submit(feedId, bought, signature);

        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(round, 1);
        assertEq(value, 77);
        Questions.FeedView memory v = q.feedState(feedId);
        assertEq(v.failStreak, 0);
        assertEq(v.nextRequestBlock, askedBlock + CADENCE);
        (uint256 earned, uint256 pending) = q.tipsOf(address(bundle));
        assertEq(earned, TIP, "the opener keeps the tip for an answered round");
        assertEq(pending, 0);
        (earned, pending) = q.tipsOf(bob);
        assertEq(earned + pending, 0);
        vm.prank(address(bundle));
        assertEq(q.collectTips(), TIP);
        assertEq(q.totalTips(), 0);
        assertEq(imd.balanceOf(address(q)), q.totalMetered());
        // Nothing is left to abandon, at twelve hours or ever.
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(Questions.NoPendingRound.selector, feedId));
        q.abandon(feedId);
    }
}
