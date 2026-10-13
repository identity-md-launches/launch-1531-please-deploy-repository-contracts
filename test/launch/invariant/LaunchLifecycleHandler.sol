// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IQuestions} from "src/interfaces/IQuestions.sol";
import {Questions} from "src/questions/Questions.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/questions/OracleAttestation.sol";
import {Payroll} from "src/payroll/Payroll.sol";
import {JobsReport} from "src/payroll/JobsReport.sol";
import {QuestionsHarness} from "../../questions/mocks/QuestionsHarness.sol";
import {MockIntake} from "../../questions/mocks/MockIntake.sol";
import {MockSeats} from "../../payroll/mocks/MockSeats.sol";
import {LaunchFaultToken, LaunchClaimWallet} from "../LaunchStateSetup.sol";

/// @dev Inputs describe a closed economy: three funded actors, four movable seats, three real meters.
/// Ghost balances count only public calls, never storage edits. Unexpected reverts are test failures.
contract LaunchLifecycleHandler is Test {
    struct Environment {
        LaunchFaultToken token;
        MockIntake intake;
        QuestionsHarness questions;
        JobsReport report;
        Payroll payroll;
        MockSeats seats;
        LaunchClaimWallet wallet;
        address escrow;
        address writer;
        uint256 signerKey;
        bytes32[3] feeds;
        address[3] actors;
    }

    struct RoundModel {
        bytes32 intakeId;
        address opener;
        uint256 tip;
        IQuestions.RoundStatus status;
        bytes32 terminalHash;
        bytes answer;
    }

    Environment internal e;
    mapping(uint256 => RoundModel[]) internal rounds;
    mapping(address => uint256) public expectedBalance;
    mapping(address => uint256) public earned;
    mapping(address => uint256) public pendingTips;
    uint256[4] public unpaidTips;
    uint256[3] public answered;
    uint256 public entered;
    uint256 public exited;
    uint256 public intakePaid;
    uint256 public dripped;
    uint256 public payrollFunded;
    uint256 public requests;
    uint256 public failures;
    uint256 public rejectedAnswers;
    uint256 public recoveries;
    uint256 public nonce;

    constructor(Environment memory env) {
        e = env;
        for (uint256 i; i < 3; ++i) {
            expectedBalance[e.actors[i]] = e.token.balanceOf(e.actors[i]);
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return e.actors[seed % 3];
    }

    function _seat(uint256 index) private pure returns (uint256) {
        return index == 3 ? 1999 : index;
    }

    function _debit(address who, uint256 amount) private {
        entered += amount;
        expectedBalance[who] -= amount;
    }

    function _credit(address who, uint256 amount) private {
        // A seat owned by Payroll recycles its payout as unbooked revenue without leaving the system.
        if (who == address(e.payroll)) return;
        exited += amount;
        expectedBalance[who] += amount;
    }

    function pay(uint256 who, uint256 amount, bool donate) public {
        address actor = _actor(who);
        amount = bound(amount, 1, 100e18);
        vm.prank(actor);
        if (donate) e.token.transfer(address(e.payroll), amount);
        else e.payroll.pay(amount, bytes32("lifecycle"));
        _debit(actor, amount);
    }

    function book() public {
        e.payroll.book();
    }

    function tip(uint256 who, uint256 amount, uint256 seed) public {
        address actor = _actor(who);
        amount = bound(amount, 1, 10e18);
        uint256[] memory ids = new uint256[](seed % 7);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = (seed / 7 + i) % 4;
        }
        vm.prank(actor);
        e.payroll.tip(ids, amount);
        _debit(actor, amount);
        for (uint256 i; i < ids.length; ++i) {
            unpaidTips[ids[i]] += amount / ids.length;
        }
    }

    function topUp() public {
        uint256 beforePayroll = e.token.balanceOf(address(e.payroll));
        uint256 beforeQuestions = e.token.balanceOf(address(e.questions));
        (uint256 funded,) = e.payroll.fundFeeds();
        payrollFunded += funded;
        assertEq(e.token.balanceOf(address(e.payroll)) + funded, beforePayroll);
        assertEq(e.token.balanceOf(address(e.questions)), beforeQuestions + funded);
    }

    function sponsor(uint256 who, uint256 beneficiarySeed, uint256 index, uint256 amount) public {
        index %= 3;
        address actor = _actor(who);
        address beneficiary = beneficiarySeed % 4 == 3 ? address(e.payroll) : _actor(beneficiarySeed);
        amount = bound(amount, 1, 3e18);
        vm.prank(actor);
        e.questions.fundFor(e.feeds[index], amount, beneficiary);
        _debit(actor, amount);
    }

    function defund(uint256 who, uint256 index, uint256 seed, bool all) public {
        index %= 3;
        address actor = _actor(who);
        uint256 shares = e.questions.sharesOf(e.feeds[index], actor);
        if (shares == 0) {
            vm.expectRevert(Questions.NothingToDefund.selector);
            vm.prank(actor);
            e.questions.defund(e.feeds[index], type(uint256).max);
            return;
        }
        uint256 quote = e.questions.redeemable(e.feeds[index], actor);
        uint256 burned = all ? type(uint256).max : bound(seed, 1, shares);
        vm.prank(actor);
        uint256 got = e.questions.defund(e.feeds[index], burned);
        if (all) assertEq(got, quote, "full redemption differs from its quote");
        _credit(actor, got);
    }

    function request(uint256 index, uint256 keeperSeed) public {
        index %= 3;
        e.questions.newTransaction();
        e.intake.newTransaction();
        (bool ready, Questions.Blocker why, uint256 price,,) = e.questions.canRequest(e.feeds[index]);
        address keeper = _actor(keeperSeed);
        if (!ready) {
            vm.expectRevert(abi.encodeWithSelector(Questions.RequestBlocked.selector, why));
            vm.prank(keeper);
            e.questions.request(e.feeds[index]);
            return;
        }
        uint256 beforeKeeper = e.token.balanceOf(keeper);
        vm.prank(keeper);
        bytes32 id = e.questions.request(e.feeds[index]);
        assertEq(e.token.balanceOf(keeper), beforeKeeper, "request paid an unearned tip");
        uint256 held = e.questions.feedParams(e.feeds[index]).tip;
        rounds[index].push(RoundModel(id, keeper, held, IQuestions.RoundStatus.Pending, bytes32(0), ""));
        pendingTips[keeper] += held;
        intakePaid += price;
        ++requests;
    }

    function _pending(uint256 index) private view returns (bool) {
        uint256 n = rounds[index].length;
        return n != 0 && rounds[index][n - 1].status == IQuestions.RoundStatus.Pending;
    }

    function _answer(uint256 index, uint256 seed) private returns (OracleAttestation.Attestation memory a) {
        uint64 round = uint64(rounds[index].length);
        Questions.FeedParams memory p = e.questions.feedParams(e.feeds[index]);
        (, a.questionHash, a.blockHash,) = e.questions.roundRequest(e.feeds[index], round);
        (,, a.fromBlock, a.toBlock,) = e.questions.roundOf(e.feeds[index], round);
        a.requestId = keccak256(abi.encode("lifecycle oracle", ++nonce));
        a.chainId = 1;
        a.answerType = p.answerType;
        if (index == 2) {
            address[] memory list = new address[](seed % 4);
            for (uint256 i; i < list.length; ++i) {
                list[i] = e.actors[(seed / 4 + i) % 3];
            }
            a.answer = abi.encode(list);
        } else {
            a.answer = abi.encode(bound(seed, 0, index == 0 ? 1_000e18 : 1_000_000));
        }
        a.panelJobId = keccak256(abi.encode("lifecycle panel", nonce));
        a.panelSize = p.panelSize;
        a.quorum = p.quorum;
        a.agreed = p.quorum;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + p.validFor;
    }

    function _sign(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(e.signerKey, e.questions.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _roundHash(uint256 index, uint64 round) private view returns (bytes32) {
        (IQuestions.RoundStatus status, uint256 value, uint64 from, uint64 to, uint64 updated) =
            e.questions.roundOf(e.feeds[index], round);
        return keccak256(abi.encode(status, value, from, to, updated));
    }

    function answer(uint256 index, uint256 seed, bool recover) public {
        index %= 3;
        if (!_pending(index)) return;
        RoundModel storage r = rounds[index][rounds[index].length - 1];
        OracleAttestation.Attestation memory a = _answer(index, seed);
        bytes memory signature = _sign(a);
        // The actual panel-evidence employers feed permits callback delivery only.
        recover = recover && index != 2;
        if (recover) e.intake.setCallbackGas(40_000);
        vm.prank(e.writer);
        e.intake.complete(r.intakeId, 0, bytes32(0), "", abi.encode(r.intakeId, a, signature));
        if (recover) {
            assertFalse(e.intake.lastDelivered(), "missed-callback setup did not miss");
            e.intake.setCallbackGas(200_000);
            // Someone other than the opener recovers the answer, but never takes the opener's tip.
            e.questions.submit(e.feeds[index], a, signature);
            ++recoveries;
        } else {
            assertTrue(e.intake.lastDelivered(), "honest callback failed under 200,000 gas");
        }
        (IQuestions.RoundStatus status, uint256 value, uint64 from, uint64 to, uint64 updated) =
            e.questions.roundOf(e.feeds[index], uint64(rounds[index].length));
        assertEq(uint256(status), uint256(IQuestions.RoundStatus.Answered));
        assertEq(value, index == 2 ? uint256(keccak256(a.answer)) : abi.decode(a.answer, (uint256)));
        assertEq(from, a.fromBlock);
        assertEq(to, a.toBlock);
        assertEq(updated, vm.getBlockTimestamp());
        assertTrue(e.questions.consumed(a.requestId));
        assertTrue(e.questions.usedBy(a.requestId, e.feeds[index]));
        r.status = IQuestions.RoundStatus.Answered;
        r.answer = a.answer;
        r.terminalHash = _roundHash(index, uint64(rounds[index].length));
        pendingTips[r.opener] -= r.tip;
        earned[r.opener] += r.tip;
        ++answered[index];
    }

    /// @dev Signed-but-wrong data and unsigned tampering must leave the pending round recoverable.
    function rejectAnswer(uint256 index, uint256 seed, uint8 fault) public {
        index %= 3;
        if (!_pending(index)) return;
        RoundModel storage r = rounds[index][rounds[index].length - 1];
        OracleAttestation.Attestation memory a = _answer(index, seed);
        bytes32 beforeRound = _roundHash(index, uint64(rounds[index].length));
        bytes memory signature = _sign(a);
        bytes memory reason;
        fault %= 6;
        if (fault == 0) {
            a.figure = 1; // Modify a signed field without re-signing.
            reason = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
        } else {
            if (fault == 1) {
                a.chainId = 4663;
                reason = abi.encodeWithSelector(Questions.WrongChain.selector, uint256(1), uint256(4663));
            } else if (fault == 2) {
                bytes32 original = a.questionHash;
                a.questionHash ^= bytes32(uint256(1));
                reason = abi.encodeWithSelector(Questions.WrongQuestion.selector, original, a.questionHash);
            } else if (fault == 3) {
                ++a.toBlock;
                reason = abi.encodeWithSelector(Questions.WrongWindow.selector, a.fromBlock, a.toBlock);
            } else if (fault == 4) {
                a.agreed = a.quorum - 1;
                reason = abi.encodeWithSelector(Questions.NotEnoughAgreed.selector, a.agreed, a.quorum);
            } else {
                a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
                reason = abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt);
            }
            signature = _sign(a);
        }
        vm.expectRevert(reason);
        vm.prank(address(e.intake));
        e.questions.onOracleResult(r.intakeId, a, signature);
        assertEq(_roundHash(index, uint64(rounds[index].length)), beforeRound);
        assertEq(e.questions.feedOfRequest(r.intakeId), e.feeds[index]);
        assertFalse(e.questions.consumed(a.requestId));
        assertFalse(e.questions.usedBy(a.requestId, e.feeds[index]));
        ++rejectedAnswers;
    }

    function abandon(uint256 index, bool waitUntilDue) public {
        index %= 3;
        if (!_pending(index)) return;
        RoundModel storage r = rounds[index][rounds[index].length - 1];
        (, uint256 deadline) = e.questions.canAbandon(e.feeds[index]);
        if (waitUntilDue && vm.getBlockTimestamp() < deadline) {
            uint256 gap = deadline - vm.getBlockTimestamp();
            vm.warp(deadline);
            vm.roll(vm.getBlockNumber() + gap / 12 + 1);
        }
        if (vm.getBlockTimestamp() < deadline) {
            vm.expectRevert(abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, deadline));
            e.questions.abandon(e.feeds[index]);
            return;
        }
        (uint256 beforeMeter,) = e.questions.meterOf(e.feeds[index]);
        assertTrue(e.questions.abandon(e.feeds[index]));
        (uint256 afterMeter,) = e.questions.meterOf(e.feeds[index]);
        assertEq(afterMeter, beforeMeter + r.tip, "failed round did not return its reserved tip");
        pendingTips[r.opener] -= r.tip;
        r.status = IQuestions.RoundStatus.Failed;
        r.terminalHash = _roundHash(index, uint64(rounds[index].length));
        ++failures;
    }

    function collect(uint256 who) public {
        address actor = _actor(who);
        vm.prank(actor);
        uint256 got = e.questions.collectTips();
        assertEq(got, earned[actor]);
        earned[actor] = 0;
        _credit(actor, got);
    }

    function advance(uint256 seed) public {
        uint256[6] memory jumps = [uint256(12), 30 minutes, 12 hours, 7 days, 14 days, 181 days];
        uint256 elapsed = jumps[seed % 6];
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.roll(vm.getBlockNumber() + elapsed / 12);
    }

    function changePrice(uint256 seed) public {
        uint256[5] memory prices = [uint256(0), 1, 0.5e18, 2e18, 2e18 + 1];
        e.intake.setPrice(bytes32("oracle.request@oracle-1"), address(e.token), prices[seed % 5]);
    }

    function moveSeat(uint256 index, uint256 who) public {
        index %= 4;
        address[6] memory owners =
            [e.actors[0], e.actors[1], e.actors[2], address(e.wallet), e.escrow, address(e.payroll)];
        e.seats.setOwner(_seat(index), owners[who % 6]);
    }

    function claim(uint256 index, bool walletInitiates) public {
        index %= 4;
        uint256 seat = _seat(index);
        address owner = e.seats.ownerOf(seat);
        uint256 share = e.payroll.seatClaimable(seat);
        uint256 tipDue = unpaidTips[index];
        uint256 paid;
        if (owner == address(e.wallet) && walletInitiates) {
            paid = e.wallet.claim(e.payroll, seat, index);
        } else if (owner == e.escrow || owner == address(e.wallet)) {
            if (share != 0) vm.expectRevert(abi.encodeWithSelector(Payroll.ContractOwnerMustClaim.selector, owner));
            e.payroll.claimSeat(seat);
            if (tipDue != 0) vm.expectRevert(abi.encodeWithSelector(Payroll.ContractOwnerMustClaim.selector, owner));
            e.payroll.claimTip(index);
            return;
        } else {
            paid = e.payroll.claimSeat(seat) + e.payroll.claimTip(index);
        }
        assertEq(paid, share + tipDue);
        unpaidTips[index] = 0;
        _credit(owner, paid);
    }

    function drip() public {
        (,,,, uint256 next, uint256 due) = e.payroll.stream();
        if (vm.getBlockTimestamp() < next) {
            vm.expectRevert(abi.encodeWithSelector(Payroll.DripTooSoon.selector, next));
            e.payroll.drip();
            return;
        }
        uint256 sent = e.payroll.drip();
        assertEq(sent, due);
        dripped += sent;
        exited += sent;
    }

    function printReport() public {
        JobsReport.Summary memory before = e.report.summary();
        e.report.print();
        JobsReport.Summary memory after_ = e.report.summary();
        assertLe(after_.payrollsRead - before.payrollsRead + after_.hiresRead - before.hiresRead, 8);
        assertGe(after_.prints, before.prints);
        assertGe(after_.counts, before.counts);
    }

    function crown(uint256 seed, bool wrongBytes) public {
        uint256 n = rounds[2].length;
        if (n == 0) return;
        uint64 round = uint64(seed % n + 1);
        RoundModel storage r = rounds[2][round - 1];
        bytes memory answerBytes = wrongBytes ? bytes.concat(r.answer, hex"01") : r.answer;
        if (e.report.crownOf(round).crownedAt != 0) {
            vm.expectRevert(abi.encodeWithSelector(JobsReport.AlreadyCrowned.selector, round));
        } else if (r.status != IQuestions.RoundStatus.Answered) {
            vm.expectRevert(abi.encodeWithSelector(JobsReport.RoundNotAnswered.selector, round));
        } else if (wrongBytes) {
            vm.expectRevert(abi.encodeWithSelector(JobsReport.AnswerMismatch.selector, round));
        }
        e.report.crown(round, answerBytes);
        if (r.status == IQuestions.RoundStatus.Answered && !wrongBytes) {
            address[] memory list = abi.decode(r.answer, (address[]));
            JobsReport.Crown memory c = e.report.crownOf(round);
            assertEq(c.places, list.length);
            if (list.length != 0) assertEq(c.first, list[0]);
            if (list.length > 1) assertEq(c.second, list[1]);
            if (list.length > 2) assertEq(c.third, list[2]);
        }
    }

    function checkRounds() external view {
        for (uint256 i; i < 3; ++i) {
            assertEq(e.questions.roundCount(e.feeds[i]), rounds[i].length);
            for (uint256 j; j < rounds[i].length; ++j) {
                RoundModel storage r = rounds[i][j];
                (IQuestions.RoundStatus actual,,,,) = e.questions.roundOf(e.feeds[i], uint64(j + 1));
                assertEq(uint256(actual), uint256(r.status));
                if (r.status == IQuestions.RoundStatus.Pending) {
                    assertEq(j + 1, rounds[i].length);
                    assertEq(e.questions.feedOfRequest(r.intakeId), e.feeds[i]);
                } else {
                    assertEq(_roundHash(i, uint64(j + 1)), r.terminalHash, "terminal round changed");
                    assertEq(e.questions.feedOfRequest(r.intakeId), bytes32(0));
                }
            }
        }
        (uint256 unearned, uint256 unrequested) = e.questions.tipsOf(address(this));
        assertEq(unearned + unrequested, 0, "recovery caller took the opener's tip");
    }

    function finish() external {
        // Drain the bounded report queue; every accepted daily answer must eventually be printed.
        uint256 calls = (rounds[0].length + rounds[1].length) / 8 + 2;
        for (uint256 i; i < calls; ++i) {
            e.report.print();
        }
        assertEq(e.report.printCount(), answered[0]);
        assertEq(e.report.countsRecorded(), answered[1]);
        // Every actual funder can redeem from the final state even with rounds still pending.
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                defund(j, i, 0, true);
            }
        }
    }
}
