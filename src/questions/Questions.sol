// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Blockhash} from "@openzeppelin/contracts/utils/Blockhash.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IQuestions} from "../interfaces/IQuestions.sol";
import {IIntake} from "../interfaces/external/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {QuestionBody} from "./QuestionBody.sol";

/// @title Standing Questions: a contract that keeps buying its own oracle answers
/// @notice A feed is one question about this chain, asked again and again. Anyone may create a
/// feed, anyone may put IMD on its meter, and anyone may press `request` when the feed is due: the
/// contract then pays the IdentityMD Intake from the meter, sends the question for the newest block
/// window, and waits. The oracle's signed answer comes back through the Intake's callback and is
/// stored as one word per round, for other contracts to read with `latest` and `roundOf`.
///
/// Nobody owns this contract and nothing in it can be changed after deployment. The Intake, the IMD
/// token and the oracle signer are constructor arguments and stay fixed. What has to move with the
/// protocol is read at the moment it is needed: the price comes from `Intake.priceOf` under a cap
/// each feed sets for itself, and the action id is a parameter of each feed.
///
/// @dev Deviation from the protocol's oracle-consumer guide, on purpose: the guide asks for an
/// owner who can re-point the intake, the signer and the action. Here there is no such key, so
/// there is nobody who can redirect a feed to a signer of their own. The price of that choice is
/// that a rotated oracle signer or a moved Intake stops new answers from being accepted. Nothing
/// is lost when that happens: rounds fail and back off, every funder can still take back what the
/// meter has not spent, and feeds are content-addressed, so a redeployed copy of this contract
/// gives every feed the same id.
///
/// What an answer must satisfy before it is stored (`onOracleResult` and `submit` share the code):
/// it comes for a round that is still pending; it is signed by the oracle signer for this contract
/// on this chain and is inside its validity window; it has not already answered a round of this
/// feed; its chain, block window and answer type are the ones the round asked for; for a feed that
/// pins its question, its `questionHash` is the one built on chain from the feed's own text; its
/// panel and quorum are at least the feed's; enough panel members gave the signed answer; and its
/// closing block hash is the one this chain had when the round was opened.
///
/// Risks a reader should know:
/// - One key signs every answer. A wrong or compromised oracle key can write wrong values into
///   feeds. It cannot move a meter's IMD: no function pays out on an answer. If that key's account
///   ever gets code (an EIP-7702 delegation, for example), signatures are checked by asking that
///   code (ERC-1271), plain signatures stop verifying, and every round fails until this contract is
///   launched again. Meters stay redeemable throughout.
/// - A request costs the Intake price and is never refunded, answered or not. A round that gets
///   no answer is closed by `abandon` and the feed asks again later, at the meter's expense.
/// - The Intake serves one request per transaction. `request` refuses a second one of its own in
///   the same transaction, but it cannot see a request its caller bought elsewhere earlier in the
///   same transaction. This contract's request is then paid for and never served. The meter loses
///   the price; the round stays pending until its full silence deadline unless the
///   Intake completes it sooner; and the feed's cadence doubles. The caller is paid nothing for
///   it: the keeper tip is only set aside when a round is opened, it is earned when the round is
///   answered, and a round that fails gives it back to the meter. A caller that wins the first
///   request at each due block five times running still keeps a daily feed silent for about two
///   months, at the cost of five Intake prices of its own. Nothing on chain tells such a
///   transaction from an honest one, so this is disclosed and not prevented. What limits it: a
///   keeper sends `request` as a transaction of its own, never in a batch or a shared bundle; and
///   for a feed that `submit` is open to, anyone who buys the same question from the oracle for
///   this contract can hand the answer in thirty minutes after the request, which answers the
///   round and leaves the cadence as it was. The opener keeps the round's tip even then:
///   no on-chain field identifies which purchase produced a matching attestation.
/// - The Intake's callback can be hours late. `submit` opens after thirty minutes. Silence alone
///   permits abandonment only after twelve hours plus the feed's `validFor`, five minutes of
///   signing-clock tolerance, and one second: an answer signed within those first twelve hours
///   has its full requested validity to arrive. This is 36 hours, 5 minutes and 1 second for the
///   house feeds. Until answered or closed, a feed cannot ask again. The oracle may itself sign
///   later than twelve hours, or the writer may miss the entire deadline; those requests can
///   still fail. Panel-evidence feeds depend entirely on the callback, as `submit` is closed.
/// - `submit` takes any answer the oracle signed for this contract to the feed's question about
///   the round's blocks, from a panel at least as large as the feed's, once the Intake has
///   completed the feed's own request and nothing was stored, or thirty minutes after the request
///   if the Intake has still not completed it. Chain evidence with the recipe pinned in the
///   definitions has one answer, whoever asks, so it does not matter whose request it came from.
///   A feed whose question a panel judges cannot use `submit` at all. A chain-evidence feed that
///   leaves the recipe to the panel can be answered differently by two panels: once `submit` is
///   open, a party with an interest could buy several answers and hand in the one it prefers, so
///   nothing of value should hang on such a feed. What the question hash does not cover (guards,
///   tolerance, the ambiguity switch) is the submitted request's own.
/// - Two feeds with the same question text can ask about the same blocks. One attestation then
///   answers a round of each, once per feed. Each feed paid for a request of its own, and what one
///   of them does with an answer never takes it away from the other.
/// - A feed's WHEN gate is read once, inside the transaction that asks, and whoever asks earns
///   the tip once the round is answered. A gate on a value that can be moved and moved back within
///   one transaction (a pool balance, a spot price) can be opened by the caller at will.
/// - A tip given back by a failed round never lifts a meter share above one wei. In the rare case
///   where the shares outstanding cannot take all of it (most funders left while the round was
///   pending, or the meter was refilled from zero), the rest stays on the meter, pays for later
///   requests of the same feed, and can be taken out by nobody.
/// - IMD sent here by plain transfer, not through `fund`, belongs to no meter and stays here.
contract Questions is IQuestions, OracleAttestationConsumer, ReentrancyGuardTransient {
    // Every function that changes state and calls out takes the same transient lock, so no nested
    // call can run in between and put this contract's events out of order. The lint cannot see the
    // lock, and it counts calls into internal libraries as calls out.
    // forge-lint: disable-start(reentrancy-events)
    //
    // Every `==` in this contract compares an amount or a time stamp with zero (nothing there),
    // or two values of an enum. None compares a token balance with a figure somebody could push it
    // off by a wei, which is what the static analyser's strict-equality rule is for.
    // slither-disable-start incorrect-equality

    using SafeERC20 for IERC20;
    using TransientSlot for *;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Everything that defines a feed besides its question text. A feed's id is the hash of
    /// these, the question prefix and the tail, so two people who write the same feed get the same
    /// id and there is nothing to take over.
    struct FeedParams {
        /// The Intake action bought each round, e.g. `bytes32("oracle.request@oracle-1")`.
        bytes32 action;
        /// The chain the question is about. Must be the chain this contract is on: block windows
        /// are counted in this chain's blocks and the closing block hash is read from this chain.
        uint64 chainId;
        /// The protocol's code: 0 bool, 1 address, 2 bytes32, 3 uint256, 4 address[], 5 bytes32[].
        uint8 answerType;
        /// The panel size the body asks for, 2 to 300 (the protocol's limit; the live service may
        /// allow fewer and then refuses the body). An answer from a smaller panel is refused.
        uint16 panelSize;
        /// The quorum the body asks for. An answer signed for a lower quorum is refused.
        uint16 quorum;
        /// The fewest panel members that must have given the signed answer, 1 to `quorum`.
        /// `quorum` means "only what the panel itself agreed on": the answer is refused unless
        /// `agreed >= quorum` of the attestation. A lower number is the feed's choice to also take
        /// a chain-evidence answer the oracle settled by rerunning the members' recipe when their
        /// answers split, as long as at least this many members had the signed answer.
        uint16 minAgreed;
        /// `validForSeconds` as the body states it, 60 seconds to 30 days: how long after signing an
        /// answer may still be delivered or submitted.
        uint32 validFor;
        /// The fewest blocks between two requests. Doubles after each failed round, up to 32 times.
        uint32 cadenceBlocks;
        /// The most blocks one question may cover. A feed that is not contiguous always asks about
        /// exactly this many. A contiguous feed needs it above `cadenceBlocks`: the difference is
        /// how many blocks each round can catch up after a late or a failed one.
        uint32 maxWindowBlocks;
        /// How far behind the head a window ends, 5 to 256 blocks. The protocol refuses a window
        /// that ends fewer than 5 blocks back; 12 is the usual choice.
        uint16 lagBlocks;
        /// True: each window starts at the block after the last answered window's end, so windows
        /// tile with no gap and no overlap. False: each window is the newest `maxWindowBlocks`.
        bool contiguous;
        /// True: an answer must carry the `questionHash` built on chain from this feed's text.
        /// Required for `submit`. False only for a question whose hash the builder cannot reproduce.
        bool pinHash;
        /// The most the feed will pay the Intake for one request. A higher live price blocks requests.
        uint96 maxPrice;
        /// The keeper tip, at most `maxPrice`. `request` takes it from the meter and sets it aside;
        /// it is earned when the round is answered by the keeper that called `request`, whether
        /// the Intake delivers the answer or somebody hands it in with `submit`. A round that fails
        /// gives it back to the meter. Earned tips are taken out with `collectTips`.
        uint96 tip;
        /// WHEN gate comparison: 0 none, 1 >=, 2 <=, 3 >, 4 <, 5 ==, 6 != (the returned word against
        /// `gateThreshold`). Must be 0 exactly when `gateTarget` is zero.
        uint8 gateCmp;
        /// WHEN gate target. Zero for a feed with no gate. Otherwise `request` is allowed only while
        /// `gateTarget.staticcall(gateData)`, capped at 100,000 gas, returns a first word that
        /// compares true. The gate is read once, in the transaction that asks: point it at a value
        /// that cannot be moved and moved back within one transaction.
        address gateTarget;
        uint256 gateThreshold;
        /// The gate call's data, at most 68 bytes: a selector and up to two words.
        bytes gateData;
    }

    /// @notice Why a feed could not be created, as `BadFeed` reports it.
    enum FeedFault {
        None,
        /// The action id is zero.
        Action,
        /// `chainId` is not this chain.
        Chain,
        /// `answerType` is not one of the six codes.
        AnswerType,
        /// `panelSize` outside 2 to 300, `quorum` below 2 or above `panelSize`, or `minAgreed`
        /// outside 1 to `quorum`.
        Panel,
        /// `validFor` outside 60 seconds to 30 days.
        ValidFor,
        /// `cadenceBlocks` or `maxWindowBlocks` is zero, or a contiguous feed's longest window is
        /// not longer than its cadence, so that a round asked late could never be made up.
        Window,
        /// `lagBlocks` outside 5 to 256.
        Lag,
        /// `maxPrice` is zero, so no request could ever be paid.
        Price,
        /// The gate fields contradict each other, or the gate data is longer than 68 bytes.
        Gate,
        /// The prefix does not begin with the feed's answer type and chain in canonical form, or
        /// does not end with `"v":1,"window":{"fromBlock":`.
        Prefix,
        /// The tail does not begin with a comma and end with a closing brace, or does not state
        /// the feed's `panelSize`, `quorum` and `validForSeconds`.
        Tail,
        /// The longest body the feed could send would exceed the Intake's 16,384 bytes.
        TooLong,
        /// `tip` is above `maxPrice`: a keeper would be paid more for asking than the feed is
        /// willing to pay for the answer.
        Tip
    }

    /// @notice Why `request` cannot be made right now, as `RequestBlocked` and `canRequest` report it.
    enum Blocker {
        None,
        UnknownFeed,
        /// This contract already made a request in this transaction; the Intake serves one.
        AlreadyAskedThisTransaction,
        /// The previous round has no answer yet and has not been abandoned.
        RoundPending,
        /// The cadence, lengthened by any failed rounds, has not elapsed.
        TooSoon,
        /// There is no block window to ask about yet.
        NoBlocks,
        /// The feed has a WHEN gate and it is not true now.
        GateClosed,
        /// The Intake does not sell the feed's action for IMD, or its price could not be read.
        NotSold,
        /// The live price is above the feed's `maxPrice`.
        PriceAboveCap,
        /// The meter holds less than the price plus the keeper tip.
        MeterTooLow
    }

    /// @notice What `abandon` would do with a feed's pending round if it were called now, as
    /// `canAbandon` reports it.
    enum AbandonStep {
        /// Nothing: no round is pending, or it is too early and the call would revert.
        Wait,
        /// Record that the Intake has completed the request, which starts the thirty minutes left
        /// for `submit`. The round stays pending.
        StartWait,
        /// Close the round as failed.
        Close
    }

    /// @dev One slot. Block numbers and round counts fit 48 bits for longer than any chain will run.
    struct FeedState {
        uint48 rounds;
        uint48 latestRound;
        uint48 lastRequestBlock;
        uint48 lastToBlock;
        uint8 failStreak;
        bool pending;
        bool exists;
        /// When `abandon` first found the pending round's Intake request completed. Zero when it
        /// has not, and whenever no round is pending.
        uint40 completionSeenAt;
    }

    /// @dev `totalShares >= balance` always holds: a share is never worth more than one wei, which
    /// is what keeps a funder from being rounded out of anything but dust.
    struct Meter {
        uint128 balance;
        uint32 epoch;
        uint32 rescales;
        uint256 totalShares;
    }

    struct Stake {
        uint256 shares;
        uint32 epoch;
        uint32 rescales;
    }

    struct Round {
        bytes32 requestId;
        bytes32 questionHash;
        bytes32 blockHash;
        uint64 fromBlock;
        uint64 toBlock;
        uint48 requestedAt;
        uint48 updatedAt;
        RoundStatus status;
        uint256 value;
    }

    /// @dev The tip set aside for a feed's pending round and who opened it, in one slot, so that
    /// the callback reads both at once. Written by `request` for a feed with a tip; meaningful only
    /// while the feed's round is pending.
    struct Held {
        address keeper;
        uint96 tip;
    }

    struct Feed {
        FeedState state;
        Meter meter;
        FeedParams params;
        bytes qPrefix;
        bytes tail;
        /// Set at creation when the question prefix holds `"evidence":"panel"`: a panel judges the
        /// answer, two panels can differ, and only the Intake may deliver. A chain-evidence question
        /// whose definitions happen to hold that very key and value is flagged too; all that costs
        /// it is `submit`.
        bool panelEvidence;
        Held held;
    }

    /// @notice A feed's moving parts in one read, for a page that shows it.
    struct FeedView {
        bool exists;
        uint64 rounds;
        uint64 latestRound;
        uint64 lastRequestBlock;
        uint64 lastToBlock;
        uint8 failStreak;
        bool pending;
        /// The Intake's id of the pending round's request, zero when no round is pending.
        bytes32 pendingRequestId;
        /// The first block at which the cadence allows another request.
        uint64 nextRequestBlock;
        uint256 meterBalance;
        uint256 totalShares;
        /// What `costOf` reports: the live Intake price plus the keeper tip, zero when no request
        /// could be bought at the live price.
        uint256 cost;
        /// `Blocker.None` when `request` would go through in this block.
        Blocker blocker;
    }

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event FeedCreated(bytes32 indexed feedId, address indexed creator, FeedParams params, bytes qPrefix, bytes tail);
    /// @notice `amount` IMD went onto the meter and `shares` were minted to `funder`, the address the
    /// shares belong to. After `fundFor` that is the beneficiary, and `FundedFor` names who paid.
    event Funded(bytes32 indexed feedId, address indexed funder, uint256 amount, uint256 shares);
    /// @notice Follows `Funded` in the same transaction when `payer` funded the meter through
    /// `fundFor` for somebody else. It repeats the amounts; it is not a second funding.
    event FundedFor(
        bytes32 indexed feedId, address indexed payer, address indexed beneficiary, uint256 amount, uint256 shares
    );
    event Defunded(bytes32 indexed feedId, address indexed funder, uint256 shares, uint256 amount);
    /// @notice The meter was spent to exactly zero, so every share minted before `epoch` is a claim
    /// on nothing and no longer counts. Shares minted from now on belong to `epoch`.
    event SharesRetired(bytes32 indexed feedId, uint32 epoch);
    /// @notice Every share count of this meter, each holder's and the total, was divided by 2^64
    /// once for each step `rescales` rose by. Nobody's part of the meter changed by more than a wei.
    event SharesRescaled(bytes32 indexed feedId, uint32 rescales);
    /// @notice A request was bought. `price` went to the Intake and `tip` was set aside for `keeper`,
    /// both from the meter. `blockHash` is the closing block's hash as this chain had it, zero when
    /// the block was too old to read. The body is in the Intake's own `Requested` event for
    /// `intakeRequestId`.
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
    /// @notice An answer was stored. `oracleRequestId` is the attestation's request id (the oracle
    /// request's UUID, left-aligned), `deliveredBy` the Intake or whoever called `submit`. The
    /// round's tip always goes to the `keeper` of its `RoundOpened`. `deliveredBy` records
    /// the transport only and does not identify the tip recipient.
    event RoundAnswered(
        bytes32 indexed feedId,
        uint64 indexed round,
        bytes32 indexed oracleRequestId,
        uint256 value,
        uint256 figure,
        uint16 agreed,
        bytes32 panelJobId,
        address deliveredBy
    );
    /// @notice `abandon` found the pending round's Intake request completed with nothing stored.
    /// The round stays pending: `submit` may still hand the answer in, and from `closableAt` on
    /// `abandon` closes the round.
    event CompletionSeen(bytes32 indexed feedId, uint64 indexed round, bytes32 intakeRequestId, uint64 closableAt);
    /// @notice A round was closed without an answer. `completed` is what the Intake said about the
    /// request at that moment; `failStreak` is the feed's count of failed rounds in a row. The tip
    /// set aside for the round (the `tip` of its `RoundOpened`) went back onto the meter.
    event RoundFailed(
        bytes32 indexed feedId, uint64 indexed round, bytes32 intakeRequestId, bool completed, uint8 failStreak
    );
    /// @notice The list behind a list-typed round, published by anyone who had it.
    event AnswerRevealed(bytes32 indexed feedId, uint64 indexed round, bytes answer);
    /// @notice `keeper` took out `amount` IMD of tips it had earned.
    event TipsCollected(address indexed keeper, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownFeed(bytes32 feedId);
    error BadFeed(FeedFault fault);
    error ZeroShares();
    error NothingToDefund();
    error RequestBlocked(Blocker why);
    /// @dev The Intake left part of the price it was approved for untaken.
    error PriceNotTaken();
    error MetersNotCovered();
    error RequestIdReused(bytes32 requestId);
    error NotTheIntake();
    error UnknownRequest(bytes32 requestId);
    error NoPendingRound(bytes32 feedId);
    error SubmitNeedsPinnedQuestion();
    error SubmitNotForPanelEvidence();
    /// @dev The Intake has not completed the round's own request, and the time at which `submit`
    /// opens without it has not come: the callback goes first.
    error SubmitTooEarly(uint256 opensAt);
    error WrongChain(uint256 expected, uint256 got);
    error WrongQuestion(bytes32 expected, bytes32 got);
    error WrongWindow(uint64 fromBlock, uint64 toBlock);
    error PanelTooSmall(uint16 panelSize, uint16 quorum);
    error NotEnoughAgreed(uint16 agreed, uint16 needed);
    error WrongBlockHash(bytes32 expected, bytes32 got);
    error MalformedAnswer();
    error TooEarlyToAbandon(uint256 notBefore);
    error NothingToReveal();
    error WrongAnswerBytes();

    // ---------------------------------------------------------------------------------------------
    // Constants and storage
    // ---------------------------------------------------------------------------------------------

    /// @notice The gas a feed's WHEN gate call may use.
    uint256 public constant GATE_GAS = 100_000;
    /// @notice The longest gate call data: a selector and two words.
    uint256 public constant GATE_DATA_MAX = 68;
    /// @notice A pending round whose Intake request is completed may be abandoned this long after
    /// `abandon` first found it so: time for anyone to `submit` an answer the callback missed. The
    /// Intake keeps no completion time, so the wait starts when the completion is first seen here.
    uint256 public constant ABANDON_AFTER_COMPLETED = 30 minutes;
    /// @notice The allowance for the oracle to sign before the silence recovery deadline.
    /// `abandon` additionally waits the feed's `validFor`, `ISSUED_AT_TOLERANCE` and one second.
    uint256 public constant ABANDON_AFTER_SILENCE = 12 hours;
    /// @notice `submit` opens this long after a request the Intake has still not completed. The
    /// callback has that half hour to itself: the oracle signs a chain-evidence answer within
    /// minutes, and the Intake's writer can take hours to deliver it. The full silence deadline
    /// additionally preserves the feed's requested answer validity.
    uint256 public constant SUBMIT_AFTER_SILENCE = 30 minutes;
    /// @notice The largest panel a feed may ask for: the protocol's own limit.
    uint256 public constant MAX_PANEL_SIZE = 300;
    /// @notice After this many failed rounds in a row the cadence stops doubling (2^5 = 32 times).
    uint256 public constant MAX_BACKOFF_DOUBLINGS = 5;
    /// @notice The closest to the head a feed's windows may end. The protocol refuses a window that
    /// ends fewer than five blocks back.
    uint256 public constant MIN_LAG_BLOCKS = 5;
    /// @notice The furthest behind the head a feed's windows may end: as far as BLOCKHASH reaches,
    /// so the closing block's hash can always be read when a round opens on time.
    uint256 public constant MAX_LAG_BLOCKS = 256;

    uint256 internal constant MIN_VALID_FOR = 60;
    uint256 internal constant MAX_VALID_FOR = 30 days;
    /// @dev The gas given to each read of the Intake (`priceOf`, `requests`): many times what a
    /// mapping read needs, and a bound, so a getter that burns gas can neither keep a round from
    /// being closed nor make the views unusable.
    uint256 internal constant INTAKE_READ_GAS = 50_000;
    /// @dev Share counts are divided by 2^64 when a meter has more than 2^128 shares for each wei.
    uint256 internal constant RESCALE_BITS = 64;
    uint256 internal constant RESCALE_AT_BITS = 128;
    /// @dev Where the pending half of a keeper's tips starts in its word; see `_tips`.
    uint256 internal constant TIP_PENDING_SHIFT = 128;

    /// @dev A transient slot: set by `request`, gone when the transaction ends.
    bytes32 internal constant ASKED_SLOT = keccak256("help-wanted.questions.asked-this-transaction");

    /// @notice The IdentityMD Intake every request is bought from and every callback must come from.
    IIntake public immutable INTAKE;
    /// @notice The token meters hold and the Intake is paid in.
    IERC20 public immutable IMD;

    /// @notice The sum of every meter's balance. `IMD.balanceOf(this)` is never below this plus
    /// `totalTips`; anything above the two is IMD that reached the contract by plain transfer.
    uint256 public totalMetered;
    /// @notice Keeper tips held here: those set aside for pending rounds and those earned and not
    /// yet collected.
    uint256 public totalTips;

    mapping(bytes32 feedId => Feed) internal _feeds;
    mapping(bytes32 feedId => mapping(uint256 round => Round)) internal _rounds;
    mapping(bytes32 feedId => mapping(address funder => Stake)) internal _stakes;
    /// @dev Set while a request is pending, cleared when its round is answered or abandoned.
    mapping(bytes32 intakeRequestId => bytes32 feedId) internal _feedOfRequest;
    bytes32[] internal _feedIds;
    /// @dev One keeper's tips, two figures in one word: the low 128 bits are what it has earned
    /// and may collect, the high 128 bits what is set aside for rounds it opened that have no
    /// outcome yet. Crediting a tip to the keeper that opened the round moves it from the high half
    /// to the low half: one write to a slot that already holds a value, which is what keeps the
    /// callback's cost down. Neither half can reach 2^128: both are IMD this contract holds
    /// (`totalTips` is their sum over all keepers and `request` checks the balance covers it), and
    /// 2^128 wei is far more IMD than exists.
    mapping(address keeper => uint256) internal _tips;

    /// @notice Whether the attestation with this oracle request id has answered a round of this
    /// feed. An attestation answers at most one round of a feed. `consumed` (from the base contract)
    /// says whether it has answered a round of any feed here.
    // Written in `_settle` through a storage reference, which the static analyser does not follow.
    // slither-disable-next-line uninitialized-state
    mapping(bytes32 oracleRequestId => mapping(bytes32 feedId => bool)) public usedBy;

    /// @param intake The IdentityMD Intake on this chain.
    /// @param imd The IMD token on this chain.
    /// @param oracleSigner_ The address oracle attestations must be signed by. Fixed for good: the
    /// base contract's `_setOracleSigner` runs here once and no function reaches it again.
    /// @dev No external call and no code check: the launch pipeline runs constructors on an empty
    /// chain. A wrong address shows itself at the first `request` or the first answer.
    constructor(address intake, address imd, address oracleSigner_) OracleAttestationConsumer(oracleSigner_) {
        if (intake == address(0) || imd == address(0)) revert ZeroAddress();
        INTAKE = IIntake(intake);
        IMD = IERC20(imd);
    }

    // ---------------------------------------------------------------------------------------------
    // Feeds
    // ---------------------------------------------------------------------------------------------

    /// @notice Registers a feed. Anyone may call; it costs gas and nothing else.
    /// @dev The id depends only on what the feed is, so creating a feed that exists returns its id
    /// and changes nothing. What can be checked is checked here, so that an accepted feed is not one
    /// whose answers could never be accepted: the numbers the callback enforces are the numbers the
    /// body states. The wording of the question itself is the creator's to get right; the protocol's
    /// free check (`POST /requests/check`) is the place to test it before funding a meter.
    /// @param p The feed's parameters.
    /// @param qPrefix The canonical question document up to and including `"window":{"fromBlock":`.
    /// @param tail The rest of the body after the window's closing brace, from its leading comma to
    /// the final brace.
    /// @return feedId `keccak256(abi.encode(p, keccak256(qPrefix), keccak256(tail)))`.
    function createFeed(FeedParams calldata p, bytes calldata qPrefix, bytes calldata tail)
        external
        returns (bytes32 feedId)
    {
        feedId = feedIdOf(p, qPrefix, tail);
        Feed storage f = _feeds[feedId];
        if (f.state.exists) return feedId;
        FeedFault fault = checkFeed(p, qPrefix, tail);
        if (fault != FeedFault.None) revert BadFeed(fault);
        f.state.exists = true;
        f.params = p;
        f.qPrefix = qPrefix;
        f.tail = tail;
        // The oracle's question hash covers `evidence` only when it is "panel", so a prefix without
        // these bytes can only ever match the hash of a chain-evidence question.
        if (QuestionBody.holdsPanelEvidence(qPrefix)) f.panelEvidence = true;
        _feedIds.push(feedId);
        emit FeedCreated(feedId, msg.sender, p, qPrefix, tail);
    }

    /// @notice The id a feed with these parts has, whether or not it exists yet.
    function feedIdOf(FeedParams calldata p, bytes calldata qPrefix, bytes calldata tail)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(p, keccak256(qPrefix), keccak256(tail)));
    }

    /// @notice What `createFeed` would refuse about these parts, or `FeedFault.None`.
    function checkFeed(FeedParams calldata p, bytes calldata qPrefix, bytes calldata tail)
        public
        view
        returns (FeedFault)
    {
        if (p.action == bytes32(0)) return FeedFault.Action;
        if (p.chainId != block.chainid) return FeedFault.Chain;
        if (p.answerType > OracleAttestation.ANSWER_BYTES32_LIST) return FeedFault.AnswerType;
        if (p.panelSize < 2 || p.panelSize > MAX_PANEL_SIZE) return FeedFault.Panel;
        if (p.quorum < 2 || p.quorum > p.panelSize) return FeedFault.Panel;
        if (p.minAgreed == 0 || p.minAgreed > p.quorum) return FeedFault.Panel;
        if (p.validFor < MIN_VALID_FOR || p.validFor > MAX_VALID_FOR) return FeedFault.ValidFor;
        if (p.cadenceBlocks == 0 || p.maxWindowBlocks == 0) return FeedFault.Window;
        // With the two equal a round asked one block late could never be made up, and the feed
        // would fall further behind the head with every late or failed round.
        if (p.contiguous && p.maxWindowBlocks <= p.cadenceBlocks) return FeedFault.Window;
        if (p.lagBlocks < MIN_LAG_BLOCKS || p.lagBlocks > MAX_LAG_BLOCKS) return FeedFault.Lag;
        if (p.maxPrice == 0) return FeedFault.Price;
        if (p.tip > p.maxPrice) return FeedFault.Tip;
        if (p.gateTarget == address(0)) {
            if (p.gateCmp != 0 || p.gateThreshold != 0 || p.gateData.length != 0) return FeedFault.Gate;
        } else if (p.gateCmp == 0 || p.gateCmp > 6 || p.gateData.length > GATE_DATA_MAX) {
            return FeedFault.Gate;
        }
        if (qPrefix.length + tail.length + QuestionBody.WINDOW_MAX_BYTES > QuestionBody.MAX_BODY_BYTES) {
            return FeedFault.TooLong;
        }
        if (
            !QuestionBody.startsWith(qPrefix, QuestionBody.prefixStart(p.answerType, p.chainId))
                || !QuestionBody.endsWith(qPrefix, QuestionBody.PREFIX_END)
        ) return FeedFault.Prefix;
        if (
            tail.length < 2 || tail[0] != "," || tail[tail.length - 1] != "}"
                || !QuestionBody.hasNumber(tail, '"panelSize":', p.panelSize)
                || !QuestionBody.hasNumber(tail, '"quorum":', p.quorum)
                || !QuestionBody.hasNumber(tail, '"validForSeconds":', p.validFor)
        ) return FeedFault.Tail;
        return FeedFault.None;
    }

    // ---------------------------------------------------------------------------------------------
    // Meters
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IQuestions
    /// @dev Anyone may fund any existing feed. Shares are minted at the meter's current worth, so
    /// what earlier rounds spent is not charged to a later funder. The first funder gets one share
    /// per wei and nothing but `fund` can raise a meter's balance, so there is no way to inflate a
    /// share's worth and round a later funder down to nothing. The amount credited is what actually
    /// arrived. Reverts for an unknown feed, a zero amount, or a transfer that fails.
    function fund(bytes32 feedId, uint256 amount) external nonReentrant returns (uint256 shares) {
        return _fund(feedId, amount, msg.sender);
    }

    /// @notice The same as `fund`, except that the shares belong to `beneficiary`: the caller
    /// pays, and only `beneficiary` can later `defund` them. For contracts that fund a meter on
    /// somebody's behalf and must not end up holding the shares themselves.
    /// @dev Anyone may call. Reverts as `fund` does, and for a zero beneficiary, whose shares
    /// nobody could ever take back. Emits `Funded` for the beneficiary, then `FundedFor` naming
    /// the payer when the two differ.
    function fundFor(bytes32 feedId, uint256 amount, address beneficiary)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (beneficiary == address(0)) revert ZeroAddress();
        return _fund(feedId, amount, beneficiary);
    }

    /// @dev Pulls `amount` from the caller onto the feed's meter and mints the shares to `beneficiary`.
    function _fund(bytes32 feedId, uint256 amount, address beneficiary) internal returns (uint256 shares) {
        Feed storage f = _feed(feedId);
        if (amount == 0) revert ZeroAmount();

        uint256 held = IMD.balanceOf(address(this));
        IMD.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IMD.balanceOf(address(this)) - held;
        if (received == 0) revert ZeroAmount();

        Meter storage m = f.meter;
        uint256 balance = m.balance;
        uint256 total = m.totalShares;
        if (total != 0 && balance == 0) {
            // Rounds spent the meter to exactly zero: the old shares are claims on nothing. They are
            // retired so a new funder does not have to buy out an infinite number of them.
            m.epoch += 1;
            total = 0;
            emit SharesRetired(feedId, m.epoch);
        }
        if (total == 0) {
            shares = received;
        } else {
            // Spending lowers what a share is worth and never burns one, so a long-lived meter mints
            // more and more shares per wei. Before the count can overflow, every count is divided by
            // the same power of two; `_sharesOf` applies the division to each holder when read.
            uint32 steps = 0;
            while ((total >> RESCALE_AT_BITS) >= balance) {
                total >>= RESCALE_BITS;
                ++steps;
            }
            if (steps != 0) {
                m.rescales += steps;
                emit SharesRescaled(feedId, m.rescales);
            }
            shares = Math.mulDiv(received, total, balance);
        }
        if (shares == 0) revert ZeroShares();

        Stake storage s = _stakes[feedId][beneficiary];
        s.shares = _sharesOf(m, s) + shares;
        s.epoch = m.epoch;
        s.rescales = m.rescales;
        m.totalShares = total + shares;
        m.balance = (balance + received).toUint128();
        totalMetered += received;
        emit Funded(feedId, beneficiary, received, shares);
        if (beneficiary != msg.sender) emit FundedFor(feedId, msg.sender, beneficiary, received, shares);
    }

    /// @inheritdoc IQuestions
    /// @dev Never blocked: not by a pending round (its cost left the meter when it was requested),
    /// not by a failing feed. Asking for more shares than the caller holds takes everything the
    /// caller holds, so `type(uint256).max` empties a position. The amount is rounded down; the
    /// dust stays on the meter. Reverts only when the caller holds no shares of this meter.
    function defund(bytes32 feedId, uint256 shares) external nonReentrant returns (uint256 amount) {
        Meter storage m = _feeds[feedId].meter;
        Stake storage s = _stakes[feedId][msg.sender];
        uint256 mine = _sharesOf(m, s);
        if (shares > mine) shares = mine;
        if (shares == 0) revert NothingToDefund();

        amount = Math.mulDiv(shares, m.balance, m.totalShares);
        s.shares = mine - shares;
        s.epoch = m.epoch;
        s.rescales = m.rescales;
        m.totalShares -= shares;
        m.balance -= amount.toUint128();
        totalMetered -= amount;
        emit Defunded(feedId, msg.sender, shares, amount);
        if (amount != 0) IMD.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Asking
    // ---------------------------------------------------------------------------------------------

    /// @notice Buys the feed's next answer from the Intake. Anyone may call. The feed's keeper tip
    /// is set aside for the caller and becomes the caller's when the round is answered.
    /// @dev Allowed only when `canRequest` says so; otherwise reverts `RequestBlocked` with the
    /// reason. The caller chooses nothing: the price is the Intake's live price under the feed's
    /// cap, the body is built here from the feed's stored text and this block's number, and the
    /// Intake is approved for exactly the price. The meter is charged the price and the tip before
    /// any token moves. The call reverts if the Intake did not take all of the price
    /// (`PriceNotTaken`: no allowance is ever left standing and a meter is never charged for IMD
    /// that stayed here), or if paying left the contract holding less IMD than its meters and the
    /// tips it holds add up to (`MetersNotCovered`).
    ///
    /// No tip is paid here. Asking earns nothing by itself: the tip waits with the round, goes to
    /// the caller when the round is answered (including through `submit` by somebody else),
    /// and goes back onto the meter if the round is closed without one. `collectTips`
    /// pays out what a keeper has earned.
    ///
    /// Send it as a transaction of its own. The Intake serves the first request of a transaction
    /// only; see the risks in the contract's notice for what a caller that asks elsewhere first
    /// costs the feed.
    /// @return intakeId The Intake's id for the request; the callback's first argument.
    // Two writes follow the call into the Intake: the request id, which only the Intake's answer
    // gives, and the feed it belongs to. Every entry point that could run in between holds this
    // function's lock, and the views that read a round show it pending with no id until then.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function request(bytes32 feedId) external nonReentrant returns (bytes32 intakeId) {
        Feed storage f = _feeds[feedId];
        (Blocker why, uint256 price, uint64 fromBlock, uint64 toBlock) = _readiness(f);
        if (why != Blocker.None) revert RequestBlocked(why);
        ASKED_SLOT.asBoolean().tstore(true);

        (bytes memory body, bytes32 questionHash) = _body(f, fromBlock, toBlock);
        // The closing block's hash as this chain has it now, from BLOCKHASH or, past 256 blocks, the
        // EIP-2935 history contract. Zero only for a catch-up window that ends more than 8,191
        // blocks back; such a block is long final and its hash is then not checked.
        bytes32 closingHash = Blockhash.blockHash(toBlock);
        uint256 tip = f.params.tip;
        uint256 cost = price + tip;

        FeedState memory s = f.state;
        uint48 round = s.rounds + 1;
        s.rounds = round;
        s.pending = true;
        s.lastRequestBlock = block.number.toUint48();
        s.completionSeenAt = 0;
        f.state = s;
        f.meter.balance -= cost.toUint128();
        totalMetered -= cost;
        if (tip != 0) {
            // A tip is a uint96 parameter of the feed, so the narrowing is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            f.held = Held(msg.sender, uint96(tip));
            _tips[msg.sender] += tip << TIP_PENDING_SHIFT;
            totalTips += tip;
        }
        Round storage r = _rounds[feedId][round];
        r.questionHash = questionHash;
        r.blockHash = closingHash;
        r.fromBlock = fromBlock;
        r.toBlock = toBlock;
        r.requestedAt = block.timestamp.toUint48();
        r.status = RoundStatus.Pending;

        IMD.forceApprove(address(INTAKE), price);
        intakeId = INTAKE.request(
            f.params.action, body, IIntake.Callback(address(this), this.onOracleResult.selector), address(IMD), price
        );
        // The meter was charged the whole price, so the whole price must have gone. An Intake that
        // took less would leave IMD here that belongs to no meter, and an allowance behind it.
        if (IMD.allowance(address(this), address(INTAKE)) != 0) revert PriceNotTaken();
        // The id is the Intake's to choose and is only known now. Every other entry point shares
        // this function's lock, so nothing can run between the call above and these writes.
        if (_feedOfRequest[intakeId] != bytes32(0)) revert RequestIdReused(intakeId);
        _feedOfRequest[intakeId] = feedId;
        r.requestId = intakeId;
        if (IMD.balanceOf(address(this)) < totalMetered + totalTips) revert MetersNotCovered();

        emit RoundOpened(feedId, round, intakeId, fromBlock, toBlock, questionHash, closingHash, price, tip, msg.sender);
    }

    /// @notice The Intake's callback: stores the oracle's answer for a pending round.
    /// @dev Only the Intake may call, only for a request this contract made and has not settled.
    /// The checks are in the contract's notice. A "no", a zero or an empty list is an answer and is
    /// stored like any other, and earns the keeper that opened the round its tip. A revert here
    /// leaves the round pending: where `submit` is open to the feed the same attestation can still
    /// be handed in, and failing that the round is closed by `abandon`.
    /// @param requestId The Intake's id, as `request` returned it.
    /// @param a The attestation. Its own `requestId` is the oracle request's UUID, not the Intake's id.
    /// @param signature The oracle signer's signature over `attestationDigest(a)`.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        if (msg.sender != address(INTAKE)) revert NotTheIntake();
        bytes32 feedId = _feedOfRequest[requestId];
        if (feedId == bytes32(0)) revert UnknownRequest(requestId);
        _settle(feedId, requestId, a, signature);
    }

    /// @notice Hands in an attestation the callback missed or has not brought. Anyone may call,
    /// once the Intake has completed the round's own request and nothing was stored, or thirty
    /// minutes after the request if the Intake has still not completed it.
    /// @dev The same checks as the callback. Three conditions come first, each with its reason:
    ///
    /// - The feed pins its question (`SubmitNeedsPinnedQuestion`). With the question hash checked,
    ///   an answer to any other question cannot be presented here. Without the pin the pairing of
    ///   answer and request is the Intake's alone.
    /// - The question is not judged by a panel (`SubmitNotForPanelEvidence`). Nothing on chain ties
    ///   an attestation to the request this round paid for: the oracle signs for whichever
    ///   contract a request names, so anyone can buy answers of their own to a feed's question,
    ///   addressed here. Two panels can judge one question differently, and whoever submits would
    ///   choose between them. Only the Intake delivers to such a feed.
    /// - The Intake has completed the round's own request, or thirty minutes have passed since it
    ///   was made (`SubmitTooEarly`). The callback goes first for that half hour, so the answer
    ///   the meter paid for is the one stored whenever the Intake delivers it in that time. After
    ///   it, whoever holds a signed answer may hand it in. That is there for a request the Intake
    ///   never serves (see the contract's notice: a caller that asked elsewhere first in the same
    ///   transaction), whose round could otherwise only fail, and for an answer the oracle has
    ///   signed and the Intake's writer has not delivered, which has been seen to take hours.
    ///   Thirty minutes can be less than the oracle itself takes: an answer somebody else bought
    ///   to the same question may then be stored before the one the meter paid for exists. An
    ///   Intake that cannot be read counts as not having completed anything.
    ///
    /// What is left is disclosed in the contract's notice: once `submit` is open, any answer the
    /// oracle signed for this contract to the same question about the same blocks is accepted,
    /// whoever bought it.
    ///
    /// The round's tip stays with its opener. A public attestation must not let an observer take
    /// the tip reserved for the keeper that paid to open the round. There is no on-chain way to
    /// distinguish an answer to that purchase from another matching purchase, so this also applies
    /// to independently bought answers. Submission itself earns no separate reward.
    function submit(bytes32 feedId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Feed storage f = _feed(feedId);
        if (!f.params.pinHash) revert SubmitNeedsPinnedQuestion();
        if (f.panelEvidence) revert SubmitNotForPanelEvidence();
        if (!f.state.pending) revert NoPendingRound(feedId);
        Round storage r = _rounds[feedId][f.state.rounds];
        if (!_submitOpen(r)) revert SubmitTooEarly(uint256(r.requestedAt) + SUBMIT_AFTER_SILENCE);
        _settle(feedId, r.requestId, a, signature);
    }

    /// @notice Closes a pending round that will not be answered, so the feed can ask again.
    /// Anyone may call.
    /// @dev Two rules, whichever allows it first:
    ///
    /// - After the request plus twelve hours, the feed's `validFor`, five minutes of clock tolerance
    ///   and one second, whatever the Intake says. This allows an answer signed within the first
    ///   twelve hours its full validity. An answer delivered after closure is refused.
    /// - Thirty minutes after `abandon` first found the Intake's request completed (refused, no
    ///   answer, or an answer whose callback failed). That takes two calls. The first records the
    ///   time, emits `CompletionSeen`, changes nothing else and returns false; the second, thirty
    ///   minutes later, closes the round. The Intake stores no completion time, and counting from
    ///   the request would leave an answer that arrived late and missed its callback no time to
    ///   be handed in through `submit`.
    ///
    /// Closing marks the round `Failed` and doubles the cadence. The price is spent either way; the
    /// tip that was set aside goes back onto the meter and its keeper gets nothing. The meter's
    /// shares are left as they are, so the funders share the returned tip, with one bound: it never
    /// lifts a share above one wei (see `_returnTip`). What the feed asks next: a contiguous feed that already has an answer starts
    /// its next window at the same block, so no block is skipped, and ends it at a fresh block
    /// (or `maxWindowBlocks` later), so the closing hash can still be read; a contiguous feed with
    /// no answer yet, and any feed that is not contiguous, asks about the newest blocks, and the
    /// failed round's own blocks are not asked about again. An Intake that cannot be read counts
    /// as not completed.
    /// @return closed True when the round was closed, false when the call started the wait.
    function abandon(bytes32 feedId) external nonReentrant returns (bool closed) {
        Feed storage f = _feed(feedId);
        FeedState memory s = f.state;
        if (!s.pending) revert NoPendingRound(feedId);
        Round storage r = _rounds[feedId][s.rounds];
        bytes32 requestId = r.requestId;

        (AbandonStep step, uint256 closableAt, bool completed) = _abandonStep(s, r, f.params.validFor);
        if (step == AbandonStep.Wait) revert TooEarlyToAbandon(closableAt);
        if (step == AbandonStep.StartWait) {
            s.completionSeenAt = block.timestamp.toUint40();
            f.state = s;
            emit CompletionSeen(feedId, s.rounds, requestId, closableAt.toUint64());
            return false;
        }

        delete _feedOfRequest[requestId];
        r.status = RoundStatus.Failed;
        r.updatedAt = block.timestamp.toUint48();
        s.pending = false;
        s.completionSeenAt = 0;
        if (s.failStreak != type(uint8).max) s.failStreak += 1;
        f.state = s;
        _returnTip(f);
        emit RoundFailed(feedId, s.rounds, requestId, completed, s.failStreak);
        return true;
    }

    /// @notice Pays the caller every keeper tip it has earned and not yet taken out. Anyone may
    /// call; a caller that has earned nothing is paid nothing and the call does not revert.
    /// @dev Tips set aside for rounds that are still pending are not included: they are earned
    /// only when their round is answered.
    /// @return amount IMD sent to the caller.
    function collectTips() external nonReentrant returns (uint256 amount) {
        uint256 tips = _tips[msg.sender];
        // The low half: what has been earned.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint128(tips);
        if (amount == 0) return 0;
        _tips[msg.sender] = tips - amount;
        totalTips -= amount;
        emit TipsCollected(msg.sender, amount);
        IMD.safeTransfer(msg.sender, amount);
    }

    /// @notice Publishes the list behind a list-typed round in an event. Anyone who has the bytes
    /// may call; nothing is stored.
    /// @dev A list round keeps only `uint256(keccak256(answer))`. The list itself travels in the
    /// Intake's `complete` transaction and in the protocol's API; this puts it in this contract's
    /// log, checked against the stored word.
    function reveal(bytes32 feedId, uint64 round, bytes calldata answer) external {
        Round storage r = _rounds[feedId][round];
        if (
            r.status != RoundStatus.Answered || _feeds[feedId].params.answerType < OracleAttestation.ANSWER_ADDRESS_LIST
        ) revert NothingToReveal();
        if (uint256(keccak256(answer)) != r.value) revert WrongAnswerBytes();
        emit AnswerRevealed(feedId, round, answer);
    }

    // ---------------------------------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IQuestions
    function latest(bytes32 feedId)
        external
        view
        returns (uint256 value, uint64 fromBlock, uint64 toBlock, uint64 round, uint64 updatedAt)
    {
        round = _feeds[feedId].state.latestRound;
        if (round != 0) {
            Round storage r = _rounds[feedId][round];
            (value, fromBlock, toBlock, updatedAt) = (r.value, r.fromBlock, r.toBlock, r.updatedAt);
        }
    }

    /// @notice One round of a feed. `updatedAt` is when the answer was stored; for a failed round,
    /// when it was closed; for a pending round, zero.
    function roundOf(bytes32 feedId, uint64 round)
        external
        view
        returns (RoundStatus status, uint256 value, uint64 fromBlock, uint64 toBlock, uint64 updatedAt)
    {
        Round storage r = _rounds[feedId][round];
        return (r.status, r.value, r.fromBlock, r.toBlock, r.updatedAt);
    }

    /// @notice What a round asked and when: the Intake's request id, the question hash an answer
    /// must carry, the closing block's hash seen when the round opened (zero if it could not be
    /// read), and the time of the request.
    function roundRequest(bytes32 feedId, uint64 round)
        external
        view
        returns (bytes32 intakeRequestId, bytes32 questionHash, bytes32 blockHash, uint64 requestedAt)
    {
        Round storage r = _rounds[feedId][round];
        return (r.requestId, r.questionHash, r.blockHash, r.requestedAt);
    }

    /// @inheritdoc IQuestions
    function roundCount(bytes32 feedId) external view returns (uint64) {
        return _feeds[feedId].state.rounds;
    }

    /// @inheritdoc IQuestions
    /// @dev Also zero while the Intake does not sell the feed's action for IMD, cannot be read, or
    /// asks more than the feed's `maxPrice`: no request can be bought then, so there is no cost to
    /// state, and a funder that sizes a top-up by this figure adds nothing to a meter that cannot
    /// spend. `canRequest` still reports the live price in that case.
    function costOf(bytes32 feedId) public view returns (uint256) {
        Feed storage f = _feeds[feedId];
        if (!f.state.exists) return 0;
        FeedParams storage p = f.params;
        (bool ok, uint256 price) = _price(p.action);
        return ok && price != 0 && price <= p.maxPrice ? price + p.tip : 0;
    }

    /// @notice A keeper's tips. `earned` is what `collectTips` would pay it now; `pending` is set
    /// aside for rounds it opened that have neither an answer nor been closed yet.
    function tipsOf(address keeper) external view returns (uint256 earned, uint256 pending) {
        uint256 tips = _tips[keeper];
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint128(tips), tips >> TIP_PENDING_SHIFT);
    }

    /// @notice The meter's unspent IMD and the shares that divide it.
    function meterOf(bytes32 feedId) external view returns (uint256 balance, uint256 totalShares) {
        Meter storage m = _feeds[feedId].meter;
        return (m.balance, m.totalShares);
    }

    /// @notice A funder's shares of a feed's meter. Zero once the meter has been spent to nothing.
    function sharesOf(bytes32 feedId, address funder) external view returns (uint256) {
        return _sharesOf(_feeds[feedId].meter, _stakes[feedId][funder]);
    }

    /// @notice The IMD `funder` would get by defunding everything now.
    function redeemable(bytes32 feedId, address funder) external view returns (uint256) {
        Meter storage m = _feeds[feedId].meter;
        uint256 mine = _sharesOf(m, _stakes[feedId][funder]);
        return mine == 0 ? 0 : Math.mulDiv(mine, m.balance, m.totalShares);
    }

    /// @notice A feed's parameters as it was created with. Reverts for an unknown feed.
    function feedParams(bytes32 feedId) external view returns (FeedParams memory) {
        return _feed(feedId).params;
    }

    /// @notice A feed's stored question prefix and body tail. Reverts for an unknown feed.
    function feedText(bytes32 feedId) external view returns (bytes memory qPrefix, bytes memory tail) {
        Feed storage f = _feed(feedId);
        return (f.qPrefix, f.tail);
    }

    /// @notice How many feeds have been created.
    function feedCount() external view returns (uint256) {
        return _feedIds.length;
    }

    /// @notice The id of the `index`-th feed created, counting from zero.
    function feedAt(uint256 index) external view returns (bytes32) {
        return _feedIds[index];
    }

    /// @notice The feed a pending Intake request belongs to, zero for any other id.
    function feedOfRequest(bytes32 intakeRequestId) external view returns (bytes32) {
        return _feedOfRequest[intakeRequestId];
    }

    /// @notice Where a feed stands. `exists` is false and the rest zero for an unknown feed.
    function feedState(bytes32 feedId) external view returns (FeedView memory v) {
        Feed storage f = _feeds[feedId];
        FeedState memory s = f.state;
        if (!s.exists) {
            v.blocker = Blocker.UnknownFeed;
            return v;
        }
        v.exists = true;
        (v.rounds, v.latestRound, v.lastRequestBlock, v.lastToBlock) =
        (s.rounds, s.latestRound, s.lastRequestBlock, s.lastToBlock);
        (v.failStreak, v.pending) = (s.failStreak, s.pending);
        if (s.pending) v.pendingRequestId = _rounds[feedId][s.rounds].requestId;
        v.nextRequestBlock = _nextRequestBlock(f.params, s);
        (v.meterBalance, v.totalShares) = (f.meter.balance, f.meter.totalShares);
        v.cost = costOf(feedId);
        (v.blocker,,,) = _readiness(f);
    }

    /// @notice Whether `request(feedId)` would go through in this block and, if not, why.
    /// @return ok True when nothing blocks a request.
    /// @return why The first thing that blocks it.
    /// @return price The live Intake price, when it was read.
    /// @return fromBlock The window a request made in this block would ask about.
    function canRequest(bytes32 feedId)
        external
        view
        returns (bool ok, Blocker why, uint256 price, uint64 fromBlock, uint64 toBlock)
    {
        (why, price, fromBlock, toBlock) = _readiness(_feeds[feedId]);
        ok = why == Blocker.None;
    }

    /// @notice The exact bytes a request made in this block would send to the Intake, the question
    /// hash an answer to it must carry, and its window. Reverts for an unknown feed; empty when
    /// there is no window to ask about yet.
    /// @dev The window ends `lagBlocks` behind the block the call is made in, so the bytes change
    /// with every block.
    function nextBody(bytes32 feedId)
        external
        view
        returns (bytes memory body, bytes32 questionHash, uint64 fromBlock, uint64 toBlock)
    {
        Feed storage f = _feed(feedId);
        (fromBlock, toBlock) = _window(f.params, f.state);
        if (toBlock != 0) (body, questionHash) = _body(f, fromBlock, toBlock);
    }

    /// @notice Whether a feed's WHEN gate is true now. True for a feed with no gate.
    function gateOpen(bytes32 feedId) external view returns (bool) {
        return _gateOpen(_feed(feedId).params);
    }

    /// @notice Whether `submit` is open for a feed right now: the feed pins its question, a panel
    /// does not judge it, a round is pending, and either the Intake has completed that round's
    /// request or thirty minutes have passed since it was made. False for an unknown feed.
    function canSubmit(bytes32 feedId) external view returns (bool) {
        Feed storage f = _feeds[feedId];
        FeedState memory s = f.state;
        return s.pending && f.params.pinHash && !f.panelEvidence && _submitOpen(_rounds[feedId][s.rounds]);
    }

    /// @notice What `abandon(feedId)` would do in this block.
    /// @return step `Close`, `StartWait` (the call would record the Intake's completion and start
    /// the thirty minutes), or `Wait` (the call would revert, or no round is pending).
    /// @return closableAt The earliest time the pending round can be closed as things stand; for
    /// `StartWait`, if `abandon` is called now. Zero when no round is pending.
    function canAbandon(bytes32 feedId) external view returns (AbandonStep step, uint256 closableAt) {
        FeedState memory s = _feeds[feedId].state;
        if (s.pending) {
            (step, closableAt,) = _abandonStep(s, _rounds[feedId][s.rounds], _feeds[feedId].params.validFor);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _feed(bytes32 feedId) internal view returns (Feed storage f) {
        f = _feeds[feedId];
        if (!f.state.exists) revert UnknownFeed(feedId);
    }

    /// @dev The bytes a request about this window sends to the Intake and the question hash an
    /// answer to it must carry, both built from the feed's one stored text. Used by `request` and by
    /// `nextBody`, so a page is shown exactly what a transaction would send.
    function _body(Feed storage f, uint64 fromBlock, uint64 toBlock)
        internal
        view
        returns (bytes memory body, bytes32 questionHash)
    {
        bytes memory shared = QuestionBody.shared(f.qPrefix, fromBlock, toBlock);
        questionHash = keccak256(bytes.concat(shared, "}"));
        body = bytes.concat(shared, f.tail);
    }

    /// @dev The one place that decides whether a request may be made, used by `request` and by the
    /// views, so a page can never be told something the transaction would not do.
    function _readiness(Feed storage f)
        internal
        view
        returns (Blocker why, uint256 price, uint64 fromBlock, uint64 toBlock)
    {
        FeedState memory s = f.state;
        if (!s.exists) return (Blocker.UnknownFeed, 0, 0, 0);
        if (ASKED_SLOT.asBoolean().tload()) return (Blocker.AlreadyAskedThisTransaction, 0, 0, 0);
        if (s.pending) return (Blocker.RoundPending, 0, 0, 0);
        FeedParams storage p = f.params;
        if (block.number < _nextRequestBlock(p, s)) return (Blocker.TooSoon, 0, 0, 0);
        (fromBlock, toBlock) = _window(p, s);
        if (toBlock == 0) return (Blocker.NoBlocks, 0, 0, 0);
        if (!_gateOpen(p)) return (Blocker.GateClosed, 0, fromBlock, toBlock);
        bool ok;
        (ok, price) = _price(p.action);
        if (!ok || price == 0) return (Blocker.NotSold, 0, fromBlock, toBlock);
        if (price > p.maxPrice) return (Blocker.PriceAboveCap, price, fromBlock, toBlock);
        if (f.meter.balance < price + p.tip) return (Blocker.MeterTooLow, price, fromBlock, toBlock);
    }

    /// @dev The first block at which the cadence allows a request. Zero before the first round.
    /// Each failed round in a row doubles the wait, five times at most.
    function _nextRequestBlock(FeedParams storage p, FeedState memory s) internal view returns (uint64) {
        if (s.rounds == 0) return 0;
        uint256 doublings = s.failStreak < MAX_BACKOFF_DOUBLINGS ? s.failStreak : MAX_BACKOFF_DOUBLINGS;
        uint256 next = s.lastRequestBlock + (uint256(p.cadenceBlocks) << doublings);
        return next.toUint64();
    }

    /// @dev Whether `submit` may be used on a pending round as far as time goes: the Intake has
    /// completed the round's request, or the request is thirty minutes old.
    function _submitOpen(Round storage r) internal view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp >= uint256(r.requestedAt) + SUBMIT_AFTER_SILENCE || _intakeCompleted(r.requestId);
    }

    /// @dev The one place that decides what `abandon` does with a pending round, used by `abandon`
    /// and by `canAbandon`. The silence deadline includes time to sign and to deliver a valid
    /// answer. Completion can shorten it to thirty minutes after first being observed; a recorded
    /// completion counts only while the Intake still reports it. For `StartWait`, `closableAt`
    /// assumes the completion wait starts now.
    function _abandonStep(FeedState memory s, Round storage r, uint32 validFor)
        internal
        view
        returns (AbandonStep step, uint256 closableAt, bool completed)
    {
        completed = _intakeCompleted(r.requestId);
        // Allow the oracle the silence interval to sign, then the answer its full requested
        // validity plus clock tolerance. Expiry is inclusive, hence the extra second.
        closableAt = uint256(r.requestedAt) + ABANDON_AFTER_SILENCE + validFor + ISSUED_AT_TOLERANCE + 1;
        uint256 seenAt = s.completionSeenAt;
        if (completed) {
            uint256 waitFrom = seenAt == 0 ? block.timestamp : seenAt;
            closableAt = Math.min(closableAt, waitFrom + ABANDON_AFTER_COMPLETED);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= closableAt) {
            step = AbandonStep.Close;
        } else if (completed && seenAt == 0) {
            step = AbandonStep.StartWait;
        }
    }

    /// @dev The window a request made in this block asks about, or two zeros when there is none.
    /// It ends `lagBlocks` behind this block, so a real window never ends at block zero. A
    /// contiguous feed starts at the block after its last answered window (its first window covers
    /// one cadence) and is cut at `maxWindowBlocks`, oldest blocks first. Any other feed asks about
    /// the newest `maxWindowBlocks`.
    ///
    /// After a failed round this means: a contiguous feed with an answer behind it asks from the
    /// same first block again, to a fresh last block; a contiguous feed that has never been
    /// answered asks about the newest `cadenceBlocks`; a feed that is not contiguous asks about the
    /// newest `maxWindowBlocks`. Only the first of the three covers the failed round's blocks, so a
    /// reader takes each figure's period from the round's own `fromBlock` and `toBlock`.
    function _window(FeedParams storage p, FeedState memory s)
        internal
        view
        returns (uint64 fromBlock, uint64 toBlock)
    {
        uint256 lag = p.lagBlocks;
        if (block.number <= lag) return (0, 0);
        uint256 newest = block.number - lag;
        uint256 from = 0;
        uint256 to = newest;
        if (p.contiguous && s.latestRound != 0) {
            from = uint256(s.lastToBlock) + 1;
            if (from > newest) return (0, 0);
            uint256 cut = from + p.maxWindowBlocks - 1;
            if (cut < to) to = cut;
        } else {
            uint256 span = p.contiguous ? p.cadenceBlocks : p.maxWindowBlocks;
            if (newest >= span) from = newest + 1 - span;
        }
        return (from.toUint64(), to.toUint64());
    }

    /// @dev A gate that reverts, runs out of its 100,000 gas, returns fewer than 32 bytes or has no
    /// code is closed. Only the first returned word is read, whatever the target returns.
    function _gateOpen(FeedParams storage p) internal view returns (bool) {
        address target = p.gateTarget;
        if (target == address(0)) return true;
        (bool ok, uint256 word) = _readWord(target, p.gateData, GATE_GAS, 0);
        if (!ok) return false;
        uint256 threshold = p.gateThreshold;
        uint256 cmp = p.gateCmp;
        if (cmp == 1) return word >= threshold;
        if (cmp == 2) return word <= threshold;
        if (cmp == 3) return word > threshold;
        if (cmp == 4) return word < threshold;
        if (cmp == 5) return word == threshold;
        return word != threshold;
    }

    function _price(bytes32 action) internal view returns (bool ok, uint256 price) {
        return _readWord(address(INTAKE), abi.encodeCall(IIntake.priceOf, (action, address(IMD))), INTAKE_READ_GAS, 0);
    }

    /// @dev `Intake.requests(id).completed`, the fourth returned word. Anything but a clean `true`
    /// counts as not completed.
    function _intakeCompleted(bytes32 requestId) internal view returns (bool) {
        (bool ok, uint256 word) =
            _readWord(address(INTAKE), abi.encodeCall(IIntake.requests, (requestId)), INTAKE_READ_GAS, 3);
        return ok && word == 1;
    }

    /// @dev A static call that trusts nothing about its target: bounded gas, no revert passed on,
    /// and exactly one word copied out however much is returned.
    /// @param index Which 32-byte word of the return data to read.
    function _readWord(address target, bytes memory data, uint256 gasLimit, uint256 index)
        internal
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(data, 0x20), mload(data), 0x00, 0x00)
            let start := mul(index, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), add(start, 0x20))))
            if ok {
                returndatacopy(0x00, start, 0x20)
                word := mload(0x00)
            }
        }
    }

    function _sharesOf(Meter storage m, Stake storage s) internal view returns (uint256) {
        if (s.epoch != m.epoch) return 0;
        uint256 bits = uint256(m.rescales - s.rescales) * RESCALE_BITS;
        return bits < 256 ? s.shares >> bits : 0;
    }

    /// @dev Gives the tip of a round that is being closed without an answer back to the meter it
    /// came from. No share is minted, so the funders share it. A meter's shares must never be worth
    /// more than one wei each (that is what protects a later funder from being rounded out of its
    /// money), and the returned tip is no exception: when the shares outstanding are fewer than the
    /// meter's wei after the return, the count is raised to match, and the shares added belong to
    /// nobody. That happens only when funders took their money out while the round was pending or
    /// the meter was refilled from zero; the part nobody owns then stays on the meter and pays for
    /// later requests.
    function _returnTip(Feed storage f) private {
        Held memory h = f.held;
        if (h.tip == 0) return;
        _tips[h.keeper] -= uint256(h.tip) << TIP_PENDING_SHIFT;
        totalTips -= h.tip;
        Meter storage m = f.meter;
        uint256 balance = uint256(m.balance) + h.tip;
        m.balance = balance.toUint128();
        if (m.totalShares < balance) m.totalShares = balance;
        totalMetered += h.tip;
    }

    /// @dev Checks an attestation against the feed's pending round and stores its answer. Called
    /// with the pending round's Intake request id; `onOracleResult` got it from the Intake and
    /// looked the feed up by it, `submit` read it from the round.
    function _settle(
        bytes32 feedId,
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) private {
        Feed storage f = _feeds[feedId];
        FeedState memory s = f.state;
        if (!s.pending) revert NoPendingRound(feedId);
        Round storage r = _rounds[feedId][s.rounds];
        delete _feedOfRequest[requestId];

        _verifyAttestation(a, signature);
        // An attestation answers at most one round of a feed. The mark is per feed, and the base
        // contract's `_consume`, one flag for the whole contract, is not used: two feeds can ask
        // the same question about the same blocks, each pays for a request of its own, and an
        // answer handed to one of them must not be lost to the other. `consumed` still records,
        // for any reader, that the attestation was acted on here.
        mapping(bytes32 => bool) storage used = usedBy[a.requestId];
        if (used[feedId]) revert AlreadyConsumed(a.requestId);
        used[feedId] = true;
        consumed[a.requestId] = true;

        FeedParams storage p = f.params;
        if (a.chainId != p.chainId) revert WrongChain(p.chainId, a.chainId);
        if (p.pinHash && a.questionHash != r.questionHash) revert WrongQuestion(r.questionHash, a.questionHash);
        if (a.fromBlock != r.fromBlock || a.toBlock != r.toBlock) revert WrongWindow(a.fromBlock, a.toBlock);
        if (a.answerType != p.answerType) revert WrongAnswerType(p.answerType, a.answerType);
        if (a.panelSize < p.panelSize || a.quorum < p.quorum) revert PanelTooSmall(a.panelSize, a.quorum);
        // `agreed` is below the signed quorum only for chain evidence, when members who ran one
        // recipe split and the oracle's own rerun settled the answer. A feed created with
        // `minAgreed == quorum` refuses that: it wants the panel's own agreement. A feed created
        // with less accepts it, down to its own floor and no further.
        uint16 needed = p.minAgreed == p.quorum ? a.quorum : p.minAgreed;
        if (a.agreed < needed) revert NotEnoughAgreed(a.agreed, needed);
        bytes32 closingHash = r.blockHash;
        if (closingHash != bytes32(0) && a.blockHash != closingHash) revert WrongBlockHash(closingHash, a.blockHash);

        uint256 value = _valueOf(a);
        r.value = value;
        r.status = RoundStatus.Answered;
        r.updatedAt = block.timestamp.toUint48();
        s.pending = false;
        s.completionSeenAt = 0;
        s.latestRound = s.rounds;
        s.lastToBlock = uint256(a.toBlock).toUint48();
        s.failStreak = 0;
        f.state = s;

        // The answer earns the tip that was set aside when the round was opened. When the keeper
        // that opened it is always credited, whether the Intake or an observer delivered the answer:
        // this reads and writes one slot that already holds a value.
        Held memory h = f.held;
        if (h.tip != 0) {
            _tips[h.keeper] -= uint256(h.tip) << TIP_PENDING_SHIFT;
            _tips[h.keeper] += h.tip;
        }
        emit RoundAnswered(feedId, s.rounds, a.requestId, value, a.figure, a.agreed, a.panelJobId, msg.sender);
    }

    /// @dev The answer as one word, as `IQuestions.latest` defines it. The type was checked against
    /// the feed's before this is called.
    function _valueOf(OracleAttestation.Attestation calldata a) private pure returns (uint256 value) {
        uint8 t = a.answerType;
        if (t >= OracleAttestation.ANSWER_ADDRESS_LIST) return uint256(keccak256(a.answer));
        if (a.answer.length != 32) revert MalformedAnswer();
        value = abi.decode(a.answer, (uint256));
        if (
            (t == OracleAttestation.ANSWER_BOOL && value > 1)
                || (t == OracleAttestation.ANSWER_ADDRESS && value > type(uint160).max)
        ) revert MalformedAnswer();
    }

    // slither-disable-end incorrect-equality
    // forge-lint: disable-end(reentrancy-events)
}
