# What this launch trusts, and where its guarantees stop

This document lists every outside party the three contracts rely on, what each is relied on for,
and every limit we know of, including the ones our own reviewers raised. It is written for an
auditor. Where a statement is shown by a test, the test is named; where it is not shown by
anything, it is listed in the last section.

Contracts: `Questions` (Standing Questions), `JobsReport` (the Robot Jobs Report), `Payroll`.
Status: not launched. Audited twice by IdentityMD's audit agents on commit `5c049e0`, on 13 October
2026: `docs/AUDITS.md` lists the nine findings and what was done about each. Two findings are left
open on purpose and are limits of this launch, stated below: P2 (a visitor to sIMD takes a staker's
share of every drip it attends) and P3 (a booking can delay money that was already vesting). Two
waits in `Questions` were changed after the audits and have not been audited: Q8.

## 1. Who can do what

There is no owner, no admin, no setter, no pause and no upgrade path in any of the three contracts.
The functions that can change state are the 21 listed in `README.md` and no others, none of them
payable (`test_launch_stateChangingFunctionsAreExactlyTheDocumentedOnes`, which reads the compiler's
ABI); the manifest gives no contract an owner (`test_manifest_namesTheThreeContractsInOrder`). Every
one of the 21 is open to any caller, with one exception: `Questions.onOracleResult` accepts calls
from the Intake only (`test_callback_fromAnyoneButTheIntake_reverts`). A caller never chooses where
money goes. It chooses only when a fixed rule runs.

Money leaves the contracts in these ways and no others:

| Contract | Way out | Who receives |
|---|---|---|
| Questions | `request` | The Intake's fee payee: the live price, at most the feed's `maxPrice` |
| Questions | `defund` | The caller: its own share of what a meter has not spent |
| Questions | `collectTips` | The caller: tips it earned by answered rounds |
| Payroll | `drip` | sIMD |
| Payroll | `claimSeat`, `claimSeats` | The current owner of each seat |
| Payroll | `claimTip` | The current owner of the seat the agent is bound to |
| Payroll | `fundFeeds` | The three house feeds' meters in `Questions` |
| JobsReport | none | It holds no money |

## 2. Trust roots

