# What the audits found, and what was done about each finding

This file records the two historical audits. The additional four findings supplied with the
launch adaptation, their reproductions, fixes and retained design dependency are recorded in
[`ADAPTATION.md`](../ADAPTATION.md). In particular, the earlier tip and silence rules described
below have been superseded; current behavior is in `docs/LAUNCH.md`, section 4.

Two audit jobs were bought from the IdentityMD network on this repository as it stood at commit
`5c049e0f703bde97f0255368bc124254161b637e`. Each job is four specialist agents (math, permissions,
economics, control flow) and a judge that reproduces, merges and ranks what they found. Both
reports were judged on 13 October 2026.

| | Report one | Report two |
|---|---|---|
| Job | `be91e8ae-9f45-495f-a318-60fab672a92e` | `22624be0-d2da-400e-91c4-51dac0a9a7f5` |
| Asked for | The oracle paths and meter accounting of `Questions`; the split, the stream and the claims of `Payroll` | "Audit the contracts as they are" |
| Judged | 13 October 2026, 00:51 UTC | 13 October 2026, 01:30 UTC |
| Findings | 1 medium, 2 low, 1 info | 1 medium, 2 low, 2 info |

All nine findings are in `Payroll` or `JobsReport`. Neither report has a finding in `Questions`,
and no fix for a finding touched it. Two of its constants were changed afterwards, for a reason no
finding gave; the last section of this document says what changed and why.

**Where things stand.** Four findings describe two defects in the feed budget and one in a view;
those are fixed in the code. Two describe a difference between what the stream does and what the
documents said; the documents were wrong and are corrected, and the stream is as the build brief
fixed it. Two are left as they are, with the reason below: one of them is report two's medium
finding, which the project lead decided to acknowledge and not to close. One info finding is left.
Every finding has a test that starts from the auditors' own proof or reproduction.

| # | Severity | Finding | Outcome |
|---|---|---|---|
| 1.1 | Medium | A booking that crosses a fortnight boundary releases the old feed tranche to stakers before the meters are served | **Fixed** in `Payroll` |
| 1.2 | Low | Payroll sizes a meter's shortfall from the pooled meter balance, so IMD parked by a stranger turns the old tranche into staker stream | **Fixed** in `Payroll` |
| 1.3 | Low | Stream re-levelling delays money already vesting, contrary to the contract notice, the `drip` NatSpec and THREATS P3 | **Left** in the code (the rule is a decision of the build brief); the three statements **corrected** |
| 1.4 | Info | `stream().dueNow` reports an amount `drip()` refuses to send while sIMD is not ready | **Fixed** in `Payroll` |
| 2.1 | Medium | Deposits into sIMD just before each drip take the same share of the stream as stakers who stay | **Acknowledged and left**, by the lead's decision; the false claim removed, sIMD's own hold tested and written down |
| 2.2 | Low | Anyone can make `fundFeeds` place nothing by funding and defunding the house meters around it | **Fixed** by the change for 1.2 |
| 2.3 | Low | Stream re-levelling delays money that was already vesting; NatSpec and THREATS P3 claim it cannot | The same as 1.3 |
| 2.4 | Info | `stream().dueNow` reports an amount `drip()` refuses to send while sIMD is not a ready vault | **Fixed** by the change for 1.4 |
| 2.5 | Info | `JobsReport`'s `BadWindow` skip is unreachable from the pinned `Questions` and would drop a round for good if it ever fired | **Left**; the NatSpec made exact and the unreachability tested |

The tests named below are in `test/payroll/audit/AuditReports.t.sol` unless another file is given.

## 1.1 (medium, fixed): a booking at a fortnight boundary released the old tranche before the meters were served

**What was found.** Feed budget is aged in fortnights, and budget that no meter needed in time is
released to the staker stream. `fundFeeds` served the meters first and released only what they
left. But every booking (`pay`, `book`) ran the same ageing step first and never looked at the
meters. Whichever call crossed a boundary first decided where the old tranche went: a one-wei `pay`
that landed before `fundFeeds` sent the whole old tranche to stakers and left the meters with
their shortfall. The amount was bounded by what the meters lacked at that moment (one runway each)
and could not be brought back.

