// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Vm} from "forge-std/Vm.sol";

import {IQuestions} from "../../../src/interfaces/IQuestions.sol";
import {IIntake} from "../../../src/interfaces/external/IIntake.sol";
import {Mainnet} from "../../../src/interfaces/external/Mainnet.sol";
import {Questions} from "../../../src/questions/Questions.sol";
import {JobsReport} from "../../../src/payroll/JobsReport.sol";
import {Payroll} from "../../../src/payroll/Payroll.sol";
import {LaunchKit} from "../LaunchKit.sol";
import {IIntakeV2} from "../../questions/fork/IIntakeV2.sol";

/// @dev IdentityMD's ProjectFactory, as a contracts-only launch uses it. Taken from the verified ABI
/// (Sourcify, Ethereum mainnet `0xff03410d0fe5fa8f7f59f743de35e333d9857120`).
interface IProjectFactory {
    struct LaunchRecord {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct ContractsParams {
        uint64 launchNumber;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        LaunchRecord record;
        uint256[] agentIds;
    }

    event ContractsLaunched(uint64 indexed launchNumber, address[] contracts);

    error NotDeployer();
    error AlreadyLaunched(uint64 launchNumber);

    function launchContracts(ContractsParams calldata p) external returns (address[] memory contracts);

    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);

    function deploymentBlock(uint64 launchNumber) external view returns (uint256 blockNumber);

    function deployer() external view returns (address);
}

