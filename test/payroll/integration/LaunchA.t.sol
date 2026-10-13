// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Questions} from "../../../src/questions/Questions.sol";
import {OracleAttestation} from "../../../src/questions/OracleAttestation.sol";
import {Payroll} from "../../../src/payroll/Payroll.sol";
import {JobsReport} from "../../../src/payroll/JobsReport.sol";
import {QuestionsFixture} from "../../questions/QuestionsFixture.sol";
import {MockSIMD} from "../mocks/MockTokens.sol";
import {MockSeats, MockAdapter} from "../mocks/MockSeats.sol";

/// @dev Payroll and JobsReport against the real `Questions` contract, the third contract of launch A,
/// instead of this area's hand-written mock. The mock lets a test write any window by hand; the real
/// contract derives every window from the block a request was made in, which is what the two findings
/// about the hires count and the streak turned on. These tests began as the reviewers' demonstrations.
///
/// The set-up (a mock Intake that follows the verified one, a test oracle key, the helpers that play
/// the keeper and the Intake's writer) is the Questions area's own `QuestionsFixture`; nothing in that
/// area is changed, only compiled.
contract LaunchAIntegrationTest is QuestionsFixture {
    uint256 internal constant SEAT_COUNT = 2000;

    bytes32 internal payrollsFeed;
    bytes32 internal hiresFeed;
    bytes32 internal employersFeed;

    Payroll internal payroll;
    JobsReport internal report;
    MockSIMD internal simd;
    MockSeats internal seats;
    MockAdapter internal adapter;

    address internal payer = makeAddr("payer");

    function setUp() public override {
        super.setUp();

        // The three house feeds, with the launch fixtures' shape: two daily contiguous uint256 feeds
        // (cadence 7,000 blocks, window at most 21,600, lag 12) and a weekly address-list feed.
        Questions.FeedParams memory p = _params();
        payrollsFeed = q.createFeed(p, _prefixWith("uint256", "What is the sum in the window?"), _tail(7, 5, 86_400));
        hiresFeed = q.createFeed(p, _prefixWith("uint256", "How many in the window?"), _tail(7, 5, 86_400));
        p.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        p.contiguous = false;
        p.cadenceBlocks = 49_000;
        p.maxWindowBlocks = 50_400;
        employersFeed = q.createFeed(p, _prefixWith("address[]", "Who paid most in the window?"), _tail(7, 5, 86_400));

        simd = new MockSIMD(IERC20(address(imd)));
        seats = new MockSeats(SEAT_COUNT);
        adapter = new MockAdapter();
        payroll = _payroll(payrollsFeed, hiresFeed, employersFeed);
        report = new JobsReport(address(q), payrollsFeed, hiresFeed, employersFeed);

        imd.mint(payer, 1_000_000e18);
        vm.startPrank(payer);
        imd.approve(address(payroll), type(uint256).max);
        imd.approve(address(simd), type(uint256).max);
        simd.deposit(1_000e18, payer);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _payroll(bytes32 a, bytes32 b, bytes32 c) internal returns (Payroll) {
        return
            new Payroll(address(imd), address(simd), address(seats), SEAT_COUNT, address(adapter), address(q), a, b, c);
    }

    function _prefixWith(string memory answerType, string memory question) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                '{"answerType":"',
                answerType,
                '","chainId":',
                vm.toString(vm.getChainId()),
                ',"definitions":{"recipe":"{\\"kind\\":\\"log-sum\\"} - write recipe exactly this."},',
                '"question":"',
                question,
                '","v":1,"window":{"fromBlock":'
            )
        );
    }

    function _advance(uint256 blockCount) internal {
        vm.roll(vm.getBlockNumber() + blockCount);
        skip(blockCount * 12);
    }

    function _rollTo(uint256 blockNumber) internal {
        uint256 current = vm.getBlockNumber();
        if (blockNumber > current) _advance(blockNumber - current);
    }

    /// @dev The first block at which the feed's cadence allows another request.
    function _dueBlock(bytes32 feedId) internal view returns (uint256) {
        return q.feedState(feedId).nextRequestBlock;
    }

    /// @dev Buys the feed's next answer at the first block its cadence allows, as a keeper paid by the
    /// tip would.
    function _answerWhenDue(bytes32 feedId, uint256 value) internal {
        _rollTo(_dueBlock(feedId));
        _answer(feedId, abi.encode(value));
    }

    function _fundThroughPayroll(uint256 revenue) internal {
        vm.prank(payer);
        payroll.pay(revenue, bytes32("integration"));
        payroll.fundFeeds();
    }

    function _window(bytes32 feedId, uint64 round) internal view returns (uint64 fromBlock, uint64 toBlock) {
        (,, fromBlock, toBlock,) = q.roundOf(feedId, round);
    }

    function _meter(bytes32 feedId) internal view returns (uint256 balance) {
        (balance,) = q.meterOf(feedId);
    }

    // ---------------------------------------------------------------------------------------------
    // The feed budget against real meters
    // ---------------------------------------------------------------------------------------------

    /// @dev `fundFeeds` reads the real `costOf` and `redeemable`, and the real `fund` takes exactly the
    /// shortfall: the two daily meters end at 14 requests' worth, the weekly one at 4, a bought request
    /// is replaced, and no allowance stays.
    function test_integration_fundFeedsTopsUpRealMeters() public {
        assertEq(q.costOf(payrollsFeed), COST, "live Intake price plus the feed's keeper tip");

        vm.prank(payer);
        payroll.pay(1_000e18, bytes32("integration")); // 200 IMD of feed budget
        (uint256 funded, uint256 released) = payroll.fundFeeds();

        assertEq(funded, (14 + 14 + 4) * COST);
        assertEq(released, 0);
        assertEq(_meter(payrollsFeed), 14 * COST);
        assertEq(_meter(hiresFeed), 14 * COST);
        assertEq(_meter(employersFeed), 4 * COST);
        bytes32[3] memory feeds = [payrollsFeed, hiresFeed, employersFeed];
        for (uint256 i; i < 3; ++i) {
            (, uint256 totalShares) = q.meterOf(feeds[i]);
            assertEq(q.sharesOf(feeds[i], address(payroll)), totalShares, "Payroll holds every share it paid for");
        }
        assertEq(imd.allowance(address(payroll), address(q)), 0);
        assertEq(q.totalMetered(), 32 * COST);

        // Full meters take nothing more.
        (funded,) = payroll.fundFeeds();
        assertEq(funded, 0);

        // A request is bought from one meter (price to the Intake, tip to the keeper): only that is replaced.
        _answer(payrollsFeed, abi.encode(uint256(53.5e18)));
        assertEq(_meter(payrollsFeed), 13 * COST);
        (funded,) = payroll.fundFeeds();
        assertEq(funded, COST);

        Payroll.Ledger memory l = payroll.ledger();
        assertEq(l.feedsFunded, 33 * COST);
        (,,,, uint256 total) = payroll.owed();
        assertEq(imd.balanceOf(address(payroll)), total, "the balance is exactly what is owed");
    }

    /// @dev A budget too small for the two daily feeds is split between them; the weekly feed, which the
    /// report does not need, gets nothing until they are covered. The real `fund` accepts each part.
    function test_integration_aShortBudgetGoesToTheTwoDailyFeeds() public {
        vm.prank(payer);
        payroll.pay(25e18, bytes32("integration")); // 5 IMD of feed budget against 14.28 the two lack
        (uint256 funded,) = payroll.fundFeeds();

        assertEq(funded, 5e18);
        assertEq(_meter(payrollsFeed), 2.5e18);
        assertEq(_meter(hiresFeed), 2.5e18);
        assertEq(_meter(employersFeed), 0);

        // With 2.5 IMD each, both daily feeds can buy their answers; the report prints with its count.
        _answer(payrollsFeed, abi.encode(uint256(53.5e18)));
        _answer(hiresFeed, abi.encode(uint256(107)));
        (uint256 printed, uint256 counted) = report.print();
        assertEq(printed, 1);
        assertEq(counted, 1);
        assertEq(report.printAt(0).count, 107);
    }

    /// @dev A feed Questions does not know costs nothing and is skipped, whichever of the three it is;
    /// the others are still served. (The real `fund` reverts for an unknown feed; it is never called.)
    function test_integration_anUnknownHouseFeedIsSkipped() public {
        bytes32 unknown = keccak256("a feed nobody created");
        Payroll noThird = _payroll(payrollsFeed, hiresFeed, unknown);
        Payroll noFirst = _payroll(unknown, hiresFeed, employersFeed);
        vm.startPrank(payer);
        imd.approve(address(noThird), type(uint256).max);
        imd.approve(address(noFirst), type(uint256).max);
        noThird.pay(1_000e18, bytes32("integration"));
        noFirst.pay(1_000e18, bytes32("integration"));
        vm.stopPrank();

        (uint256 funded,) = noThird.fundFeeds();
        assertEq(funded, 28 * COST);

        // The second Payroll keeps a runway of its own on the hires meter, whatever the first one
        // holds there (each counts only its own position), and the weekly feed takes its four requests.
        (funded,) = noFirst.fundFeeds();
        assertEq(funded, 18 * COST);
        assertEq(_meter(hiresFeed), 28 * COST);
        assertEq(q.redeemable(hiresFeed, address(noThird)), 14 * COST);
        assertEq(q.redeemable(hiresFeed, address(noFirst)), 14 * COST);
        assertEq(_meter(employersFeed), 4 * COST);
    }

    // ---------------------------------------------------------------------------------------------
    // Printing and crowning from real rounds
    // ---------------------------------------------------------------------------------------------

    /// @dev The answer bytes of a real attested address list (oracle request a4d33e90, kept in
    /// test/fixtures/payroll/attested-address-list.json), stored by the real Questions as its hash and
    /// crowned from the same bytes.
    function test_integration_crownAcceptsARealAttestedList() public {
        string memory json = vm.readFile("test/fixtures/payroll/attested-address-list.json");
        bytes memory attested = vm.parseJsonBytes(json, ".answer");
        assertEq(keccak256(attested), vm.parseJsonBytes32(json, ".answerKeccak"));

        _fundThroughPayroll(1_000e18);
        _answer(employersFeed, attested);
        (, uint256 stored, uint64 fromBlock, uint64 toBlock,) = q.roundOf(employersFeed, 1);
        assertEq(stored, uint256(keccak256(attested)));

        report.crown(1, attested);
        JobsReport.Crown memory c = report.crownOf(1);
        assertEq(c.first, vm.parseJsonAddress(json, ".first"));
        assertEq(c.second, address(0));
        assertEq(c.places, vm.parseJsonUint(json, ".places"));
        assertEq(c.fromBlock, fromBlock);
        assertEq(c.toBlock, toBlock);
        assertEq(uint256(toBlock) - fromBlock + 1, 50_400);

        // A list with one address changed is refused; the attested one is accepted.
        _advance(49_000);
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(0xA1), address(0xB2), address(0xC3));
        _answer(employersFeed, abi.encode(three));
        three[2] = address(0xC4);
        vm.expectRevert(abi.encodeWithSelector(JobsReport.AnswerMismatch.selector, uint64(2)));
        report.crown(2, abi.encode(three));
        three[2] = address(0xC3);
        report.crown(2, abi.encode(three));
        assertEq(report.crownOf(2).third, address(0xC3));
        assertEq(report.latestCrownedRound(), 2);
    }

    /// @dev Both daily feeds bought in the same block: one print with its count. Then a payrolls round
    /// that gets no answer: it is passed over, and the hires answer of that day is recorded all the same.
    function test_integration_printFollowsRealRounds() public {
        _fundThroughPayroll(1_000e18);
        _answer(payrollsFeed, abi.encode(uint256(53.5e18)));
        _answer(hiresFeed, abi.encode(uint256(107)));
        (uint256 printed, uint256 counted) = report.print();
        assertEq(printed, 1);
        assertEq(counted, 1);
        JobsReport.Print memory first = report.printAt(0);
        assertEq(first.amount, 53.5e18);
        assertEq(first.count, 107);
        assertEq(uint256(first.toBlock) - first.fromBlock + 1, CADENCE, "the first window is one cadence long");

        // Day 1: the payrolls round gets no answer and is abandoned; the hires round is answered.
        _rollTo(_dueBlock(payrollsFeed));
        _request(payrollsFeed);
        _answer(hiresFeed, abi.encode(uint256(90)));
        // Twelve hours of silence, at twelve seconds a block.
        _advance((abandonAfterSilence + 11) / 12);
        q.abandon(payrollsFeed);
        (printed, counted) = report.print();
        assertEq(printed, 0);
        assertEq(counted, 1, "the hires answer does not wait for a print");
        JobsReport.Summary memory s = report.summary();
        assertEq(s.payrollsRead, 2, "the failed round is consumed");
        assertEq(s.totalCount, 197);
        assertEq(report.countAt(1).print, 0, "its print has not come yet");

        // The payrolls feed asks again once its doubled cadence allows. Its window now covers day 1
        // and the hours since, so the print is longer than the day's count and the count stays in its
        // own series, where a reader finds it with its exact window.
        _answerWhenDue(payrollsFeed, 61e18);
        report.print();
        assertEq(report.printCount(), 2);
        assertEq(report.printAt(1).amount, 61e18);
        assertEq(report.printAt(1).fromBlock, first.toBlock + 1, "nothing between the two prints was skipped");
        assertEq(report.total(), 114.5e18);
    }

    /// @dev Audit job 22624be0, finding 5 (info). The Jobs Report passes over a round whose window
    /// ends at or after the block `print` is called in, and that is the one skip that depends on
    /// when the call is made. Against the real Questions it cannot fire: a window ends `lagBlocks`
    /// (at least five) behind the block of its request, so it is over before the answer can be
    /// stored, let alone printed. Here the request, the answer and `print` all happen in one block,
    /// the earliest a print can come, for a first window and for a catch-up window.
    function test_integration_aRealWindowIsAlwaysOverWhenItsAnswerIsPrinted() public {
        _fundThroughPayroll(1_000e18);
        assertGe(q.MIN_LAG_BLOCKS(), 5);

        for (uint256 day; day < 3; ++day) {
            if (day != 0) _rollTo(_dueBlock(payrollsFeed) + (day == 2 ? 30_000 : 0)); // day 2 is asked days late
            uint256 askedAt = vm.getBlockNumber();
            _answer(payrollsFeed, abi.encode(uint256(50e18)));
            (, uint64 toBlock) = _window(payrollsFeed, uint64(day + 1));
            assertLe(uint256(toBlock) + q.MIN_LAG_BLOCKS(), askedAt, "a window ended less than five blocks back");

            vm.recordLogs();
            (uint256 printed,) = report.print();
            assertEq(vm.getBlockNumber(), askedAt, "printed in the block of the request");
            assertEq(printed, 1, "a real round was passed over");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                assertTrue(logs[i].topics[0] != JobsReport.RoundSkipped.selector, "a real round was skipped");
            }
        }
        assertEq(report.printCount(), 3);
    }

    // ---------------------------------------------------------------------------------------------
    // The hires count after one late request
    // ---------------------------------------------------------------------------------------------

    /// @dev Reviewers' finding, as a regression test against the real contract. `request` is open to
    /// anyone and pays its caller the feed's tip, so each feed is asked as soon as its own cadence
    /// allows. If the hires feed is once asked 60 blocks (12 minutes) after payrolls, each feed's
    /// cadence keeps the two that far apart on every later day: both edges of every later hires window
    /// sit 60 blocks after the print's. Under the old rule (both edges within 50 blocks) only the first
    /// of these nine prints ever got a count. Now all nine do, and each count says which blocks it covers.
    function test_integration_theHiresCountSurvivesOneLateRequest() public {
        _fundThroughPayroll(2_000e18);

        // Day 0: both feeds asked in the same block.
        _answer(payrollsFeed, abi.encode(uint256(50e18)));
        _answer(hiresFeed, abi.encode(uint256(100)));
        report.print();
        assertEq(report.printAt(0).hiresRound, 1, "day 0 has its count");

        // Day 1: payrolls on time, hires 60 blocks later.
        _answerWhenDue(payrollsFeed, 51e18);
        _advance(60);
        _answer(hiresFeed, abi.encode(uint256(101)));
        report.print();

        // Days 2 to 8: each feed asked at the first block its cadence allows.
        for (uint256 day = 2; day <= 8; ++day) {
            _answerWhenDue(payrollsFeed, (50 + day) * 1e18);
            _answerWhenDue(hiresFeed, 100 + day);
            report.print();
            payroll.fundFeeds();
        }

        // The windows are a constant 60 blocks apart on both edges, day after day.
        (uint64 payFrom, uint64 payTo) = _window(payrollsFeed, 9);
        (uint64 hiresFrom, uint64 hiresTo) = _window(hiresFeed, 9);
        assertEq(hiresFrom - payFrom, 60);
        assertEq(hiresTo - payTo, 60);

        JobsReport.Summary memory s = report.summary();
        assertEq(s.prints, 9, "nine days were printed");
        assertEq(s.counts, 9, "nine counts were recorded");
        assertEq(s.hiresRead, 9);
        uint256 sum;
        for (uint256 day; day <= 8; ++day) {
            JobsReport.Print memory p = report.printAt(day);
            assertEq(p.hiresRound, day + 1, "a print is without its count");
            assertEq(p.count, 100 + day);
            assertEq(p.amount, (50 + day) * 1e18);
            JobsReport.Count memory c = report.countAt(day);
            assertEq(c.print, day + 1);
            (uint64 from, uint64 to) = _window(hiresFeed, uint64(day + 1));
            assertEq(c.fromBlock, from, "the count keeps the window it really covers");
            assertEq(c.toBlock, to);
            sum += 100 + day;
        }
        assertEq(s.totalCount, sum);
        assertEq(s.streak, 9, "payrolls was asked on time every day");
    }

    /// @dev The hires feed falls a whole day behind (its meter was dry, say) and catches up with one
    /// window over two days. That count joins no daily print, is still in the total, and the days after
    /// pair again.
    function test_integration_aCatchUpCountIsKeptAndTheDaysAfterPairAgain() public {
        _fundThroughPayroll(2_000e18);
        _answer(payrollsFeed, abi.encode(uint256(50e18)));
        _answer(hiresFeed, abi.encode(uint256(100)));

        // Day 1: only payrolls. Day 2: both, so the hires window covers days 1 and 2.
        _answerWhenDue(payrollsFeed, 51e18);
        _answerWhenDue(payrollsFeed, 52e18);
        _answer(hiresFeed, abi.encode(uint256(203)));
        // Day 3: both, in the same block again.
        _answerWhenDue(payrollsFeed, 53e18);
        _answer(hiresFeed, abi.encode(uint256(104)));
        report.print();
        report.print();

        (uint64 from, uint64 to) = _window(hiresFeed, 2);
        assertEq(uint256(to) - from + 1, 2 * uint256(CADENCE), "one hires window over two days");
        assertEq(report.printCount(), 4);
        assertEq(report.countsRecorded(), 3);
        assertEq(report.totalCount(), 407, "nothing is dropped from the total");
        assertEq(report.printAt(0).count, 100);
        assertEq(report.printAt(1).hiresRound, 0);
        assertEq(report.printAt(2).hiresRound, 0);
        assertEq(report.countAt(1).print, 0, "a two-day count is no day's count");
        assertEq(report.printAt(3).count, 104);
        assertEq(report.countAt(2).print, 4);
    }

    // ---------------------------------------------------------------------------------------------
    // The streak on a feed whose windows tile
    // ---------------------------------------------------------------------------------------------

    /// @dev Reviewers' finding, as a regression test against the real contract. A contiguous feed always
    /// starts its next window at the block after its last answered one, so no print ever shows a gap:
    /// before the fix the streak never broke and was simply the number of prints. Here nobody asks for
    /// four days, then a round fails. The catch-up prints that follow cover three days each and end
    /// the run; a new run starts with the first day-sized print.
    function test_integration_theStreakEndsAfterAMissedDay() public {
        _fundThroughPayroll(1_000e18);
        _answer(payrollsFeed, abi.encode(uint256(50e18)));
        _answerWhenDue(payrollsFeed, 50e18);
        report.print();
        assertEq(report.summary().streak, 2);

        // Nobody asks for four days (28,800 blocks). Then a failed round, then two answered ones.
        _advance(28_800);
        _request(payrollsFeed);
        _advance((abandonAfterSilence + 11) / 12);
        q.abandon(payrollsFeed);
        _answerWhenDue(payrollsFeed, 150e18);
        _answerWhenDue(payrollsFeed, 120e18);
        report.print();

        JobsReport.Summary memory s = report.summary();
        assertEq(s.prints, 4);
        assertEq(s.streak, 0, "four days of silence and a failed round ended the run");
        assertEq(s.longestStreak, 2);
        JobsReport.Print memory catchUp = report.printAt(2);
        assertEq(uint256(catchUp.toBlock) - catchUp.fromBlock + 1, MAX_WINDOW, "a three-day catch-up window");
        assertEq(catchUp.fromBlock, report.printAt(1).toBlock + 1, "with no gap before it");
        assertEq(report.bestAmount(), 50e18, "which cannot be the best day either");

        // The feed works off its backlog, asked every time its cadence allows; the run restarts with
        // the first window that is a day long again.
        uint256 catchUps;
        while (true) {
            _answerWhenDue(payrollsFeed, 10e18);
            report.print();
            JobsReport.Print memory p = report.printAt(report.printCount() - 1);
            if (uint256(p.toBlock) - p.fromBlock + 1 <= report.MAX_DAY_BLOCKS()) break;
            assertEq(report.summary().streak, 0);
            assertLt(++catchUps, 10);
        }
        assertEq(report.summary().streak, 1);
        _answerWhenDue(payrollsFeed, 10e18);
        report.print();
        s = report.summary();
        assertEq(s.streak, 2);
        assertEq(s.longestStreak, 2);
        assertLt(s.streak, s.prints, "the streak is no longer the number of prints");
    }

    // ---------------------------------------------------------------------------------------------
    // The launch as a whole
    // ---------------------------------------------------------------------------------------------

    /// @dev The launch pipeline creates the three contracts in manifest order on a chain where none of
    /// their dependencies has code, and calls nothing afterwards. All three constructors must run
    /// there, and the launch must fit the gas gate: the brief counts about 240 gas for each byte of
    /// initcode, all costs included, and sets the gate at 12 million (the hard limit is 16.7 million).
    function test_integration_launchAConstructsOnAnEmptyChainInsideTheGasGate() public {
        address intake = address(0x1A7A4E);
        address token = address(0x1AD);
        address signer = address(0x5160E2);
        assertEq(intake.code.length + token.code.length + signer.code.length, 0);

        // Each contract is created with CREATE on its creation code and arguments, as the factory
        // creates it, so that the cost is charged to this call and can be measured. (`new` in a
        // test is not charged: this Foundry turns it into a cheatcode that deploys for nothing.)
        (address questions, uint256 creationGas) =
            _createMeasured(bytes.concat(type(Questions).creationCode, abi.encode(intake, token, signer)), 0);
        address r;
        (r, creationGas) = _createMeasured(
            bytes.concat(type(JobsReport).creationCode, abi.encode(questions, payrollsFeed, hiresFeed, employersFeed)),
            creationGas
        );
        address pr;
        (pr, creationGas) = _createMeasured(
            bytes.concat(
                type(Payroll).creationCode,
                abi.encode(
                    token,
                    address(0x51AD),
                    address(0x5EA75),
                    SEAT_COUNT,
                    address(0xADA97E2),
                    questions,
                    payrollsFeed,
                    hiresFeed,
                    employersFeed
                )
            ),
            creationGas
        );
        assertEq(address(JobsReport(r).QUESTIONS()), questions);
        assertEq(Payroll(pr).QUESTIONS(), questions);
        // Storing code alone costs 200 gas a byte: a figure below that was not measured at all.
        assertGt(
            creationGas,
            200 * (questions.code.length + r.code.length + pr.code.length),
            "the creation cost was not measured"
        );

        // 96, 128 and 288 bytes of constructor arguments follow the three creation codes.
        uint256 initcode = type(Questions).creationCode.length + type(JobsReport).creationCode.length
            + type(Payroll).creationCode.length + 96 + 128 + 288;
        emit log_named_uint("initcode of launch A, bytes", initcode);
        emit log_named_uint("launch A at 240 gas a byte", initcode * 240);
        emit log_named_uint("creation alone, measured here", creationGas);
        assertLt(initcode * 240, 12_000_000, "launch A is over our gas gate");
        assertLt(creationGas, initcode * 240, "the estimate is on the safe side of the measured creation cost");
    }

    /// @dev CREATE on `initcode`. Returns the new address and `spent` plus what the creation cost.
    function _createMeasured(bytes memory initcode, uint256 spent) internal returns (address created, uint256 total) {
        uint256 g = gasleft();
        assembly ("memory-safe") {
            created := create(0, add(initcode, 0x20), mload(initcode))
        }
        total = spent + (g - gasleft());
        assertTrue(created != address(0), "a launch constructor reverted on a chain with no other contract");
    }

    // ---------------------------------------------------------------------------------------------
    // Decision 13: complete without the employers feed
    // ---------------------------------------------------------------------------------------------

    /// @dev The employers feed is never asked (or never answers): the report still prints amounts,
    /// counts, the total, the best day and the streak. Only `crown` has nothing to work with.
    function test_integration_theReportIsCompleteWithoutTheEmployersFeed() public {
        _fundThroughPayroll(1_000e18);
        for (uint256 day; day < 3; ++day) {
            _answerWhenDue(payrollsFeed, (40 + day) * 1e18);
            _answer(hiresFeed, abi.encode(uint256(80 + day)));
        }
        assertEq(q.roundCount(employersFeed), 0);
        report.print();

        JobsReport.Summary memory s = report.summary();
        assertEq(s.prints, 3);
        assertEq(s.total, 123e18);
        assertEq(s.totalCount, 243);
        assertEq(s.bestAmount, 42e18);
        assertEq(s.streak, 3);
        assertEq(s.pairedPrints, 3);
        assertEq(s.crowns, 0);
        (bool crowned,,) = report.latestCrown();
        assertFalse(crowned);

        vm.expectRevert(abi.encodeWithSelector(JobsReport.RoundNotAnswered.selector, uint64(1)));
        report.crown(1, abi.encode(new address[](0)));
    }
}