**What was done.** A booking no longer releases anything. It only sorts the budget into its
tranches, so that budget booked now lands in the current fortnight. What has fallen due is kept in
a new figure, `feedBudgetDue`, and waits for `fundFeeds`, which serves the meters from it first
(due, then old, then fresh) and releases what they leave. `fundFeeds` is now the one place budget
leaves for the stream.

**What it changes for a caller.** Budget whose wait is over stays in Payroll until somebody calls
`fundFeeds`. Anyone can, and a `Questions` contract that reverts or answers nonsense does not stop
the release. The event `FeedBudgetReleased` now comes from `fundFeeds` only.

**Tests.** `test_report1_finding1_aOneWeiBookingAtTheBoundaryDoesNotStarveTheMeters` is the
auditors' proof; it failed before the fix with "the meters were not served before the old tranche
was released: 0 != 16640000000000000000".
`test_report1_finding1_aBookingAtTheBoundaryReleasesNothing` does the same through `book`. In
`test/payroll/PayrollFeeds.t.sol`: `test_budget_aBookingAgesTheBudgetAndReleasesNothing`,
`test_budget_whoCrossesTheBoundaryFirstDoesNotMatter`,
`test_budget_dueIsSpentBeforeOldAndOldBeforeFresh`,
`test_budget_aRefusedTopUpDoesNotHoldBackWhatIsDue` and
`test_budget_aPartialTopUpTakesOnlyWhatLeftOutOfWhatIsDue`. The invariant handler now fails a run
in which a booking releases budget, in which more is released than had fallen due, or in which
budget is released while a meter still lacks something.

**A test that was replaced.** `test_budget_ageingRunsInsideABooking` asserted the behaviour the
finding is about (it expected `FeedBudgetReleased` from a `pay`). It is now
`test_budget_aBookingAgesTheBudgetAndReleasesNothing` and asserts the opposite.

## 1.2 and 2.2 (low, fixed): what somebody else put on a meter counted as Payroll's runway

**What was found.** Payroll sized each top-up from the meter's whole balance. A meter is a pool:
anybody can fund it and take their part out again. So a stranger could fund the three house meters
to their runways, let `fundFeeds` run (every shortfall read zero, nothing was placed), and defund
in the next transaction, or do all of it in one transaction, with its IMD back whole. Around a
boundary that turned the old tranche into staker stream (report one). Repeated before every honest
call it kept the meters empty until the whole budget had aged away (report two).

**What was done.** Payroll now sizes a top-up from its own position on the meter: what its own
meter shares would fetch (`Questions.redeemable(feedId, payroll)`), not the pooled balance. It keeps
one runway of its own on each house meter whatever anybody else holds there. A shortfall of a
single wei is not counted as a need: a top-up goes in through the meter's share pool, which rounds
in the pool's favour, and can leave the position one wei short of the runway it was sized for.

`Questions` has had the view `redeemable` since the first build; the shared interface file
`IQuestions.sol` does not list it and was not changed. Payroll declares the one signature it needs
in a local interface, `IMeterPosition`.

**What it changes.** A meter can hold more than one runway in all when others fund it too: theirs
and Payroll's. Payroll's own money on a meter is still at most one runway. A request is paid by
everyone on the meter in proportion to their shares, and Payroll replaces its own part.
`feedShortfalls()` now reports Payroll's own shortfalls.

**Tests.** `test_report1_finding2_parkedIMDDoesNotTurnTheOldTrancheIntoStakerStream` is report
one's proof (it failed with "Payroll placed nothing because it counted the stranger's IMD: 0 !=
16640000000000000000"). `test_report2_finding2_aFundAndDefundAroundFundFeedsChangesNothing` is
report two's reproduction: the fund, `fundFeeds`, defund sandwich as one transaction, then once a
day for 29 days. In `test/payroll/PayrollFeeds.t.sol`:
`test_fundFeeds_doesNotCountWhatOthersPutOnAMeter` and
`test_fundFeeds_replacesOnlyPayrollsPartOfWhatAMeterSpent` (which also shows the one-wei case: with
the tolerance removed, in a copy outside the repository, the second call placed one wei).
`testFuzz_feeds_neverFundBeyondTheRunwayOrTheBudget` was rewritten for the new rule.