/// @title Launch A rehearsed through the real ProjectFactory
/// @notice On a fork of Ethereum mainnet, the launch deployer calls the real factory's
/// `launchContracts` with this project's three contracts, built from the manifest in
/// `docs/LAUNCH.md`: the same call, by the same sender, that the launch pipeline makes (compare
/// launch 1240, transaction `0x93a1b0cc…972d71a3`). Then the first-day runbook is walked against
/// what the factory created and against the live Intake, IMD, sIMD and seat token.
///
/// What is rehearsed: the factory accepts the three initcodes in manifest order and creates them
/// at the addresses it predicts; `$contract:Questions` resolves to the first of them; the whole
/// call fits our 12 million gas gate with the transaction's own intrinsic cost added; the deployed
/// bytecode holds no forbidden opcode; the documented `createFeed` calldata creates the three
/// feeds; a funded meter buys a real request from the live Intake; a round nobody answers gives
/// its tip back; Payroll tops the meters up and drips to the live sIMD.
///
/// What cannot be rehearsed here: the pipeline's own checks before it sends the transaction, and
/// a real oracle answer (the launched `Questions` accepts only the real oracle signer, whose key
/// no test has; `test/payroll/fork/LaunchAFork.t.sol` covers answers with a test signer).
///
/// The record fields the factory stores with a launch (source commit, manifest hash, attestation
/// hash, verifier key, repository URL) are placeholders here. The launch number is one no launch
/// has used.
///
/// Run with `FOUNDRY_PROFILE=fork forge test`. Every test skips itself when the RPC cannot be reached.
contract LaunchRehearsalForkTest is LaunchKit {
    IProjectFactory internal constant FACTORY = IProjectFactory(Mainnet.PROJECT_FACTORY);
    IIntake internal constant INTAKE = IIntake(Mainnet.INTAKE);
    IERC20 internal constant IMD = IERC20(Mainnet.IMD);

    /// @dev Far above any launch number in use (they are in the low thousands).
    uint64 internal constant LAUNCH_NUMBER = 4_000_000_001;

    bool internal forked;
    bytes[] internal initcodes;
    address[] internal predicted;
    address[] internal launched;
    uint256 internal launchExecutionGas;
    uint256 internal launchIntrinsicGas;
    Vm.Log[] internal launchLogs;

    Questions internal q;
    JobsReport internal report;
    Payroll internal payroll;
    bytes32[3] internal feeds;

    address internal funder = makeAddr("first funder");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("mainnet")) returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        _launch();
        q = Questions(launched[0]);
        report = JobsReport(launched[1]);
        payroll = Payroll(launched[2]);
        feeds = _recomputedIds();
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true, "mainnet RPC unreachable");
            return;
        }
        _;
    }

    // ---- the launch -----------------------------------------------------------------------------

    /// @dev Builds the factory call from the document's manifest and makes it as the launch deployer.
    function _launch() internal {
        (, Entry[] memory entries) = _manifest();
        IProjectFactory.ContractsParams memory p;
        p.launchNumber = LAUNCH_NUMBER;
        p.contractCreationCodes = new bytes[](entries.length);
        p.contractNames = new bytes32[](entries.length);
        p.expectedContracts = new address[](entries.length);

        for (uint256 i; i < entries.length; ++i) {
            // A reference to an earlier contract is filled with the address the factory will give it.
            bytes32[] memory words = new bytes32[](entries[i].args.length);
            for (uint256 a; a < words.length; ++a) {
                string[] memory ref = vm.split(entries[i].args[a], "$contract:");
                if (ref.length == 2) {
                    words[a] = _word(_predictedByName(entries, p.expectedContracts, i, ref[1]));
                } else {
                    words[a] = bytes32(vm.parseUint(entries[i].args[a]));
                }
            }
            bytes memory init = _initcode(i, words);
            p.contractCreationCodes[i] = init;
            p.contractNames[i] = bytes32(bytes(entries[i].name));
            p.expectedContracts[i] = FACTORY.predictContract(LAUNCH_NUMBER, i, init);
            initcodes.push(init);
            predicted.push(p.expectedContracts[i]);
        }

        p.record = IProjectFactory.LaunchRecord({
            kind: bytes32("evm_contracts"),
            launchNumber: LAUNCH_NUMBER,
            recordedAt: 0,
            sourceCommit: bytes32(bytes20(keccak256("a rehearsal has no commit"))),
            manifestHash: keccak256("rehearsal manifest"),
            attestationHash: keccak256("rehearsal attestation"),
            verifierKey: keccak256("rehearsal verifier key"),
            sourceRepoUrl: "https://example.invalid/help-wanted/a-payroll"
        });
        p.agentIds = new uint256[](0);

        launchIntrinsicGas = _intrinsicGas(abi.encodeCall(IProjectFactory.launchContracts, (p)));

        vm.recordLogs();
        vm.prank(Mainnet.LAUNCH_DEPLOYER);
        uint256 gasBefore = gasleft();
        address[] memory created = FACTORY.launchContracts(p);
        launchExecutionGas = gasBefore - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            launchLogs.push(logs[i]);
        }
        for (uint256 i; i < created.length; ++i) {
            launched.push(created[i]);
        }
    }

    function _predictedByName(Entry[] memory entries, address[] memory known, uint256 before, string memory name)
        internal
        pure
        returns (address)
    {
        for (uint256 e; e < before; ++e) {
            if (keccak256(bytes(entries[e].name)) == keccak256(bytes(name))) return known[e];
        }
        revert(string.concat("a reference that does not point backward: ", name));
    }

    /// @dev What a transaction with this calldata costs before any code runs: 21,000, plus 4 gas
    /// for each zero byte and 16 for each other byte. (The floor price EIP-7623 sets for calldata,
    /// 10 and 40, applies only to a transaction that executes almost nothing; this one does not.)
    function _intrinsicGas(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    /// @notice The factory created the three contracts where it said it would, in manifest order,
    /// and recorded the launch. A stranger cannot launch, and a launch number is used once.
    function test_fork_rehearsal_factoryCreatesTheThreeContracts() public onFork {
        assertEq(FACTORY.deployer(), Mainnet.LAUNCH_DEPLOYER, "the launch deployer has changed");
        assertEq(launched.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(launched[i], predicted[i], _contractName(i));
            assertGt(launched[i].code.length, 0, _contractName(i));
        }
        assertEq(FACTORY.deploymentBlock(LAUNCH_NUMBER), vm.getBlockNumber());

        // The factory's own event names the three addresses.
        bool seen;
        for (uint256 i; i < launchLogs.length; ++i) {
            if (
                launchLogs[i].emitter == address(FACTORY)
                    && launchLogs[i].topics[0] == IProjectFactory.ContractsLaunched.selector
            ) {
                address[] memory named = abi.decode(launchLogs[i].data, (address[]));
                assertEq(named.length, 3);
                for (uint256 k; k < 3; ++k) {
                    assertEq(named[k], launched[k]);
                }
                seen = true;
            }
        }
        assertTrue(seen, "the factory did not emit ContractsLaunched");

        // What each contract was built with is what the manifest says.
        bytes32[3] memory ids = _recomputedIds();
        assertEq(address(q.INTAKE()), Mainnet.INTAKE);
        assertEq(address(q.IMD()), Mainnet.IMD);
        assertEq(q.oracleSigner(), Mainnet.ORACLE_SIGNER);
        assertEq(address(report.QUESTIONS()), address(q), "$contract:Questions, in JobsReport");
        assertEq(payroll.QUESTIONS(), address(q), "$contract:Questions, in Payroll");
        assertEq(report.PAYROLLS_FEED(), ids[0]);
        assertEq(report.HIRES_FEED(), ids[1]);
        assertEq(report.EMPLOYERS_FEED(), ids[2]);
        assertEq(address(payroll.IMD()), Mainnet.IMD);
        assertEq(payroll.SIMD(), Mainnet.SIMD);
        assertEq(payroll.SEATS(), Mainnet.SEATS);
        assertEq(payroll.SEAT_COUNT(), Mainnet.SEAT_COUNT);
        assertEq(payroll.ADAPTER(), Mainnet.SEAT_ADAPTER);
        assertEq(payroll.FEED_A(), ids[0]);
        assertEq(payroll.FEED_B(), ids[1]);
        assertEq(payroll.FEED_C(), ids[2]);

        // The dependencies the constructors could not check are what the contracts expect. The
        // Intake is version 2: it answers a getter version 1 does not have.
        assertGt(Mainnet.INTAKE.code.length, 0);
        assertEq(Mainnet.INTAKE, 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(IIntakeV2(Mainnet.INTAKE).failureSelectorOf(bytes32(0)), bytes4(0), "the Intake is not version 2");
        assertEq(IERC4626(Mainnet.SIMD).asset(), Mainnet.IMD, "sIMD is a vault over IMD");
        assertGt(IERC20(Mainnet.SIMD).totalSupply(), 0, "sIMD has stakers");
        assertEq(INTAKE.priceOf(Mainnet.ORACLE_ACTION, Mainnet.IMD), 0.5e18, "the Intake price has changed");
    }

    function test_fork_rehearsal_onlyTheDeployerLaunchesAndOnlyOnce() public onFork {
        IProjectFactory.ContractsParams memory p;
        p.launchNumber = LAUNCH_NUMBER + 1;
        p.contractCreationCodes = new bytes[](1);
        p.contractCreationCodes[0] = initcodes[0];
        p.contractNames = new bytes32[](1);
        p.contractNames[0] = bytes32("Questions");
        p.expectedContracts = new address[](1);
        p.expectedContracts[0] = FACTORY.predictContract(LAUNCH_NUMBER + 1, 0, initcodes[0]);
        p.record.kind = bytes32("evm_contracts");
        p.record.launchNumber = LAUNCH_NUMBER + 1;
        p.agentIds = new uint256[](0);

        vm.expectRevert(IProjectFactory.NotDeployer.selector);
        FACTORY.launchContracts(p);

        p.launchNumber = LAUNCH_NUMBER;
        p.record.launchNumber = LAUNCH_NUMBER;
        vm.prank(Mainnet.LAUNCH_DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IProjectFactory.AlreadyLaunched.selector, LAUNCH_NUMBER));
        FACTORY.launchContracts(p);
    }

    /// @notice The whole launch, as one transaction, is inside our 12 million gas gate (the
    /// protocol's ceiling is 16.7 million): what the factory call used here plus what the
    /// transaction's calldata costs before any code runs. Each contract is inside our size gates.
    function test_fork_rehearsal_launchFitsOurGasAndSizeGates() public onFork {
        uint256 totalInitcode;
        uint256 totalRuntime;
        for (uint256 i; i < 3; ++i) {
            totalRuntime += launched[i].code.length;
            emit log_named_uint(string.concat(_contractName(i), ": runtime bytes"), launched[i].code.length);
            emit log_named_uint(string.concat(_contractName(i), ": initcode bytes with arguments"), initcodes[i].length);
            assertLe(launched[i].code.length, RUNTIME_GATE, _contractName(i));
            assertLe(initcodes[i].length, INITCODE_GATE, _contractName(i));
            totalInitcode += initcodes[i].length;
        }
        uint256 total = launchExecutionGas + launchIntrinsicGas;
        emit log_named_uint("launch A: initcode bytes in all", totalInitcode);
        emit log_named_uint("launch A: gas used by the factory call", launchExecutionGas);
        emit log_named_uint("launch A: intrinsic gas of the transaction", launchIntrinsicGas);
        emit log_named_uint("launch A: the two together", total);
        emit log_named_uint("launch A: gas per initcode byte", total / totalInitcode);
        // Storing code alone costs 200 gas a byte: a figure below that was not measured at all.
        assertGt(launchExecutionGas, 200 * totalRuntime, "the factory call's gas was not measured");
        assertLt(total, LAUNCH_GAS_GATE, "launch A is over our gas gate");
        assertLt(total, totalInitcode * GAS_PER_INITCODE_BYTE, "the 240-a-byte estimate is not on the safe side");
    }

    /// @notice The bytecode the factory put on chain holds no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_fork_rehearsal_deployedBytecodeHasNoForbiddenOpcode() public onFork {
        for (uint256 i; i < 3; ++i) {
            bytes memory code = launched[i].code;
            assertEq(_firstOpcode(code, _forbidden()), code.length, _contractName(i));
        }
    }

    // ---- the first day --------------------------------------------------------------------------

    /// @dev Steps 1 and 2 of the runbook: anyone creates the three feeds from the calldata in the
    /// document, and a wallet funds each meter with its runway.
    function _createAndFundTheFeeds() internal {
        string[3] memory names = _feedNames();
        string memory doc = _doc();
        for (uint256 i; i < 3; ++i) {
            bytes memory data = vm.parseBytes(_block(doc, string.concat("createFeed:", names[i]), "text"));
            uint256 g = gasleft();
            (bool ok, bytes memory out) = address(q).call(data);
            emit log_named_uint(string.concat("createFeed, ", names[i], ": gas"), g - gasleft());
            assertTrue(ok, names[i]);
            assertEq(abi.decode(out, (bytes32)), feeds[i], names[i]);
        }
        uint256 cost = q.costOf(feeds[0]);
        deal(Mainnet.IMD, funder, 32 * cost);
        vm.startPrank(funder);
        IMD.approve(address(q), 32 * cost);
        q.fund(feeds[0], 14 * cost);
        q.fund(feeds[1], 14 * cost);
        q.fund(feeds[2], 4 * cost);
        vm.stopPrank();
    }

    /// @dev Step 3 for one feed: a keeper's `request`, bought from the live Intake. One request per
    /// test, because the real contract allows one per transaction.
    function _firstRequest(uint256 i) internal {
        _createAndFundTheFeeds();
        uint256 price = INTAKE.priceOf(Mainnet.ORACLE_ACTION, Mainnet.IMD);
        uint256 tip = q.feedParams(feeds[i]).tip;
        (bytes memory body, bytes32 questionHash, uint64 fromBlock, uint64 toBlock) = q.nextBody(feeds[i]);
        (uint256 meterBefore,) = q.meterOf(feeds[i]);
        uint256 payeeBefore = IMD.balanceOf(Mainnet.FEE_PAYEE);

        vm.recordLogs();
        vm.prank(keeper);
        uint256 g = gasleft();
        bytes32 intakeId = q.request(feeds[i]);
        emit log_named_uint(string.concat("request, ", _feedNames()[i], ": gas"), g - gasleft());

        // The live Intake took the price and recorded the request with this contract's callback.
        assertEq(IMD.balanceOf(Mainnet.FEE_PAYEE) - payeeBefore, price, "the fee payee was not paid the price");
        (address payer, address target, bytes4 selector, bool completed) = INTAKE.requests(intakeId);
        assertEq(payer, address(q));
        assertEq(target, address(q));
        assertEq(selector, Questions.onOracleResult.selector);
        assertFalse(completed);
        // The Intake's own event carries the body, byte for byte what `nextBody` showed beforehand.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].emitter == Mainnet.INTAKE && logs[k].topics[0] == IIntake.Requested.selector) {
                (bytes memory sent,,,,) = abi.decode(logs[k].data, (bytes, address, bytes4, address, uint256));
                assertEq(sent, body, "the body sent is not the body shown");
                assertEq(logs[k].topics[1], intakeId);
                seen = true;
            }
        }
        assertTrue(seen, "the Intake did not emit Requested");

        // The round is open for the window shown, the meter paid price and tip, the tip is set aside.
        (IQuestions.RoundStatus status,, uint64 from, uint64 to,) = q.roundOf(feeds[i], 1);
        assertTrue(status == IQuestions.RoundStatus.Pending);
        assertEq(from, fromBlock);
        assertEq(to, toBlock);
        (, bytes32 storedHash, bytes32 closingHash,) = q.roundRequest(feeds[i], 1);
        assertEq(storedHash, questionHash);
        assertEq(closingHash, blockhash(toBlock), "the closing block's hash was not read");
        (uint256 meterAfter,) = q.meterOf(feeds[i]);
        assertEq(meterBefore - meterAfter, price + tip);
        (uint256 earned, uint256 pending) = q.tipsOf(keeper);
        assertEq(earned, 0, "asking earned the keeper something");
        assertEq(pending, tip);
        assertEq(IMD.balanceOf(address(q)), q.totalMetered() + q.totalTips());
        assertEq(IMD.allowance(address(q), Mainnet.INTAKE), 0);

        // Nobody answers. One second before the the full silence deadline are up the round cannot be closed;
        // at the full silence deadline anyone closes it and the tip is back on the meter.
        uint256 askedAt = vm.getBlockTimestamp();
        uint256 silence = q.ABANDON_AFTER_SILENCE() + q.feedParams(feeds[i]).validFor + q.ISSUED_AT_TOLERANCE() + 1;
        skip(silence - 1);
        vm.expectRevert(abi.encodeWithSelector(Questions.TooEarlyToAbandon.selector, askedAt + silence));
        q.abandon(feeds[i]);
        skip(1);
        assertTrue(q.abandon(feeds[i]));
        (uint256 meterClosed,) = q.meterOf(feeds[i]);
        assertEq(meterBefore - meterClosed, price, "a failed round cost the meter more than the price");
        (earned, pending) = q.tipsOf(keeper);
        assertEq(earned + pending, 0);
        assertEq(q.totalTips(), 0);
        // The funder can still take out everything that was not spent.
        vm.prank(funder);
        assertEq(q.defund(feeds[i], type(uint256).max), meterClosed);
    }

    function test_fork_rehearsal_firstRequest_payrolls() public onFork {
        _firstRequest(0);
    }

    function test_fork_rehearsal_firstRequest_hires() public onFork {
        _firstRequest(1);
    }

    function test_fork_rehearsal_firstRequest_employers() public onFork {
        _firstRequest(2);
    }

    /// @notice Revenue reaches the launched Payroll, its feed budget tops the launched meters up to
    /// their runways and no further, and the staker stream reaches the live sIMD.
    function test_fork_rehearsal_payrollFundsTheMetersAndDrips() public onFork {
        string[3] memory names = _feedNames();
        string memory doc = _doc();
        for (uint256 i; i < 3; ++i) {
            (bool ok,) = address(q).call(vm.parseBytes(_block(doc, string.concat("createFeed:", names[i]), "text")));
            assertTrue(ok);
        }
        address payer = makeAddr("payer");
        deal(Mainnet.IMD, payer, 1_000e18);
        vm.startPrank(payer);
        IMD.approve(address(payroll), 1_000e18);
        payroll.pay(1_000e18, bytes32("rehearsal")); // 500 stakers, 300 seats, 200 feeds
        vm.stopPrank();

        uint256 cost = q.costOf(feeds[0]);
        (uint256 funded, uint256 released) = payroll.fundFeeds();
        assertEq(funded, (14 + 14 + 4) * cost);
        assertEq(released, 0);
        (uint256 again,) = payroll.fundFeeds();
        assertEq(again, 0, "full meters take nothing more");
        assertEq(IMD.allowance(address(payroll), address(q)), 0);

        skip(1 hours);
        uint256 assetsBefore = IERC4626(Mainnet.SIMD).totalAssets();
        uint256 sent = payroll.drip();
        assertGt(sent, 0);
        assertEq(IERC4626(Mainnet.SIMD).totalAssets(), assetsBefore + sent);
        (,,,, uint256 total) = payroll.owed();
        assertEq(IMD.balanceOf(address(payroll)), total, "the balance is exactly what is owed");
    }

    // ---- the proof requests bought before launch ------------------------------------------------

    /// @dev What `docs/LAUNCH.md` tells the team to do before launch, for one feed: from an
    /// ordinary wallet, approve the Intake for the price and buy the feed's body with no callback.
    /// The body is assembled the way the document's shell lines assemble it. This shows the live
    /// Intake takes the call and the payment; whether the oracle then answers the body is what the
    /// real purchase is for, and no test can show it.
    function _proofRequest(uint256 i) internal {
        HouseFeed memory h = _houseFeed(_feedNames()[i]);
        uint256 blocks = vm.parseUint(_block(_doc(), string.concat("proof:blocks:", h.name), "text"));
        uint256 to = vm.getBlockNumber() - 12;
        uint256 from = to - (blocks - 1);
        bytes memory body = bytes.concat(
            h.qPrefix, bytes(string.concat(vm.toString(from), ',"toBlock":', vm.toString(to), "}")), h.tail
        );

        address wallet = makeAddr("an ordinary wallet");
        uint256 price = vm.parseUint(_block(_doc(), "proof:priceWei", "text"));
        deal(Mainnet.IMD, wallet, price);
        uint256 payeeBefore = IMD.balanceOf(Mainnet.FEE_PAYEE);

        vm.startPrank(wallet);
        IMD.approve(Mainnet.INTAKE, price);
        vm.expectEmit(false, true, true, true, Mainnet.INTAKE);
        emit IIntake.Requested(
            bytes32(0), wallet, Mainnet.ORACLE_ACTION, body, address(0), bytes4(0), Mainnet.IMD, price
        );
        bytes32 intakeId =
            INTAKE.request(Mainnet.ORACLE_ACTION, body, IIntake.Callback(address(0), bytes4(0)), Mainnet.IMD, price);
        vm.stopPrank();

        assertEq(IMD.balanceOf(Mainnet.FEE_PAYEE) - payeeBefore, price);
        assertEq(IMD.balanceOf(wallet), 0);
        assertEq(IMD.allowance(wallet, Mainnet.INTAKE), 0);
        (address payer, address target, bytes4 selector, bool completed) = INTAKE.requests(intakeId);
        assertEq(payer, wallet);
        assertEq(target, address(0));
        assertEq(selector, bytes4(0));
        assertFalse(completed);
    }

    function test_fork_proof_walletBuysThePayrollsBody() public onFork {
        _proofRequest(0);
    }

    function test_fork_proof_walletBuysTheHiresBody() public onFork {
        _proofRequest(1);
    }

    function test_fork_proof_walletBuysTheEmployersBody() public onFork {
        _proofRequest(2);
    }
}
