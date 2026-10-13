// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation} from "../../src/questions/OracleAttestation.sol";
import {QuestionBody} from "../../src/questions/QuestionBody.sol";
import {Questions} from "../../src/questions/Questions.sol";
import {CanonicalQuestion} from "./lib/CanonicalQuestion.sol";
import {QuestionsFixture} from "./QuestionsFixture.sol";

/// @title The three house feeds of the Robot Jobs Report
/// @notice `test/fixtures/questions/feeds/{payrolls,hires,employers}.json` hold each feed's
/// parameters, question prefix, tail, an example body and its id. They were written by a script
/// with its own ABI encoder and keccak; these tests recompute every derived value with the contract
/// and tie the question text to the canonical form the fixtures test proved against the oracle.
contract HouseFeedsTest is QuestionsFixture {
    string internal constant DIR = "test/fixtures/questions/feeds/";
    address internal constant IMD_MAINNET = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant FEE_PAYEE = 0x4e0fA57Bde726079356537E2F34d671E9F41ADbc;

    struct HouseFeed {
        string json;
        Questions.FeedParams params;
        bytes qPrefix;
        bytes tail;
        bytes32 feedId;
    }

    function setUp() public override {
        super.setUp();
        // The house feeds are about Ethereum mainnet and can only be created there.
        vm.chainId(1);
    }

    function _names() internal pure returns (string[3] memory) {
        return ["payrolls", "hires", "employers"];
    }

    function _load(string memory name) internal view returns (HouseFeed memory h) {
        h.json = vm.readFile(string.concat(DIR, name, ".json"));
        assertEq(vm.parseJsonString(h.json, ".name"), name);
        string memory j = h.json;
        Questions.FeedParams memory p;
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
        p.gateCmp = uint8(vm.parseJsonUint(j, ".params.gateCmp"));
        p.gateTarget = vm.parseJsonAddress(j, ".params.gateTarget");
        p.gateThreshold = vm.parseJsonUint(j, ".params.gateThreshold");
        p.gateData = vm.parseJsonBytes(j, ".params.gateData");
        h.params = p;
        h.qPrefix = vm.parseJsonBytes(j, ".qPrefixHex");
        h.tail = vm.parseJsonBytes(j, ".tailHex");
        h.feedId = vm.parseJsonBytes32(j, ".feedId");
    }

    /// @notice Each feedId is recomputed from its parts, by the contract and by hand.
    function test_feedIdsRecomputeFromTheirParts() public view {
        string[3] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            HouseFeed memory h = _load(names[i]);
            assertEq(q.feedIdOf(h.params, h.qPrefix, h.tail), h.feedId, names[i]);
            assertEq(keccak256(abi.encode(h.params, keccak256(h.qPrefix), keccak256(h.tail))), h.feedId, names[i]);
            // The readable strings in the file are the same bytes as the hex the id is made from.
            assertEq(bytes(vm.parseJsonString(h.json, ".qPrefix")), h.qPrefix, names[i]);
            assertEq(bytes(vm.parseJsonString(h.json, ".tail")), h.tail, names[i]);
        }
    }

    /// @notice The three ids differ, and each feed passes every check `createFeed` makes on mainnet.
    function test_feedsAreAcceptedOnMainnet() public {
        string[3] memory names = _names();
        bytes32[3] memory ids;
        for (uint256 i; i < names.length; ++i) {
            HouseFeed memory h = _load(names[i]);
            assertEq(uint8(q.checkFeed(h.params, h.qPrefix, h.tail)), uint8(Questions.FeedFault.None), names[i]);
            ids[i] = q.createFeed(h.params, h.qPrefix, h.tail);
            assertEq(ids[i], h.feedId, names[i]);
            assertEq(h.params.action, bytes32("oracle.request@oracle-1"));
            assertTrue(h.params.pinHash, "house feeds pin their question");
            assertEq(h.params.minAgreed, h.params.quorum, "house feeds take only the panel's own agreement");
            assertEq(h.params.gateTarget, address(0));
        }
        assertTrue(ids[0] != ids[1] && ids[1] != ids[2] && ids[0] != ids[2]);
        assertEq(q.feedCount(), 3);
    }

    /// @notice They cannot be created on another chain: the windows would be counted in the wrong blocks.
    function test_feedsAreRefusedOffMainnet() public {
        vm.chainId(4663);
        HouseFeed memory h = _load("payrolls");
        vm.expectRevert(abi.encodeWithSelector(Questions.BadFeed.selector, Questions.FeedFault.Chain));
        q.createFeed(h.params, h.qPrefix, h.tail);
    }

    /// @notice The example body in each file is what the contract sends for the example window,
    /// byte for byte, and the example hash is what an answer to it must carry.
    function test_exampleBodiesAreWhatTheContractSends() public {
        string[3] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            HouseFeed memory h = _load(names[i]);
            uint64 fromBlock = uint64(vm.parseJsonUint(h.json, ".example.fromBlock"));
            uint64 toBlock = uint64(vm.parseJsonUint(h.json, ".example.toBlock"));
            bytes memory example = vm.parseJsonBytes(h.json, ".example.bodyHex");
            bytes32 exampleHash = vm.parseJsonBytes32(h.json, ".example.questionHash");
            assertEq(bytes(vm.parseJsonString(h.json, ".example.body")), example, names[i]);
            assertEq(QuestionBody.body(h.qPrefix, h.tail, fromBlock, toBlock), example, names[i]);
            assertEq(QuestionBody.questionHash(h.qPrefix, fromBlock, toBlock), exampleHash, names[i]);

            // And through the contract: created, funded and requested in the example's block.
            bytes32 feedId = q.createFeed(h.params, h.qPrefix, h.tail);
            vm.roll(vm.parseJsonUint(h.json, ".example.requestBlock"));
            (bytes memory next, bytes32 nextHash, uint64 nextFrom, uint64 nextTo) = q.nextBody(feedId);
            assertEq(next, example, names[i]);
            assertEq(nextHash, exampleHash, names[i]);
            assertEq(nextFrom, fromBlock, names[i]);
            assertEq(nextTo, toBlock, names[i]);
            _fund(alice, feedId, 10e18);
            _request(feedId);
            assertEq(intake.lastBody(), example, names[i]);
            (, bytes32 pinned,,) = q.roundRequest(feedId, 1);
            assertEq(pinned, exampleHash, names[i]);
        }
    }

    /// @notice Each prefix is the canonical document of its own example body: reading the body back
    /// as JSON and writing it by the rule the fixtures test proved gives the stored prefix. So the
    /// hash the contract pins is the hash the oracle will compute for the body it receives.
    function test_prefixesAreTheCanonicalFormOfTheBody() public view {
        string[3] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            HouseFeed memory h = _load(names[i]);
            string memory body = vm.parseJsonString(h.json, ".example.body");
            assertEq(CanonicalQuestion.prefix(body), h.qPrefix, names[i]);
            // The fields the hash does not cover are in the tail, as the contract's checks read them.
            assertEq(vm.parseJsonUint(body, ".panelSize"), h.params.panelSize);
            assertEq(vm.parseJsonUint(body, ".quorum"), h.params.quorum);
            assertEq(vm.parseJsonUint(body, ".validForSeconds"), h.params.validFor);
            // The two daily feeds are chain evidence; the weekly ranking is judged by the panel.
            assertEq(vm.parseJsonString(body, ".evidence"), i == 2 ? "panel" : "chain", names[i]);
            assertEq(vm.parseJsonUint(body, ".v"), 1);
            assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        }
    }

    /// @notice What the two daily feeds ask, read back from their own text: the IMD token's
    /// Transfer events to the fee payee, summed and counted by a recipe the oracle reruns itself.
    function test_recipesNameTheTokenAndThePayee() public view {
        string[2] memory names = ["payrolls", "hires"];
        string[2] memory kinds = ["log-sum", "log-count"];
        for (uint256 i; i < names.length; ++i) {
            HouseFeed memory h = _load(names[i]);
            string memory body = vm.parseJsonString(h.json, ".example.body");
            string memory pinned = vm.parseJsonString(body, ".definitions.recipe");
            // The definition is the recipe as JSON followed by one sentence; cut the sentence off.
            bytes memory text = bytes(pinned);
            bytes memory sentence = " - write recipe exactly this, event text included.";
            assertGt(text.length, sentence.length);
            string memory recipe = string(CanonicalQuestion.slice(text, 0, text.length - sentence.length));
            assertEq(CanonicalQuestion.slice(text, text.length - sentence.length, text.length), sentence, names[i]);
            assertEq(vm.parseJsonString(recipe, ".kind"), kinds[i]);
            assertEq(vm.parseJsonAddress(recipe, ".address"), IMD_MAINNET);
            assertEq(vm.parseJsonAddress(recipe, ".filter.to"), FEE_PAYEE);
            assertEq(
                vm.parseJsonString(recipe, ".event"),
                "event Transfer(address indexed from, address indexed to, uint256 value)"
            );
        }
        assertTrue(_load("payrolls").params.contiguous);
        assertTrue(_load("hires").params.contiguous);
    }

    /// @notice What the weekly ranking asks, read back from its own text. It has no recipe: the
    /// oracle's ranking recipe takes no filter, so the method is written out for the panel and the
    /// panel's agreement is the answer. The method names the token, the event, the payee, how to
    /// add up and how to order, and asks for exactly three addresses.
    function test_employersIsJudgedByThePanelWithItsMethodPinned() public view {
        HouseFeed memory employers = _load("employers");
        string memory body = vm.parseJsonString(employers.json, ".example.body");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonString(body, ".answerType"), "address[]");
        assertEq(vm.parseJsonUint(body, ".head"), 3);
        assertFalse(vm.keyExistsJson(body, ".definitions.recipe"), "a panel-judged question pins no recipe");
        assertFalse(vm.keyExistsJson(body, ".toleranceBps"));
        string memory method = vm.parseJsonString(body, ".definitions.method");
        assertTrue(vm.contains(method, "Transfer(address indexed from, address indexed to, uint256 value) logs"));
        assertTrue(vm.contains(method, "emitted by 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7 on Ethereum mainnet"));
        assertTrue(vm.contains(method, "keep those whose to is 0x4e0fa57bde726079356537e2f34d671e9f41adbc"));
        assertTrue(vm.contains(method, "add up value per from address"));
        assertTrue(vm.contains(method, "ties by ascending address"));
        assertTrue(vm.contains(method, "answer the first 3 addresses"));
        assertTrue(vm.contains(vm.parseJsonString(body, ".definitions.source"), "event logs only"));
        string memory question = vm.parseJsonString(body, ".question");
        assertTrue(vm.contains(question, "answer exactly the top 3 addresses"));
        assertFalse(employers.params.contiguous, "a ranking is of a period, not a running total");
        assertEq(employers.params.maxWindowBlocks, 50_400, "seven days");
        // Every definition is inside the hashed prefix, so an answer to another method is refused.
        assertTrue(vm.contains(string(employers.qPrefix), method));
        assertTrue(vm.contains(string(employers.qPrefix), '"evidence":"panel","head":3,'));

        // The feed's own documentation says what resting on a panel means.
        string[] memory judged = vm.parseJsonStringArray(employers.json, ".notes.panelJudged");
        assertGe(judged.length, 4);
        assertTrue(vm.contains(judged[0], "IdentityMD does not recompute this answer"));
        assertTrue(vm.contains(vm.parseJsonString(employers.json, ".title"), "panel"), "the title does not say");
    }

    /// @notice What the contract does with a feed a panel judges. `submit` is closed for it, at any
    /// time and for anyone: two panels can differ and whoever submits would choose. Only the
    /// Intake's own callback delivers. With `minAgreed` equal to the quorum an answer fewer members
    /// agreed on than its signed quorum is refused; with the quorum met it is stored.
    function test_employersTakesAnswersFromTheIntakeOnlyAndOnlyWithTheQuorumMet() public {
        HouseFeed memory h = _load("employers");
        bytes32 feedId = q.createFeed(h.params, h.qPrefix, h.tail);
        assertEq(h.params.minAgreed, h.params.quorum);
        vm.roll(vm.parseJsonUint(h.json, ".example.requestBlock"));
        _fund(alice, feedId, 10e18);
        bytes32 intakeId = _request(feedId);

        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(0xA1), address(0xB2), address(0xC3));
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(three));

        // Nobody can hand an answer in: not when the wait that opens `submit` on the daily feeds
        // is over, not hours later, and not after the Intake completed.
        assertFalse(q.canSubmit(feedId));
        skip(submitAfterSilence);
        assertFalse(q.canSubmit(feedId));
        skip(3 hours);
        assertFalse(q.canSubmit(feedId));
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + h.params.validFor;
        bytes memory signature = _sign(a);
        vm.expectRevert(Questions.SubmitNotForPanelEvidence.selector);
        q.submit(feedId, a, signature);

        // An answer four of seven agreed on, signed for a quorum of five, is refused by the callback.
        a.agreed = 4;
        signature = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(Questions.NotEnoughAgreed.selector, uint16(4), uint16(5)));
        _callback(intakeId, a, signature);

        // The panel's own agreement, delivered by the Intake, is stored: the list as its hash.
        a.agreed = 5;
        signature = _sign(a);
        assertTrue(_complete(intakeId, a, signature), "the callback was not delivered");
        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(round, 1);
        assertEq(value, uint256(keccak256(abi.encode(three))));
        assertFalse(q.canSubmit(feedId));
    }

    /// @notice The imported audit's twelve-hour grief no longer discards a valid house-feed answer.
    function test_employersAcceptsAValidDeliveryAfterTwelveHours() public {
        HouseFeed memory h = _load("employers");
        bytes32 feedId = q.createFeed(h.params, h.qPrefix, h.tail);
        vm.roll(vm.parseJsonUint(h.json, ".example.requestBlock"));
        _fund(alice, feedId, 10e18);
        bytes32 intakeId = _request(feedId);
        uint256 askedAt = vm.getBlockTimestamp();
        skip(5 minutes);
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(0xA1), address(0xB2), address(0xC3));
        OracleAttestation.Attestation memory a = _attestation(feedId, abi.encode(three));
        bytes memory signature = _sign(a);
        vm.warp(askedAt + 12 hours);
        vm.expectRevert(abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, askedAt + abandonAfterSilence));
        vm.prank(bob);
        q.abandon(feedId);
        vm.expectRevert(Questions.SubmitNotForPanelEvidence.selector);
        q.submit(feedId, a, signature);
        vm.warp(a.expiresAt);
        assertTrue(_complete(intakeId, a, signature), "delivery at signed expiry was refused");
        (uint256 value,,, uint64 round,) = q.latest(feedId);
        assertEq(round, 1);
        assertEq(value, uint256(keccak256(abi.encode(three))));
        assertEq(q.feedState(feedId).failStreak, 0);
    }

    /// @notice Silence allows twelve hours to sign, then the full requested validity and clock skew.
    function test_theWaitsFitTheHouseFeeds() public view {
        string[3] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            Questions.FeedParams memory p = _load(names[i]).params;
            uint256 timeout = q.ABANDON_AFTER_SILENCE() + p.validFor + q.ISSUED_AT_TOLERANCE() + 1;
            assertEq(timeout, 36 hours + 5 minutes + 1, names[i]);
            assertGt(timeout, p.validFor, names[i]);
            assertLt(submitAfterSilence, timeout, names[i]);
        }
    }

    /// @notice The hires feed counts every Transfer log to the fee payee, zero-value ones included,
    /// because no recipe can leave them out: its recipe has no condition on `value` (a log-count
    /// filter reaches indexed arguments only). The feed's own documentation has to say so, in its
    /// title and in its limits, so that nobody reads the figure as a count of paid actions and so
    /// that an unofficial tally counts the same way.
    function test_hiresSaysItCountsZeroValueTransfers() public view {
        HouseFeed memory hires = _load("hires");
        string memory body = vm.parseJsonString(hires.json, ".example.body");
        string memory pinned = vm.parseJsonString(body, ".definitions.recipe");
        assertTrue(vm.contains(pinned, '"kind":"log-count"'));
        assertTrue(vm.contains(pinned, '"filter":{"to":"0x4e0fa57bde726079356537e2f34d671e9f41adbc"}'));
        assertFalse(vm.contains(pinned, "value\":"), "the recipe has a condition on value: update the feed's limits");
        assertFalse(vm.contains(pinned, "sumArg"));

        assertTrue(vm.contains(vm.parseJsonString(hires.json, ".title"), "zero-value"), "the title does not say");
        assertFalse(vm.contains(vm.parseJsonString(hires.json, ".title"), "paid actions"));
        assertTrue(vm.contains(vm.parseJsonString(hires.json, ".notes.what"), "zero-value"));
        string[] memory limits = vm.parseJsonStringArray(hires.json, ".notes.limits");
        assertGe(limits.length, 2);
        assertTrue(vm.contains(limits[0], "zero-value transfers are counted"), "the limits do not say");
        assertTrue(vm.contains(limits[1], "must count the same way"));

        // Every feed states its limits, and each says that the feeds' own purchases are counted.
        string[3] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            limits = vm.parseJsonStringArray(_load(names[i]).json, ".notes.limits");
            bool saysOwnPurchases;
            for (uint256 k; k < limits.length; ++k) {
                if (vm.contains(limits[k], "the feeds' own purchases are included")) saysOwnPurchases = true;
            }
            assertTrue(saysOwnPurchases, names[i]);
        }
    }
}