**Tests that were replaced.** `test_fundFeeds_countsWhatOthersAlreadyPutOnAMeter` asserted the old
rule and is now `test_fundFeeds_doesNotCountWhatOthersPutOnAMeter`.
`test_fundFeeds_unevenNeedsGetTheSameFraction` made its uneven needs with a stranger's deposit and
now makes them with two different costs; its arithmetic is unchanged. One line of
`test_runbook_firstDayGoesThroughInTheOrderWritten` and one of
`test_integration_anUnknownHouseFeedIsSkipped` expected a meter funded by somebody else to need
nothing from Payroll, and now expect the opposite.

## 1.3 and 2.3 (low, the code left, the documents corrected): a booking can delay money that was already vesting

**What was found.** When a booking arrives, what is still vesting and the new money become one
stream that ends at the average of the time the old money had left and seven days, weighted by the
two amounts. That is the rule of the build brief (section 12, decision 2), and the code follows it.
The contract notice, the NatSpec of `drip` and `docs/THREATS.md` P3 said more than the rule gives:
that money already vesting "never waits longer because more arrived". It can. The auditors' figures,
which our tests reproduce to the wei: a 100 IMD stream with one hour and 0.595 IMD left, then a
booking of 10 IMD more: by the old end 0.067 IMD has vested where the old stream alone owed 0.595,
and the end is 567,424 seconds later (report one). A booking equal to the remainder, one hour
before the end: 0.014 of the 0.595 IMD has vested by the old end, and the end is three and a half
days later (report two). Report two also showed that "one wei moves the end by nothing" fails when
the remainder is itself dust.

**What was done.** The three statements were corrected to what the rule gives, in `Payroll.sol` and
in THREATS P3:

- a booking moves the end by nothing when amount × (7 days − timeLeft) is less than remaining +
  amount, which one wei is whenever 604,800 wei or more are still unvested;
- the joined stream vests more slowly than the old one when timeLeft × (2 × remaining + amount) is
  less than 7 days × remaining; for a booking as large as the remainder that is any moment in the
  last 2 days 8 hours of a stream, and with half the stream's time or more still to run no booking
  slows it;
- the old money then arrives later, by at most seven days less the time it had left; the end is
  never more than seven days after the latest booking, and the rate after a booking is never above
  the old rate plus the new amount over seven days;
- stakers are paid in full. When is what a booking can move.

**Why the rule was not changed.** The auditors name the choice themselves: correct the statements,
or keep the old remainder on its own schedule, "which changes decision 2 and is the requester's
call". Decision 2 is binding on this build, and the alternatives are not free: giving the old money
its own rate ends a stream of 10 IMD in 16 hours when it joins the last hour of a larger one, which
gives up "a large booking still takes about seven days". No money is lost and nobody gains from
the delay; whoever causes it pays the amount booked, half of which goes to the stakers themselves.

**Tests.** `test_report1_finding3_aBookingDelaysMoneyAlreadyVestingUpToSevenDays` and
`test_report2_finding3_aBookingEqualToTheRemainderOneHourBeforeTheEnd` are the two proofs with the
measured figures asserted in place of the property the documents used to claim, and with the
ceiling asserted. `testFuzz_report2_finding3_theRuleForWhenABookingSlowsTheOldMoney` checks the
stated rule both ways. `test_report2_finding3_dustAgainstARemainderThatIsDustMovesTheEnd` is the
dust case. The auditors' proofs as written assert the old claim and cannot pass while decision 2
stands; the judge of report two says so ("it is the right test only if option (2) is chosen").

## 1.4 and 2.4 (info, fixed): `stream().dueNow` promised what `drip` refuses

**What was found.** While sIMD has no shares outstanding, is not a vault over IMD, or has no code,
`drip` reverts `StakingVaultNotReady`. The view still reported the vested backlog as due, so a
keeper that went by the view sent a reverting transaction.

**What was done.** `dueNow` is zero whenever `drip` would send nothing: inside the ten-minute gap,
and while the vault is not ready. The view reads the vault only when something would otherwise be
due (two static calls).

