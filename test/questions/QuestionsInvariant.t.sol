// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IQuestions} from "../../src/interfaces/IQuestions.sol";
import {OracleAttestation} from "../../src/questions/OracleAttestation.sol";
import {Questions} from "../../src/questions/Questions.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {GateTarget} from "./mocks/Oddities.sol";
import {QuestionsHarness} from "./mocks/QuestionsHarness.sol";

/// @dev Everyone who can touch Questions, acting at random: funders, keepers, an oracle that
/// answers honestly, someone who presents old answers again, someone who opens a copy of a feed to
/// take its answer first, an Intake that refuses, and time.
///
/// The handler also keeps its own book of keeper tips, from nothing but what it saw happen: a tip
/// is set aside when a round opens, earned by the round's keeper when the Intake delivers the
/// answer, earned by the handler itself when it hands an answer in through `submit`, and gone from
/// the keeper's book when the round is closed without an answer. The contract's book must agree
/// with it for every address at every step.
contract QuestionsHandler is Test {
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    address internal constant PAY_TO = address(0x4E0F);
    address internal constant WRITER = address(0x3D3C);

    QuestionsHarness public q;
    MockIMD public imd;
    MockIntake public intake;
    GateTarget public gate;
    uint256 internal oracleKey;

    bytes32[] public feeds;
    address[] public funders;
    address[] public keepers;

    struct Saved {
        bytes32 feedId;
        OracleAttestation.Attestation a;
        bytes signature;
    }

    Saved[] internal accepted;
    /// @dev Which feeds each attestation has answered, as the handler saw it happen.
    mapping(bytes32 oracleRequestId => mapping(bytes32 feedId => bool)) internal took;
    mapping(bytes32 feedId => bool) internal known;

    // Ghosts.
    uint256 public funded;
    uint256 public defunded;
    uint256 public donated;
    uint256 public answers;
    uint256 public failures;
    uint256 public requests;
    uint256 public waitsStarted;
    /// @dev Answers that went to a second feed asking the same question about the same blocks.
    uint256 public sharedAnswers;
    uint256 public twins;
    bool public replayAccepted;
    bool public defundBroken;
    /// @dev Set if `fundFor` ever left the beneficiary short or cost the payer part of its own position.
    bool public fundForBroken;
    /// @dev Set if a feed was ever refused the honest answer to the request it paid for.
    bool public paidAnswerLost;

    // The handler's own book of keeper tips.
    mapping(address who => uint256) public tipsEarned;
    mapping(address who => uint256) public tipsPending;
    mapping(bytes32 feedId => address) internal keeperOf;
    mapping(bytes32 feedId => uint256) internal tipHeldFor;
    /// @dev Tips paid out by `collectTips`, tips earned by an answer, tips given back to a meter.
    uint256 public tipsCollected;
    uint256 public tipsEarnedInAll;
    uint256 public tipsEarnedThroughSubmit;
    uint256 public tipsReturned;
    /// @dev Set if `collectTips` ever paid anything but what the handler's book said was earned.
    bool public collectBroken;

    constructor(QuestionsHarness q_, MockIMD imd_, MockIntake intake_, GateTarget gate_, uint256 oracleKey_) {
        (q, imd, intake, gate, oracleKey) = (q_, imd_, intake_, gate_, oracleKey_);
        for (uint256 i; i < 4; ++i) {
            address funder = makeAddr(string.concat("funder ", vm.toString(i)));
            funders.push(funder);
            imd.mint(funder, 1000e18);
            vm.prank(funder);
            imd.approve(address(q), type(uint256).max);
        }
        keepers.push(makeAddr("keeper 0"));
        keepers.push(makeAddr("keeper 1"));
    }

    function addFeed(bytes32 feedId) public {
        if (known[feedId]) return;
        known[feedId] = true;
        feeds.push(feedId);
    }

    function feedCount() external view returns (uint256) {
        return feeds.length;
    }

    function funderCount() external view returns (uint256) {
        return funders.length;
    }

    function keeperCount() external view returns (uint256) {
        return keepers.length;
    }

    function acceptedCount() external view returns (uint256) {
        return accepted.length;
    }

    function acceptedId(uint256 i) external view returns (bytes32) {
        return accepted[i].a.requestId;
    }

    function acceptedFeed(uint256 i) external view returns (bytes32) {
        return accepted[i].feedId;
    }

    /// @dev Records that a feed stored an answer from this attestation. A feed taking the same
    /// attestation a second time is what Q2 forbids. The round's tip is earned with the answer: by
    /// the keeper that opened the round, whether delivered or submitted.
    function _accept(bytes32 feedId, OracleAttestation.Attestation memory a, bytes memory signature, bool bySubmit)
        internal
    {
        if (took[a.requestId][feedId]) replayAccepted = true;
        took[a.requestId][feedId] = true;
        ++answers;
        accepted.push(Saved(feedId, a, signature));

        uint256 tip = tipHeldFor[feedId];
        if (tip != 0) {
            tipsPending[keeperOf[feedId]] -= tip;
            tipsEarned[keeperOf[feedId]] += tip;
            tipsEarnedInAll += tip;
            if (bySubmit) tipsEarnedThroughSubmit += tip;
            tipHeldFor[feedId] = 0;
        }
    }

    /// @dev Records that a round was opened by `keeper`: the feed's tip is set aside for it.
    function _opened(bytes32 feedId, address keeper) internal {
        uint256 tip = q.feedParams(feedId).tip;
        keeperOf[feedId] = keeper;
        tipHeldFor[feedId] = tip;
        tipsPending[keeper] += tip;
        ++requests;
    }

    function _feed(uint256 seed) internal view returns (bytes32) {
        return feeds[seed % feeds.length];
    }

    // ---- actions --------------------------------------------------------------------------------

    function fund(uint256 funderSeed, uint256 feedSeed, uint256 amount) external {
        address funder = funders[funderSeed % funders.length];
        // Mostly amounts near one round's cost, so meters keep running out and being refilled.
        amount = bound(amount, 1, amount % 5 == 0 ? 20e18 : 0.6e18);
        if (imd.balanceOf(funder) < amount) return;
        vm.prank(funder);
        q.fund(_feed(feedSeed), amount);
        funded += amount;
    }

    /// @dev One funder pays, another gets the shares.
    function fundFor(uint256 payerSeed, uint256 beneficiarySeed, uint256 feedSeed, uint256 amount) external {
        address payer = funders[payerSeed % funders.length];
        address beneficiary = funders[beneficiarySeed % funders.length];
        amount = bound(amount, 1, 2e18);
        if (imd.balanceOf(payer) < amount) return;
        bytes32 feedId = _feed(feedSeed);
        uint256 payerBefore = q.redeemable(feedId, payer);
        uint256 beneficiaryBefore = q.redeemable(feedId, beneficiary);
        vm.prank(payer);
        q.fundFor(feedId, amount, beneficiary);
        funded += amount;
        // What was paid in is the beneficiary's to take out, less rounding dust, and paying for
        // somebody else takes nothing from what the payer could already take out.
        if (q.redeemable(feedId, beneficiary) + 2 < beneficiaryBefore + amount) fundForBroken = true;
        if (payer != beneficiary && q.redeemable(feedId, payer) + 1 < payerBefore) fundForBroken = true;
    }

    function defund(uint256 funderSeed, uint256 feedSeed, uint256 shares) external {
        address funder = funders[funderSeed % funders.length];
        bytes32 feedId = _feed(feedSeed);
        uint256 mine = q.sharesOf(feedId, funder);
        if (mine == 0) return;
        shares = bound(shares, 1, mine);
        uint256 quoted = shares == mine ? q.redeemable(feedId, funder) : 0;
        vm.prank(funder);
        try q.defund(feedId, shares) returns (uint256 amount) {
            defunded += amount;
            if (shares == mine && amount != quoted) defundBroken = true;
        } catch {
            // A holder of shares can always defund: any revert here breaks the invariant.
            defundBroken = true;
        }
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e18);
        imd.mint(address(q), amount);
        donated += amount;
    }

    function pass(uint256 blocks, uint256 secs) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 40));
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 hours));
    }

    function movePrice(uint256 seed) external {
        // Sometimes above the feeds' cap of 1 IMD, sometimes not sold at all.
        uint256[5] memory prices = [uint256(0.5e18), 0.5e18, 0.25e18, 1.2e18, 0];
        intake.setPrice(ACTION, address(imd), prices[seed % prices.length]);
    }

    function moveGate(uint256 value) external {
        gate.set(value % 3);
    }

    function request(uint256 feedSeed, uint256 keeperSeed) external {
        q.newTransaction();
        intake.newTransaction();
        address keeper = keepers[keeperSeed % keepers.length];
        bytes32 feedId = _feed(feedSeed);
        uint256 keeperBefore = imd.balanceOf(keeper);
        vm.prank(keeper);
        try q.request(feedId) {
            _opened(feedId, keeper);
            // Asking pays nothing.
            if (imd.balanceOf(keeper) != keeperBefore) collectBroken = true;
        } catch {}
    }

    /// @dev A keeper, or this handler (which earns nothing merely for submitting), takes out what
    /// it has earned. It must be paid exactly what the handler's book says, and nothing that is
    /// still set aside for a pending round.
    function collect(uint256 whoSeed) external {
        address who =
            whoSeed % (keepers.length + 1) == keepers.length ? address(this) : keepers[whoSeed % keepers.length];
        uint256 before = imd.balanceOf(who);
        vm.prank(who);
        uint256 amount = q.collectTips();
        if (amount != tipsEarned[who] || imd.balanceOf(who) != before + amount) collectBroken = true;
        tipsEarned[who] = 0;
        tipsCollected += amount;
    }

    /// @dev What an honest oracle signs for the feed's pending round.
    function _honest(bytes32 feedId, uint64 round, uint256 valueSeed, uint8 agreedSeed)
        internal
        view
        returns (OracleAttestation.Attestation memory a, bytes memory signature)
    {
        Questions.FeedParams memory p = q.feedParams(feedId);
        (, bytes32 questionHash, bytes32 blockHash,) = q.roundRequest(feedId, round);
        (,, uint64 fromBlock, uint64 toBlock,) = q.roundOf(feedId, round);
        a = OracleAttestation.Attestation({
            requestId: bytes32(bytes16(keccak256(abi.encode("oracle", requests, answers, failures, waitsStarted)))),
            chainId: p.chainId,
            questionHash: p.pinHash ? questionHash : keccak256(abi.encode("unpinned", valueSeed)),
            answerType: p.answerType,
            answer: _answerOf(p.answerType, valueSeed),
            figure: valueSeed,
            fromBlock: fromBlock,
            toBlock: toBlock,
            blockHash: blockHash,
            panelJobId: bytes32(uint256(1)),
            panelSize: p.panelSize,
            quorum: p.quorum,
            // Between the feed's floor and the whole panel.
            agreed: uint16(bound(agreedSeed, p.minAgreed, p.panelSize)),
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + p.validFor
        });
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(oracleKey, q.attestationDigest(a));
        signature = abi.encodePacked(sr, ss, sv);
    }

    /// @dev The Intake's writer completes a request with an answer. With `miss` the callback is
    /// given too little gas to run to the end, as after the Intake's owner lowered the stipend.
    function _deliver(bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory signature, bool miss)
        internal
        returns (bool delivered)
    {
        if (miss) intake.setCallbackGas(40_000);
        vm.prank(WRITER);
        intake.complete(intakeId, 0, bytes32(0), "", abi.encode(intakeId, a, signature));
        delivered = intake.lastDelivered();
        if (miss) intake.setCallbackGas(200_000);
    }

    /// @dev The oracle answers the pending round honestly. The answer arrives through the Intake's
    /// callback or, for a pinned feed, the callback is missed and somebody hands it in with `submit`.
    function answer(uint256 feedSeed, uint256 valueSeed, bool bySubmit, uint8 agreedSeed) external {
        bytes32 feedId = _feed(feedSeed);
        Questions.FeedView memory v = q.feedState(feedId);
        if (!v.pending) return;
        (OracleAttestation.Attestation memory a, bytes memory signature) =
            _honest(feedId, v.rounds, valueSeed, agreedSeed);

        bool stored;
        (,,, bool completed) = intake.requests(v.pendingRequestId);
        bool submitted;
        if (bySubmit && q.feedParams(feedId).pinHash) {
            if (!completed) stored = _deliver(v.pendingRequestId, a, signature, true);
            if (!stored) {
                try q.submit(feedId, a, signature) {
                    (stored, submitted) = (true, true);
                } catch {
                    // The Intake has completed the request and the answer is honest and fresh:
                    // nothing may keep it out.
                    paidAnswerLost = true;
                }
            }
        } else if (!completed) {
            stored = _deliver(v.pendingRequestId, a, signature, false);
            if (!stored) paidAnswerLost = true;
        }
        if (stored) _accept(feedId, a, signature, submitted);
    }

    /// @dev Somebody opens a copy of a pinned feed's pending question: the same text about the same
    /// blocks, with no tip and the lowest floor for agreement. The copy's own request is refused,
    /// which opens `submit` on it, and the honest answer to the first feed's request is handed to
    /// the copy before the Intake delivers it to the feed that paid for it. That delivery must
    /// still succeed.
    function twin(uint256 feedSeed, uint256 valueSeed, uint8 agreedSeed, bool missCallback) external {
        bytes32 feedId = _feed(feedSeed);
        Questions.FeedView memory v = q.feedState(feedId);
        if (!v.pending) return;
        Questions.FeedParams memory p = q.feedParams(feedId);
        (,,, bool completed) = intake.requests(v.pendingRequestId);
        if (!p.pinHash || completed) return;
        (,, uint64 fromBlock, uint64 toBlock,) = q.roundOf(feedId, v.rounds);
        uint256 lag = vm.getBlockNumber() - toBlock;
        uint256 price = intake.priceOf(ACTION, address(imd));
        if (lag > 256 || price == 0 || price > p.maxPrice || imd.balanceOf(funders[0]) < price) return;

        // The copy: not contiguous, exactly as long as the first feed's window, ending where it ends.
        (bytes memory qPrefix, bytes memory tail) = q.feedText(feedId);
        (p.contiguous, p.cadenceBlocks, p.maxWindowBlocks, p.lagBlocks) =
        (false, 1, uint32(toBlock - fromBlock + 1), uint16(lag));
        (p.minAgreed, p.tip) = (1, 0);
        (p.gateTarget, p.gateCmp, p.gateThreshold, p.gateData) = (address(0), 0, 0, "");
        bytes32 twinId = q.createFeed(p, qPrefix, tail);
        addFeed(twinId);
        if (q.feedState(twinId).pending) return;
        vm.prank(funders[0]);
        q.fund(twinId, price);
        funded += price;
        q.newTransaction();
        intake.newTransaction();
        vm.prank(keepers[0]);
        try q.request(twinId) returns (bytes32 twinIntakeId) {
            _opened(twinId, keepers[0]);
            ++twins;
            vm.prank(WRITER);
            intake.complete(twinIntakeId, 1, bytes32(0), "", "");
        } catch {
            return;
        }

        (OracleAttestation.Attestation memory a, bytes memory signature) =
            _honest(feedId, v.rounds, valueSeed, agreedSeed);
        try q.submit(twinId, a, signature) {
            ++sharedAnswers;
            _accept(twinId, a, signature, true);
        } catch {}

        // The feed that paid for the answer is now given it: by the callback, or by `submit` after
        // a missed callback.
        bool stored = _deliver(v.pendingRequestId, a, signature, missCallback);
        bool submitted;
        if (!stored && missCallback) {
            try q.submit(feedId, a, signature) {
                (stored, submitted) = (true, true);
            } catch {}
        }
        if (stored) _accept(feedId, a, signature, submitted);
        else paidAnswerLost = true;
    }

    /// @dev Someone presents an answer that was already accepted, to any feed with a pending round.
    /// The feed it answered before must refuse it. Another feed may take it, once, if it asked the
    /// same question about the same blocks.
    function replay(uint256 savedSeed, uint256 feedSeed, bool bySubmit) external {
        if (accepted.length == 0) return;
        Saved memory s = accepted[savedSeed % accepted.length];
        bytes32 feedId = _feed(feedSeed);
        Questions.FeedView memory v = q.feedState(feedId);
        if (!v.pending) return;
        bool stored;
        if (bySubmit) {
            try q.submit(feedId, s.a, s.signature) {
                stored = true;
            } catch {}
        } else {
            vm.prank(address(intake));
            try q.onOracleResult(v.pendingRequestId, s.a, s.signature) {
                stored = true;
            } catch {}
        }
        if (stored) {
            if (!took[s.a.requestId][feedId]) ++sharedAnswers;
            _accept(feedId, s.a, s.signature, bySubmit);
        }
    }

    /// @dev The Intake completes the pending request as refused or unanswered: no callback.
    function refuse(uint256 feedSeed, bool unanswered) external {
        Questions.FeedView memory v = q.feedState(_feed(feedSeed));
        if (!v.pending) return;
        (,,, bool completed) = intake.requests(v.pendingRequestId);
        if (completed) return;
        vm.prank(WRITER);
        intake.complete(v.pendingRequestId, unanswered ? 2 : 1, bytes32(0), "", "");
    }

    /// @dev Anyone tries to close a feed's pending round, with `wait` after the silence that lets
    /// any round be closed. A call that only starts the thirty minutes closes nothing.
    function abandon(uint256 feedSeed, bool wait) external {
        bytes32 feedId = _feed(feedSeed);
        if (wait) {
            vm.warp(
                vm.getBlockTimestamp() + q.ABANDON_AFTER_SILENCE() + q.feedParams(feedId).validFor
                    + q.ISSUED_AT_TOLERANCE() + 1
            );
        }
        (uint256 meterBefore,) = q.meterOf(feedId);
        try q.abandon(feedId) returns (bool closed) {
            if (closed) {
                ++failures;
                // The tip set aside for the round is back on the meter and off the keeper's book.
                uint256 tip = tipHeldFor[feedId];
                tipsPending[keeperOf[feedId]] -= tip;
                tipsReturned += tip;
                tipHeldFor[feedId] = 0;
                (uint256 meterAfter,) = q.meterOf(feedId);
                if (meterAfter != meterBefore + tip) collectBroken = true;
            } else {
                ++waitsStarted;
            }
        } catch {}
    }

    function _answerOf(uint8 answerType, uint256 seed) internal pure returns (bytes memory) {
        if (answerType == OracleAttestation.ANSWER_BOOL) return abi.encode(seed % 2 == 0);
        if (answerType == OracleAttestation.ANSWER_ADDRESS_LIST) {
            address[] memory list = new address[](seed % 4);
            for (uint256 i; i < list.length; ++i) {
                list[i] = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            }
            return abi.encode(list);
        }
        return abi.encode(seed);
    }
}

