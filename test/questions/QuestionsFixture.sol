// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IQuestions} from "../../src/interfaces/IQuestions.sol";
import {OracleAttestation} from "../../src/questions/OracleAttestation.sol";
import {Questions} from "../../src/questions/Questions.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {QuestionsHarness} from "./mocks/QuestionsHarness.sol";

/// @dev Reads a block hash in a frame of its own. The tests are compiled through the optimiser,
/// which is entitled to treat `block.number`, `block.timestamp`, `block.chainid` and `blockhash(n)`
/// as fixed for the length of a call and reuse an earlier read after a cheatcode has moved them. So
/// the tests read all four through calls it cannot reuse: `vm.getBlockNumber()`,
/// `vm.getBlockTimestamp()`, `vm.getChainId()` and this.
contract BlockReader {
    function hashOf(uint256 number) external view returns (bytes32) {
        return blockhash(number);
    }
}

/// @dev What every Questions test starts from: a mock Intake selling the oracle action for 0.5 IMD,
/// a mock IMD, a Questions built with a test oracle key, and helpers that play the keeper, the
/// oracle and the Intake's writer.
abstract contract QuestionsFixture is Test {
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 internal constant PRICE = 0.5e18;
    uint96 internal constant TIP = 0.01e18;
    uint256 internal constant COST = PRICE + TIP;
    uint32 internal constant CADENCE = 7000;
    uint32 internal constant MAX_WINDOW = 21_600;
    uint16 internal constant LAG = 12;
    uint256 internal constant START_BLOCK = 26_200_000;
    uint256 internal constant START_TIME = 1_791_600_000;

    address internal constant PAY_TO = address(0x4E0F);
    address internal constant WRITER = address(0x3D3C);

    MockIMD internal imd;
    MockIntake internal intake;
    QuestionsHarness internal q;
    BlockReader internal blocks = new BlockReader();
    address internal oracle;
    uint256 internal oracleKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    uint256 internal oracleRequests;

    /// @dev The submit/completion waits and the default feed's full silence deadline. A test that waits a rule out names
    /// the rule and not a number of hours, so it follows the contract; the numbers themselves are
    /// stated in `test_waits_areTheValuesFixedAtLaunch`.
    uint256 internal submitAfterSilence;
    uint256 internal abandonAfterSilence;
    uint256 internal abandonAfterCompleted;

    function setUp() public virtual {
        vm.roll(START_BLOCK);
        vm.warp(START_TIME);
        (oracle, oracleKey) = makeAddrAndKey("oracle signer");
        imd = new MockIMD();
        intake = new MockIntake(PAY_TO, WRITER);
        intake.setPrice(ACTION, address(imd), PRICE);
        q = new QuestionsHarness(address(intake), address(imd), oracle);
        submitAfterSilence = q.SUBMIT_AFTER_SILENCE();
        abandonAfterSilence = q.ABANDON_AFTER_SILENCE() + _params().validFor + q.ISSUED_AT_TOLERANCE() + 1;
        abandonAfterCompleted = q.ABANDON_AFTER_COMPLETED();
        for (uint256 i; i < 3; ++i) {
            address who = [alice, bob, keeper][i];
            imd.mint(who, 1_000_000e18);
            vm.prank(who);
            imd.approve(address(q), type(uint256).max);
        }
    }

    // ---- feeds --------------------------------------------------------------------------------

    /// @dev The canonical question prefix of a pinned log-sum feed about this chain.
    function _prefix(string memory answerType) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                '{"answerType":"',
                answerType,
                '","chainId":',
                vm.toString(vm.getChainId()),
                ',"definitions":{"recipe":"{\\"kind\\":\\"log-sum\\"} - write recipe exactly this."},',
                '"question":"What is the sum in the window?","v":1,"window":{"fromBlock":'
            )
        );
    }

    function _tail(uint256 panelSize, uint256 quorum, uint256 validFor) internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                ',"evidence":"chain","panelSize":',
                vm.toString(panelSize),
                ',"quorum":',
                vm.toString(quorum),
                ',"toleranceBps":0,"validForSeconds":',
                vm.toString(validFor),
                "}"
            )
        );
    }

    /// @dev A daily, contiguous, pinned uint256 feed with a panel of 7 and a quorum of 5.
    function _params() internal view returns (Questions.FeedParams memory p) {
        p.action = ACTION;
        p.chainId = uint64(vm.getChainId());
        p.answerType = OracleAttestation.ANSWER_UINT256;
        p.panelSize = 7;
        p.quorum = 5;
        p.minAgreed = 5;
        p.validFor = 86_400;
        p.cadenceBlocks = CADENCE;
        p.maxWindowBlocks = MAX_WINDOW;
        p.lagBlocks = LAG;
        p.contiguous = true;
        p.pinHash = true;
        p.maxPrice = 1e18;
        p.tip = TIP;
    }

    function _typeName(uint8 answerType) internal pure returns (string memory) {
        return ["bool", "address", "bytes32", "uint256", "address[]", "bytes32[]"][answerType];
    }

    function _create(Questions.FeedParams memory p) internal returns (bytes32) {
        return q.createFeed(p, _prefix(_typeName(p.answerType)), _tail(p.panelSize, p.quorum, p.validFor));
    }

    function _createDefault() internal returns (bytes32) {
        return _create(_params());
    }

    function _fund(address who, bytes32 feedId, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = q.fund(feedId, amount);
    }

    // ---- rounds -------------------------------------------------------------------------------

    /// @dev One keeper transaction: `request` as its own transaction.
    function _request(bytes32 feedId) internal returns (bytes32 intakeId) {
        q.newTransaction();
        intake.newTransaction();
        vm.prank(keeper);
        intakeId = q.request(feedId);
    }

    /// @dev The attestation an honest oracle would sign for the feed's pending round.
    function _attestation(bytes32 feedId, bytes memory answer)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        Questions.FeedParams memory p = q.feedParams(feedId);
        uint64 round = q.roundCount(feedId);
        (, bytes32 questionHash, bytes32 blockHash,) = q.roundRequest(feedId, round);
        (,, uint64 fromBlock, uint64 toBlock,) = q.roundOf(feedId, round);
        a = OracleAttestation.Attestation({
            requestId: bytes32(bytes16(keccak256(abi.encode("oracle request", ++oracleRequests)))),
            chainId: p.chainId,
            questionHash: questionHash,
            answerType: p.answerType,
            answer: answer,
            figure: 0,
            fromBlock: fromBlock,
            toBlock: toBlock,
            blockHash: blockHash,
            panelJobId: bytes32(bytes16(keccak256(abi.encode("panel job", oracleRequests)))),
            panelSize: p.panelSize,
            quorum: p.quorum,
            agreed: p.quorum,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + p.validFor
        });
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return _signWith(oracleKey, a);
    }

    function _signWith(uint256 key, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, q.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The Intake's writer completing a request with an answer, as on the live chain.
    function _complete(bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory signature)
        internal
        returns (bool delivered)
    {
        vm.prank(WRITER);
        intake.complete(intakeId, 0, keccak256("result"), "uri", abi.encode(intakeId, a, signature));
        return intake.lastDelivered();
    }

    /// @dev The Intake's writer completing a request that got no answer: status 1 is a refused body,
    /// status 2 a panel that did not agree. No callback is made for either.
    function _completeWithoutAnswer(bytes32 intakeId, uint8 status) internal {
        vm.prank(WRITER);
        intake.complete(intakeId, status, bytes32(0), "https://api.imd.fun/oracle/requests/x", "");
        assertFalse(intake.lastDelivered());
    }

    /// @dev The Intake's writer completing a request with an answer whose callback does not run to
    /// the end, as after the Intake's owner lowered the stipend. The stipend is put back afterwards.
    function _completeWithMissedCallback(
        bytes32 intakeId,
        OracleAttestation.Attestation memory a,
        bytes memory signature
    ) internal {
        uint64 stipend = intake.callbackGas();
        intake.setCallbackGas(40_000);
        assertFalse(_complete(intakeId, a, signature), "the callback fitted in 40,000 gas");
        intake.setCallbackGas(stipend);
    }

    /// @dev The whole happy path for one round: request, sign, deliver.
    function _answer(bytes32 feedId, bytes memory answer) internal returns (bytes32 intakeId) {
        intakeId = _request(feedId);
        OracleAttestation.Attestation memory a = _attestation(feedId, answer);
        assertTrue(_complete(intakeId, a, _sign(a)), "callback was not delivered");
    }

    /// @dev Calls the callback directly as the Intake, so a revert reason can be asserted.
    function _callback(bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory signature) internal {
        vm.prank(address(intake));
        q.onOracleResult(intakeId, a, signature);
    }

    function _blockhash(uint256 number) internal view returns (bytes32) {
        return blocks.hashOf(number);
    }

    function _status(bytes32 feedId, uint64 round) internal view returns (IQuestions.RoundStatus status) {
        (status,,,,) = q.roundOf(feedId, round);
    }

    function _blocked(Questions.Blocker why) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Questions.RequestBlocked.selector, why);
    }
}
