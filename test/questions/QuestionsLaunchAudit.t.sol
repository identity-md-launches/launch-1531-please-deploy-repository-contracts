// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Questions} from "../../src/questions/Questions.sol";
import {IQuestions} from "../../src/interfaces/IQuestions.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../../src/questions/OracleAttestation.sol";
import {QuestionsFixture} from "./QuestionsFixture.sol";

/// @notice Regressions for the audit supplied with the contracts-only launch assignment.
contract QuestionsLaunchAuditTest is QuestionsFixture {
    function _auditFeed(bool panel) internal returns (bytes32 id) {
        Questions.FeedParams memory p = _params();
        p.tip = 0.05e18;
        bytes memory prefix = panel
            ? bytes(
                string.concat(
                    '{"answerType":"uint256","chainId":',
                    vm.toString(vm.getChainId()),
                    ',"evidence":"panel","question":"Panel question","v":1,"window":{"fromBlock":'
                )
            )
            : _prefix("uint256");
        bytes memory tail = panel
            ? bytes(',"panelSize":7,"quorum":5,"validForSeconds":86400}')
            : _tail(p.panelSize, p.quorum, p.validFor);
        id = q.createFeed(p, prefix, tail);
        _fund(alice, id, 10e18);
    }

    /// @dev 2ab3a604a08a: copying the public signature must not take the opener's tip.
    function test_audit_publicAttestationCannotTakeTheOpenersTip() public {
        bytes32 id = _auditFeed(false);
        bytes32 intakeId = _request(id);
        (uint256 earned, uint256 pending) = q.tipsOf(keeper);
        assertEq(earned, 0);
        assertEq(pending, 0.05e18);
        skip(2 minutes);
        OracleAttestation.Attestation memory a = _attestation(id, abi.encode(uint256(114e18)));
        bytes memory signature = _sign(a);
        skip(28 minutes);
        vm.prank(bob);
        q.submit(id, a, signature);

        (earned, pending) = q.tipsOf(keeper);
        assertEq(earned, 0.05e18, "opener lost its tip");
        assertEq(pending, 0);
        (earned, pending) = q.tipsOf(bob);
        assertEq(earned + pending, 0, "observer took the tip");
        assertFalse(_complete(intakeId, a, signature), "round settled twice");
        vm.prank(keeper);
        assertEq(q.collectTips(), 0.05e18);
        assertEq(q.totalTips(), 0);
        assertEq(imd.balanceOf(address(q)), q.totalMetered());
    }

    /// @dev a89a35815623: the writer can still deliver a valid panel answer after twelve hours.
    function test_audit_observerCannotDiscardAStillValidPanelAnswerAtTwelveHours() public {
        bytes32 id = _auditFeed(true);
        bytes32 intakeId = _request(id);
        uint256 askedAt = vm.getBlockTimestamp();
        skip(5 minutes);
        OracleAttestation.Attestation memory a = _attestation(id, abi.encode(uint256(3)));
        bytes memory signature = _sign(a);
        vm.warp(askedAt + 12 hours);
        assertFalse(q.canSubmit(id), "panel answers still require the Intake");
        vm.prank(bob);
        (bool closed,) = address(q).call(abi.encodeCall(q.abandon, (id)));
        assertFalse(closed, "observer discarded an unfinished request at twelve hours");
        assertEq(q.feedOfRequest(intakeId), id);
        assertEq(q.feedState(id).failStreak, 0);
        skip(1);
        assertTrue(_complete(intakeId, a, signature), "late valid answer was lost");
        assertEq(uint8(_status(id, 1)), uint8(IQuestions.RoundStatus.Answered));
        assertEq(q.feedState(id).failStreak, 0);
        (uint256 balance,) = q.meterOf(id);
        assertEq(balance, 10e18 - PRICE - 0.05e18);
    }

    /// @dev a7e63b8cd49c is an immutable trust dependency, not an authority to add a signer setter.
    function test_audit_rotatedSignerIsRejectedAndUnspentMeterRemainsRedeemable() public {
        bytes32 id = _auditFeed(false);
        bytes32 intakeId = _request(id);
        OracleAttestation.Attestation memory a = _attestation(id, abi.encode(uint256(7)));
        (, uint256 rotatedKey) = makeAddrAndKey("rotated oracle");
        bytes memory signature = _signWith(rotatedKey, a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(intakeId, a, signature);
        assertEq(q.oracleSigner(), oracle);
        assertFalse(q.consumed(a.requestId));
        vm.prank(alice);
        assertEq(q.defund(id, type(uint256).max), 10e18 - PRICE - 0.05e18);
    }

    function test_audit_signerCodeWithoutERC1271RejectsPlainSignatures() public {
        bytes32 id = _auditFeed(false);
        bytes32 intakeId = _request(id);
        OracleAttestation.Attestation memory a = _attestation(id, abi.encode(uint256(7)));
        bytes memory signature = _sign(a);
        // Non-1271 code exercises the code-account branch used by a delegated signer as well.
        vm.etch(oracle, hex"00");
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(intakeId, a, signature);
        assertFalse(_complete(intakeId, a, signature));
        assertEq(q.feedOfRequest(intakeId), id);
        assertFalse(q.consumed(a.requestId));
        vm.prank(alice);
        assertEq(q.defund(id, type(uint256).max), 10e18 - PRICE - 0.05e18);
    }

    /// @dev The silence deadline covers every supported validFor, including inclusive expiry.
    function testFuzz_audit_silenceWaitsThroughTheRequestedValidity(uint32 validFor) public {
        Questions.FeedParams memory p = _params();
        p.validFor = uint32(bound(validFor, 60, 30 days));
        bytes32 id = _create(p);
        _fund(alice, id, 10e18);
        bytes32 intakeId = _request(id);
        uint256 askedAt = vm.getBlockTimestamp();
        vm.warp(askedAt + q.ABANDON_AFTER_SILENCE());
        OracleAttestation.Attestation memory a = _attestation(id, abi.encode(uint256(42)));
        a.issuedAt += uint64(q.ISSUED_AT_TOLERANCE());
        a.expiresAt = a.issuedAt + p.validFor;
        bytes memory signature = _sign(a);

        vm.warp(a.expiresAt);
        (Questions.AbandonStep step, uint256 closableAt) = q.canAbandon(id);
        assertEq(uint8(step), uint8(Questions.AbandonStep.Wait));
        assertEq(closableAt, uint256(a.expiresAt) + 1);
        vm.expectRevert(abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, closableAt));
        q.abandon(id);
        uint256 snapshot = vm.snapshotState();
        assertTrue(_complete(intakeId, a, signature), "answer lost within its validity");
        vm.revertToState(snapshot);

        skip(1);
        (step, closableAt) = q.canAbandon(id);
        assertEq(uint8(step), uint8(Questions.AbandonStep.Close));
        assertEq(closableAt, vm.getBlockTimestamp());
        assertTrue(q.abandon(id), "uncompleted request cannot block a feed forever");
        assertEq(q.feedState(id).failStreak, 1);
        (uint256 meter,) = q.meterOf(id);
        assertEq(meter, 10e18 - PRICE);
        assertEq(q.totalTips(), 0);
    }
}
