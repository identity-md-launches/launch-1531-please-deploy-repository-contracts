// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Blockhash} from "@openzeppelin/contracts/utils/Blockhash.sol";
import {IQuestions} from "../../../src/interfaces/IQuestions.sol";
import {IIntake} from "../../../src/interfaces/external/IIntake.sol";
import {Mainnet} from "../../../src/interfaces/external/Mainnet.sol";
import {OracleAttestation} from "../../../src/questions/OracleAttestation.sol";
import {Questions} from "../../../src/questions/Questions.sol";
import {QuestionsHarness} from "../mocks/QuestionsHarness.sol";
import {IIntakeV2} from "./IIntakeV2.sol";

/// @dev Reads block hashes in a frame of its own, through the same library the contract uses.
contract HistoryReader {
    function hashOf(uint256 number) external view returns (bytes32) {
        return Blockhash.blockHash(number);
    }

    function plain(uint256 number) external view returns (bytes32) {
        return blockhash(number);
    }
}

/// @title Questions against the live Intake, version 2, on a fork of Ethereum mainnet
/// @notice Questions is deployed on the fork with a test key as its oracle signer, funded, and
/// asked to buy a real request from the real Intake with the real IMD. The Intake is version 2
/// (`0xa43e6f75ee006411f79ac1c84120606c2330de82`), the one the launch manifest names; the first
/// test shows that it is. The tests then play the Intake's writer: they call the real `complete`
/// with an attestation signed by the test key, so the real contract calls the callback under its
/// real gas stipend. Nothing is mocked but the oracle's signature, which no test can have. Run
/// with `FOUNDRY_PROFILE=fork forge test`; every test skips itself when the RPC cannot be reached.
contract QuestionsIntakeForkTest is Test {
    string internal constant FEEDS = "test/fixtures/questions/feeds/";

    IIntakeV2 internal constant INTAKE = IIntakeV2(Mainnet.INTAKE);
    IERC20 internal constant IMD = IERC20(Mainnet.IMD);

    bool internal forked;
    Questions internal q;
    HistoryReader internal history;
    uint256 internal oracleKey;
    address internal funder = makeAddr("funder");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("mainnet")) returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        address oracle;
        (oracle, oracleKey) = makeAddrAndKey("fork oracle signer");
        q = new Questions(Mainnet.INTAKE, Mainnet.IMD, oracle);
        history = new HistoryReader();
        _giveImd(funder, 50e18);
        vm.prank(funder);
        IMD.approve(address(q), type(uint256).max);
    }

    /// @dev IMD for the test, by writing the balance or, if the token's layout hides it, by moving
    /// some from the staking vault. Either way no real account is touched: this is a fork.
    function _giveImd(address to, uint256 amount) internal {
        try this.dealImd(to, amount) {}
        catch {
            vm.prank(Mainnet.SIMD);
            IMD.transfer(to, amount);
        }
        assertGe(IMD.balanceOf(to), amount, "could not fund the test with IMD");
    }

    function dealImd(address to, uint256 amount) external {
        deal(Mainnet.IMD, to, amount);
        require(IMD.balanceOf(to) == amount, "deal did not take");
    }

    function _houseFeed(string memory name)
        internal
        view
        returns (Questions.FeedParams memory p, bytes memory qPrefix, bytes memory tail, bytes32 feedId)
    {
        string memory j = vm.readFile(string.concat(FEEDS, name, ".json"));
        p.action = vm.parseJsonBytes32(j, ".params.action");
        p.chainId = uint64(vm.parseJsonUint(j, ".params.chainId"));
        p.answerType = uint8(vm.parseJsonUint(j, ".params.answerType"));
        p.panelSize = uint16(vm.parseJsonUint(j, ".params.panelSize"));
        p.quorum = uint16(vm.parseJsonUint(j, ".params.quorum"));
        p.minAgreed = uint16(vm.parseJsonUint(j, ".params.minAgreed"));
        p.validFor = uint32(vm.parseJsonUint(j, ".params.validFor"));
        p.cadenceBlocks = uint32(vm.parseJsonUint(j, ".params.cadenceBlocks"));
        p.maxWindowBlocks = uint32(vm.parseJsonUint(j, ".params.maxWindowBlocks"));
        p.lagBlocks = uint16(vm.parseJsonUint(j, ".params.lagBlocks"));
        p.contiguous = vm.parseJsonBool(j, ".params.contiguous");
        p.pinHash = vm.parseJsonBool(j, ".params.pinHash");
        p.maxPrice = uint96(vm.parseJsonUint(j, ".params.maxPrice"));
        p.tip = uint96(vm.parseJsonUint(j, ".params.tip"));
        qPrefix = vm.parseJsonBytes(j, ".qPrefixHex");
        tail = vm.parseJsonBytes(j, ".tailHex");
        feedId = vm.parseJsonBytes32(j, ".feedId");
    }

    function _attest(Questions on, bytes32 feedId, bytes memory answer)
        internal
        view
        returns (OracleAttestation.Attestation memory a, bytes memory signature)
    {
        Questions.FeedParams memory p = on.feedParams(feedId);
        uint64 round = on.roundCount(feedId);
        (, bytes32 questionHash, bytes32 blockHash,) = on.roundRequest(feedId, round);
        (,, uint64 fromBlock, uint64 toBlock,) = on.roundOf(feedId, round);
        a = OracleAttestation.Attestation({
            requestId: bytes32(bytes16(keccak256(abi.encode("fork oracle request", feedId, round)))),
            chainId: 1,
            questionHash: questionHash,
            answerType: p.answerType,
            answer: answer,
            figure: 0,
            fromBlock: fromBlock,
            toBlock: toBlock,
            blockHash: blockHash,
            panelJobId: bytes32(bytes16(keccak256("fork panel job"))),
            panelSize: p.panelSize,
            quorum: p.quorum,
            agreed: p.quorum,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + p.validFor
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oracleKey, on.attestationDigest(a));
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice The Intake these tests run against is version 2: it has the getter version 1 lacks,
    /// and everything `Questions` reads or relies on is as it is on version 1, which is still served.
    function test_fork_theIntakeIsVersionTwo() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        assertEq(Mainnet.INTAKE, 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(address(q.INTAKE()), Mainnet.INTAKE);
        assertGt(Mainnet.INTAKE.code.length, 0);

        // Version 2 answers `failureSelectorOf`; version 1 has no such function.
        assertEq(INTAKE.failureSelectorOf(bytes32(0)), bytes4(0));
        (bool ok,) = Mainnet.INTAKE_V1.staticcall(abi.encodeCall(IIntakeV2.failureSelectorOf, (bytes32(0))));
        assertFalse(ok, "the address kept as version 1 answers like version 2");

        // What Questions reads is the same on both: the price, and who is paid.
        IIntake v1 = IIntake(Mainnet.INTAKE_V1);
        assertEq(INTAKE.priceOf(Mainnet.ORACLE_ACTION, Mainnet.IMD), v1.priceOf(Mainnet.ORACLE_ACTION, Mainnet.IMD));
        assertEq(INTAKE.payTo(), v1.payTo());
        assertEq(INTAKE.payTo(), Mainnet.FEE_PAYEE, "the fee payee the Jobs Report counts transfers to");
        assertEq(INTAKE.writer(), v1.writer());
        assertEq(INTAKE.MAX_BODY_BYTES(), 16_384);
        console2.log("live callback stipend, version 2:", INTAKE.callbackGas());
        assertGe(INTAKE.callbackGas(), 140_000, "the stipend is below what the callback tests allow for");
    }

    /// @notice The Payrolls house feed, as its fixture file defines it, buys a request from the
    /// live Intake and takes the answer back through the live Intake's `complete`.
    function test_fork_houseFeedBuysARealRequestAndTakesTheCallback() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        (Questions.FeedParams memory p, bytes memory qPrefix, bytes memory tail, bytes32 expectedId) =
            _houseFeed("payrolls");
        bytes32 feedId = q.createFeed(p, qPrefix, tail);
        assertEq(feedId, expectedId, "the feed id does not depend on where Questions is deployed");

        // The live price is read from the Intake and is within the feed's cap.
        uint256 price = INTAKE.priceOf(p.action, Mainnet.IMD);
        assertGt(price, 0, "the Intake no longer sells oracle.request for IMD");
        assertLe(price, p.maxPrice, "the live price is above the house feeds' cap");
        assertEq(q.costOf(feedId), price + p.tip);
        vm.prank(funder);
        q.fund(feedId, 10e18);

        (bytes memory body, bytes32 questionHash, uint64 fromBlock, uint64 toBlock) = q.nextBody(feedId);
        assertLe(body.length, INTAKE.MAX_BODY_BYTES());
        address payTo = INTAKE.payTo();
        uint256 payToBefore = IMD.balanceOf(payTo);
        uint256 nonceBefore = INTAKE.nonce();

        vm.recordLogs();
        vm.prank(keeper);
        bytes32 intakeId = q.request(feedId);

        // The Intake recorded this contract as payer and callback, and was paid exactly its price.
        assertEq(INTAKE.nonce(), nonceBefore + 1);
        assertEq(intakeId, keccak256(abi.encode(uint256(1), Mainnet.INTAKE, nonceBefore + 1)));
        (address payer, address target, bytes4 selector, bool completed) = INTAKE.requests(intakeId);
        assertEq(payer, address(q));
        assertEq(target, address(q));
        assertEq(selector, Questions.onOracleResult.selector);
        assertFalse(completed);
        assertEq(IMD.balanceOf(payTo), payToBefore + price);
        // Asking pays the keeper nothing: the tip is off the meter and set aside in the contract.
        assertEq(IMD.balanceOf(keeper), 0);
        assertEq(IMD.balanceOf(address(q)), 10e18 - price);
        assertEq(q.totalMetered(), 10e18 - price - p.tip);
        assertEq(q.totalTips(), p.tip);
        assertEq(q.totalMetered() + q.totalTips(), IMD.balanceOf(address(q)));
        assertEq(IMD.allowance(address(q), Mainnet.INTAKE), 0);
        // Asked with plain `request`: no failure function is named (docs/DEVIATIONS.md, D2).
        assertEq(INTAKE.failureSelectorOf(intakeId), bytes4(0));

        // The Intake's own event carries the body, byte for byte what `nextBody` promised.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawRequested;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != Mainnet.INTAKE) continue;
            assertTrue(logs[i].topics[0] != IIntakeV2.FailureHookSet.selector, "a failure function was named");
            if (logs[i].topics[0] != IIntake.Requested.selector) continue;
            assertEq(logs[i].topics[1], intakeId);
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(q)))));
            assertEq(logs[i].topics[3], p.action);
            (bytes memory sent, address callbackTarget, bytes4 callbackSelector, address asset, uint256 amount) =
                abi.decode(logs[i].data, (bytes, address, bytes4, address, uint256));
            assertEq(sent, body);
            assertEq(callbackTarget, address(q));
            assertEq(callbackSelector, Questions.onOracleResult.selector);
            assertEq(asset, Mainnet.IMD);
            assertEq(amount, price);
            sawRequested = true;
        }
        assertTrue(sawRequested, "the Intake did not emit Requested");
        assertEq(toBlock, vm.getBlockNumber() - p.lagBlocks);
        assertEq(uint256(toBlock) - fromBlock + 1, p.cadenceBlocks);
        (, bytes32 pinnedHash, bytes32 pinnedBlockHash,) = q.roundRequest(feedId, 1);
        assertEq(pinnedHash, questionHash);
        assertEq(pinnedBlockHash, history.plain(toBlock));
        assertTrue(pinnedBlockHash != bytes32(0));

        // A quarter of an hour later the writer completes the request with the answer.
        vm.roll(vm.getBlockNumber() + 70);
        skip(14 minutes);
        (OracleAttestation.Attestation memory a, bytes memory signature) =
            _attest(q, feedId, abi.encode(uint256(53.5e18)));
        bytes32 resultHash = keccak256("the attestation document");
        string memory uri = "https://api.imd.fun/oracle/requests/x/attestation";
        bytes memory args = abi.encode(intakeId, a, signature);
        address writer = INTAKE.writer();
        console2.log("live callback stipend:", INTAKE.callbackGas());

        // `delivered` is true only if the callback ran to the end inside the live stipend.
        vm.expectEmit(Mainnet.INTAKE);
        emit IIntake.Completed(intakeId, 0, resultHash, uri, true);
        vm.prank(writer);
        INTAKE.complete(intakeId, 0, resultHash, uri, args);

        (,,, completed) = INTAKE.requests(intakeId);
        assertTrue(completed);
        (uint256 value, uint64 gotFrom, uint64 gotTo, uint64 round, uint64 updatedAt) = q.latest(feedId);
        assertEq(value, 53.5e18);
        assertEq(gotFrom, fromBlock);
        assertEq(gotTo, toBlock);
        assertEq(round, 1);
        assertEq(updatedAt, vm.getBlockTimestamp());
        assertTrue(q.consumed(a.requestId));
        assertTrue(q.usedBy(a.requestId, feedId));

        // The live Intake's callback also earned the keeper its tip, which it now takes out.
        (uint256 earned, uint256 pending) = q.tipsOf(keeper);
        assertEq(earned, p.tip);
        assertEq(pending, 0);
        vm.prank(keeper);
        assertEq(q.collectTips(), p.tip);
        assertEq(IMD.balanceOf(keeper), p.tip);
        assertEq(q.totalTips(), 0);
        assertEq(q.totalMetered(), IMD.balanceOf(address(q)));

        // The Intake completes a request once.
        vm.expectRevert();
        vm.prank(writer);
        INTAKE.complete(intakeId, 0, resultHash, uri, args);
    }

    /// @notice `abandon` and `submit` read the live Intake's `requests` getter the way it is laid out
    /// on chain: not completed means the full silence deadline, and no `submit` for the first thirty minutes;
    /// completed with no answer opens `submit` at once and lets the round be closed thirty minutes
    /// after `abandon` first saw it.
    function test_fork_abandonReadsTheLiveIntake() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        (Questions.FeedParams memory p, bytes memory qPrefix, bytes memory tail,) = _houseFeed("hires");
        bytes32 feedId = q.createFeed(p, qPrefix, tail);
        vm.prank(funder);
        q.fund(feedId, 10e18);
        vm.prank(keeper);
        bytes32 intakeId = q.request(feedId);
        uint256 askedAt = vm.getBlockTimestamp();
        uint256 silence = q.ABANDON_AFTER_SILENCE() + p.validFor + q.ISSUED_AT_TOLERANCE() + 1;
        bytes memory tooEarly = abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, askedAt + silence);

        // The live Intake reports the request as not completed. To the last second of the thirty
        // minutes `submit` is closed, and the round cannot be closed.
        skip(q.SUBMIT_AFTER_SILENCE() - 1);
        assertFalse(q.canSubmit(feedId));
        vm.expectRevert(tooEarly);
        q.abandon(feedId);

        // Had the writer stayed silent: `submit` opens at thirty minutes by the clock alone, and
        // the round can be closed at the full silence deadline and not one second sooner.
        uint256 snapshot = vm.snapshotState();
        skip(1);
        assertTrue(q.canSubmit(feedId), "thirty minutes of silence did not open submit");
        skip(silence - q.SUBMIT_AFTER_SILENCE() - 1);
        vm.expectRevert(tooEarly);
        q.abandon(feedId);
        skip(1);
        assertTrue(q.abandon(feedId), "the full silence deadline of silence did not let the round be closed");
        vm.revertToState(snapshot);
        assertFalse(q.canSubmit(feedId));

        // The panel disagreed: the writer completes with status 2. Version 2 would call a failure
        // function here if the request had named one. Questions names none, so nothing is called,
        // whether or not the writer sends the failure's arguments along; the round is noticed by
        // `abandon`, which reads `requests(id).completed`, laid out as on version 1.
        address writer = INTAKE.writer();
        bytes memory failure = abi.encode(intakeId, uint8(2), bytes32("disagreed"), uint16(3), uint16(7), bytes(""));
        vm.expectEmit(Mainnet.INTAKE);
        emit IIntake.Completed(intakeId, 2, bytes32(0), "https://api.imd.fun/oracle/requests/x", false);
        vm.prank(writer);
        INTAKE.complete(intakeId, 2, bytes32(0), "https://api.imd.fun/oracle/requests/x", failure);
        (address payer, address target, bytes4 selector, bool completed) = INTAKE.requests(intakeId);
        assertEq(payer, address(q));
        assertEq(target, address(q));
        assertEq(selector, Questions.onOracleResult.selector);
        assertTrue(completed);

        // The first call sees the completion and starts the thirty minutes; the second closes.
        assertTrue(q.canSubmit(feedId));
        uint256 seenAt = vm.getBlockTimestamp();
        assertFalse(q.abandon(feedId));
        (Questions.AbandonStep step, uint256 closableAt) = q.canAbandon(feedId);
        assertEq(uint8(step), uint8(Questions.AbandonStep.Wait));
        assertEq(closableAt, seenAt + q.ABANDON_AFTER_COMPLETED());
        skip(q.ABANDON_AFTER_COMPLETED());
        assertTrue(q.abandon(feedId));
        (IQuestions.RoundStatus status,,,,) = q.roundOf(feedId, 1);
        assertEq(uint8(status), uint8(IQuestions.RoundStatus.Failed));
        assertEq(q.feedState(feedId).failStreak, 1);
        // The funder takes back everything the failed round did not spend: all but the price. The
        // tip that was set aside went back onto the meter when the round was closed.
        uint256 left = q.redeemable(feedId, funder);
        assertEq(left, 10e18 - INTAKE.priceOf(p.action, Mainnet.IMD));
        assertEq(q.totalTips(), 0);
        vm.prank(funder);
        assertEq(q.defund(feedId, type(uint256).max), left);
        assertEq(IMD.balanceOf(address(q)), 0);
    }

    /// @notice A catch-up window that ends more than 256 blocks back gets its closing block hash
    /// from the EIP-2935 history contract, and on mainnet that is the block's true hash.
    function test_fork_oldClosingBlockHashComesFromTheHistoryContract() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 head = vm.getBlockNumber();
        bytes32 trueHash = history.plain(head - 6);
        assertTrue(trueHash != bytes32(0));

        // This test makes two requests, which on a real chain are two transactions. The harness
        // adds only the door that ends a transaction for the one-request-per-transaction rule.
        QuestionsHarness h = new QuestionsHarness(Mainnet.INTAKE, Mainnet.IMD, vm.addr(oracleKey));
        Questions.FeedParams memory p;
        p.action = Mainnet.ORACLE_ACTION;
        p.chainId = 1;
        p.answerType = OracleAttestation.ANSWER_UINT256;
        (p.panelSize, p.quorum, p.minAgreed) = (7, 5, 5);
        p.validFor = 86_400;
        (p.cadenceBlocks, p.maxWindowBlocks, p.lagBlocks) = (5, 6, 12);
        (p.contiguous, p.pinHash) = (true, true);
        p.maxPrice = 2e18;
        bytes32 feedId = h.createFeed(
            p,
            '{"answerType":"uint256","chainId":1,"question":"A fork test question?","v":1,"window":{"fromBlock":',
            ',"panelSize":7,"quorum":5,"validForSeconds":86400}'
        );
        vm.startPrank(funder);
        IMD.approve(address(h), type(uint256).max);
        h.fund(feedId, 10e18);
        vm.stopPrank();

        // Round 1 ends twelve blocks behind the fork's head and is answered.
        bytes32 intakeId = h.request(feedId);
        (OracleAttestation.Attestation memory a, bytes memory signature) = _attest(h, feedId, abi.encode(uint256(1)));
        assertEq(a.toBlock, head - 12);
        bytes memory args = abi.encode(intakeId, a, signature);
        address writer = INTAKE.writer();
        vm.prank(writer);
        INTAKE.complete(intakeId, 0, bytes32(0), "", args);
        (,,, uint64 round,) = h.latest(feedId);
        assertEq(round, 1, "the live Intake did not deliver the first answer");

        // 290 blocks pass with nobody asking. Round 2 covers the next six blocks, the most the feed
        // may ask about at once, which now end 296 blocks back: out of BLOCKHASH's reach, inside
        // the history contract's.
        vm.roll(head + 290);
        skip(58 minutes);
        assertEq(history.plain(head - 6), bytes32(0));
        assertEq(history.hashOf(head - 6), trueHash, "the history contract does not hold the true hash");
        h.newTransaction();
        h.request(feedId);
        (,, uint64 fromBlock, uint64 toBlock,) = h.roundOf(feedId, 2);
        assertEq(fromBlock, head - 11);
        assertEq(toBlock, head - 6);
        (,, bytes32 pinned,) = h.roundRequest(feedId, 2);
        assertEq(pinned, trueHash);
    }
}