| # | Party | Trusted for | If it fails or turns against us | What it cannot do |
|---|---|---|---|---|
| T1 | The oracle signer, `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, one externally owned key | Signing every answer. `Questions` accepts an answer only with its signature. | A wrong or compromised key can write wrong values into any feed, and so into the Jobs Report. | Move any meter's IMD or anything in Payroll: no function pays out on the content of an answer. The only money tied to an answer is the round's own keeper tip (0.05 IMD on the house feeds). |
| T2 | IdentityMD's Intake, version 2, `0xa43e6f75ee006411f79ac1c84120606c2330de82`, and its owner | Taking the price and recording the request. Its owner sets the price and the callback gas. | A price above a feed's `maxPrice` stops that feed's requests. Callback gas below what the callback needs (116,622 at most in our tests, 200,000 allowed today) stops delivery by callback; for the two daily feeds `submit` remains, for the employers feed nothing does (F4). | Take more than the live price, capped by the feed (`test_blocked_whenThePriceIsAboveTheFeedsCap`). Leave an allowance behind (`test_request_revertsWhenTheIntakeTakesLessThanThePrice`). |
| T3 | The Intake's writer, `0x3d3c0df7c1a17d384545e9d7c8228897bd9625cb` (the same for both versions of the Intake), and the service behind it | Calling `complete`, which delivers the answer, and doing it in time: an answer is useless to a round that was closed before it came. Marking a request completed. | A request that is never served or never completed costs the meter the price. The round can be closed by anyone after the full silence deadline and not before (`test_abandon_afterTheFullSilenceDeadline`, `test_abandon_doesNotDependOnTheIntakeBehaving`). For the two daily feeds anyone can hand the answer in instead, from thirty minutes after the request (`submit`); for the employers feed nobody can, so it depends on the writer delivering within the full silence deadline and signed validity (F4, Q8). | Deliver an answer the oracle signer did not sign. |
| T4 | The IMD token | Being a plain ERC-20 with no fee on transfer and no hooks. | Both contracts book what actually arrived, by balance difference (`test_fund_creditsWhatActuallyArrived`, `test_pay_booksWhatArrivedNotWhatWasAsked`). | |
| T5 | sIMD, `0x9efa934d9fad4ae28c998a40195646b965a97247`. It has no owner: `owner()` is the zero address and `paused()` is false (read 13 October 2026) | Receiving the stakers' stream by plain transfer and pricing its shares from its IMD balance. And one property Payroll cannot enforce: a holder cannot leave in the block it staked in (P2). | While it does not answer as a vault over IMD with shares outstanding, `drip` reverts and the stream waits in Payroll (`test_drip_waitsWhileTheVaultHasNoStakers` and the four tests after it). Without its one-block hold, a visitor could take a staker's share of every drip with IMD borrowed for one transaction (P2). | Block bookings, seat claims or tips (`test_stuckVaultDoesNotBlockTheRestOfPayroll`). |
| T6 | The seat token, `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` | Saying who owns a seat. Payroll pays whoever `ownerOf` names at the moment of a claim. | A seat whose owner is never named again keeps its share of the seat pool in Payroll for good. | Take another seat's share (`test_claimSeat_cannotTouchAnotherSeatsShare`). |
| T7 | The seat Adapter, `0xde152afb7db5373f34876e1499fbd893a82dd336`, an upgradeable proxy, and whoever controls it | Saying which seat an agent is bound to. Only tips depend on it. | Its controller decides which seat's owner can claim an agent's unclaimed tips, or that nobody can; in the second case the tips fall to the seat pool after 180 to 360 days. | Touch the stakers' stream, the seat pool or the feed budget. Make a read cost more than 100,000 gas (`test_adapterRead_anAdapterBeyondItsAllowanceIsNotHeard`). |
| T8 | `Questions`, as Payroll and JobsReport see it | Payroll hands it at most one runway per house feed at a time. JobsReport copies its answers. | It is this launch's own immutable code. | Take more from Payroll than the amount offered (`test_fundFeeds_revertsIfATopUpTakesMoreThanItWasOffered`), or block the rest of Payroll (`test_questionsDown_blocksNothing`). |
| T9 | The launch pipeline and the ProjectFactory | Creating the three contracts with the manifest's arguments, in order. | A wrong argument is permanent. `docs/LAUNCH.md` says how to read every argument back after the launch. | Hold any privilege afterwards: no constructor stores `msg.sender`. |
| T10 | Keepers: whoever calls `request`, `submit`, `print`, `drip`, `fundFeeds`, `abandon` | Liveness only. | With no keeper nothing moves and nothing is lost: feeds go stale, the stream waits, and feed budget whose wait is over stays in Payroll until somebody calls `fundFeeds`. | |
| T11 | OpenZeppelin Contracts 5.5.0 (vendored in `lib/`), solc 0.8.26, and the EIP-2935 history contract that `Blockhash` reads for a block hash older than 256 blocks | Correctness of the library code and the compiler. | | |
| T12 | The oracle's rule for computing `questionHash` | Staying as it is. `Questions` rebuilds the hash on chain from a rule we reconstructed from 23 attested requests and checked against the three proofs of the house feeds (`docs/DEVIATIONS.md`, D6). | If the rule changes, every feed that pins its hash, the three house feeds included, refuses every answer from then on. Rounds fail and back off; meters stay redeemable. | |
| T13 | The oracle's panel for the employers feed: seven agents, each holding one seat | Reading the chain as the question's method says and answering what they find. For this one feed the oracle signs what five of the seven agree on and does not recompute it (F4). | Five of seven agreeing on a wrong list put a wrong list of three into the employers feed and into `JobsReport.crown`. | Reach the two daily feeds, which the oracle recomputes itself before it signs. Move any IMD: no function pays out on an answer. Change what `JobsReport.print` records: it never reads the employers feed. |

The oracle signer and the Intake are constructor arguments and cannot be replaced. That is a
deliberate departure from IdentityMD's guidance; `docs/DEVIATIONS.md` gives the reasoning and the
cost. `Intake.signer()` is a different key (it signs price quotes) and is not used.

If the oracle signer's account ever gets code (an EIP-7702 delegation, for example), signatures are
checked by asking that code (ERC-1271), plain signatures stop verifying, and every round fails until
the contracts are launched again. Meters stay redeemable throughout.

## 3. Limits of Questions

**Q1. A request is paid for whether or not it is answered.** The Intake never refunds. A refused
body, a panel that does not agree, a request the service never serves: each costs the meter the
price (0.5 IMD today). The keeper tip does come back to the meter (`test_tip_goesBackToTheMeterWhenTheRoundFails`).

**Q2. A caller can make a round go unserved, at its own expense.** The service serves only the
first Intake request of a transaction. `request` refuses a second request of its own in one
transaction (`test_blocked_secondRequestInOneTransaction_unmodifiedContract`), but it cannot see a
request its caller bought from the Intake earlier in the same transaction. The feed's request is
then paid for and never served: the meter loses the price, the round stays pending until it is
closed (after the full silence deadline unless the Intake completes it sooner), and the cadence doubles. A caller
that wins the first request at every due block five times running keeps a daily feed silent for
about two months (requests at cadence 0, 2, 6, 14 and 30, the next one allowed at 62). It pays five
Intake prices of its own for that and earns nothing: since decision 1 of the brief's section 12 the
tip is earned only by an answer (`test_request_afterTheCallersOwnIntakeRequest_isNeverServedAndEarnsTheCallerNothing`).
Nothing on chain tells such a transaction from an honest one without `tx.origin`, which we do not
use, so this is disclosed and not prevented. What limits it: for a feed open to `submit`, anyone can
answer the round thirty minutes after the request by buying the same question for this contract,
which leaves the cadence as it was (`test_request_anUnservedRoundCanBeAnsweredThroughSubmit`). The
two daily house feeds are open to `submit`. The employers feed is not (F4): for it nothing limits
this but what it costs the caller: five Intake prices of its own keep the weekly list silent for
about fourteen months. Whatever its cadence, a feed that is not open to `submit` cannot ask again
until the full silence deadline after an unserved request: its round stays open that long (Q8).

**Q3. `submit` takes any signed answer to the feed's question about the round's blocks.** Nothing
on chain ties an attestation to the request a round paid for. Once `submit` is open (the Intake has
completed the round's own request with nothing stored, or thirty minutes have passed since the
request), any attestation the oracle signed for this contract, for the same question hash and
window, from a panel at least as large as the feed's, is accepted, whoever bought it. The callback
has only those thirty minutes to itself (`test_submit_beforeTheIntakeHasCompletedTheRequest_reverts`,
`test_submit_opensThirtyMinutesAfterARequestTheIntakeNeverCompleted`). That is short on purpose
(Q8), and it can be shorter than the oracle itself takes: on IdentityMD's public list of requests
on 10 October 2026 the median request was answered in 14 minutes, and one in ten took more than
55. In such a round an answer somebody else bought to the same question can be stored before the
one the meter paid for exists. For chain evidence with the recipe pinned in the definitions, as in
the two daily house feeds, there is one answer whoever asks, so this changes neither the answer nor who is
paid the tip (Q4). A chain-evidence feed that leaves the recipe to the panel can be answered
differently by two panels, and a party with an interest could buy several answers and hand in the
one it prefers: nothing of value should depend on such a feed. A feed whose question a panel
judges cannot use `submit` at all (`test_submit_isNotForAQuestionAPanelJudges`); the employers
house feed is one (F4). The question hash does not cover `guards`, `toleranceBps`,
`allowAmbiguous`, `validForSeconds` or `consumer`: those are the submitted request's own.

**Q4. The opener keeps the tip of every answered round.** The launch audit reproduced an
observer taking the opener's tip with a public signature. `_settle` now always credits the
keeper recorded by `request`, regardless of who submits. Submission itself earns no reward.
The oracle request UUID cannot be linked on chain to an Intake purchase, so this also credits
an opener whose unserved request is rescued with a separately bought matching answer. That
trade-off preserves the gas incentive for honest openers without an unenforceable identity test.
See `test_audit_publicAttestationCannotTakeTheOpenersTip` and `QuestionsTips.t.sol`.

**Q5. A returned tip is shared by whoever holds the meter's shares when the round is closed.** It
comes back as balance and no share is minted, so every share is worth a little more afterwards. An
account that funds a meter while a round is pending and takes its money out after the round has
failed therefore receives part of a tip that earlier funders paid for
(`test_returnedTip_aFunderThatArrivesWhileTheRoundIsPendingSharesIt`). It does not need to wait: a
round that is about to be closed is visible to everyone (the thirty-minute wait after a refused
request, the full silence deadline of a silent one), and funding, `abandon` and `defund` fit in one
transaction. With a deposit much larger than the meter it collects nearly the whole tip. The amount
is bounded by the feed's tip for each failed round, 0.05 IMD on the house feeds, and it needs a
round that fails; making one fail costs more than the tip (Q2). We did not close this: every way we
found either stops funding while a round is pending or leaves value on the meter that nobody can
withdraw, and `Questions` has no room left for more code (section 7).

**Q6. In two rare cases part of a returned tip belongs to nobody.** A share must never be worth
more than one wei. When the shares outstanding cannot take all of a returned tip (every funder left
while the round was pending, or the meter was spent to zero and refilled), the rest stays on the
meter, pays for later requests of the same feed, and can be withdrawn by nobody
(`test_returnedTip_withEveryFunderGone_belongsToNobody`, `test_returnedTip_afterTheMeterWasRefilledFromZero`).

**Q7. Failed rounds back the feed off.** After each failed round in a row the feed waits twice as
long before it may ask again, up to 32 times its cadence: about a month for a daily feed, about 31
weeks for the weekly one. One answer resets it (`test_blocked_backsOffAfterFailedRounds`). The rule
and its numbers are fixed at launch.

**Q8. Silence has a bounded deadline that includes the requested validity.** `submit` opens
at thirty minutes. Silence permits `abandon` at `requestedAt + 12 hours + validFor + 5 minutes
+ 1 second`; all house feeds therefore wait 36 h 5 min 1 s. The twelve hours allow for signing,
then an answer signed within that allowance has its whole requested validity to arrive. Clock
tolerance and inclusive signature expiry are covered. Completion observed from the Intake can
still shorten the wait to thirty minutes after first observation.

This fixes the supplied twelve-hour reproduction and is fuzzed over the entire 60-second to
30-day `validFor` range. The real employers feed accepts a callback after twelve hours, through
the signed expiry (`test_employersAcceptsAValidDeliveryAfterTwelveHours`). The full deadline still
lets a feed recover from an Intake that never completes or whose getter cannot be read.

The oracle can itself take more than twelve hours to sign; a signed answer may then remain valid
past the full deadline. Such an answer, or any delivery after closure, may still be lost. There
is no on-chain expiry record for an answer that has not arrived, and waiting forever would let
an unavailable Intake block a feed forever. A pending round blocks new requests; the longer
wait can delay a daily feed. Funders can still redeem unspent meter balances. Panel-evidence
feeds still have no `submit` recovery. These remain liveness assumptions, not delivery guarantees.

**Q9. A WHEN gate is read once, inside the transaction that asks.** A gate on a value that can be
moved and moved back within one transaction (a pool balance, a spot price) can be opened by the
caller at will. The three house feeds have no gate.

**Q10. One attestation can answer one round of each of two feeds** that hold the same question and
ask about the same blocks. Each feed paid for a request of its own, and what one does with an
answer never takes it away from the other (`test_anAnswerUsedOnATwinStillReachesTheFeedThatPaidForIt`).

**Q11. A feed can be created to waste its funders' IMD.** `createFeed` checks what can be checked
(panel, quorum, window, lag, tip at most `maxPrice`, the body's shape and length). It cannot check
that a question is answerable. Fund only a feed whose parameters and text you have read. Payroll
funds the three ids in its constructor and no others.

**Q12. IMD sent to `Questions` by plain transfer is not on any meter** and can be withdrawn by
nobody. There is no sweep on purpose: crediting it to a meter would let a sender change what a
share is worth.

**Q13. An old catch-up window's closing block hash is not checked.** When a window ends more than
8,191 blocks back, the chain no longer serves its hash, zero is stored, and the answer's
`blockHash` is accepted as signed. A daily house feed reaches that only when its last answered
window ended more than 29,791 blocks, a little over four days, before the request (the window is
cut at 21,600 blocks and its end is then more than 8,191 blocks back). The weekly feed always asks
about the newest blocks and never does.

**Q14. What is asked after a failed round depends on the feed.** A feed whose windows tile and
that already has an answer starts its next window at the same block and ends it at a newer one, so
no block is skipped. A tiling feed with no answer yet, and any feed that does not tile, asks about
the newest blocks; the failed round's own blocks are not asked about again
(`test_windows_contiguous_afterAFailedRound_startAtTheSameBlock`).

**Q15. Smaller points.** `costOf` is zero while no request can be bought (unknown feed, action not
sold, price unreadable or above the feed's cap). A feed can only be about the chain it is on. A
chain-evidence question whose definitions hold the exact text `"evidence":"panel"` is treated as
judged by a panel and loses `submit`. A list answer is stored as its hash; the list itself is
published by anyone who has it, through `reveal` or `JobsReport.crown`. An answer is valid for the
time its feed states (one day on the house feeds) and is refused after that.

## 4. Limits of the three house feeds

**F1. Each body was accepted by the live oracle once.** On 12 and 13 October 2026 one request per
feed was bought with exactly the bytes `Questions` sends, and all three were attested
(`docs/LAUNCH.md`, section 5; records in `test/fixtures/questions/proofs/`;
`test/questions/HouseFeedProofs.t.sol`). That proves the bodies, the question hash built on chain,
the answer types and the panel figures. It is one request each: it says nothing about how often
the panel will agree, and for the two daily feeds it covers a window of 7,000 blocks, not the
catch-up window of up to 21,600 they ask for after a missed or failed round. The proofs named no
callback, so they do not show the Intake delivering an answer to this contract.

**F2. Hires counts transfers, not purchases.** It counts every IMD `Transfer` log whose recipient
is the fee payee, transfers of zero included, because a `log-count` filter reaches indexed
arguments only. Anyone can raise the day's figure for the price of gas. The fixture states this in
its title and limits (`test_hiresSaysItCountsZeroValueTransfers`), and any unofficial tally must
count the same way.

**F3. Payrolls and the ranking count every transfer to the fee payee**, whatever it paid for,
including this launch's own purchases of answers: `Questions` pays the fee payee for every request,
so it is itself one of the senders the ranking sees. An address can buy a place among the Employers
of the Week by paying the fee payee, and a sender of a zero-value transfer can appear when fewer
than three addresses paid in the week.

**F4. The employers feed is judged by a panel, and the two daily feeds are not.** This is the
difference a reader of the feeds most needs to know.

- *Payrolls and hires are recomputed.* They are chain evidence with a pinned recipe: every member
  of the panel answers with the recipe, and IdentityMD's oracle reruns the agreed recipe itself at
  the pinned blocks before it signs. The figure is a fact about the chain that anybody can
  recompute, and the oracle did.
- *Employers is not recomputed.* The oracle has no recipe that ranks senders among the transfers to
  one recipient: its ranking recipe takes no filter. The first body this feed had, a ranking recipe
  with a filter, was answered alike by all five members that answered and then not attested,
  because the oracle's own rerun, without the filter, named five other addresses
  (`test_proofs_theFirstEmployersBodyWasNotAttested`). The feed therefore asks the same question
  with `evidence` `panel`: the method is written out in the question's `definitions` for the
  members to follow, and what the oracle signs is what the panel agreed on. **IdentityMD does not
  recompute this answer.** It rests on at least five of seven agents, each holding one seat, giving
  the same three addresses in the same order. A panel of seven is cheap to fill for anyone who
  controls enough seats, and five of seven agreeing on a wrong list would be signed like a right
  one.
- *What the contract adds.* The method and its source are inside the hashed question, so an answer
  to any other wording is refused. `minAgreed` equals the quorum, so an attestation whose `agreed`
  is below its signed quorum is refused; for a panel-judged question that is the only agreement
  there is. And `submit` is closed for this feed, at any time and for anyone
  (`test_employersTakesAnswersFromTheIntakeOnlyAndOnlyWithTheQuorumMet`): two panels can differ,
  and whoever submitted would choose between them. The price of that is that only the Intake's own
  callback delivers within the full silence deadline and the signed validity (Q8). A round whose
  callback is missed, arrives after closure, or is never served fails and backs the feed
  off; it cannot be rescued as a daily round can (Q2, Q7).
- *What depends on it.* Only the weekly list of three: `JobsReport.crown` and whoever reads the
  feed. `JobsReport.print` never reads it (`test_print_neverReadsTheEmployersFeed`,
  `test_integration_theReportIsCompleteWithoutTheEmployersFeed`), no money moves on it, and Payroll
  funds it last, to a runway of four requests. Nothing of value should be made to depend on it.
- *What anybody can do.* Read the same logs with the method in the feed's text and compare. For the
  proof request we did: 2,737 transfers to the fee payee in the window, and the three largest
  senders are the three attested, in that order (`test/fixtures/questions/proofs/index.json`).

**F5. Their parameters are part of their ids**, and the ids are constructor arguments of
`JobsReport` and `Payroll`. A feed whose body the oracle later stops accepting cannot be replaced
without launching the three contracts again.

## 5. Limits of Payroll

**P1. Unclaimed seat revenue follows the seat.** Claims pay the current `ownerOf`, including
revenue accrued before a transfer. Anyone may initiate payment to an ordinary wallet. For a seat
held by code, that holder must call itself; another caller gets `ContractOwnerMustClaim` from
`claimSeat` or `claimTip`, and `claimSeats` skips it. This prevents an observer forcing IMD into
a passive NFT escrow. The escrowed share continues accruing and follows the seat when returned
or sold. A bound seat's unpaid agent tips remain protected from sweeping too.

Contract wallets can deliberately accept payment by calling Payroll. Payroll's own shares remain
permissionlessly recyclable as unbooked revenue. An account with an EIP-7702 delegation also has
code and must initiate its claim. This check cannot identify a future contract address or code
still under construction; do not move a seat to such an address expecting escrow protection.
See `PayrollLaunchAudit.t.sol` for forced single, batch and tip claims and contract-wallet claims.

**P2. A visitor to sIMD takes a staker's share of every drip it attends.** Open, by decision: this
is the medium finding of the second audit (`docs/AUDITS.md`, 2.1), acknowledged and not closed.

`drip` pays the stakers by plain transfer to sIMD, and sIMD has no time weighting: IMD that reaches
it is shared by whoever holds its shares at that moment. A visitor that holds C against S staked by
others takes C / (S + C) of every drip it is present for. Present at every drip of a stream, it
takes that share of the whole stream: exactly what a staker of that size who stayed all week
receives, with its capital in sIMD for two blocks an hour and not all week. The stakers who stay are
diluted exactly as they would be by a permanent staker of that size. Nothing in Payroll can prevent
it, and because anyone may call `drip`, the visitor chooses the moment
(`test_visitor_repeatedOverAWholeStreamTakesItsProRataShareAndNoMore`: 168 visits with half the
vault take half the stream and not a wei more;
`test_visitor_aStakerOfTheSameSizeWhoStaysGetsTheSame`).

What a visit needs is set by sIMD, not by Payroll, and this launch relies on it (T5). The real sIMD
does not let a holder leave in the block it staked in: a deposit or a mint blocks that holder's
`withdraw` and `redeem` for the rest of the block, and the block goes with the shares when they
are transferred. Checked against the real contract on a fork: staking, dripping and leaving in one
transaction reverts, handing the shares to a second address does not get round it, and a visit
that leaves one block later takes its pro-rata share of that one drip to the wei
(`test_fork_visit_stakeDripLeaveInOneTransactionReverts`,
`test_fork_visit_movingTheSharesDoesNotGetRoundTheHold`,
`test_fork_visit_leavingOneBlockLaterTakesItsProRataShareOfThatDrip`). So a visit cannot be paid
for with IMD borrowed for the length of a transaction: it takes IMD of the visitor's own, staked
from one block into the next, at every drip. If sIMD had no hold, the same share could be taken
with no capital at all (`test_visitor_withoutTheHoldTheSameShareNeedsNoCapitalAtAll`: 82.27 of a 168
IMD stream, with 1,000 IMD borrowed and repaid inside each of 168 transactions).

What the ten-minute gap and the one-hour cap are for: they bound the size of any one transfer, and
so what one visit can take (a visitor's share of an hour of stream, not of a week's fees at once),
and they set what a keeper must do to keep pace. They do not deter visits and they do not lower
what visits add up to; they set how many it takes. After days without a call the vested backlog
leaves in capped calls, up to six hours of stream an hour. The rules are kept as built by decision 3.

Why the plain transfer is kept: it is how the protocol itself pays its stakers, it reaches every
staker with nothing to claim, and the alternative, a reward contract that accounts by time, would
have to hold stakers' sIMD. This launch takes custody of nobody's sIMD.

**P3. A booking can delay money that was already vesting.** Open, by decision: the low finding 1.3
and 2.3 of the audits; the rule is the build brief's decision 2. On each booking what is still
vesting and the new money become one stream, whose end is the average of the time the old money
had left and seven days, weighted by the two amounts.

- A booking moves the end by nothing when amount × (7 days − timeLeft) is less than remaining +
  amount. One wei is that small whenever 604,800 wei or more are still unvested
  (`test_booking_ofDustDoesNotMoveTheEnd`, `test_booking_hourlyDustDoesNotStretchTheStream`,
  `test_report2_finding3_dustAgainstARemainderThatIsDustMovesTheEnd`).
- A booking much larger than what is left takes close to seven days.
- A booking in between slows the old money: the joined stream vests more slowly than the old one
  when timeLeft × (2 × remaining + amount) is less than 7 days × remaining. For a booking as large
  as the remainder that is any moment in the last 2 days 8 hours of a stream; with half the
  stream's time or more still to run, no booking slows it
  (`testFuzz_report2_finding3_theRuleForWhenABookingSlowsTheOldMoney`). Measured: a 100 IMD stream
  with one hour and 0.595 IMD left, joined by 10 IMD, has vested 0.067 IMD by its old end, and
  ends 6 days 13 hours later (`test_report1_finding3_aBookingDelaysMoneyAlreadyVestingUpToSevenDays`).
- The limits that hold: the old money arrives later by at most seven days less the time it had
  left; the end is never more than seven days after the latest booking; the stream is never
  rushed, its rate after a booking being at most the old rate plus the new amount over seven days
  (`testFuzz_booking_weightedEndIsBetweenTheTwoTimes`); and stakers are paid in full.

Anyone can cause the delay with `pay` or `book`. It costs them the amount booked, half of which
goes to the stakers; nobody gains from it. A release of feed budget re-levels the stream the same
way, at most once a fortnight.

**P4. Tips depend on the Adapter (T7).** Only the first 16 agent ids of a tip share it; an id
listed twice is credited twice; ids are not checked when the tip arrives. A tip whose agent is
unbound, bound to something that is not a seat, or bound to a seat with no readable owner waits 180
to 360 days and can then be moved to the seat pool by anyone
(`test_sweepTip_aTipWaitsBetween180And360Days`). A later tip never delays an earlier one
(`test_sweepTip_oneWeiTipsCannotHoldOlderTipsOutOfTheSeatPool`). The binding is read once, when
`sweepTip` is called: an agent bound to an owned seat at that moment keeps its tip, whatever came
before. `claimTip` and `sweepTip` revert `GasTooLow` when the transaction carries too little gas to
read the Adapter or the seat token reliably, so a caller cannot make a bound agent look unbound, or
an owned seat look ownerless, by starving the read (`testFuzz_sweepTip_lowGasNeverSweepsABoundAgent`,
`testFuzz_sweepTip_lowGasNeverMakesAnOwnedSeatLookOwnerless`).

**P5. A seat nobody owns keeps its share.** If the seat token never names an owner for a seat
again, that seat's share of the seat pool stays in Payroll for good. Tips bound to such a seat are
different: they can be swept after their wait. A seat held by Payroll itself is paid like any
other; the IMD arrives back in Payroll and is booked again as revenue
(`test_seatOwnedByPayrollRecyclesItsShare`).

**P6. Payroll never takes IMD back from a meter.** What it places on a house feed's meter is spent
by that feed or stays there. The most that can sit on a meter that has stopped being used is one
runway: 14 requests for each daily feed and 4 for the weekly one, each counted at no more than 2
IMD. At the live cost of 0.55 IMD that is 7.7, 7.7 and 2.2 IMD. Payroll is a funder like any other
on those meters, so Q5 applies to it: a returned tip on a house meter is shared with whoever else
holds shares of it at that moment.

A house meter is a pool, and a stranger can fill it and empty it again. Payroll does not count what
others put there: it sizes each top-up from its own position, what its own meter shares would
fetch, and keeps one runway of its own on the meter whatever else is there
(`test_fundFeeds_doesNotCountWhatOthersPutOnAMeter`;
`test_report2_finding2_aFundAndDefundAroundFundFeedsChangesNothing`). This was the low finding 1.2
and 2.2 of the audits, and it is fixed. What follows from the fix: a meter that others fund too
holds more than one runway in all; every request is paid by everyone on the meter in proportion to
their shares, and Payroll replaces its own part
(`test_fundFeeds_replacesOnlyPayrollsPartOfWhatAMeterSpent`). A shortfall of a single wei is not
counted as a need, because a top-up through the share pool can leave the position one wei short.

**P7. Feed budget waits, then goes to stakers, and only `fundFeeds` sends it.** Budget booked in
one fortnight falls due at the second boundary after it, so it waits 14 to 28 days for a meter to
need it (`test_budget_isKeptThroughOneBoundaryAndReleasedAtTheNext`). Falling due moves no money. A
booking that crosses a boundary only sorts the budget into its tranches; `fundFeeds` alone releases
what is due, after it has served the meters from it. So whichever call crosses a boundary first,
the meters come first (`test_budget_whoCrossesTheBoundaryFirstDoesNotMatter`). This was the medium
finding 1.1 of the first audit, and it is fixed. What follows from the fix: budget whose wait is
over stays in Payroll until somebody calls `fundFeeds`. Anyone can, and a `Questions` contract that
reverts or answers nonsense does not stop the release
(`test_budget_aBookingAgesTheBudgetAndReleasesNothing`,
`test_budget_aRefusedTopUpDoesNotHoldBackWhatIsDue`).

**P8. A tip that falls back to a plain transfer is booked as revenue.** A caller that cannot
complete `tip` and transfers the IMD plainly has it split 50/30/20 by `book`, not held for the
agents. `tip` to 16 agents never seen before stays under 600,000 gas, and the dearest `tip` and
`pay` under the 1,000,000 the hire desk forwards (`test_gas_tipToSixteenNewAgents`,
`test_gas_tipToSixteenAgentsWhoseEarlierTipsMustBeAged`).

**P9. `claimSeats` takes at most 200 ids.** A full list of seats never paid before used between
47,600 and 49,400 gas a seat on a mainnet fork on two days, 9.5 to 9.9 million for 200, inside the
16.7 million one transaction may use.

## 6. Limits of JobsReport

**J1. It reports what the oracle answered.** It adds no check of its own on the figures beyond
passing over failed rounds, empty or unfinished windows, overlapping windows and answers above
2^128 − 1. One of these rules reads the block of the call: a round whose window ends at or after
the block `print` is called in is passed over for good, where the same round would be printed if
the first call came later. `Questions` never stores such an answer (a window ends at least five
blocks behind its request), so the rule cannot fire here
(`test_integration_aRealWindowIsAlwaysOverWhenItsAnswerIsPrinted`); what it would do if it did is
shown with the test rig (`test_print_aWindowNotOverYetIsPassedOverForGood`). It is kept as a guard,
for the reason in `docs/AUDITS.md`, 2.5.

**J2. A count may cover a shifted window.** The two daily feeds are bought by separate
transactions. When they are requested in the same block the count is exact for its print's period.
When they have drifted, a count is attached to the print it shares more than half of the longer
window with; the print keeps the hires round and the count keeps its own window, so a reader can
show the exact blocks (`test_counts_aFeedThatDriftedStillPairsEveryDay`,
`test_integration_theHiresCountSurvivesOneLateRequest`). A count that pairs with no print stays in
its own series and in `totalCount`.

**J3. The streak ends on a catch-up.** A print over more than 7,500 blocks, which is what a missed
day produces, cannot take the best-day record and ends the streak
(`test_integration_theStreakEndsAfterAMissedDay`).

**J4. The crown is decoration.** Anyone holding the attested list may publish a round's top three,
once per round, in any order of rounds. Nothing else in the report depends on it.

## 7. Limits of the build

**B1. `Questions` is 22,963 bytes: 37 under our own 23,000-byte gate and 1,613 under the protocol's
limit.** Nothing of substance can be added to it. That is why Q5 is disclosed and not closed.

**B2. The launch is about 11.1 million gas in our rehearsal**, against our gate of 12 million and the
protocol's ceiling of 16.7 million (`test_fork_rehearsal_launchFitsOurGasAndSizeGates`).

**B3. Nothing is called after deployment.** The three feeds exist only after three transactions
that anyone may send; `docs/LAUNCH.md` holds their calldata. Until then meters cannot be funded and
Payroll's feed budget ages toward stakers.

**B4. Some tests use `QuestionsRig`**, which is `Questions` itself with six added functions that
write its storage directly, so that Payroll and JobsReport can be shown round shapes the real
contract never produces. No function of `Questions` is overridden. The tests under
`test/payroll/integration`, `test/launch` and every `fork` folder do not use the rig: they use
`Questions` as it is launched, or `QuestionsHarness`, which adds one function that clears the
one-request-per-transaction flag (a test function can run as a single transaction) and two
read-only views. The callback gas tests, the launch tests and the fork rehearsal use the contract
with nothing added. One test puts another contract in the place of `Questions`
(`test_fundFeeds_revertsIfATopUpTakesMoreThanItWasOffered`): it takes more IMD than `fund` was
told, which the real contract cannot do, and is the only way to reach Payroll's `FeedOverdrawn`.

## 8. Static analysis

Command: `slither . --filter-paths "lib|test"` (Slither 0.11.4), run on 13 October 2026 on the
sources as they are after the audit fixes and after the change of the two waits (Q8). Result: 44
findings. None is of high or medium impact. 20 are of low impact, all from one detector; 24 are
informational.

### The 20 low findings: `timestamp`

Slither reports every comparison that involves `block.timestamp` or a value derived from it. On
Ethereum a block's timestamp is fixed by its slot, so a proposer cannot move it by more than
skipping a slot; and every period compared here is between ten minutes and 360 days long.

| Function | What is compared | Why it is safe |
|---|---|---|
| `Payroll.drip`, `Payroll.stream` | now against the last drip plus ten minutes | A ten-minute gap. |
| `Payroll._unvestedNow` | now against the stream's end | A stream that runs for up to seven days. |
| `Payroll._ageFeedBudget`, `Payroll._agedFeedBudget`, `Payroll.fundFeeds` | the number of the current 14-day period against the stored one; in `fundFeeds`, an amount that has fallen due against zero | Counters of fortnights. |
| `Payroll._creditTip`, `Payroll._agedTip` | the number of the current 180-day period against a tip's | Counters of 180-day periods. |
| `Questions._submitOpen`, `Questions.canSubmit` | now against the request time plus thirty minutes | A thirty-minute wait. |
| `Questions._abandonStep`, `Questions.abandon` | now against request + 12 h + `validFor` + 5 min + 1 s, or recorded completion + 30 min | Signing, validity and bounded recovery waits; inclusive expiry is tested. |
| `Payroll.book`, `Payroll.claimTip`, `Payroll.sweepTip`, `Payroll._book`, `Payroll._creditSeatPool`, `Payroll._nextRipeAt`, `Payroll._levelStream`, and the `unvested == 0` test in `Payroll._unvestedNow` and the `sent == 0` test in `Payroll.drip` | an amount against zero | No time is compared. The amount was computed in a function that also reads the time, which is what the detector follows. |
| `JobsReport.crown` | a stored crowning time against zero | "Has this round been crowned": no time is compared with another. |

### The 24 informational findings

- `assembly` (4): `Questions._readWord` and `Payroll._readWord` are bounded static calls that copy
  exactly one word of whatever is returned; `Payroll._bindingOf` is the same for the Adapter's three
  words; `QuestionBody.holdsPanelEvidence` searches calldata a word at a time, which costs a fifth
  of the plain loop and is fuzzed against it.
- `low-level-calls` (1): `Payroll._fund` calls `Questions.fund` at low level so that a revert in
  `Questions` cannot block the rest of Payroll.
- `cyclomatic-complexity` (1): `Questions._settle` is the list of checks an answer must pass, one
  after another.
- `naming-convention` (16): immutables are written in upper case, and `IIntake.MAX_BODY_BYTES`
  carries the Intake's own name.
- `too-many-digits` (1): `Mainnet.ORACLE_ACTION` is the text `oracle.request@oracle-1` as a
  `bytes32`.
- `missing-inheritance` (1): `Questions` has the one function of `IMeterPosition`, the interface
  `Payroll` declares for the single read it makes beyond `IQuestions`, and does not inherit it. The
  interface is Payroll's own and sits in Payroll's file on purpose: the shared `IQuestions.sol`,
  which later launches hold copies of, was left as it is, and `Questions` was not touched.

### What is silenced in the source, and why

In eleven places `src/` carries a comment that tells Slither not to report a finding. Each is listed
here so that a reader does not have to search for them.

| Where | Detector | Reason |
|---|---|---|
| `Questions` and `Payroll`, whole contract | `incorrect-equality` | Every `==` compares an amount, a balance difference or a stored time with zero, two period counters, or two values of an enum. None compares a token balance with a figure a sender could push off by one wei. |
| `Questions.request` | `reentrancy-no-eth`, `reentrancy-benign` | The Intake's request id is known only after the call, so two writes follow it. Every state-changing entry point holds the same transient lock (`test_request_cannotBeReentered`). |
| `Payroll.fundFeeds` | `reentrancy-no-eth`, `reentrancy-benign` | The books are written before each call into `Questions` as if the whole offer had left; what follows the calls is the correction when less left, then the ageing step and the release of what is due, which run last on purpose so that the meters are served first. Same lock (`test_callBackDuringATopUp_isRefused`, `test_fundFeeds_theBalanceCoversWhatIsOwedInTheMiddleOfATopUp`). |
| `Payroll._fund` | `reentrancy-no-eth` | The correction named in the row above. |
| `Questions.usedBy` | `uninitialized-state` | It is written in `_settle` through a storage reference. (Slither 0.11.4 does not report it even without the comment.) |
| `Payroll.tip` | `divide-before-multiply` | `got − (got / n) × n` is the remainder of the equal split, on purpose: it joins the seat pool. |
| `Payroll._creditSeatPool` | `weak-prng` | `sum % SEAT_COUNT` is the remainder carried to the next credit, not a source of chance. |
| `JobsReport._readPayrolls`, `JobsReport._readHires` | `calls-loop`, `unused-return` | One read of this launch's own `Questions` per round, at most eight a call; the time an answer was stored is not part of a print. |
| `JobsReport.crown` | `unused-return` | The same unused value. |

We also ran Slither on a copy of the project with these comments removed (outside the repository,
13 October 2026). It then reports 78 findings: the 44 above and 34 more, which are exactly the ones
the table covers. One of high impact: `weak-prng` in `Payroll._creditSeatPool`. Twenty-nine of medium
impact: 21 `incorrect-equality`, 4 `reentrancy-no-eth` (`Questions.request`, `Payroll.fundFeeds`
twice, `Payroll._fund`), 3 `unused-return` (the three reads in `JobsReport`), 1
`divide-before-multiply` (`Payroll.tip`). Four of low impact: 2 `calls-loop` and 2
`reentrancy-benign`. A reader who does not accept a reason in the table should treat the matching
finding as open.

## 9. What is not verified

- **A real answer delivered by the live Intake to the launched contracts.** The three house bodies
  were proven with requests that named no callback, so their answers were signed for no consumer
  (F1). Those three real answers, with the oracle signer's real signatures, do pass every check of
  the real callback for the real feeds when `Questions` is placed at the address they were signed
  for (`test_proofs_theRealSignedAnswersPassEveryCheckOfTheCallback`), as six other real
  attestations do at the addresses they were signed for (`test/questions/RealAttestations.t.sol`).
  What no test can show before launch is the live writer calling the launched `Questions` with an
  answer signed for its address. On a fork the writer's call is played with a test signer
  (`test/questions/fork/QuestionsIntake.fork.t.sol`, against version 2 of the Intake).
- **How fast the Intake's writer completes a request.** The oracle attested the three proofs 52
  seconds, 62 seconds and 4 minutes 16 seconds after they were admitted. Two hours later the
  Intake's service still listed each as `completing`, and `Intake.requests(id).completed` was false
  on chain: the writer had not sent `complete`. Those requests named no callback, so nothing waited
  for the call. Requests another contract made with a callback through version 2 that day were
  completed two to nine minutes after they were made (18 of them, up to block 26,179,302). Then the
  writer fell behind: the next, made at block 26,179,272, was completed at block 26,180,506, a
  little over four hours later, and three more had been waiting two to four hours when we last
  looked (13 October 2026, 02:28 UTC). The original twelve-hour closure followed that reading. The launch adaptation
  adds the requested validity and clock tolerance (Q8). It is one day's reading, not a bound: we do not know how late the writer can be. The
  callback is the only way an answer reaches the employers feed; see T3 and F4.
- **How often the panel agrees on the employers question.** One request, one attestation, in which
  five members answered and all five agreed. One fewer and the quorum would not have been met.
- **A catch-up window of the daily feeds.** The proofs asked about 7,000 blocks. After a missed or
  failed round the daily feeds ask about up to 21,600.
- **The launch pipeline itself.** The factory call is rehearsed on a fork as the launch deployer
  (`test/launch/fork/LaunchRehearsal.fork.t.sol`). The pipeline's own checks before that call are
  not ours to run.
- **Whether the service ever completes a request it did not serve** (one that was not the first of
  its transaction). The contract handles both cases: `submit` opens at once if it does, thirty
  minutes after the request if it does not. IdentityMD's guide of 13 October 2026 still says only the first
  request of a transaction is served; on that day the logs of version 2 showed one contract making
  two requests in one transaction several times, with both completed. We did not rely on either.
- **That sIMD keeps its one-block hold.** It is read from the live contract on a fork (P2). sIMD
  has no owner, so we know of nobody who could change it, but its source is not in this repository.
- **An audit of the code as it is now.** The two audits read commit `5c049e0`. The fixes made since
  (`docs/AUDITS.md`) have been tested here and have not been audited again. The launch assignment supplied a further four-finding audit; its reproductions and changes
  are recorded in `ADAPTATION.md` and still require the independent final review.
- **Gas figures** are from tests and from a mainnet fork, not from mainnet transactions.