/// @title What must hold whatever anyone does
/// @notice Q1: a feed has at most one pending round, and it is its newest. Q2: an attestation
/// answers at most one round of a feed, and a feed is never refused the honest answer to the
/// request it paid for, whatever was done with that answer on another feed. Q3: a contiguous
/// feed's answered windows tile with no gap and no overlap. Meters: together with the keeper tips
/// held they add up to what the contract holds, a share is never worth more than a wei, and every
/// holder can take their part out at any time. Tips: a keeper is owed exactly the tips of the
/// rounds that were answered, never one for asking alone.
contract QuestionsInvariantTest is Test {
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    address internal constant PAY_TO = address(0x4E0F);

    QuestionsHarness internal q;
    MockIMD internal imd;
    MockIntake internal intake;
    GateTarget internal gate;
    QuestionsHandler internal handler;

    function setUp() public {
        vm.roll(26_200_000);
        vm.warp(1_791_600_000);
        (address oracle, uint256 oracleKey) = makeAddrAndKey("oracle signer");
        imd = new MockIMD();
        intake = new MockIntake(PAY_TO, address(0x3D3C));
        intake.setPrice(ACTION, address(imd), 0.5e18);
        q = new QuestionsHarness(address(intake), address(imd), oracle);
        gate = new GateTarget();
        gate.set(1);
        handler = new QuestionsHandler(q, imd, intake, gate, oracleKey);

        // A: a contiguous, pinned sum. B: a rolling, unpinned yes/no. C: a contiguous, pinned list
        // that accepts rerun-settled answers and whose windows are often cut. D: A behind a gate.
        handler.addFeed(_create(OracleAttestation.ANSWER_UINT256, "uint256", 5, 50, true, true, 5, address(0)));
        handler.addFeed(_create(OracleAttestation.ANSWER_BOOL, "bool", 3, 20, false, false, 5, address(0)));
        handler.addFeed(_create(OracleAttestation.ANSWER_ADDRESS_LIST, "address[]", 7, 10, true, true, 3, address(0)));
        handler.addFeed(_create(OracleAttestation.ANSWER_UINT256, "uint256", 5, 50, true, true, 5, address(gate)));

        // Every meter starts with enough for a few rounds, so runs reach requests and answers early.
        for (uint256 i; i < handler.feedCount(); ++i) {
            handler.fund(i, i, 10e18);
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = QuestionsHandler.fund.selector;
        selectors[1] = QuestionsHandler.defund.selector;
        selectors[2] = QuestionsHandler.donate.selector;
        selectors[3] = QuestionsHandler.pass.selector;
        selectors[4] = QuestionsHandler.movePrice.selector;
        selectors[5] = QuestionsHandler.moveGate.selector;
        selectors[6] = QuestionsHandler.request.selector;
        selectors[7] = QuestionsHandler.answer.selector;
        selectors[8] = QuestionsHandler.replay.selector;
        selectors[9] = QuestionsHandler.refuse.selector;
        selectors[10] = QuestionsHandler.abandon.selector;
        selectors[11] = QuestionsHandler.fundFor.selector;
        selectors[12] = QuestionsHandler.twin.selector;
        selectors[13] = QuestionsHandler.collect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _create(
        uint8 answerType,
        string memory typeName,
        uint32 cadence,
        uint32 maxWindow,
        bool contiguous,
        bool pinHash,
        uint16 minAgreed,
        address gateTarget
    ) internal returns (bytes32) {
        Questions.FeedParams memory p;
        p.action = ACTION;
        p.chainId = uint64(vm.getChainId());
        p.answerType = answerType;
        (p.panelSize, p.quorum, p.minAgreed) = (7, 5, minAgreed);
        p.validFor = 86_400;
        (p.cadenceBlocks, p.maxWindowBlocks, p.lagBlocks) = (cadence, maxWindow, 12);
        (p.contiguous, p.pinHash) = (contiguous, pinHash);
        (p.maxPrice, p.tip) = (1e18, 0.01e18);
        if (gateTarget != address(0)) {
            (p.gateTarget, p.gateCmp, p.gateThreshold) = (gateTarget, 1, 1);
            p.gateData = abi.encodeCall(GateTarget.value, ());
        }
        bytes memory prefix = bytes(
            string.concat(
                '{"answerType":"',
                typeName,
                '","chainId":',
                vm.toString(vm.getChainId()),
                ',"question":"A standing question?","v":1,"window":{"fromBlock":'
            )
        );
        return q.createFeed(p, prefix, ',"panelSize":7,"quorum":5,"validForSeconds":86400}');
    }

    /// @notice The handler is not idle: a fixed sequence reaches answered, failed and pending
    /// rounds on every feed, an answer through `submit`, a round closed in two steps, an answer
    /// shared with a copy of a feed before the feed that paid for it got it, refused replays and a
    /// spent meter, and every invariant holds at the end of it.
    function test_handlerReachesEveryState() public {
        uint256 houseFeeds = handler.feedCount();
        for (uint256 lap; lap < 6; ++lap) {
            for (uint256 f; f < houseFeeds; ++f) {
                handler.request(f, lap);
                handler.replay(lap, f, lap % 2 == 0);
                if ((lap + f) % 3 == 0) {
                    handler.refuse(f, lap % 2 == 0);
                    if (lap % 2 == 0) {
                        // Two steps: the first call starts the thirty minutes, the second closes.
                        handler.abandon(f, false);
                        handler.pass(1, q.ABANDON_AFTER_COMPLETED());
                        handler.abandon(f, false);
                    } else {
                        handler.abandon(f, true);
                    }
                } else if ((lap + f) % 3 == 1) {
                    handler.pass(3, 1 minutes);
                    handler.twin(f, 2000 + lap * 10 + f, uint8(lap), lap % 2 == 0);
                    handler.answer(f, 1000 + lap * 10 + f, lap % 2 == 1, uint8(lap));
                } else {
                    handler.answer(f, 1000 + lap * 10 + f, lap % 2 == 1, uint8(lap));
                }
                handler.defund(f, f, 1e17);
                handler.fund(lap, f, 3e18 + lap);
                handler.fundFor(lap, lap + f + 1, f, 1e17 + f);
            }
            // The two keepers take out what they have earned.
            if (lap % 2 == 1) handler.collect(lap / 2 % 2);
            handler.donate(1e17);
            handler.pass(40, 1 hours);
            handler.pass(40, 1 hours);
        }
        handler.request(0, 0);

        assertGt(handler.requests(), 12, "few requests went through");
        assertGt(handler.answers(), 6, "few answers were stored");
        assertGt(handler.failures(), 3, "few rounds failed");
        assertGt(handler.waitsStarted(), 1, "no round was closed in two steps");
        assertGt(handler.twins(), 2, "few copies of a feed were opened");
        assertGt(handler.sharedAnswers(), 2, "few answers were shared between two feeds");
        assertGt(handler.donated(), 0);
        assertGt(handler.tipsCollected(), 0, "no keeper collected a tip");
        assertGt(handler.tipsReturned(), 0, "no failed round gave its tip back");
        assertGt(handler.tipsEarnedThroughSubmit(), 0, "no opener earned a tip through submission");
        assertEq(handler.tipsEarned(address(handler)), 0, "a submitter took an opener's tip");
        assertGt(q.totalTips(), 0, "no tip is set aside or waiting to be collected");
        assertTrue(q.feedState(handler.feeds(0)).pending);
        for (uint256 f; f < houseFeeds; ++f) {
            assertGt(q.roundCount(handler.feeds(f)), 2);
            (,,, uint64 latestRound,) = q.latest(handler.feeds(f));
            assertGt(latestRound, 0, "a feed never got an answer");
        }

        invariant_Q1_onePendingRoundPerFeed();
        invariant_Q2_eachAttestationAnswersAFeedOnce();
        invariant_Q3_contiguousWindowsTile();
        invariant_metersAddUpToTheContractsBalance();
        invariant_tipsAreOwedForAnswersOnly();
        invariant_sharesNeverClaimMoreThanTheMeter();
        invariant_everyHolderCanAlwaysDefund();
    }

    /// @notice Q1: one pending round per feed, always the newest, and exactly one Intake request
    /// id points at a feed while its round is pending.
    function invariant_Q1_onePendingRoundPerFeed() public view {
        for (uint256 i; i < handler.feedCount(); ++i) {
            bytes32 feedId = handler.feeds(i);
            Questions.FeedView memory v = q.feedState(feedId);
            uint64 rounds = q.roundCount(feedId);
            uint256 pending;
            for (uint64 r = 1; r <= rounds; ++r) {
                (IQuestions.RoundStatus status,,,,) = q.roundOf(feedId, r);
                assertTrue(status != IQuestions.RoundStatus.None, "a round that was opened reads as none");
                if (status == IQuestions.RoundStatus.Pending) {
                    ++pending;
                    assertEq(r, rounds, "an older round is still pending");
                }
            }
            assertEq(pending, v.pending ? 1 : 0);
            if (v.pending) {
                assertEq(q.feedOfRequest(v.pendingRequestId), feedId);
            } else {
                assertEq(v.pendingRequestId, bytes32(0));
            }
            (IQuestions.RoundStatus beyond,,,,) = q.roundOf(feedId, rounds + 1);
            assertEq(uint8(beyond), uint8(IQuestions.RoundStatus.None));
        }
    }

    /// @notice Q2: an attestation answers a feed at most once. No feed ever took one it had taken
    /// before, the answered rounds are exactly the acceptances the handler saw, and the contract's
    /// own records say the same. And the other half: no feed was ever refused the honest answer to
    /// the request it paid for, whatever was done with that answer on another feed first.
    function invariant_Q2_eachAttestationAnswersAFeedOnce() public view {
        assertFalse(handler.replayAccepted(), "a feed accepted the same attestation twice");
        assertFalse(handler.paidAnswerLost(), "a feed was refused the answer it paid for");
        uint256 answered;
        for (uint256 i; i < handler.feedCount(); ++i) {
            bytes32 feedId = handler.feeds(i);
            uint64 rounds = q.roundCount(feedId);
            for (uint64 r = 1; r <= rounds; ++r) {
                (IQuestions.RoundStatus status,,,,) = q.roundOf(feedId, r);
                if (status == IQuestions.RoundStatus.Answered) ++answered;
            }
        }
        assertEq(answered, handler.answers());
        assertEq(answered, handler.acceptedCount());
        for (uint256 i; i < handler.acceptedCount(); ++i) {
            assertTrue(q.consumed(handler.acceptedId(i)));
            assertTrue(q.usedBy(handler.acceptedId(i), handler.acceptedFeed(i)));
        }
    }

    /// @notice Q3: for a contiguous feed, each answered window starts at the block after the one
    /// before it ended, so no block is counted twice and none is skipped. Every window, of any
    /// feed, is well formed and no longer than the feed allows.
    function invariant_Q3_contiguousWindowsTile() public view {
        for (uint256 i; i < handler.feedCount(); ++i) {
            bytes32 feedId = handler.feeds(i);
            Questions.FeedParams memory p = q.feedParams(feedId);
            uint64 rounds = q.roundCount(feedId);
            uint64 lastTo;
            bool any;
            for (uint64 r = 1; r <= rounds; ++r) {
                (IQuestions.RoundStatus status,, uint64 fromBlock, uint64 toBlock,) = q.roundOf(feedId, r);
                assertLe(fromBlock, toBlock);
                assertLe(uint256(toBlock) - fromBlock + 1, p.maxWindowBlocks);
                if (status != IQuestions.RoundStatus.Answered) continue;
                if (p.contiguous && any) assertEq(fromBlock, lastTo + 1, "contiguous windows do not tile");
                (lastTo, any) = (toBlock, true);
            }
            (,, uint64 latestTo, uint64 latestRound,) = q.latest(feedId);
            assertEq(latestTo, lastTo);
            assertEq(latestRound != 0, any);
            assertEq(q.feedState(feedId).lastToBlock, lastTo);
        }
    }

    /// @notice The meters add up: to `totalMetered`; with the keeper tips held, to what the
    /// contract holds less what was sent to it by plain transfer; and to everything funded less
    /// everything taken back, paid to the Intake, collected by a keeper or still held as a tip.
    /// Not a wei is made or lost.
    function invariant_metersAddUpToTheContractsBalance() public view {
        uint256 sum;
        for (uint256 i; i < handler.feedCount(); ++i) {
            (uint256 balance,) = q.meterOf(handler.feeds(i));
            sum += balance;
        }
        assertEq(sum, q.totalMetered());
        assertEq(imd.balanceOf(address(q)), sum + q.totalTips() + handler.donated());
        // What keepers hold is exactly what they collected: nothing reaches them any other way.
        uint256 paidOut = imd.balanceOf(address(handler));
        for (uint256 k; k < handler.keeperCount(); ++k) {
            paidOut += imd.balanceOf(handler.keepers(k));
        }
        assertEq(paidOut, handler.tipsCollected());
        assertEq(
            handler.funded() - handler.defunded() - imd.balanceOf(PAY_TO) - handler.tipsCollected() - q.totalTips(), sum
        );
        assertEq(imd.allowance(address(q), address(intake)), 0);
    }

    /// @notice Tips: the contract's book agrees with the handler's for every address. What an
    /// address has earned is the tips of the answered rounds it opened or handed the answer in
    /// for, less what it collected; what is pending for it is the tips of the rounds it opened that
    /// have no outcome yet; a round closed without an answer leaves its keeper nothing. The total
    /// held is the sum of the two over everyone, and it equals what was earned and not collected
    /// plus what is set aside.
    function invariant_tipsAreOwedForAnswersOnly() public view {
        assertFalse(handler.collectBroken(), "a keeper was paid for asking, or collected another amount than it earned");
        uint256 earnedSum;
        uint256 pendingSum;
        for (uint256 k; k <= handler.keeperCount(); ++k) {
            address who = k == handler.keeperCount() ? address(handler) : handler.keepers(k);
            (uint256 earned, uint256 pending) = q.tipsOf(who);
            assertEq(earned, handler.tipsEarned(who), "earned tips differ from the rounds that were answered");
            assertEq(pending, handler.tipsPending(who), "pending tips differ from the rounds still open");
            earnedSum += earned;
            pendingSum += pending;
        }
        assertEq(q.totalTips(), earnedSum + pendingSum);
        assertEq(earnedSum, handler.tipsEarnedInAll() - handler.tipsCollected());
    }

    /// @notice Shares: never worth more than a wei each, never adding up to more than the total,
    /// and never redeemable for more than the meter holds.
    function invariant_sharesNeverClaimMoreThanTheMeter() public view {
        assertFalse(handler.fundForBroken(), "fundFor left the beneficiary short or took from the payer");
        for (uint256 i; i < handler.feedCount(); ++i) {
            bytes32 feedId = handler.feeds(i);
            (uint256 balance, uint256 totalShares) = q.meterOf(feedId);
            assertGe(totalShares, balance, "a share is worth more than a wei");
            uint256 held;
            uint256 claims;
            for (uint256 k; k < handler.funderCount(); ++k) {
                held += q.sharesOf(feedId, handler.funders(k));
                claims += q.redeemable(feedId, handler.funders(k));
            }
            assertLe(held, totalShares);
            assertLe(claims, balance);
        }
    }

    /// @notice Shares are always redeemable: from any state, every holder can take out exactly what
    /// `redeemable` quoted, in any order, whatever the feeds are doing.
    function invariant_everyHolderCanAlwaysDefund() public {
        assertFalse(handler.defundBroken(), "a defund reverted or paid another amount than quoted");
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < handler.feedCount(); ++i) {
            bytes32 feedId = handler.feeds(i);
            for (uint256 k; k < handler.funderCount(); ++k) {
                address funder = handler.funders(k);
                if (q.sharesOf(feedId, funder) == 0) continue;
                uint256 quoted = q.redeemable(feedId, funder);
                uint256 before = imd.balanceOf(funder);
                vm.prank(funder);
                uint256 amount = q.defund(feedId, type(uint256).max);
                assertEq(amount, quoted);
                assertEq(imd.balanceOf(funder), before + quoted);
                assertEq(q.sharesOf(feedId, funder), 0);
            }
        }
        // With every funder gone, the contract still holds every tip it owes.
        assertGe(imd.balanceOf(address(q)), q.totalMetered() + q.totalTips());
        vm.revertToState(snapshot);
    }
}
