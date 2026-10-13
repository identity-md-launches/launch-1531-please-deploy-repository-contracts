// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchKit} from "./LaunchKit.sol";
import {Questions} from "src/questions/Questions.sol";
import {OracleAttestation} from "src/questions/OracleAttestation.sol";
import {Payroll} from "src/payroll/Payroll.sol";
import {JobsReport} from "src/payroll/JobsReport.sol";
import {MockIMD} from "../questions/mocks/MockIMD.sol";
import {MockIntake} from "../questions/mocks/MockIntake.sol";
import {QuestionsHarness} from "../questions/mocks/QuestionsHarness.sol";
import {MockSIMD} from "../payroll/mocks/MockTokens.sol";
import {MockSeats, MockAdapter} from "../payroll/mocks/MockSeats.sol";

/// @dev Fail *after* changing ERC-20 balances, so rollback tests cover both contracts' state.
/// This is fault injection, not an assumption about the mainnet IMD token.
contract LaunchFaultToken is MockIMD {
    error TransferRefused();

    address public failingFrom;
    address public failingTo;
    uint8 public failureMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function failTransfer(address from, address to, uint8 mode) external {
        failingFrom = from;
        failingTo = to;
        failureMode = mode;
    }

    function armCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return _afterTransfer(msg.sender, to);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return _afterTransfer(from, to);
    }

    function _afterTransfer(address from, address to) private returns (bool) {
        address target = callbackTarget;
        if (target != address(0)) {
            callbackTarget = address(0);
            (callbackSucceeded, callbackResult) = target.call(callbackData);
        }
        if (from != failingFrom || to != failingTo) return true;
        if (failureMode == 1) revert TransferRefused();
        if (failureMode == 2) return false;
        if (failureMode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

/// @dev A contract account can deliberately collect its own seat's revenue.
contract LaunchClaimWallet {
    function claim(Payroll payroll, uint256 seat, uint256 agent) external returns (uint256 paid) {
        paid = payroll.claimSeat(seat) + payroll.claimTip(agent);
    }
}

contract LaunchPassiveEscrow {}

/// @dev All three application contracts, exact house-feed fixtures and the mainnet seat count.
/// Only external dependencies are mocked. QuestionsHarness changes no application logic:
/// its transaction-reset helper clears the transient request flag between simulated transactions.
abstract contract LaunchStateSetup is LaunchKit {
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 internal constant PRICE = 0.5e18;
    uint256 internal constant INITIAL = 1_000_000e18;
    uint256 internal constant STAKED = 1_000e18;
    uint256 internal constant SEAT_COUNT = 2000;

    LaunchFaultToken internal token;
    MockIntake internal intake;
    QuestionsHarness internal questions;
    JobsReport internal report;
    Payroll internal payroll;
    MockSIMD internal simd;
    MockSeats internal seats;
    MockAdapter internal adapter;
    LaunchClaimWallet internal wallet;
    LaunchPassiveEscrow internal escrow;
    bytes32[3] internal feeds;
    address[3] internal actors;
    address internal feePayee;
    address internal writer;
    address internal signer;
    uint256 internal signerKey;
    uint256 internal oracleNonce;

    function setUp() public virtual {
        vm.chainId(1);
        vm.roll(26_200_000);
        vm.warp(1_791_600_000);
        feePayee = makeAddr("launch state intake fees");
        writer = makeAddr("launch state writer");
        (signer, signerKey) = makeAddrAndKey("launch state test oracle");
        actors = [makeAddr("launch actor 0"), makeAddr("launch actor 1"), makeAddr("launch actor 2")];
        token = new LaunchFaultToken();
        intake = new MockIntake(feePayee, writer);
        intake.setPrice(ACTION, address(token), PRICE);
        simd = new MockSIMD(IERC20(address(token)));
        seats = new MockSeats(SEAT_COUNT);
        adapter = new MockAdapter();
        wallet = new LaunchClaimWallet();
        escrow = new LaunchPassiveEscrow();

        questions = new QuestionsHarness(address(intake), address(token), signer);
        string[3] memory names = _feedNames();
        for (uint256 i; i < 3; ++i) {
            HouseFeed memory h = _houseFeed(names[i]);
            feeds[i] = questions.createFeed(h.params, h.qPrefix, h.tail);
            assertEq(feeds[i], h.feedId);
        }
        report = new JobsReport(address(questions), feeds[0], feeds[1], feeds[2]);
        payroll = new Payroll(
            address(token),
            address(simd),
            address(seats),
            SEAT_COUNT,
            address(adapter),
            address(questions),
            feeds[0],
            feeds[1],
            feeds[2]
        );
        for (uint256 i; i < 3; ++i) {
            token.mint(actors[i], INITIAL);
            vm.startPrank(actors[i]);
            token.approve(address(payroll), type(uint256).max);
            token.approve(address(questions), type(uint256).max);
            vm.stopPrank();
        }
        token.mint(address(this), STAKED);
        token.approve(address(simd), STAKED);
        simd.deposit(STAKED, address(this));
        for (uint256 i; i < 4; ++i) {
            uint256 id = i == 3 ? 1999 : i;
            seats.setOwner(id, actors[i % 3]);
            adapter.bind(i, address(seats), id);
        }
    }

    function _pay(uint256 amount) internal {
        vm.prank(actors[0]);
        payroll.pay(amount, bytes32("launch state"));
    }

    function _tip(uint256 agent, uint256 amount) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = agent;
        vm.prank(actors[0]);
        payroll.tip(ids, amount);
    }

    function _request(uint256 index, address keeper) internal returns (bytes32 id) {
        questions.newTransaction();
        intake.newTransaction();
        vm.prank(keeper);
        id = questions.request(feeds[index]);
    }

    function _attestation(uint256 index, bytes memory answer)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        bytes32 feed = feeds[index];
        uint64 round = questions.roundCount(feed);
        Questions.FeedParams memory p = questions.feedParams(feed);
        (, a.questionHash, a.blockHash,) = questions.roundRequest(feed, round);
        (,, a.fromBlock, a.toBlock,) = questions.roundOf(feed, round);
        a.requestId = keccak256(abi.encode("launch state oracle answer", ++oracleNonce));
        a.chainId = 1;
        a.answerType = p.answerType;
        a.answer = answer;
        a.panelJobId = keccak256(abi.encode("launch state panel", oracleNonce));
        a.panelSize = p.panelSize;
        a.quorum = p.quorum;
        a.agreed = p.quorum;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + p.validFor;
    }

    function _signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, questions.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(bytes32 requestId, OracleAttestation.Attestation memory a, bytes memory signature) internal {
        vm.prank(writer);
        intake.complete(requestId, 0, bytes32(0), "", abi.encode(requestId, a, signature));
        assertTrue(intake.lastDelivered(), "valid answer did not fit the 200,000 gas callback");
    }
}