**Tests.** `test_report1_finding4_dueNowIsZeroWhileTheVaultHasNoStakers` and
`test_report2_finding4_dueNowIsZeroWhileTheVaultHasNoCode`. The invariant handler now fails a run
in which `drip` reverts although the view said something was due.

## 2.1 (medium, acknowledged and left): a visitor to sIMD takes its share of every drip it attends

**What was found.** `drip` pays the stakers' stream to sIMD by plain transfer, and sIMD shares what
it receives among whoever holds its shares at that moment. A visitor that stakes just before a drip
and leaves just after takes its pro-rata share of that drip, and one that does so at every drip
takes over a stream exactly what a staker of its size who stayed would have. The cap on a drip does
not lower that; it sets how many visits it takes. The NatSpec and THREATS P2 said a short visit "is
not worth the round trip" and that somebody dripping once an hour helps. Neither is true: anyone
may call `drip`, so the visitor can be the one who calls it.

**The decision.** The auditors' options all touch the build brief's decision 3, and they say the
requester must choose. The project lead chose to keep the plain transfer to sIMD and to leave this
finding open:

- a plain transfer is how the protocol itself pays its stakers. It reaches every staker with
  nothing to claim and nothing to opt into;
- the alternative that removes the visitor's share is a reward contract that accounts by time, in
  which stakers would have to deposit their sIMD. This launch will not take custody of anybody's
  sIMD;
- the visitor takes no more than any staker of its size: the stakers who stay are diluted exactly
  as they would be by a permanent staker of that size. Nobody's principal is at risk.

**What a visit needs, which the auditors could not check without a fork.** The real sIMD does not
let a holder leave in the block it staked in. A deposit or a mint stamps the holder with the block
number; in that block `maxWithdraw` and `maxRedeem` are zero and `withdraw` and `redeem` revert; the
stamp goes with the shares when they are transferred. So a visit cannot stake, drip and leave in
one transaction, and cannot be paid for with IMD borrowed for the length of a transaction. It takes
IMD of the visitor's own, staked from one block into the next, at every drip. That is a property of
sIMD, which has no owner (`owner()` is the zero address) and which Payroll cannot enforce: it is
written down as a trust assumption in `docs/THREATS.md` (T5, P2).

**What was done.**

- The false claim is gone from `Payroll.sol` (the contract notice and `drip`) and from THREATS P2,
  replaced by the real figure: C / (S + C) of every drip attended, for a visitor holding C against
  S staked by others.
