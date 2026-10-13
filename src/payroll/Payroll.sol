// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPayroll} from "../interfaces/IPayroll.sol";
import {IQuestions} from "../interfaces/IQuestions.sol";
import {ISeatAdapter, ISeats} from "../interfaces/external/ISeatAdapter.sol";

/// @title The one read of Standing Questions that Payroll needs beyond `IQuestions`
/// @notice `Questions` has this view; the shared interface file, which later launches hold copies of,
/// does not list it, and is left as it is.
interface IMeterPosition {
    /// @notice The IMD `funder` would get by defunding all its shares of a feed's meter now.
    function redeemable(bytes32 feedId, address funder) external view returns (uint256);
}

/// @title Payroll: where HELP WANTED's fees arrive and how they leave
/// @notice Every IMD that reaches this contract through `pay`, or by a plain transfer picked up by
/// `book`, is split by fixed shares: 50% to sIMD stakers as a slow stream, 30% to the owners of the
/// 2,000 seats as pull claims, 20% to a budget that keeps three house feeds of Standing Questions
/// funded. Tips are separate money: they are not split, they wait for the seat whose agent did the job.
///
/// There is no owner, no setter and no way to pause. Anyone may trigger the fixed rules, except
/// that a contract holding a seat must initiate its own claims (Payroll itself can recycle its share). Every address this contract depends on is a constructor
/// argument written in the launch manifest.
///
/// @dev How the books are kept. The contract stores running totals (`ledger`) and derives what it owes
/// from them, so the parts can never disagree with the whole:
///
///   owed to stakers   = toStakers − dripped
///   owed to seats     = toSeats + tipsToSeats − seatClaimed
///   owed as tips      = tipsIn − tipsToSeats − tipsClaimed
///   feed budget       = toFeeds − feedsFunded
///
/// Their sum is what the IMD balance must cover. Any balance above that sum is revenue that arrived by
/// plain transfer and has not been booked yet.
///
/// Every outside contract (sIMD, the seat token, the seat Adapter, Questions) is read with a low-level
/// call and a length check, and is assumed able to revert, to return nonsense, or to change. A failure
/// in one of them stops only the one payout that needs it: `pay`, `tip` and `book` touch nothing but IMD.
///
/// What each dependency is trusted with, and no more:
///  - The seat token says who owns a seat. Payroll pays whoever `ownerOf` names when a claim is made.
///  - The seat Adapter (an upgradeable proxy) says which seat an agent is bound to. Whoever controls it
///    decides where unclaimed tips can go, or that they cannot be claimed, in which case they fall to
///    the seat pool after 180 to 360 days. Only tips depend on it.
///  - sIMD receives the stakers' stream by plain transfer. While it has no shares outstanding, or does
///    not answer as a vault over IMD, the stream waits here.
///  - Questions is handed at most one runway per house feed at a time: Payroll tops up its own
///    position on a meter, never past the runway. IMD placed on a meter is spent by that feed or
///    stays on it; Payroll never takes it back.
///
/// Limits a reader should know:
///  - A claim pays whoever holds the seat at that moment. A contract holder must initiate payment
///    itself, except Payroll's own recycling, so passive escrows keep the share and tips unclaimed.
///    Code under construction or a future contract address cannot be identified by this check.
///  - A seat whose owner the seat token never names again keeps its share of the seat pool here for
///    good. Tips bound to such a seat are different: once they have waited their time they can be
///    swept to the pool.
///  - sIMD has no time weighting: IMD that reaches it is shared by whoever holds its shares at that
///    moment. A wallet that stakes just before a drip and leaves after it takes its share of that
///    drip, in proportion to what it staked; one that does so at every drip of a stream takes what
///    a staker of its size who stayed all week would have, and the stakers who stay are diluted by
///    as much. Nothing in this contract prevents that. What a visit needs is set by sIMD: a holder
///    cannot leave in the block it staked in, so a visit takes IMD of the visitor's own, staked
///    from one block into the next, and cannot be paid for with IMD borrowed for one transaction.
///  - The stream is only as even as its callers make it. `drip` sends at most one hour of stream per
///    call, ten minutes apart, so a backlog left by days without a call leaves at up to six hours of
///    stream an hour. Somebody dripping about once an hour keeps the flow even. The cap bounds one
///    transfer, and so what one visit to sIMD can take; it does not bound what visits add up to.
///  - A booking never restarts the stream, and it can slow it. The money still vesting and the new
///    money become one stream with one end time: the average of the time the old money had left
///    and seven days, each weighted by its amount. A booking that is dust next to what is left
///    therefore moves the end by nothing, and one much larger takes close to seven days. A booking in
///    between makes money that was already vesting arrive later than it would have: one as large
///    as what is left, made in the last 2 days 8 hours of a stream, lowers the rate at which the
///    old money vests. The delay has a ceiling: the stream never ends more than seven days after
///    the latest booking. Stakers are paid in full; when is what a booking can move.
contract Payroll is IPayroll, ReentrancyGuardTransient {
    // Every function that changes state holds the same transient lock, so no nested call can run in
    // between and reorder this contract's events. The lint cannot see the lock, and it counts the
    // low-level reads of sIMD, the seat token, the Adapter and Questions as calls that could re-enter.
    // forge-lint: disable-start(reentrancy-events)
    //
    // Every `==` in this contract compares an amount with zero (nothing to do) or two period counters
    // with each other. None compares a token balance with a figure somebody could push it off by a
    // wei, which is what the static analyser's strict-equality rule is for.
    // slither-disable-start incorrect-equality

    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Running totals, in IMD wei. Read all of them at once with `ledger()`.
    /// @param received Everything booked as revenue, through `pay` and `book`.
    /// @param toStakers The stakers' half of `received`, plus every rounding remainder, plus feed budget
    /// that was later released to them. `received == toStakers + toSeats + toFeeds` at all times.
    /// @param toSeats The seats' 30% of `received`.
    /// @param toFeeds The feeds' 20% of `received`, less whatever was later released to stakers. It can
    /// therefore go down; the feeds' share as it was booked is `toFeeds + feedsReleased`.
    /// @param dripped Sent to sIMD so far. Never more than `toStakers`.
    /// @param seatClaimed Paid to seat owners from the seat pool.
    /// @param tipsIn Pulled through `tip`.
    /// @param tipsClaimed Paid to seat owners through `claimTip`.
    /// @param feedsFunded Placed on the house feeds' meters.
    /// @param tipsToSeats The part of `tipsIn` that joined the seat pool: remainders of the equal split,
    /// tips sent with an empty list, and tips swept after their wait.
    /// @param feedsReleased Feed budget that waited too long and joined the staker stream. A history
    /// figure only: it is already inside `toStakers` and already taken out of `toFeeds`.
    struct Ledger {
        uint256 received;
        uint256 toStakers;
        uint256 toSeats;
        uint256 toFeeds;
        uint256 dripped;
        uint256 seatClaimed;
        uint256 tipsIn;
        uint256 tipsClaimed;
        uint256 feedsFunded;
        uint256 tipsToSeats;
        uint256 feedsReleased;
    }

    /// @notice The four clocks of the contract, kept in one storage slot.
    /// @param streamEnd When the staker stream finishes vesting (unix seconds).
    /// @param streamCursor Up to when vesting has been accounted.
    /// @param lastDripAt When `drip` last sent IMD to sIMD.
    /// @param feedPeriod The fortnight (unix time / `FEED_BUDGET_PERIOD`) the feed budget was last aged in.
    struct Clock {
        uint64 streamEnd;
        uint64 streamCursor;
        uint64 lastDripAt;
        uint64 feedPeriod;
    }

    /// @dev One agent's unpaid tips, in three tranches by age, so that a later tip can never lengthen
    /// the wait of an earlier one. Time is cut into periods of `TIP_SWEEP_DELAY` counted from the unix
    /// epoch. `fresh` arrived during `period`, `old` during the period before it, `ripe` earlier than
    /// that: only `ripe` has waited a whole period and may be swept. `fresh` and `period` share a
    /// storage slot, so a tip to an agent already tipped in this period, or never tipped, writes one
    /// slot. `period` is zero exactly when nothing is owed (the slot is deleted when it empties).
    struct TipSlot {
        uint128 fresh;
        uint64 period;
        uint128 old;
        uint128 ripe;
    }

    /// @dev What the seat Adapter says about an agent, reduced to the three cases that matter here.
    enum Binding {
        Unbound,
        Elsewhere,
        Seat
    }

    // ---------------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice The seats' share of every booking, in basis points.
    uint256 public constant SEAT_BPS = 3_000;
    /// @notice The feeds' share of every booking, in basis points. Stakers get the rest (50% and the
    /// rounding remainder).
    uint256 public constant FEED_BPS = 2_000;
    uint256 private constant BPS = 10_000;

    /// @notice New money takes this long to vest. A stream that already holds unvested money ends
    /// sooner than this after a booking: see `drip`.
    uint256 public constant STREAM_DURATION = 7 days;
    /// @notice The shortest time between two drips.
    uint256 public constant DRIP_INTERVAL = 10 minutes;
    /// @notice One drip sends at most this much stream time: an hour of the stream at the rate it
    /// had when it was last re-levelled (for a single booking, 1/168 of it).
    uint256 public constant DRIP_WINDOW = 1 hours;

    /// @notice Only the first 16 ids of a tip's list share it.
    uint256 public constant MAX_TIP_AGENTS = 16;
    /// @notice The least a tip waits for its agent to be bound to a seat before it can be swept, and
    /// the length of one ageing period. A tip is swept at the earliest at the start of the second
    /// period after the one it arrived in, so it waits between one and two of these.
    uint256 public constant TIP_SWEEP_DELAY = 180 days;
    /// @notice The longest list `claimSeats` accepts. Measured on a mainnet fork on two days, a seat
    /// paid for the first time costs between 47,000 and 51,000 gas, so a full list is about 10
    /// million: well inside the 16,777,216 gas one transaction may use.
    uint256 public constant MAX_SEATS_PER_CALL = 200;

    /// @notice The meters of the first two house feeds are topped up to this many requests' worth and
    /// no further: two weeks of a feed that is asked once a day.
    uint256 public constant FEED_RUNWAY_REQUESTS = 14;
    /// @notice The runway of the third house feed, in its own requests. It is meant for a slow feed
    /// (the weekly ranking of employers): four requests are about four weeks of it.
    uint256 public constant FEED_C_RUNWAY_REQUESTS = 4;
    /// @notice The most this contract will assume one request costs when it sizes a top-up. The price is
    /// set by the Intake's owner; this cap keeps a price change from emptying the budget into one meter.
    uint256 public constant FEED_COST_CAP = 2e18;
    /// @notice Feed budget is aged in fortnights; see `fundFeeds`.
    uint256 public constant FEED_BUDGET_PERIOD = 14 days;

    /// @notice Gas given to the Adapter's `bindingOf`. The mainnet Adapter needs a small fraction of it.
    uint256 public constant BINDING_GAS = 100_000;
    /// @dev Gas that must be on hand before the binding read, so that the read receives all of
    /// `BINDING_GAS` after the EVM keeps back one 64th. Without this floor a caller could send just
    /// enough gas for the read to run out, and a bound agent would look unbound.
    uint256 private constant BINDING_GAS_FLOOR = (BINDING_GAS * 64) / 63 + 5_000;
    /// @dev Gas that must be left after a seat-owner read that failed, before `sweepTip` acts on the
    /// failure. A read that ran out of gas leaves the caller one 64th of what it was given, so this
    /// much left over means the read had at least 63 times as much (6.3 million) and still named no
    /// owner. A caller cannot make a seat look ownerless by sending little gas.
    uint256 private constant OWNER_READ_MARGIN = 100_000;

    /// @notice The IMD token.
    IERC20 public immutable IMD;
    /// @notice The sIMD vault. A plain IMD transfer to it raises `totalAssets` for every staker.
    address public immutable SIMD;
    /// @notice The seat ERC-721.
    address public immutable SEATS;
    /// @notice How many seats share the seat pool: token ids `0 … SEAT_COUNT − 1`.
    uint256 public immutable SEAT_COUNT;
    /// @notice IdentityMD's agent-to-seat Adapter (an upgradeable proxy; treated as untrusted).
    address public immutable ADAPTER;
    /// @notice The Standing Questions contract whose meters the feed budget tops up.
    address public immutable QUESTIONS;
    /// @notice The first house feed (the Jobs Report's payrolls feed). It and `FEED_B` are served
    /// first; when the budget cannot cover both, each gets the same fraction of what it lacks.
    bytes32 public immutable FEED_A;
    /// @notice The second house feed (the Jobs Report's hires feed).
    bytes32 public immutable FEED_B;
    /// @notice The third house feed (the weekly ranking of employers). It is served only when the
    /// first two are covered, and up to its own shorter runway, so a feed the Jobs Report does not
    /// need can never take budget from the two it is printed from.
    bytes32 public immutable FEED_C;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    Ledger private _ledger;

    /// @notice The stream, feed and drip clocks.
    Clock public clock;

    /// @notice The part of the staker stream that had not vested at `clock.streamCursor`.
    uint256 public streamUnvested;
    /// @notice The most one drip may send, set when the stream was last re-levelled: one hour of the
    /// stream at its rate then, and never less than 1/168 of everything outstanding nor, while money
    /// that has already vested is waiting to be sent, than the cap before. See `drip`.
    uint256 public dripCap;

    /// @notice IMD credited to each seat since launch. A seat's claimable amount is this minus `seatPaid`.
    uint256 public seatAccrued;
    /// @notice Seat-pool wei too few to give every seat one more; they join the next credit.
    uint256 public seatCarry;
    /// @notice What each seat has been paid, measured against `seatAccrued`.
    mapping(uint256 tokenId => uint256) public seatPaid;

    mapping(uint256 agentId => TipSlot) private _tips;

    /// @notice The part of the feed budget booked in the fortnight before the one the budget was last
    /// aged in. It falls due at the next fortnight boundary unless a meter takes it first.
    uint256 public feedBudgetOld;
    /// @notice The part of the feed budget whose wait is over. Meters are served from it first, and
    /// `fundFeeds` releases what they leave of it to the staker stream. A booking never does.
    uint256 public feedBudgetDue;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice `from` paid `amount` IMD in through `pay`, labelled `memo`.
    event Paid(address indexed from, bytes32 indexed memo, uint256 amount);
    /// @notice `amount` was booked as revenue and split three ways.
    event Booked(uint256 amount, uint256 toStakers, uint256 toSeats, uint256 toFeeds);
    /// @notice The staker stream was re-levelled: `outstanding` is everything still to be sent, of which
    /// `unvested` vests evenly until `endsAt`; one drip sends at most `dripCap`.
    event StreamLevelled(uint256 outstanding, uint256 unvested, uint256 endsAt, uint256 dripCap);
    /// @notice `amount` IMD was transferred to sIMD; `outstanding` is still to come.
    event Dripped(address indexed caller, uint256 amount, uint256 outstanding);
    /// @notice A seat's share of the seat pool was paid to its owner.
    event SeatClaimed(uint256 indexed tokenId, address indexed owner, uint256 amount);
    /// @notice A tip arrived. Each id in `agentIds` was credited `perAgent`; `toSeatPool` joined the pool.
    event Tipped(address indexed from, uint256 amount, uint256 perAgent, uint256 toSeatPool, uint256[] agentIds);
    /// @notice An agent's tips were paid to the owner of the seat it is bound to.
    event TipClaimed(uint256 indexed agentId, uint256 indexed tokenId, address indexed owner, uint256 amount);
    /// @notice The part of an agent's tips that had waited a whole period without becoming claimable
    /// joined the seat pool.
    event TipSwept(uint256 indexed agentId, uint256 amount);
    /// @notice `amount` of the feed budget was placed on a feed's meter.
    event FeedFunded(bytes32 indexed feedId, uint256 amount);
    /// @notice Questions did not take a top-up of `amount`; the budget keeps it.
    event FeedFundingFailed(bytes32 indexed feedId, uint256 amount);
    /// @notice Feed budget that the meters did not need in time joined the staker stream. Emitted by
    /// `fundFeeds` only, after the meters were served.
    event FeedBudgetReleased(uint256 amount);
    /// @notice A fortnight boundary was crossed with budget on hand: `heldOver` is now the old tranche,
    /// the part that falls due at the next boundary unless a meter takes it first. What was the old
    /// tranche until now is due (`feedBudgetDue`): the next `fundFeeds` serves the meters from it and
    /// releases the rest.
    event FeedBudgetAged(uint256 indexed period, uint256 heldOver);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice A constructor address argument was zero.
    error ZeroAddress();
    /// @notice The constructor's seat count was zero.
    error ZeroSeatCount();
    /// @notice Two of the three feed ids were the same; one meter would be counted twice.
    error DuplicateFeed();
    /// @notice `drip` was called less than `DRIP_INTERVAL` after the previous one.
    error DripTooSoon(uint256 notBefore);
    /// @notice sIMD did not answer as a vault over IMD with shares outstanding, so a transfer to it would
    /// not reach stakers. The stream keeps the money until it does.
    error StakingVaultNotReady();
    /// @notice The token id is not one of the `SEAT_COUNT` seats.
    error UnknownSeat(uint256 tokenId);
    /// @notice The seat token did not name an owner for this seat. Nothing is lost: claim again later.
    error SeatHasNoOwner(uint256 tokenId);
    /// @notice A contract holding a seat must initiate its own claim to accept the IMD.
    error ContractOwnerMustClaim(address owner);
    /// @notice `claimSeats` was given more than `MAX_SEATS_PER_CALL` ids.
    error TooManySeats(uint256 given, uint256 max);
    /// @notice The Adapter has no binding for this agent (its call reverted or returned too little).
    error AgentNotBound(uint256 agentId);
    /// @notice The agent is bound to something other than one of the seats.
    error AgentBoundElsewhere(uint256 agentId);
    /// @notice None of the agent's tips has waited a whole period yet; the oldest does at `notBefore`.
    error TipNotSweepableYet(uint256 agentId, uint256 notBefore);
    /// @notice The agent is bound to a seat that has an owner right now: use `claimTip`, the tip is
    /// not swept.
    error TipStillClaimable(uint256 agentId, uint256 tokenId);
    /// @notice The transaction carries too little gas to read the Adapter or the seat token reliably.
    error GasTooLow();
    /// @notice More IMD left during a meter top-up than was approved for it.
    error FeedOverdrawn();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Fixes every dependency for good. Makes no external call, so it deploys on an empty chain;
    /// each dependency is checked when it is first used instead.
    /// @param imd The IMD token.
    /// @param simd The sIMD vault that stakers hold.
    /// @param seats The seat ERC-721.
    /// @param seatCount How many seats exist (2,000 on mainnet: ids 0 to 1,999).
    /// @param adapter The agent-to-seat Adapter.
    /// @param questions The Standing Questions contract.
    /// @param feedA The first house feed (the content-addressed feed id; the feed may be created later).
    /// @param feedB The second house feed. `feedA` and `feedB` share a short budget by need.
    /// @param feedC The third house feed, for a slow feed: a shorter runway, served after the other two.
    constructor(
        address imd,
        address simd,
        address seats,
        uint256 seatCount,
        address adapter,
        address questions,
        bytes32 feedA,
        bytes32 feedB,
        bytes32 feedC
    ) {
        if (
            imd == address(0) || simd == address(0) || seats == address(0) || adapter == address(0)
                || questions == address(0)
        ) revert ZeroAddress();
        if (seatCount == 0) revert ZeroSeatCount();
        if (feedA == feedB || feedA == feedC || feedB == feedC) revert DuplicateFeed();

        IMD = IERC20(imd);
        SIMD = simd;
        SEATS = seats;
        SEAT_COUNT = seatCount;
        ADAPTER = adapter;
        QUESTIONS = questions;
        FEED_A = feedA;
        FEED_B = feedB;
        FEED_C = feedC;
    }

    // ---------------------------------------------------------------------------------------------
    // Money in
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPayroll
    /// @dev Anyone may call; the caller must have approved `amount`. What is booked is what actually
    /// arrived (the balance difference), so the books stay exact whatever the token does. A zero amount
    /// does nothing and does not revert, so a caller that computes a fee of zero needs no special case.
    /// Reverts only if the IMD transfer does.
    function pay(uint256 amount, bytes32 memo) external nonReentrant {
        if (amount == 0) return;
        uint256 got = _pull(amount);
        if (got == 0) return;
        emit Paid(msg.sender, memo, got);
        _book(got);
    }

    /// @inheritdoc IPayroll
    /// @dev Anyone may call. This is how money sent without calling `pay` is counted: the IMD balance
    /// above everything already owed is booked as revenue and split like any other. A sender whose `pay`
    /// call could not go through can therefore transfer plainly and lose nothing.
    /// @return booked The amount split; zero when there was nothing new.
    function book() external nonReentrant returns (uint256 booked) {
        booked = _unbooked();
        if (booked != 0) _book(booked);
    }

    /// @inheritdoc IPayroll
    /// @dev Anyone may call; the caller must have approved `amount`. Only the first `MAX_TIP_AGENTS` ids
    /// share the tip; ids beyond that are ignored. An id listed twice is credited twice. Whatever the
    /// equal split leaves over, and the whole tip when the list is empty or the amount is too small to
    /// give each id one wei, joins the seat pool. The ids are not checked against the Adapter here: that
    /// happens in `claimTip`, so a settlement can never fail because of who worked on the job.
    /// A zero amount does nothing. Reverts only if the IMD transfer does. (A share is bounded by the
    /// IMD supply, far below the 2^128 wei a slot can hold.)
    ///
    /// Measured: a tip to 16 agents never tipped before costs about 425,000 gas (about 505,000 when it
    /// is the first tip the contract ever receives), and one to 16 agents whose earlier tips must first
    /// be aged about 550,000. Callers that cap the gas they forward should allow for that.
    function tip(uint256[] calldata agentIds, uint256 amount) external nonReentrant {
        if (amount == 0) return;
        uint256 got = _pull(amount);
        if (got == 0) return;

        uint256 n = agentIds.length > MAX_TIP_AGENTS ? MAX_TIP_AGENTS : agentIds.length;
        uint256 perAgent = n == 0 ? 0 : got / n;
        // The remainder of the equal split, on purpose: what the division dropped joins the seat pool.
        // slither-disable-next-line divide-before-multiply
        uint256 toSeatPool = got - perAgent * n;

        _ledger.tipsIn += got;
        if (perAgent != 0) {
            uint128 share = SafeCast.toUint128(perAgent);
            uint64 period = _tipPeriod();
            for (uint256 i = 0; i < n; ++i) {
                _creditTip(agentIds[i], share, period);
            }
        }
        if (toSeatPool != 0) {
            _ledger.tipsToSeats += toSeatPool;
            _creditSeatPool(toSeatPool);
        }
        emit Tipped(msg.sender, got, perAgent, toSeatPool, agentIds[:n]);
    }

    // ---------------------------------------------------------------------------------------------
    // Stakers
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPayroll
    /// @dev What the stream and its cap do, and what they do not. sIMD prices its shares from its IMD
    /// balance and has no time weighting, so a plain transfer pays whoever holds shares at that
    /// instant, however briefly they hold them, in proportion to their shares. That is how the
    /// protocol itself pays stakers: it reaches every staker with nothing to claim, and this contract
    /// never holds anybody's sIMD. Its cost is this. A visitor that holds C against S staked by others
    /// takes C / (S + C) of every drip it is present for. Present at every drip of a stream, it takes
    /// that share of the whole stream, which is what a staker of that size who stayed all week
    /// receives, and the stakers who stay are diluted exactly as they would be by a permanent staker
    /// of that size. Nothing in this contract can prevent it, and since anyone may call `drip`, the
    /// visitor chooses the moment.
    ///
    /// What a visit needs is decided by sIMD, not here. A deposit or a mint blocks that holder's
    /// `withdraw` and `redeem` for the rest of the block, and the block goes with the shares when
    /// they are transferred. A visit therefore cannot stake, drip and leave in one transaction, so it
    /// cannot be paid for with IMD borrowed for the length of a transaction: it takes IMD of the
    /// visitor's own, staked from one block into the next, at every drip. This contract relies on
    /// that property of sIMD and cannot enforce it.
    ///
    /// The stakers' half vests evenly over seven days, one call sends at most one hour of that stream
    /// (1/168 of it), and calls are at least ten minutes apart. These rules bound the size of any one
    /// transfer, and so what one visit can take: a visitor's share of an hour of stream, not of a
    /// week's fees at once. They do not lower what visits add up to; they set how many it takes (168
    /// for a week's stream at a drip an hour). They also set what a keeper must do to keep pace:
    /// after days without a call the vested backlog leaves in capped calls ten minutes apart, up to
    /// six hours of stream an hour, and the flow stays even when somebody calls about once an hour,
    /// which costs the caller only gas.
    ///
    /// Each booking re-levels the stream. What has vested so far is set aside for the next drips.
    /// What has not keeps the time it had left; the new amount gets seven days; and the two are
    /// joined in one stream that ends at the average of those two times, each weighted by its
    /// amount:
    ///
    ///   new end = now + (remaining × timeLeft + amount × 7 days) / (remaining + amount)
    ///
    /// rounded down to the second. So dust cannot be used to stretch a stream: a booking moves the
    /// end by nothing when amount × (7 days − timeLeft) is less than remaining + amount, which one
    /// wei is whenever 604,800 wei or more are still unvested. A lone booking takes seven days, and
    /// so does, nearly, one that is much larger than what was left. A booking that is neither dust
    /// nor much larger does slow money that was already vesting: the joined stream vests more
    /// slowly than the old one whenever timeLeft × (2 × remaining + amount) < 7 days × remaining,
    /// which for a booking equal to the remainder is any moment in the last 2 days 8 hours of a
    /// stream. The old money then arrives later, by at most seven days less the time it had left,
    /// and a later booking can move what is still unvested again; the end is never more than seven
    /// days after the latest booking. The rate after a booking is never above the old rate plus the
    /// new amount over seven days, so a booking cannot be used to rush the stream.
    ///
    /// The cap on one drip is set at each booking, as the largest of three figures. One hour of the
    /// stream at its new rate: a drip an hour then keeps pace with vesting. 1/168 of everything
    /// outstanding: whatever is owed at a booking can leave in 168 calls once it has vested, however
    /// long nobody called. And, while money that has already vested is waiting to be sent, the cap
    /// before the booking, cut to the size of that backlog: a booking never puts a smaller cap in
    /// front of money that was ready to go. So the sending of what has vested cannot be slowed by
    /// bookings, of any size; the vesting can, within the ceiling above.
    ///
    /// Anyone may call. Reverts `DripTooSoon` inside the ten-minute gap and `StakingVaultNotReady` when
    /// sIMD does not answer as a vault over IMD with shares outstanding (with no stakers a transfer
    /// would go to whoever deposits next). Returns zero when nothing has vested: no IMD moves and the
    /// ten-minute gap does not start, only the vesting bookkeeping is brought up to this block.
    /// @return sent IMD transferred to sIMD by this call.
    function drip() external nonReentrant returns (uint256 sent) {
        uint256 notBefore = uint256(clock.lastDripAt) + DRIP_INTERVAL;
        // A ten-minute gap; the seconds a validator can shift a timestamp do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < notBefore) revert DripTooSoon(notBefore);

        uint256 unvested = _vest();
        Ledger storage l = _ledger;
        uint256 outstanding = l.toStakers - l.dripped;
        sent = Math.min(outstanding - unvested, dripCap);
        if (sent == 0) return 0;
        if (!_stakingVaultReady()) revert StakingVaultNotReady();

        l.dripped += sent;
        // A unix time fits 64 bits for longer than the chain will run.
        // forge-lint: disable-next-line(unsafe-typecast)
        clock.lastDripAt = uint64(block.timestamp);
        emit Dripped(msg.sender, sent, outstanding - sent);
        IMD.safeTransfer(SIMD, sent);
    }

    // ---------------------------------------------------------------------------------------------
    // Seats
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPayroll
    /// @dev The money goes to `ownerOf(tokenId)` during this call, so the claim follows the seat
    /// when sold. A keeper may claim for an ordinary wallet. A contract owner must call for itself
    /// (`ContractOwnerMustClaim`), so observers cannot force IMD into a passive NFT escrow.
    /// Payroll's own shares may still be claimed by anyone and recycled as unbooked revenue.
    ///
    /// Reverts `UnknownSeat` for an id outside the seats and `SeatHasNoOwner` when the seat token
    /// does not name an owner. Unpaid shares continue accruing and follow the seat when it leaves
    /// escrow. Returns zero when nothing is due, without checking the owner or caller.
    function claimSeat(uint256 tokenId) external nonReentrant returns (uint256 paid) {
        if (tokenId >= SEAT_COUNT) revert UnknownSeat(tokenId);
        uint256 accrued = seatAccrued;
        paid = accrued - seatPaid[tokenId];
        if (paid == 0) return 0;
        (bool ok, address owner) = _ownerOf(tokenId);
        if (!ok) revert SeatHasNoOwner(tokenId);
        if (!_claimAllowed(owner)) revert ContractOwnerMustClaim(owner);

        seatPaid[tokenId] = accrued;
        _ledger.seatClaimed += paid;
        emit SeatClaimed(tokenId, owner, paid);
        IMD.safeTransfer(owner, paid);
    }

    /// @notice Claims many seats in one call. Anyone may call; each seat's share goes to its own owner
    /// as the seat token names it during the call, subject to the caller check on `claimSeat`.
    /// @dev Ids that are not seats, seats with nothing due, repeated ids and seats whose owner cannot be
    /// read or whose contract owner did not initiate the claim are skipped, so one seat cannot hold up
    /// the rest of a list. Neighbouring
    /// ids with the same owner are paid in one transfer. Reverts `TooManySeats` above
    /// `MAX_SEATS_PER_CALL` ids; a full list of seats never paid before uses about 10 million gas.
    /// @return paid The total IMD paid out by this call.
    function claimSeats(uint256[] calldata tokenIds) external nonReentrant returns (uint256 paid) {
        uint256 n = tokenIds.length;
        if (n > MAX_SEATS_PER_CALL) revert TooManySeats(n, MAX_SEATS_PER_CALL);

        uint256 accrued = seatAccrued;
        address[] memory payees = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 runs = 0;

        for (uint256 i = 0; i < n; ++i) {
            uint256 tokenId = tokenIds[i];
            if (tokenId >= SEAT_COUNT) continue;
            uint256 due = accrued - seatPaid[tokenId];
            if (due == 0) continue;
            (bool ok, address owner) = _ownerOf(tokenId);
            if (!ok || !_claimAllowed(owner)) continue;

            seatPaid[tokenId] = accrued;
            paid += due;
            emit SeatClaimed(tokenId, owner, due);
            if (runs != 0 && payees[runs - 1] == owner) {
                amounts[runs - 1] += due;
            } else {
                payees[runs] = owner;
                amounts[runs] = due;
                ++runs;
            }
        }

        if (paid == 0) return 0;
        _ledger.seatClaimed += paid;
        for (uint256 i = 0; i < runs; ++i) {
            IMD.safeTransfer(payees[i], amounts[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Tips
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPayroll
    /// @dev The Adapter is asked which token the agent is bound to, with a low-level call that must
    /// succeed and return at least 96 bytes. The tip is paid only when that token is one of the seats;
    /// all of it, whatever its age, goes to the seat's owner as of this call. As with `claimSeat`,
    /// a contract holding the seat must initiate its own claim (`ContractOwnerMustClaim`), except
    /// for Payroll itself. Otherwise anyone may call. Unpaid tips follow the seat out of escrow.
    ///
    /// Reverts `AgentNotBound`, `AgentBoundElsewhere` or `SeatHasNoOwner` when it cannot be paid yet
    /// (the tip stays owed), and `GasTooLow` when the transaction could not give the Adapter read its
    /// full gas. Returns zero when nothing is owed.
    ///
    /// The Adapter is an upgradeable proxy: whoever controls it decides where unclaimed tips can go.
    /// Only tips depend on it. The seat pool reads the seat token directly.
    function claimTip(uint256 agentId) external nonReentrant returns (uint256 paid) {
        paid = _owedTo(_tips[agentId]);
        if (paid == 0) return 0;

        (Binding binding, uint256 tokenId) = _bindingOf(agentId);
        if (binding == Binding.Unbound) revert AgentNotBound(agentId);
        if (binding == Binding.Elsewhere) revert AgentBoundElsewhere(agentId);
        (bool ok, address owner) = _ownerOf(tokenId);
        if (!ok) revert SeatHasNoOwner(tokenId);
        if (!_claimAllowed(owner)) revert ContractOwnerMustClaim(owner);

        delete _tips[agentId];
        _ledger.tipsClaimed += paid;
        emit TipClaimed(agentId, tokenId, owner, paid);
        IMD.safeTransfer(owner, paid);
    }

    /// @dev Keep permissionless payments to wallets and Payroll's own revenue recycling. Other
    /// code accounts must ask for payment themselves; a passive NFT escrow cannot lose the
    /// seat's accrued IMD to an observer's claim. Unclaimed balances still follow the seat.
    function _claimAllowed(address owner) private view returns (bool) {
        return msg.sender == owner || owner == address(this) || owner.code.length == 0;
    }

    /// @notice Moves the part of an agent's tips that has waited long enough to the seat pool, when
    /// those tips still cannot be claimed. Anyone may call.
    /// @dev How long is long enough. Time is cut into periods of `TIP_SWEEP_DELAY` (180 days) counted
    /// from the unix epoch. A tip can be swept from the start of the second period after the one it
    /// arrived in: it has then waited between 180 and 360 days. Each tip keeps its own wait: a later
    /// tip to the same agent, of any size and from anyone, changes nothing for the ones before it.
    ///
    /// Only what has waited is moved; newer tips stay owed. Nothing is swept while it can be claimed:
    /// if the agent is bound to a seat whose owner the seat token names, the call reverts
    /// `TipStillClaimable` (anyone can claim it for that owner). A tip is swept when the agent is
    /// unbound, bound to something that is not a seat, or bound to a seat with no readable owner.
    /// The binding is read once, during the call; the tip was open to `claimTip` for the whole wait.
    ///
    /// Reverts `TipNotSweepableYet` when tips are owed but none has waited, and `GasTooLow` when the
    /// transaction could not give the Adapter read its full gas or leaves too little after a seat-owner
    /// read that failed. Returns zero when nothing is owed.
    /// @return swept IMD moved to the seat pool.
    function sweepTip(uint256 agentId) external nonReentrant returns (uint256 swept) {
        uint64 period = _tipPeriod();
        TipSlot memory t = _agedTip(_tips[agentId], period);
        swept = t.ripe;
        if (swept == 0) {
            if (t.old == 0 && t.fresh == 0) return 0;
            revert TipNotSweepableYet(agentId, _nextRipeAt(t, period));
        }

        (Binding binding, uint256 tokenId) = _bindingOf(agentId);
        if (binding == Binding.Seat) {
            (bool hasOwner,) = _ownerOf(tokenId);
            if (hasOwner) revert TipStillClaimable(agentId, tokenId);
            // See `OWNER_READ_MARGIN`: the read was not cut short by a transaction sent with little gas.
            if (gasleft() < OWNER_READ_MARGIN) revert GasTooLow();
        }

        if (t.old == 0 && t.fresh == 0) {
            delete _tips[agentId];
        } else {
            t.ripe = 0;
            _tips[agentId] = t;
        }
        _ledger.tipsToSeats += swept;
        _creditSeatPool(swept);
        emit TipSwept(agentId, swept);
    }

    // ---------------------------------------------------------------------------------------------
    // Feeds
    // ---------------------------------------------------------------------------------------------

    /// @notice Tops up the three house feeds' meters from the feed budget, then releases budget that has
    /// waited too long. Anyone may call.
    /// @dev Payroll keeps a position of its own on each house meter and tops that position up to a
    /// bounded runway at the feed's current cost (as `IQuestions.costOf` reports it, capped at
    /// `FEED_COST_CAP` per request) and no further: `FEED_RUNWAY_REQUESTS` requests for the first two
    /// feeds, `FEED_C_RUNWAY_REQUESTS` for the third. The position is what Payroll's own meter shares
    /// are worth, not the meter's whole balance: IMD somebody else put on a meter can be taken off it
    /// again in the next transaction, so it is not counted as runway. The first two feeds come first:
    /// when the budget cannot cover what both lack, each gets the same fraction of its own shortfall
    /// and the third gets nothing; the third is served from what is left once both are covered. A
    /// feed that Questions does not know (cost zero) is skipped.
    ///
    /// The budget cannot be stranded, and it is never released past a meter that lacks it. It is aged
    /// in fortnights: budget booked in one fortnight falls due at the second boundary after it, so it
    /// waits between 14 and 28 days for a meter to need it. Falling due moves no money. A booking that
    /// crosses a boundary only sorts the budget into its tranches; budget leaves for the staker stream
    /// in this function alone, after the meters were served from it. So whichever call crosses a
    /// boundary first, the meters come first. What is due waits here until somebody makes this call:
    /// anyone can, and a Questions contract that reverts or answers nonsense does not stop the release.
    /// The most of Payroll's money that can sit in a meter that has stopped being used is one runway.
    ///
    /// Nothing here can block the rest of Payroll: Questions is called at low level, a call that reverts
    /// or answers nonsense only leaves that meter as it was, and what counts as spent is the IMD that
    /// actually left this contract. Before each call the books already show the whole offer as gone,
    /// so at no point, not even inside the call, does the contract owe more than it holds.
    /// @return funded IMD placed on meters by this call.
    /// @return released IMD moved from the feed budget to the staker stream by this call.
    // State is written after the calls into Questions (the correction in `_fund`, then the ageing step
    // and the release, which run last on purpose). Every entry point that could run in between holds
    // the same lock.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function fundFeeds() external nonReentrant returns (uint256 funded, uint256 released) {
        uint256 budget = _ledger.toFeeds - _ledger.feedsFunded;
        if (budget != 0) {
            // Read what every meter lacks before anything moves.
            uint256 giveA = _shortfall(FEED_A, FEED_RUNWAY_REQUESTS);
            uint256 giveB = _shortfall(FEED_B, FEED_RUNWAY_REQUESTS);
            uint256 giveC = _shortfall(FEED_C, FEED_C_RUNWAY_REQUESTS);
            uint256 needAB = giveA + giveB;
            if (needAB > budget) {
                giveA = (budget * giveA) / needAB;
                giveB = (budget * giveB) / needAB;
                giveC = 0;
            } else if (giveC > budget - needAB) {
                giveC = budget - needAB;
            }
            if (giveA != 0) funded += _fund(FEED_A, giveA);
            if (giveB != 0) funded += _fund(FEED_B, giveB);
            if (giveC != 0) funded += _fund(FEED_C, giveC);
        }

        // Ageing and the release run last on purpose: the meters are served before anything is
        // released, and only what they really took counts as spent. This is the one place budget
        // leaves for the stream. It moves figures between this contract's own books and sends no
        // token; the lock keeps every other entry point shut.
        _ageFeedBudget();
        released = feedBudgetDue;
        if (released != 0) {
            feedBudgetDue = 0;
            Ledger storage l = _ledger;
            l.toFeeds -= released;
            l.toStakers += released;
            l.feedsReleased += released;
            emit FeedBudgetReleased(released);
            _levelStream(released);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Every running total at once. See `Ledger` for what each figure means.
    function ledger() external view returns (Ledger memory) {
        return _ledger;
    }

    /// @inheritdoc IPayroll
    /// @dev What `claimSeat` would pay now. Zero for an id that is not a seat.
    function seatClaimable(uint256 tokenId) external view returns (uint256) {
        return tokenId < SEAT_COUNT ? seatAccrued - seatPaid[tokenId] : 0;
    }

    /// @inheritdoc IPayroll
    /// @dev The agent's unpaid tips of every age. Whether they can be claimed now depends on the Adapter.
    function tipOwed(uint256 agentId) external view returns (uint256) {
        return _owedTo(_tips[agentId]);
    }

    /// @notice An agent's unpaid tips and how far their wait has got at this block.
    /// @return unpaid Unpaid tips in IMD wei, of every age.
    /// @return sweepable The part that has waited a whole period: what `sweepTip` would move now if
    /// the agent's tips cannot be claimed.
    /// @return nextSweepableAt When more of it finishes its wait (unix seconds); zero when nothing is
    /// still waiting.
    function tipOf(uint256 agentId) external view returns (uint256 unpaid, uint256 sweepable, uint256 nextSweepableAt) {
        uint64 period = _tipPeriod();
        TipSlot memory t = _agedTip(_tips[agentId], period);
        unpaid = _owedTo(t);
        sweepable = t.ripe;
        nextSweepableAt = _nextRipeAt(t, period);
    }

    /// @notice The staker stream as it stands at this block.
    /// @return outstanding Everything still to be sent to sIMD.
    /// @return unvested The part of it that has not vested yet.
    /// @return endsAt When the last of it vests.
    /// @return perDrip The cap on one drip.
    /// @return nextDripAt The earliest time `drip` will not revert `DripTooSoon`.
    /// @return dueNow What `drip` would send if called in this block. Zero inside the ten-minute gap,
    /// and zero while sIMD does not answer as a vault over IMD with shares outstanding: `drip` then
    /// reverts `StakingVaultNotReady` if anything has vested, and the stream waits here.
    function stream()
        external
        view
        returns (
            uint256 outstanding,
            uint256 unvested,
            uint256 endsAt,
            uint256 perDrip,
            uint256 nextDripAt,
            uint256 dueNow
        )
    {
        Clock memory c = clock;
        outstanding = _ledger.toStakers - _ledger.dripped;
        unvested = _unvestedNow(c);
        endsAt = c.streamEnd;
        perDrip = dripCap;
        nextDripAt = uint256(c.lastDripAt) + DRIP_INTERVAL;
        // The same ten-minute gap `drip` enforces.
        // forge-lint: disable-next-line(block-timestamp)
        dueNow = block.timestamp < nextDripAt ? 0 : Math.min(outstanding - unvested, perDrip);
        // `drip` refuses to send to a vault that is not ready, so nothing is due to it.
        if (dueNow != 0 && !_stakingVaultReady()) dueNow = 0;
    }

    /// @notice What the contract owes, by kind. The IMD balance always covers `total`.
    /// @return stakers Still to be sent to sIMD.
    /// @return seats The unclaimed seat pool (including wei carried to the next credit).
    /// @return tips Tips waiting for `claimTip`.
    /// @return feeds The feed budget not yet placed or released.
    /// @return total The sum of the four.
    function owed() public view returns (uint256 stakers, uint256 seats, uint256 tips, uint256 feeds, uint256 total) {
        Ledger memory l = _ledger;
        stakers = l.toStakers - l.dripped;
        seats = l.toSeats + l.tipsToSeats - l.seatClaimed;
        tips = l.tipsIn - l.tipsToSeats - l.tipsClaimed;
        feeds = l.toFeeds - l.feedsFunded;
        total = stakers + seats + tips + feeds;
    }

    /// @notice IMD that arrived by plain transfer and has not been split yet: what `book` would book now.
    function unbooked() external view returns (uint256) {
        return _unbooked();
    }

    /// @notice The feed budget and its ageing, as they stand at this block: a fortnight boundary that
    /// no call has crossed yet is counted as crossed.
    /// @return total Budget not yet placed on a meter or released.
    /// @return old The part that falls due at `nextReleaseAt` unless a meter takes it first.
    /// @return releasableNow The part whose wait is over: what `fundFeeds` would release if it were
    /// called in this block and the meters took none of it.
    /// @return nextReleaseAt The next fortnight boundary.
    function feedBudget()
        external
        view
        returns (uint256 total, uint256 old, uint256 releasableNow, uint256 nextReleaseAt)
    {
        uint256 period;
        (period,, total, releasableNow, old) = _agedFeedBudget();
        nextReleaseAt = (period + 1) * FEED_BUDGET_PERIOD;
    }

    /// @notice How far Payroll's own position on each house feed's meter is below its runway right now,
    /// in feed order A, B, C: what `fundFeeds` would offer each meter with budget to spare. Zero for a
    /// feed Questions does not know or cannot answer for.
    function feedShortfalls() external view returns (uint256[3] memory needs) {
        needs[0] = _shortfall(FEED_A, FEED_RUNWAY_REQUESTS);
        needs[1] = _shortfall(FEED_B, FEED_RUNWAY_REQUESTS);
        needs[2] = _shortfall(FEED_C, FEED_C_RUNWAY_REQUESTS);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: booking
    // ---------------------------------------------------------------------------------------------

    /// @dev Pulls `amount` from the caller and reports what arrived.
    function _pull(uint256 amount) private returns (uint256 got) {
        uint256 balanceBefore = IMD.balanceOf(address(this));
        IMD.safeTransferFrom(msg.sender, address(this), amount);
        got = IMD.balanceOf(address(this)) - balanceBefore;
    }

    function _unbooked() private view returns (uint256) {
        (,,,, uint256 total) = owed();
        return Math.saturatingSub(IMD.balanceOf(address(this)), total);
    }

    /// @dev Splits `amount` (never zero) 50 / 30 / 20. The two fixed shares round down and the stakers'
    /// share is what is left, so the three parts always add up to `amount` exactly.
    function _book(uint256 amount) private {
        // Ageing first: budget booked now must land in the current fortnight's tranche. Nothing is
        // released here. A booking does not look at the meters, so budget that has fallen due waits
        // for `fundFeeds`, which serves them first.
        _ageFeedBudget();

        uint256 seatShare = (amount * SEAT_BPS) / BPS;
        uint256 feedShare = (amount * FEED_BPS) / BPS;
        uint256 stakerShare = amount - seatShare - feedShare;

        Ledger storage l = _ledger;
        l.received += amount;
        l.toStakers += stakerShare;
        l.toSeats += seatShare;
        l.toFeeds += feedShare;

        if (seatShare != 0) _creditSeatPool(seatShare);
        _levelStream(stakerShare);
        emit Booked(amount, stakerShare, seatShare, feedShare);
    }

    /// @dev Gives every seat an equal part of `amount`. Wei that do not divide evenly wait in
    /// `seatCarry` for the next credit, so `seatAccrued * SEAT_COUNT + seatCarry` is always exactly what
    /// the pool was given.
    function _creditSeatPool(uint256 amount) private {
        uint256 sum = amount + seatCarry;
        uint256 perSeat = sum / SEAT_COUNT;
        // The remainder of a division, carried to the next credit: bookkeeping, not a source of chance.
        // slither-disable-next-line weak-prng
        seatCarry = sum % SEAT_COUNT;
        if (perSeat != 0) seatAccrued += perSeat;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: tips
    // ---------------------------------------------------------------------------------------------

    /// @dev The ageing period this block falls in.
    function _tipPeriod() private view returns (uint64) {
        // A unix time divided by 180 days fits 64 bits with room to spare.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp / TIP_SWEEP_DELAY);
    }

    /// @dev Adds `share` to an agent's fresh tranche, ageing the older ones first when a period has
    /// passed since the slot was last written.
    function _creditTip(uint256 agentId, uint128 share, uint64 period) private {
        TipSlot storage slot = _tips[agentId];
        uint64 last = slot.period;
        if (last == period) {
            slot.fresh += share;
        } else if (last == 0) {
            // Nothing is owed to this agent, so there is nothing to age and one slot to write.
            slot.fresh = share;
            slot.period = period;
        } else {
            TipSlot memory t = _agedTip(slot, period);
            t.fresh = share;
            _tips[agentId] = t;
        }
    }

    /// @dev A slot as it stands in `period`. One period on: what was old has now waited a whole period
    /// and is ripe, what was fresh is old. Two or more: everything has waited a whole period.
    function _agedTip(TipSlot memory t, uint64 period) private pure returns (TipSlot memory) {
        if (period > t.period) {
            if (period - t.period == 1) {
                t.ripe += t.old;
                t.old = t.fresh;
            } else {
                t.ripe += t.old + t.fresh;
                t.old = 0;
            }
            t.fresh = 0;
            t.period = period;
        }
        return t;
    }

    /// @dev When the oldest tranche still waiting becomes ripe, for a slot already aged to `period`;
    /// zero when nothing is waiting.
    function _nextRipeAt(TipSlot memory t, uint64 period) private pure returns (uint256) {
        if (t.old != 0) return (uint256(period) + 1) * TIP_SWEEP_DELAY;
        if (t.fresh != 0) return (uint256(period) + 2) * TIP_SWEEP_DELAY;
        return 0;
    }

    function _owedTo(TipSlot memory t) private pure returns (uint256) {
        return uint256(t.fresh) + t.old + t.ripe;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: stream
    // ---------------------------------------------------------------------------------------------

    /// @dev The unvested part of the stream at this block. Vesting is linear from the cursor to the end;
    /// the vested part rounds down, so nothing vests early.
    function _unvestedNow(Clock memory c) private view returns (uint256 unvested) {
        unvested = streamUnvested;
        if (unvested == 0) return 0;
        // A seven-day stream; the seconds a validator can shift a timestamp do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= c.streamEnd) return 0;
        // Here cursor <= now < end, so the divisor is never zero.
        unvested -= (unvested * (block.timestamp - c.streamCursor)) / (c.streamEnd - c.streamCursor);
    }

    /// @dev Accounts vesting up to this block and moves the cursor. A second call in the same block
    /// finds nothing new and writes the same values again.
    function _vest() private returns (uint256 unvested) {
        unvested = _unvestedNow(clock);
        streamUnvested = unvested;
        // A unix time fits 64 bits for longer than the chain will run.
        // forge-lint: disable-next-line(unsafe-typecast)
        clock.streamCursor = uint64(block.timestamp);
    }

    /// @dev Adds `added` (already counted in `toStakers`) to the stream and re-levels it. What has
    /// vested stays vested. What has not (`remaining`, with `timeLeft` still to go) and `added` (which
    /// by itself would take seven days) become one stream whose length is the average of the two
    /// times, weighted by the two amounts and rounded down to the second. Rounding down is what makes
    /// a dust booking move the end by exactly nothing; it can bring the end forward by less than a
    /// second, never push it back.
    ///
    /// The length is at least one second and at most seven days: `timeLeft` is at least one whenever
    /// `remaining` is not zero (a stream that has reached its end has nothing unvested), and by
    /// induction never more than seven days.
    ///
    /// The drip cap is the largest of three figures, the first two rounded up so that a non-empty
    /// stream can always be emptied:
    ///  - an hour of the stream at its new rate, so a drip an hour keeps pace with vesting;
    ///  - 1/168 of everything outstanding, so what is owed now can leave in 168 calls once vested;
    ///  - the cap in force until now, cut to the size of the backlog (what vested before this booking
    ///    and has not been sent). Without it a booking of dust at the end of a stream would put a
    ///    cap sized for the dust in front of the last hours of that stream; cut to the backlog, an
    ///    old and large cap cannot outlive the money it was for.
    function _levelStream(uint256 added) private {
        uint256 remaining = _vest();
        uint256 unvested = remaining + added;
        // Every caller passes a non-zero amount; with nothing unvested there is nothing to level.
        if (unvested == 0) return;
        // A seven-day stream; the seconds a validator can shift a timestamp do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 timeLeft = remaining == 0 ? 0 : clock.streamEnd - block.timestamp;
        uint256 duration = (remaining * timeLeft + added * STREAM_DURATION) / unvested;
        uint256 endsAt = block.timestamp + duration;
        uint256 outstanding = _ledger.toStakers - _ledger.dripped;
        uint256 cap = Math.max(
            Math.max(
                Math.ceilDiv(unvested * DRIP_WINDOW, duration), Math.ceilDiv(outstanding * DRIP_WINDOW, STREAM_DURATION)
            ),
            Math.min(dripCap, outstanding - unvested)
        );

        streamUnvested = unvested;
        // A unix time plus at most seven days fits 64 bits for longer than the chain will run.
        // forge-lint: disable-next-line(unsafe-typecast)
        clock.streamEnd = uint64(endsAt);
        dripCap = cap;
        emit StreamLevelled(outstanding, unvested, endsAt, cap);
    }

    /// @dev True when sIMD answers as an ERC-4626 vault over IMD that has shares outstanding.
    function _stakingVaultReady() private view returns (bool) {
        (bool okAsset, uint256 asset) = _readWord(SIMD, abi.encodeCall(IERC4626.asset, ()));
        (bool okSupply, uint256 supply) = _readWord(SIMD, abi.encodeCall(IERC20.totalSupply, ()));
        return okAsset && okSupply && asset == uint256(uint160(address(IMD))) && supply != 0;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: feeds
    // ---------------------------------------------------------------------------------------------

    /// @dev The feed budget's tranches as an ageing step in this block leaves them. One boundary
    /// passed since the budget was last aged: the old tranche falls due and the fresh one becomes
    /// old. Two or more: all of it has waited a full fortnight and is due. None: as stored.
    /// @return period The fortnight this block falls in.
    /// @return crossed Whether a boundary has passed since the budget was last aged.
    /// @return budget Everything not yet placed or released.
    /// @return due The part whose wait is over.
    /// @return old The part that falls due at the next boundary.
    function _agedFeedBudget()
        private
        view
        returns (uint256 period, bool crossed, uint256 budget, uint256 due, uint256 old)
    {
        period = block.timestamp / FEED_BUDGET_PERIOD;
        uint256 last = clock.feedPeriod;
        budget = _ledger.toFeeds - _ledger.feedsFunded;
        due = feedBudgetDue;
        old = feedBudgetOld;
        // Time only moves forward, so this is "past the fortnight that was last aged". Fortnights:
        // the seconds a validator can shift a timestamp do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (period > last) {
            crossed = true;
            // forge-lint: disable-next-line(block-timestamp)
            due = period > last + 1 ? budget : due + old;
            old = budget - due;
        }
    }

    /// @dev Ages the feed budget by fortnight: sorts it into what is due, what is old and what is
    /// fresh. No money moves and nothing is released; `fundFeeds` releases what is due once the
    /// meters have been served from it.
    function _ageFeedBudget() private {
        // Inside the fortnight that was last aged there is nothing to do, and every booking comes
        // through here: one slot read. Fortnights: the seconds a validator can shift do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp / FEED_BUDGET_PERIOD <= clock.feedPeriod) return;
        (uint256 period,, uint256 budget, uint256 due, uint256 old) = _agedFeedBudget();
        // A unix time divided by 14 days fits 64 bits with room to spare.
        // forge-lint: disable-next-line(unsafe-typecast)
        clock.feedPeriod = uint64(period);
        // With no budget both tranches are already zero.
        if (budget == 0) return;
        feedBudgetDue = due;
        feedBudgetOld = old;
        emit FeedBudgetAged(period, old);
    }

    /// @dev How far Payroll's own position on a feed's meter is below `requests` requests at the feed's
    /// current cost. Zero when Questions does not know the feed or does not answer.
    ///
    /// The position is what Payroll's own shares of the meter would fetch, not the meter's balance.
    /// The balance is pooled: anybody can add to it and take their part out again, so IMD parked on a
    /// meter for one transaction would otherwise read as runway and Payroll would release, as not
    /// needed, budget the meter lacks a moment later.
    function _shortfall(bytes32 feedId, uint256 requests) private view returns (uint256) {
        (bool ok, uint256 cost) = _readWord(QUESTIONS, abi.encodeCall(IQuestions.costOf, (feedId)));
        if (!ok || cost == 0) return 0;
        if (cost > FEED_COST_CAP) cost = FEED_COST_CAP;
        (bool okOwn, uint256 own) =
            _readWord(QUESTIONS, abi.encodeCall(IMeterPosition.redeemable, (feedId, address(this))));
        if (!okOwn) return 0;
        uint256 lacking = Math.saturatingSub(cost * requests, own);
        // A top-up is paid in through the meter's share pool, which rounds in the pool's favour, so
        // it can leave the position one wei short of the runway it was sized for. One wei is
        // therefore not a need; without this a call right after a top-up would find a wei to place.
        return lacking > 1 ? lacking : 0;
    }

    /// @dev Takes `amount` out of the tranches as they stood (`due`, `old`), oldest first: what is due,
    /// then the old tranche. What neither covers comes out of the fresh tranche, which is not stored:
    /// it is the budget less the other two.
    function _spendTranches(uint256 due, uint256 old, uint256 amount) private {
        uint256 fromDue = Math.min(due, amount);
        feedBudgetDue = due - fromDue;
        feedBudgetOld = Math.saturatingSub(old, amount - fromDue);
    }

    /// @dev Offers `give` IMD to a feed's meter and returns what actually left. The books are written
    /// before Questions is called, as if all of `give` had gone (the budget is spent oldest tranche
    /// first), and corrected afterwards only when less left. The allowance is exactly `give` and is
    /// cleared afterwards, so Questions can take that much and no more.
    // The writes after the call are the correction described above; see the note at the call.
    // slither-disable-next-line reentrancy-no-eth
    function _fund(bytes32 feedId, uint256 give) private returns (uint256 spent) {
        Ledger storage l = _ledger;
        uint256 dueBefore = feedBudgetDue;
        uint256 oldBefore = feedBudgetOld;
        l.feedsFunded += give;
        _spendTranches(dueBefore, oldBefore, give);

        uint256 balanceBefore = IMD.balanceOf(address(this));
        IMD.forceApprove(QUESTIONS, give);
        // The books were written above. The only writes that can follow this call are the correction
        // below, made when Questions took less than it was offered: it can only raise what the books
        // say this contract still holds, and every entry point that could run in between is shut by
        // the lock.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (bool ok,) = QUESTIONS.call(abi.encodeCall(IQuestions.fund, (feedId, give)));
        IMD.forceApprove(QUESTIONS, 0);
        spent = Math.saturatingSub(balanceBefore, IMD.balanceOf(address(this)));
        if (spent > give) revert FeedOverdrawn();

        if (spent != give) {
            // Questions refused the top-up or took less: what did not leave goes back into the budget,
            // in the tranche it came from.
            l.feedsFunded -= give - spent;
            _spendTranches(dueBefore, oldBefore, spent);
        }
        if (ok && spent != 0) {
            emit FeedFunded(feedId, spent);
        } else {
            emit FeedFundingFailed(feedId, give);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: reading other contracts
    // ---------------------------------------------------------------------------------------------

    /// @dev Calls a view and returns its first word. `ok` is false when the call reverts or returns
    /// fewer than 32 bytes (which is also what an address without code does). Only 32 bytes of the
    /// answer are ever copied.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            word := mul(ok, mload(0x00))
        }
    }

    /// @dev The seat's owner as the seat token reports it now. `ok` is false when the call fails or the
    /// answer is not a non-zero address.
    function _ownerOf(uint256 tokenId) private view returns (bool ok, address owner) {
        uint256 word;
        (ok, word) = _readWord(SEATS, abi.encodeCall(ISeats.ownerOf, (tokenId)));
        ok = ok && word != 0 && word <= type(uint160).max;
        // Checked on the line above: the word fits an address.
        // forge-lint: disable-next-line(unsafe-typecast)
        owner = ok ? address(uint160(word)) : address(0);
    }

    /// @dev Asks the Adapter what `agentId` is bound to. The call is given exactly `BINDING_GAS`, and
    /// the transaction must hold enough for that, so the outcome does not depend on how much gas the
    /// caller chose to send. A reverting call or fewer than 96 bytes means unbound.
    function _bindingOf(uint256 agentId) private view returns (Binding binding, uint256 tokenId) {
        bytes memory data = abi.encodeCall(ISeatAdapter.bindingOf, (agentId));
        address adapter = ADAPTER;
        bool ok;
        uint256 token;
        if (gasleft() < BINDING_GAS_FLOOR) revert GasTooLow();
        assembly ("memory-safe") {
            // The 96-byte answer (standard, tokenContract, tokenId) is written to scratch memory past
            // the free pointer; nothing longer is ever copied.
            let out := mload(0x40)
            ok := staticcall(BINDING_GAS, adapter, add(data, 0x20), mload(data), out, 0x60)
            ok := and(ok, gt(returndatasize(), 0x5f))
            token := mload(add(out, 0x20))
            tokenId := mload(add(out, 0x40))
        }
        if (!ok) return (Binding.Unbound, 0);
        // The whole word is compared, so an answer with stray high bits is not mistaken for the seats.
        if (token != uint256(uint160(SEATS)) || tokenId >= SEAT_COUNT) return (Binding.Elsewhere, 0);
        return (Binding.Seat, tokenId);
    }

    // slither-disable-end incorrect-equality
    // forge-lint: disable-end(reentrancy-events)
}