- Three fork tests against the real sIMD, in `test/payroll/fork/PayrollFork.t.sol`:
  `test_fork_visit_stakeDripLeaveInOneTransactionReverts`,
  `test_fork_visit_movingTheSharesDoesNotGetRoundTheHold` (a transfer of the shares, and a deposit
  in a second address's name), and
  `test_fork_visit_leavingOneBlockLaterTakesItsProRataShareOfThatDrip`, in which a visitor holding a
  tenth of what was staked took 4.545454545454545454 IMD of a 50 IMD drip: one eleventh, to the wei.
- The stand-in sIMD of the unit tests now models that hold (`MockSIMD` in
  `test/payroll/mocks/MockTokens.sol`).
- The unit test that checked a single round trip is replaced by tests that repeat the visit over a
  whole stream, in `test/payroll/PayrollStream.t.sol`:
  `test_visitor_repeatedOverAWholeStreamTakesItsProRataShareAndNoMore` (168 visits, half the vault,
  half the stream and not a wei more), `test_visitor_aStakerOfTheSameSizeWhoStaysGetsTheSame`,
  `test_visitor_oneVisitTakesItsShareOfOneCappedDrip`,
  `test_visitor_withTheHoldAStakeDripLeaveTransactionReverts`, and
  `test_visitor_withoutTheHoldTheSameShareNeedsNoCapitalAtAll`, which runs the same loop against a
  vault with no hold, with IMD borrowed and repaid inside each transaction: 82.27 of the 168 IMD,
  for gas alone. That is what the hold prevents.
- The documents now say what the ten-minute gap and the one-hour cap are for: they bound the size
  of any one transfer, and so what one visit can take, and they set what a keeper must do to keep
  pace. They do not deter visits. The rules themselves are unchanged.

**What remains.** The finding stands as the auditors wrote it, less the same-transaction case: a
party with IMD of its own, willing to hold sIMD across one block boundary an hour, collects a
staker's share of the stream for that hour's worth of exposure and the gas of two transactions.

## 2.5 (info, left): the `BadWindow` skip of the Jobs Report reads the block of the call

**What was found.** `JobsReport.print` passes over a round whose window ends at or after the block
of the call, and a round passed over is not read again. That is the one skip that depends on when
`print` is called, which the contract's own notice said never matters. Against the `Questions`
contract the report is bound to, the rule cannot fire: a window ends at least five blocks behind
the block of its request, and the answer comes later still.

**What was done.** The code is unchanged. The notice of `print` now states the exception and why
it cannot fire. `test_integration_aRealWindowIsAlwaysOverWhenItsAnswerIsPrinted`
(`test/payroll/integration/LaunchA.t.sol`) shows it against the real `Questions`, with request,
answer and print in one block. `test_print_aWindowNotOverYetIsPassedOverForGood`
(`test/payroll/JobsReport.t.sol`) shows, with the test rig, what would happen if it did fire.

**Why it was left.** The auditors offer two changes. Dropping the test would print such a round,
and since prints may not overlap, every later round up to that window's end would then be passed
over. Turning the skip into a wait would stop that feed's series until the window's end, and for a
window far in the future, for good. The rule as it stands costs the report that one round and no
other. All three are about a round the report can never be shown; we kept the one that fails
smallest.

## Changed after the audits, and not because of a finding: two waits in `Questions`

**What the auditors read.** `Questions` at commit `5c049e0`, with `SUBMIT_AFTER_SILENCE` at two
hours and `ABANDON_AFTER_SILENCE` at six hours. Neither report has a finding about either value.

**What changed.** On 13 October 2026, after both reports, the project lead set
`SUBMIT_AFTER_SILENCE` to thirty minutes and `ABANDON_AFTER_SILENCE` to twelve hours. Nothing else
in `Questions` changed: those two numbers, and the comments that state them. `Payroll` and
`JobsReport` are untouched by this change. The runtime code of `Questions` is now 22,963 bytes, 23
fewer than the 22,986 the auditors read. Compared instruction by instruction, the two builds
differ in the four places that hold the two values and in one more: `SUBMIT_AFTER_SILENCE()` and
`ABANDON_AFTER_COMPLETED()` now return the same thirty minutes, and the compiler serves both
getters from one piece of code where it had two. Every other difference is a jump offset that
moved with those 23 bytes.

**Why.** What was seen that day (`docs/THREATS.md`, Q8 and section 9). The oracle decided each of
our four proof requests within five minutes, and the Intake's writer had completed none of them on
chain two hours and forty minutes later; a request another contract made with a callback was
completed a little over four hours after it was made. The callback can be hours late while the
signed answer is already public. With two hours, a daily feed's answer waited two hours before
anyone could hand it in. With six hours, anyone could close a round of the employers feed, which
has no `submit`, as failed while its answer was on the way.

**What it gives up, and what remains.** Thirty minutes can be less than the oracle itself takes,
and the tip of a daily round whose callback is late goes to whoever hands the answer in first
(`docs/THREATS.md`, Q3 and Q4). A round the Intake never serves blocks its feed for up to twelve
hours; the employers feed depends on the writer delivering within twelve hours; and nothing stops
a caller from closing a round at twelve hours with its answer on the way (Q8).

**Shown by.** `test_waits_areTheValuesFixedAtLaunch`; both edges of each rule, one second before
and at the boundary: `test_submit_opensThirtyMinutesAfterARequestTheIntakeNeverCompleted`,
`test_submit_beforeTheIntakeHasCompletedTheRequest_reverts`,
`test_abandon_afterTwelveHoursOfSilence`, `test_abandon_twelveHoursFromTheRequestIsAlwaysEnough`;
against the house feeds: `test_theWaitsFitTheHouseFeeds`,
`test_employersDependsOnTheWriterDeliveringWithinTwelveHours`.

**Not audited.** This change was made after both audits and has been read by no auditor.
