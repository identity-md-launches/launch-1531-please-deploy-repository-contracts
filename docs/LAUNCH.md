# Launch A: Questions, JobsReport, Payroll

This document is what the launch needs and nothing else: the launch request, the manifest we expect,
where every constructor argument comes from, every value that can never be changed afterwards, the
proof that the live oracle answers each feed, and what to do on the first day and every day after.

**Status: not launched.** None of the three contracts has been sent to a chain. Every number below
was produced by a test or a command that is named beside it. Addresses of the three contracts do
not exist yet; where a command needs one, it reads it from a shell variable.

What has happened on chain is the proof of section 5: on 12 and 13 October 2026 one real request
was bought for each of the three house feeds, with the bytes `Questions` will send, and all three
were attested. The code was then audited twice by IdentityMD's own audit agents; what they found
and what was done is in `docs/AUDITS.md`. After the audits two waits in `Questions` were changed,
because of what the same day showed about how late the Intake's callback can be: section 4 gives
the values and the reason. The supplied launch audit subsequently reproduced tip reassignment,
premature closure and forced escrow claims; `ADAPTATION.md` records the resulting changes and tests.

The tests in `test/launch/` and `test/questions/HouseFeedProofs.t.sol` read this file. The blocks
that follow a marker comment (`<!-- manifest -->`, `<!-- feedId:… -->`, `<!-- createFeed:… -->`,
`<!-- proof:… -->`, `<!-- proofs -->`) are parsed and compared with the code, the fixtures and the
saved records, so a block that is edited by hand without the matching change fails `forge test`.

## 1. The launch request

To send to IdentityMD with the repository's URL:

> Please deploy this repository as it is: contracts only, on Ethereum mainnet. There is no token
> and no owner.
>
> It holds three contracts, to be created in this order: `Questions`, `JobsReport`, `Payroll`.
> Their constructor arguments are in `docs/LAUNCH.md`: six existing mainnet addresses (IMD, sIMD,
> the seat token, the seat Adapter, version 2 of the Intake and the oracle signer), the number
> 2000, three `bytes32` feed ids, and two references to `Questions`. No argument is `$owner`: no contract has
> an owner, an admin or a setter.
>
> Nothing has to be called after deployment. The constructors make no external call and check no
> code size, so they run on an empty chain. There is no proxy, no initializer, no pausing and no
> minting; the runtime bytecode holds no DELEGATECALL, CALLCODE or SELFDESTRUCT. `forge test`
> checks each of these statements (`test/launch/LaunchManifest.t.sol`).
>
> The project builds with solc 0.8.26, EVM version cancun, optimizer 200 runs, `via_ir`,
> `bytecode_hash = "none"` and `cbor_metadata = false`, as `foundry.toml` already says. We believe
> no source file needs to change for the launch.

The repository carries no `launch.json`: the pipeline's manifest step writes it.

## 2. The manifest we expect

Contracts in order, with their constructor arguments in order:

<!-- manifest -->
```json
{
  "kind": "evm_contracts",
  "contracts": [
    {
      "contract": "Questions",
      "constructorArgs": [
        "0xa43e6f75ee006411f79ac1c84120606c2330de82",
        "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
        "0x5598aa9146215bc13eb26f2c692ad1461fd32982"
      ]
    },
    {
      "contract": "JobsReport",
      "constructorArgs": [
        "$contract:Questions",
        "0x4bf83605cd50e9658472bde9be314bb3848a563301fa793328bef17ad2a07b61",
        "0xfde22d9c1b97b7ce9763dff388a66366f9012d4ba7c57c3239377a75532bee4d",
        "0x22ad8df0e0af07aa59e29aa7f5540e0022fbfda0651ccae3eccb968553a14835"
      ]
    },
    {
      "contract": "Payroll",
      "constructorArgs": [
        "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
        "0x9efa934d9fad4ae28c998a40195646b965a97247",
        "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d",
        "2000",
        "0xde152afb7db5373f34876e1499fbd893a82dd336",
        "$contract:Questions",
        "0x4bf83605cd50e9658472bde9be314bb3848a563301fa793328bef17ad2a07b61",
        "0xfde22d9c1b97b7ce9763dff388a66366f9012d4ba7c57c3239377a75532bee4d",
        "0x22ad8df0e0af07aa59e29aa7f5540e0022fbfda0651ccae3eccb968553a14835"
      ]
    }
  ],
  "notes": "Contracts only. No token, no owner, nothing to call after deployment."
}
```

### Every argument and where its value comes from

All addresses are Ethereum mainnet. The constant names are those of
`src/interfaces/external/Mainnet.sol`, which the tests import; the deployed contracts do not import
it, they receive every address as an argument.

**`Questions(address intake, address imd, address oracleSigner_)`**

| # | Argument | Value | Source |
|---|---|---|---|
| 0 | `intake` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` | `Mainnet.INTAKE`. IdentityMD's Intake, version 2, source verified on Sourcify: the address IdentityMD names for anything new, the same on Ethereum, Robinhood Chain and Sepolia. Every request is bought from it and every callback must come from it. Version 1 (`0x1397434cd35e8a9c8ac312a61d3a285eb31dea56`, `Mainnet.INTAKE_V1`) is listed as legacy and is not used by the launch. `test_fork_theIntakeIsVersionTwo` reads the difference from the chain. |
| 1 | `imd` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | `Mainnet.IMD`. The token meters hold and the Intake is paid in. |
| 2 | `oracleSigner_` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` | `Mainnet.ORACLE_SIGNER`. The address that signs oracle attestations: the `signer` named by the attested requests saved under `test/fixtures/questions/requests/` and by the three proofs of section 5. The tests verify eleven real signatures against it: eight in `test/questions/RealAttestations.t.sol` and the three proofs in `test/questions/HouseFeedProofs.t.sol`. It is **not** `Intake.signer()`, which signs price quotes. |

**`JobsReport(address questions, bytes32 payrollsFeed, bytes32 hiresFeed, bytes32 employersFeed)`**

| # | Argument | Value | Source |
|---|---|---|---|
| 0 | `questions` | `$contract:Questions` | The first contract of this launch. |
| 1 | `payrollsFeed` | the payrolls feed id, below | Recomputed from `test/fixtures/questions/feeds/payrolls.json`. |
| 2 | `hiresFeed` | the hires feed id, below | Recomputed from `test/fixtures/questions/feeds/hires.json`. |
| 3 | `employersFeed` | the employers feed id, below | Recomputed from `test/fixtures/questions/feeds/employers.json`. |

**`Payroll(address imd, address simd, address seats, uint256 seatCount, address adapter, address questions, bytes32 feedA, bytes32 feedB, bytes32 feedC)`**

| # | Argument | Value | Source |
|---|---|---|---|
| 0 | `imd` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | `Mainnet.IMD`. |
| 1 | `simd` | `0x9efa934d9fad4ae28c998a40195646b965a97247` | `Mainnet.SIMD`. The ERC-4626 vault over IMD that stakers hold; the staker stream is sent to it by plain transfer. |
| 2 | `seats` | `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` | `Mainnet.SEATS`. The seat ERC-721. |
| 3 | `seatCount` | `2000` | `Mainnet.SEAT_COUNT`. Seats are token ids 0 to 1999. |
| 4 | `adapter` | `0xde152afb7db5373f34876e1499fbd893a82dd336` | `Mainnet.SEAT_ADAPTER`. IdentityMD's agent-to-seat Adapter (an upgradeable proxy; only tips depend on it). |
| 5 | `questions` | `$contract:Questions` | The first contract of this launch. |
| 6 | `feedA` | the payrolls feed id | Served first, 14-request runway. |
| 7 | `feedB` | the hires feed id | Served first, 14-request runway. |
| 8 | `feedC` | the employers feed id | The slow feed: served only from what the first two leave, 4-request runway. |

The order `feedA` = payrolls, `feedB` = hires, `feedC` = employers matters: the third feed is the
one Payroll funds last and least.

### The three feed ids

A feed id is `keccak256(abi.encode(params, keccak256(qPrefix), keccak256(tail)))`: it depends only on
what the feed asks, so the ids are known before any feed exists.
`test_manifest_feedIdsAreRecomputedFromTheFixtures` recomputes the three from the fixture files and
fails if any id written in this document differs.

payrolls (the sum of IMD transferred to the fee payee `0x4e0fa57bde726079356537e2f34d671e9f41adbc`, per day):

<!-- feedId:payrolls -->
```text
0x4bf83605cd50e9658472bde9be314bb3848a563301fa793328bef17ad2a07b61
```

hires (the number of IMD `Transfer` logs to the fee payee, per day, transfers of zero included):

<!-- feedId:hires -->
```text
0xfde22d9c1b97b7ce9763dff388a66366f9012d4ba7c57c3239377a75532bee4d
```

employers (the three addresses that sent the fee payee the most IMD over the last seven days, as a
panel of seven agents reads them from the chain; this id replaced
`0xc09b49435a17cb78599285e972df2f6f095b0f49658a8279812f653670633817` on 13 October 2026, when the
feed's first body proved impossible to attest, see section 5):

<!-- feedId:employers -->
```text
0x22ad8df0e0af07aa59e29aa7f5540e0022fbfda0651ccae3eccb968553a14835
```

## 3. What the tests show about the launch

| Statement | Test |
|---|---|
| The manifest above names `Questions`, `JobsReport`, `Payroll` in that order, with 3, 4 and 9 arguments, two backward references and no `$owner` | `test_manifest_namesTheThreeContractsInOrder` |
| Every argument is the `Mainnet.sol` address, the reference, or the recomputed feed id | `test_manifest_everyArgumentIsWhatTheCodeExpects`, `test_manifest_feedIdsAreRecomputedFromTheFixtures` |
| Created in manifest order from those arguments, on a chain where no dependency has code, the three contracts deploy and report the configuration written here | `test_launch_deploysInManifestOrderOnAnEmptyChain` |
| Each contract is inside our gates of 23,000 bytes of runtime code and 46,000 bytes of initcode; the launch is inside our gate of 12,000,000 gas | `test_launch_fitsOurSizeAndGasGates` |
| No runtime bytecode holds DELEGATECALL, CALLCODE or SELFDESTRUCT (walked instruction by instruction, PUSH data skipped) | `test_launch_runtimeBytecodeHasNoForbiddenOpcode`, `test_bytecodeWalk_findsWhatItLooksForAndSkipsPushData` |
| No constructor holds CALL, STATICCALL, an EXTCODE instruction, BALANCE, CREATE or CREATE2 | `test_launch_constructorsMakeNoCallAndNoCodeCheck` |
| On a mainnet fork, the launch deployer's `launchContracts` call to the real ProjectFactory creates the three contracts at the predicted addresses | `test_fork_rehearsal_factoryCreatesTheThreeContracts` (fork suite) |

Pre-adaptation sizes (final sizes are in `ADAPTATION.md`; the protocol's limits are 24,576 and 49,152 bytes):

| Contract | Runtime bytes | Initcode bytes | Initcode with arguments |
|---|---|---|---|
| Questions | 22,963 | 24,372 | 24,468 |
| JobsReport | 9,320 | 9,618 | 9,746 |
| Payroll | 11,715 | 12,429 | 12,717 |

Before the launch adaptation, `Questions` was 37 bytes under our own 23,000-byte gate and 1,613 bytes under the limit. It has no room
left for additions of any substance; that is known and accepted, since nothing can be added after
launch anyway. The audit fixes changed `Payroll` (154 bytes more than before them) and nothing in
the bytecode of the other two. The change of the two waits that followed (section 4) changed
`Questions` and nothing else, and made it 23 bytes smaller than the 22,986 it had: two of its
getters now return the same thirty minutes, and the compiler serves both from one piece of code.

Pre-adaptation launch gas (the gates remain enforced by the final tests):

| Measure | Gas | Where it comes from |
|---|---|---|
| Creating the three contracts one after another on an empty chain | 9,820,310 (Questions 5,093,757, JobsReport 2,104,841, Payroll 2,621,712) | `test_launch_fitsOurSizeAndGasGates`, with Foundry's default setting, which runs each creation as a transaction of its own. |
| The brief's estimate: 240 gas for each of the 46,931 bytes of initcode | 11,263,440 | The same test. The rate is that of launch 1240 (9,596,612 gas for 39,910 bytes). |
| The real ProjectFactory's `launchContracts`, called by the launch deployer on a mainnet fork | About 10.36 million for the call, and 0.75 million more for the transaction's base cost and calldata: about 11.1 million | `test_fork_rehearsal_launchFitsOurGasAndSizeGates`. Two runs on 13 October 2026 with the code as it is now printed 11,108,338 and 11,108,797 for the two together (the second: 10,357,397 for the call and 751,400 for the rest). Two runs earlier that day, before the two waits were changed, printed 11,093,453 and 11,108,320; the figure moves by some ten thousand gas with the block the fork is taken at. |

Our gate is 12,000,000 gas and the protocol's ceiling is 16.7 million. The rehearsed launch is
about 0.9 million gas under our gate. The second part of the rehearsal figure is added by hand
from the calldata's bytes, which may count some of it twice; the figure errs high.

## 4. What is fixed at launch

Nothing below can be changed by anyone once the launch transaction is mined. There is no owner, no
setter and no upgrade path. Each value is listed with the reason it has the value it has.

### Questions

| Value | Setting | Reason |
|---|---|---|
| Intake, IMD, oracle signer | constructor arguments | No key exists that could point a feed at another signer or another Intake. The cost is stated in `docs/DEVIATIONS.md`: if IdentityMD rotates the signer or moves the Intake, new answers stop and the contract has to be launched again. |
| Attestation domain | name `IdentityMD Oracle`, version `2` | From the protocol's `OracleAttestation.sol`, copied unchanged. |
| `ISSUED_AT_TOLERANCE` | 5 minutes | From the protocol's library: how far ahead of the chain's clock a signing time may be. |
| `SUBMIT_AFTER_SILENCE` | 30 minutes | When anyone may hand in an answer for a request the Intake has still not completed. The callback has the first half hour to itself; after it, an answer the oracle has signed does not have to wait for the Intake's writer, which can be hours late (the reading of 13 October 2026, below this table). Thirty minutes is past the median of IdentityMD's public list of requests on 10 October 2026 (14 minutes) and not past its slowest tenth (55 minutes and more), so `submit` can open before the oracle has answered. It is eleven and a half hours before the round can be closed. |
| `ABANDON_AFTER_COMPLETED` | 30 minutes | Time left to hand in an answer whose callback did not run, counted from the first `abandon` call that sees the Intake's completion. |
| `ABANDON_AFTER_SILENCE` | 12 hours, followed by `validFor` + 5 minutes + 1 second | Time allowed for signing, followed by the full requested validity, signing-clock tolerance and inclusive-expiry boundary. House feeds can close after 36 h 5 min 1 s of silence. Completed requests keep the earlier thirty-minute recovery path. |
| Back-off | cadence × 2^(failed rounds in a row), at most 2^5 = 32 (`MAX_BACKOFF_DOUBLINGS` = 5) | A feed whose question keeps failing spends its funders' IMD more and more slowly, and never stops asking altogether. One answer resets it. |
| `GATE_GAS`, `GATE_DATA_MAX` | 100,000 gas, 68 bytes | The WHEN gate is one bounded static call with a selector and at most two words. |
| `MAX_PANEL_SIZE` | 300 | The protocol's own upper limit for a panel. |
| `MIN_LAG_BLOCKS`, `MAX_LAG_BLOCKS` | 5, 256 | The protocol refuses a window that ends fewer than 5 blocks back; 256 is as far as BLOCKHASH reaches. |
| `validFor` range | 60 seconds to 30 days | The protocol's range for `validForSeconds`. |
| Longest body | 16,384 bytes | The Intake's limit. |
| Tip bound | a feed's tip is at most its `maxPrice` | A keeper is never paid more for asking than the feed pays for the answer. |
| Tip rule | set aside at `request`, earned by its opener when answered, returned to the meter on failure | An observer submitting a public signature cannot take the opener's tip. There is no separate reward for submission. |
| Intake read gas | 50,000 per read | A bound, so an Intake getter that burns gas cannot keep a round from being closed. |
| Share rescale | counts divided by 2^64 when a meter has more than 2^128 shares per wei | Keeps a long-lived meter's share count from overflowing. |

**Timing after the launch audit.** The original twelve-hour closure could discard a valid
house-feed answer while the Intake still reported an unfinished request. Silence now permits
closure at `requestedAt + 12 hours + validFor + 5 minutes + 1 second`. The twelve hours allow
for signing; the remaining time preserves the answer's requested validity, including clock skew
and the fact that a signature is valid at `expiresAt`. For all three house feeds this is
**36 hours, 5 minutes and 1 second**. `canAbandon` reports the actual deadline. The earlier path
for a completed request remains thirty minutes after completion is first observed.

`submit` still opens after thirty minutes for pinned chain-evidence feeds. It always credits the
round's opener, including when somebody else buys a matching answer: the protocol's oracle UUID
cannot be linked on chain to the Intake purchase id. There is no separate submission reward.

A pending round still blocks new requests. The longer deadline can delay the next daily request;
funders may withdraw unspent balances throughout. A response signed more than twelve hours after
purchase or delivered after the full deadline can still be lost if somebody closes the round.
No finite timeout can guarantee delivery from a service with unbounded delay. The employers feed
still depends on the Intake callback because `submit` remains closed for panel evidence.

Tests: `QuestionsLaunchAudit.t.sol`, `QuestionsAbandon.t.sol`,
`test_employersAcceptsAValidDeliveryAfterTwelveHours` and `test_theWaitsFitTheHouseFeeds`.

### Payroll

| Value | Setting | Reason |
|---|---|---|
| IMD, sIMD, seat token, seat count, Adapter, Questions, three feed ids | constructor arguments | Written in the manifest, readable by anyone. |
| Split of every booking | 50% stakers (and every rounding remainder), 30% seats (`SEAT_BPS` 3000), 20% feeds (`FEED_BPS` 2000) | The product's fee split. |
| `STREAM_DURATION` | 7 days | New money for stakers vests over a week, so no single transfer to sIMD carries a week's fees. |
| Stream end on a booking | `now + (remaining × timeLeft + amount × 7 days) / (remaining + amount)` | Brief, section 12, decision 2: a booking that is dust next to what is left moves the end by nothing; a large one still takes about seven days. A booking in between delays money that was already vesting, by at most seven days less the time it had left (`docs/THREATS.md`, P3). |
| `DRIP_INTERVAL`, `DRIP_WINDOW` | 10 minutes, 1 hour | Drips are at least ten minutes apart and one drip sends at most one hour of stream, so one transfer to sIMD is always small. That bounds what one visit to sIMD can take, not what visits add up to: a visitor takes a staker's share of every drip it attends (`docs/THREATS.md`, P2). Kept as built (decision 3). |
| `MAX_TIP_AGENTS` | 16 | Only the first 16 agent ids of a tip share it: a bounded loop, and `tip` stays under 600,000 gas. |
| `TIP_SWEEP_DELAY` | 180 days | A tip that cannot be claimed waits between 180 and 360 days, then anyone may move it to the seat pool. |
| `MAX_SEATS_PER_CALL` | 200 | A full `claimSeats` list is about 10 million gas at the per-seat cost measured on a mainnet fork. |
| `FEED_RUNWAY_REQUESTS` | 14 | Payroll keeps a position of its own on each daily feed's meter, topped up to two weeks of requests and no further. What others put on a meter is not counted. |
| `FEED_C_RUNWAY_REQUESTS` | 4 | Its position on the weekly feed's meter is topped up to four requests, and only from what the first two leave. |
| `FEED_COST_CAP` | 2 IMD | The most Payroll assumes one request costs when it sizes a top-up, so a price change at the Intake cannot empty the budget into one meter. |
| `FEED_BUDGET_PERIOD` | 14 days | Feed budget no meter needed falls due after 14 to 28 days. The next `fundFeeds` call serves the meters from it and releases the rest to stakers, so it cannot be stranded and is never released past a meter that lacks it. A booking releases nothing. |
| `BINDING_GAS` | 100,000 | Gas given to the Adapter read, with a floor so a caller cannot starve it. The live Adapter used 13,200 on a mainnet fork. |

### JobsReport

| Value | Setting | Reason |
|---|---|---|
| Questions, three feed ids | constructor arguments | Written in the manifest. |
| `MAX_ROUNDS_PER_CALL`, `MAX_PAIRING_STEPS` | 8, 16 | Bounded work per `print` call; a backlog is worked off over several calls. |
| `MAX_DAY_BLOCKS` | 7,500 | About 25 hours. A print over a longer window (the catch-up after a missed day) cannot take the best-day record and ends the streak. |
| Pairing rule | a count joins a print when the two windows share more than half of the longer one | The two daily feeds are requested by separate transactions and may drift. |
| Largest figure | 2^128 − 1 | A larger answer is passed over, so no single answer can overflow a running total. |
| `MAX_PAGE` | 100 | The most entries a page view returns. |

### The three house feeds

These are parameters of the feeds, not of the contracts. They are fixed in the sense that
`JobsReport` and `Payroll` are bound to the three ids above, and an id changes if any parameter or
any byte of the question changes. Each of the three bodies was proven against the live oracle on 12
and 13 October 2026 (section 5), and they are final.

| Parameter | payrolls | hires | employers | Reason |
|---|---|---|---|---|
| Evidence | `chain`, with the recipe pinned in `definitions.recipe`: `log-sum` of `Transfer.value` to the fee payee | `chain`, with the recipe pinned: `log-count` of `Transfer` to the fee payee | `panel`, with the method written out in `definitions.method` and `definitions.source`: add up `Transfer.value` to the fee payee per sender, largest first | The two daily figures are chain evidence: the oracle reruns the agreed recipe at the pinned blocks before it signs, so each is a fact about the chain that IdentityMD recomputed. The oracle has no recipe that ranks senders among the transfers to one recipient (its ranking recipe takes no filter), so the weekly list is judged by the panel's agreement and IdentityMD does not recompute it. Section 5 and `docs/THREATS.md`, F4. |
| Answer type | `uint256` | `uint256` | `address[]`, `head` 3: exactly three addresses | |
| Panel size, quorum, `minAgreed` | 7, 5, 5 | 7, 5, 5 | 7, 5, 5 | The values of the three proof requests, each attested with five agreeing. `minAgreed` equal to the quorum accepts only the panel's own agreement. For the panel-judged feed that is the only agreement there is: the oracle's `agreed` is below the quorum only for chain evidence that its rerun settled. |
| `submit` (hand in an answer the callback missed or has not brought) | open | open | closed | `Questions` refuses `submit` for a question a panel judges: two panels can differ, and whoever submitted would choose. Only the Intake's own callback delivers to the employers feed. |
| `validFor` | 86,400 s | 86,400 s | 86,400 s | One day to deliver an answer. |
| `cadenceBlocks` | 7,000 | 7,000 | 49,000 | 23 h 20 min, so a keeper can ask at the same clock time every day; a little under seven days for the ranking. |
| `maxWindowBlocks` | 21,600 | 21,600 | 50,400 | Three days of catch-up for the daily feeds; exactly seven days for the ranking. |
| `lagBlocks` | 12 | 12 | 12 | The usual distance behind the head. |
| `contiguous` | yes | yes | no | Daily windows tile with no gap and no overlap; a ranking is of the newest seven days. |
| `pinHash` | yes | yes | yes | An answer must carry the question hash built on chain from the feed's own text. For the employers feed that text holds the whole method. |
| `maxPrice` | 2 IMD | 2 IMD | 2 IMD | Four times the live price of 0.5 IMD. Above it, requests stop. |
| `tip` | 0.05 IMD | 0.05 IMD | 0.05 IMD | Paid to the keeper for an answered round. Kept as built (decision 3). |
| WHEN gate | none | none | none | |

Limits a reader of the feeds should know: hires counts every `Transfer` log to the fee payee,
including transfers of zero and transfers that are not purchases, because a `log-count` filter
reaches indexed arguments only. The feeds' own purchases are transfers to the fee payee too and are
counted. The employers list rests on five of seven agents agreeing and on nothing else. See
`docs/THREATS.md`, section 4.

## 5. The proof: each feed body was bought once from the live oracle

**Done on 12 and 13 October 2026. All three feeds are go.**

The protocol's free check returned no blocker for the three questions on 11 October, with one
note on each ("may be read more than one way"). The free check does not take `definitions`, so it
did not exercise the pinned recipes. Only a paid request does. So the team bought one request per
feed from an ordinary wallet (`0x871e507B6a70F858Ad4B414bddb77473630C366b`), through the Intake,
with no callback, using exactly the bytes `Questions` will send. Four requests were bought, 0.5 IMD
each, 2 IMD in all: the price is never refunded, whatever the outcome.

**They were bought through version 1 of the Intake** (`0x1397434cd35e8a9c8ac312a61d3a285eb31dea56`),
before version 2 was adopted for the launch. Version 2 has the same `request` function and the same
oracle behind it; the body, the question hash and the answer do not depend on which Intake took
the payment. The commands at the end of this section name version 2, which is what anyone repeating
the proof now should use.

### What was bought and what came back

| Feed | Request | Window asked | Oracle request | Outcome |
|---|---|---|---|---|
| payrolls | `0xc75123bfb4cd49e0f1c55b236443b2a6d6d93ac981cd3e62f4f931bc2abc9cee`, block 26,179,783, 12 October 23:48 UTC | blocks 26,172,770 to 26,179,769 (7,000) | `3744d864-8cbf-4fcf-8a8c-3529fb1736cb` | **Attested** 52 seconds after it was admitted: 114 IMD (`114000000000000000000`). Panel 7, quorum 5, agreed 5. |
| hires | `0xd7ad398293c0c9138cf7895262f5861465f0ab610861b81426efe6c7e27b16ea`, block 26,179,785, 12 October 23:48 UTC | blocks 26,172,772 to 26,179,771 (7,000) | `df50bf76-41a0-4596-ae9e-9dcfd0e1ccd5` | **Attested** 62 seconds after it was admitted: 228 transfers. Panel 7, quorum 5, agreed 5. |
| employers, the body it had then | `0x674b5e14572e1e53960802a3a664bac8403bdda0d0e39e6aad23fbaef2d38b0e`, block 26,179,787, 12 October 23:49 UTC | blocks 26,129,374 to 26,179,773 (50,400) | `c1d0ba09-c732-46e7-b257-2722841215fe` | **Not attested**: status `mismatch`, "the recipe did not reproduce the panel's answer". See below. |
| employers, as it is launched | `0x14e7189cd2f65180452995c7a5ed1d12f9101dd8c42c23c63e21a1d86b48ba9d`, block 26,179,860, 13 October 00:03 UTC | blocks 26,129,447 to 26,179,846 (50,400) | `2cbe6bb3-13f9-4617-98b9-5d83754f9e1a` | **Attested** 4 minutes 16 seconds after it was admitted: `0x21919137e69ed667ac404c7fcb71b8179b645f46`, `0x9fadab91f6fa03dbd7f4f8a08a338704baacf63f`, `0x7b8c742f2e1eeb3fb2c10d72967fa6d4a22f0479`. Panel 7, quorum 5, agreed 5. |

The three proofs of the feeds as launched, as the tests read them
(`test_proofs_theDocumentStatesWhatTheRecordsHold` compares this block with the saved records):

<!-- proofs -->
```json
[
  {
    "feed": "payrolls",
    "feedId": "0x4bf83605cd50e9658472bde9be314bb3848a563301fa793328bef17ad2a07b61",
    "transaction": "0xc75123bfb4cd49e0f1c55b236443b2a6d6d93ac981cd3e62f4f931bc2abc9cee",
    "block": 26179783,
    "oracleRequestId": "3744d864-8cbf-4fcf-8a8c-3529fb1736cb",
    "fromBlock": 26172770,
    "toBlock": 26179769,
    "questionHash": "0xa7eb81dbf5789fdd71e33f54c90cda86ac6cf4070c2320c6d1719e01e3a84dd3",
    "bodyHash": "0xbbf7d6fdf20fe61d71b05bfe3ba358d4d0e97be43c2c43d17f9b0678b0a2873d",
    "status": "attested",
    "answer": "0x0000000000000000000000000000000000000000000000062e115c008a880000",
    "agreed": 5,
    "attestedAt": "2026-10-12T23:50:00.611Z"
  },
  {
    "feed": "hires",
    "feedId": "0xfde22d9c1b97b7ce9763dff388a66366f9012d4ba7c57c3239377a75532bee4d",
    "transaction": "0xd7ad398293c0c9138cf7895262f5861465f0ab610861b81426efe6c7e27b16ea",
    "block": 26179785,
    "oracleRequestId": "df50bf76-41a0-4596-ae9e-9dcfd0e1ccd5",
    "fromBlock": 26172772,
    "toBlock": 26179771,
    "questionHash": "0xdb20f183971eca9bda183646db40164a35cd6cec00acabff45918189f15e6dc5",
    "bodyHash": "0xda6f13f65b9329f31f201dc06eed234f4c73bded9a9ebf64a061f4181a2b29a9",
    "status": "attested",
    "answer": "0x00000000000000000000000000000000000000000000000000000000000000e4",
    "agreed": 5,
    "attestedAt": "2026-10-12T23:50:31.358Z"
  },
  {
    "feed": "employers",
    "feedId": "0x22ad8df0e0af07aa59e29aa7f5540e0022fbfda0651ccae3eccb968553a14835",
    "transaction": "0x14e7189cd2f65180452995c7a5ed1d12f9101dd8c42c23c63e21a1d86b48ba9d",
    "block": 26179860,
    "oracleRequestId": "2cbe6bb3-13f9-4617-98b9-5d83754f9e1a",
    "fromBlock": 26129447,
    "toBlock": 26179846,
    "questionHash": "0x3d14a9f53e3eaf1272d67871cff61223fc9b295f26e177c7a193ca5f90d52fc6",
    "bodyHash": "0xf0841684ac251fd3f07386cc34d41cccbaef1bd64b8c2353a8c25b641ccce54a",
    "status": "attested",
    "answer": "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000300000000000000000000000021919137e69ed667ac404c7fcb71b8179b645f460000000000000000000000009fadab91f6fa03dbd7f4f8a08a338704baacf63f0000000000000000000000007b8c742f2e1eeb3fb2c10d72967fa6d4a22f0479",
    "agreed": 5,
    "attestedAt": "2026-10-13T00:08:45.443Z"
  }
]
```

The records IdentityMD's API served for the four requests are in the repository, under
`test/fixtures/questions/proofs/`: for each, the oracle's record (the request, its pinned window,
every member's answer, the agreement, the oracle's own computation, the attestation and its
signature), the Intake service's record of the purchase, and for the three attested ones the
EIP-712 document with the domain the answer was signed in. `index.json` there says where each file
came from and when.

### What the proofs show

For each of the three feeds as launched, checked by `test/questions/HouseFeedProofs.t.sol` against
the saved records and the feed's fixture file:

1. **The body is the contract's.** The hash the Intake's service recorded for the body it received
   is the hash of the feed's prefix, the window and the feed's tail, byte for byte
   (`test_proofs_theBodyThatWasBoughtIsTheBodyTheContractSends`).
2. **The question hash is the contract's.** The hash the oracle attested is the hash
   `QuestionBody`, the contract's own builder, gives for the feed's prefix and the proven window
   (`test_proofs_theContractsQuestionHashIsTheAttestedOne`). A different hash would have meant the
   launched contract refuses every answer.
3. **The window and its closing block are right.** The signed window is the one that was asked,
   and it is the window `Questions` asks first. The signed closing block hash is the chain's (read
   back with `cast block <toBlock> --field hash` on 13 October for all four requests).
4. **The answer has the feed's type and decodes** to the figure the panel agreed on: a `uint256`
   of 114 IMD, a `uint256` of 228, and an `address[]` of exactly three addresses, as `head` 3 asks
   (`test_proofs_eachAnswerDecodesUnderItsFeedsAnswerType`).
5. **The panel and the signer are what the feed requires.** Panel 7, quorum 5, agreed 5, valid
   for 86,400 seconds, signed by `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, the address in the
   manifest (`test_proofs_thePanelTheSignerAndTheValidityAreWhatTheFeedsRequire`).
6. **The real signatures pass the real callback.** `Questions` is placed at the address the
   answers were signed for, each house feed is created under its launch id, a round is opened in
   the block the proof was bought for, and the real attestation with the real signature is
   delivered: it is stored, for all three, using 115,803 to 115,943 gas of the 200,000 the Intake
   gives (`test_proofs_theRealSignedAnswersPassEveryCheckOfTheCallback`). The address is the zero
   address, because a request with no callback and no consumer is signed for nobody.
7. **The figures are the chain's.** We recounted the IMD `Transfer` logs to the fee payee over each
   window ourselves, with `cast logs` and no tool of the oracle's, on 13 October: 228 logs summing
   114 IMD from 61 senders in the payrolls window; 228 logs in the hires window; 2,737 logs from 181
   senders in the employers window, of which the three largest are the three attested, in that
   order (678, 98 and 93 IMD). No transfer of zero was among them.

### Why the employers feed changed

The employers feed first pinned a ranking recipe (`log-rank`, grouped by sender, top 5) with a
filter on the recipient, as the two daily feeds pin theirs. Five members of the panel answered,
and all five gave the same filtered ranking. The oracle did not attest. Its recipe checker refuses
a filter inside a ranking recipe, so each member had recorded the filter beside the recipe and
handed in the recipe without it; the oracle then reran that recipe, ranked every IMD transfer in
the window whoever received it, and got five other addresses. That body can never be attested.

So the feed asks the same question the other way the oracle offers: `evidence` `panel`. The method
(which logs, which filter, how to add up, how to order, how ties fall, how many addresses) is
written out in the question's `definitions`, and what the oracle signs is what the panel agreed on.
The second request, with that body, was attested, and its panel named the same three addresses the
first panel had. The feed's id changed from `0xc09b49435a17cb78599285e972df2f6f095b0f49658a8279812f653670633817`
to the one in section 2.

What that means for a reader of the feed is in `docs/THREATS.md`, F4, and it is not small:
IdentityMD does not recompute the employers answer. It rests on five of seven agents agreeing.
Only the weekly list of three depends on it; the two daily figures are recomputed by the oracle
before it signs, and the Jobs Report prints without the employers feed.

### What the proofs do not show

- **Delivery.** The requests named no callback. Nothing was delivered to a contract, and the
  answers were signed for no consumer. The fork suite plays the writer's call against version 2 of
  the Intake with a test signer (`test_fork_houseFeedBuysARealRequestAndTakesTheCallback`).
- **The on-chain completion.** When the Intake records were last read (13 October, 01:21 to 01:55
  UTC, up to two hours after the purchases) the service listed all four requests as `completing`
  with the completion `queued`, and `Intake.requests(id).completed` was still false for all four
  at 02:28 UTC (block 26,180,584), two hours and forty minutes after the first purchase: the
  oracle had decided within minutes and the writer had not yet sent `complete`.
  Go condition 1 below was therefore met in its first half (the service reports status 0, an
  answer) and not yet in its second (the `Completed` event) when this was written. See
  `docs/THREATS.md`, section 9, on how late the writer was that day, and section 4 above for the
  two waits that were set because of it.
- **More than one answer.** One request per feed. For the employers feed in particular, one
  agreement of five members out of five that answered.

### To repeat it

Anybody can buy the same proof again. It costs 0.5 IMD per request plus gas, never refunded.

<!-- proof:priceWei -->
```text
500000000000000000
```

<!-- proof:action -->
```text
0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000
```

The window each proof asks about is the window `Questions` asks first: it ends 12 blocks behind the
head and covers this many blocks.

<!-- proof:blocks:payrolls -->
```text
7000
```

<!-- proof:blocks:hires -->
```text
7000
```

<!-- proof:blocks:employers -->
```text
50400
```

`test_proof_shellRecipeGivesTheBodyTheContractSends` shows that the body and the question hash
assembled below are, byte for byte, what the contract produces for the same window, for all three
feeds. `test_fork_proof_walletBuys…` (fork suite) makes the same two calls as below against the live
Intake, version 2, on a fork.

They need `cast` (Foundry) and `jq`, and are run from the repository root. `$WALLET` stands for the
operator's own signing option for `cast send`, for example `--account NAME` (an encrypted keystore)
or `--ledger`. No key is written in this file, and none should be typed on a command line.

```sh
export RPC=...                                              # an Ethereum mainnet RPC URL
export IMD=0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7
export INTAKE=0xa43e6f75ee006411f79ac1c84120606c2330de82    # version 2; the proofs above used version 1
export ACTION=0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000
export PRICE=500000000000000000

# Once: allow the Intake to take the three prices (1.5 IMD).
cast send $IMD "approve(address,uint256)" $INTAKE 1500000000000000000 --rpc-url "$RPC" $WALLET
```

Then, for each feed in turn, **one request per transaction** (IdentityMD's guide says its service
serves only the first request of a transaction):

```sh
FEED=payrolls; BLOCKS=7000        # then: FEED=hires; BLOCKS=7000   and: FEED=employers; BLOCKS=50400
F=test/fixtures/questions/feeds/$FEED.json

HEAD=$(cast block-number --rpc-url "$RPC")
TO=$((HEAD - 12)); FROM=$((TO - BLOCKS + 1))
WINDOW="$FROM,\"toBlock\":$TO}"
BODY=$(cast concat-hex "$(jq -r .qPrefixHex $F)" "$(cast from-utf8 "$WINDOW")" "$(jq -r .tailHex $F)")
QHASH=$(cast keccak "$(cast concat-hex "$(jq -r .qPrefixHex $F)" "$(cast from-utf8 "$WINDOW}")")")
echo "$FEED: blocks $FROM to $TO, question hash $QHASH"
cast to-utf8 $BODY                                          # read the body before paying for it

cast send $INTAKE "request(bytes32,bytes,(address,bytes4),address,uint256)" \
  $ACTION $BODY "(0x0000000000000000000000000000000000000000,0x00000000)" $IMD $PRICE \
  --rpc-url "$RPC" $WALLET
```

Keep `FROM`, `TO`, `QHASH` and the transaction hash of each request.

Where to read the result:

```sh
TX=0x...                                                    # the request's transaction hash
curl -s https://api.imd.fun/intake/1/$TX | jq '.entries[0] | {state, reason, requestId, bodyHash, admission, completion}'
```

`state` moves through `received`, `paid`, `admitted`, `completing` and ends at `completed`,
`refused` or `failed`. `admission.result.statusUrl` names the oracle request; the full list is at
<https://api.imd.fun/oracle/requests>.

```sh
ID=...                                                      # admission.result.requestId
curl -s https://api.imd.fun/oracle/requests/$ID | jq '{status, questionHash, answerType, signer, failure, attestation}'
```

On chain, the Intake's `Completed` event for the request (its `requestId` is the first topic of the
`Requested` event in the transaction's receipt):

```sh
REQ=$(cast receipt $TX --rpc-url "$RPC" --json | jq -r --arg intake "$INTAKE" '.logs[] | select(.address | ascii_downcase == $intake) | .topics[1]')
cast logs --rpc-url "$RPC" --address $INTAKE --from-block $(cast receipt $TX blockNumber --rpc-url "$RPC") \
  "Completed(bytes32 indexed,uint8,bytes32,string,bool)" $REQ
```

`status` in that event is 0 for an answer, 1 for a refused request, 2 for no answer. `delivered` is
`false` here, because the request named no callback. The same three facts are in the Intake read
above, under `completion`, with the hash of the completing transaction once it has been sent. (A
free RPC node serves logs for roughly the last 9,000 blocks only, so read the event the same day.)

### Go or no-go

The conditions each proof was held to. A feed is **go** when all of these hold for its request:

1. The Intake read says `completed` and the `Completed` event has `status` 0. (For the proofs
   above: the Intake read gave status 0 with the completion still queued; see "What the proofs do
   not show".)
2. The oracle request's `status` is `attested`.
3. Its `questionHash` equals `QHASH`. This is the hash `Questions` computes on chain and requires of
   every answer, so a different hash here means the contract would refuse every answer.
4. `attestation.fromBlock` and `attestation.toBlock` equal `FROM` and `TO`, and
   `attestation.blockHash` equals `cast block $TO --field hash --rpc-url "$RPC"`.
5. `attestation.answerType` is `uint256` for payrolls and hires and `address[]` for employers.
6. `attestation.panelSize` is at least 7, `attestation.quorum` at least 5, and `attestation.agreed`
   at least `attestation.quorum`. The feeds accept only the panel's own agreement.
7. `signer` is `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, the address in the manifest.
8. For employers: `cast decode-abi "f()(address[])" <attestation.answer>` prints a list of exactly
   three addresses.

A feed is **no-go** when the request is `refused` (`status` 1: the body is not acceptable as
written), when the question hash differs (the hash rule in `QuestionBody.sol` no longer matches the
oracle's: do not launch), or when the request ends with no answer or with `agreed` below the
quorum twice running. The first employers body was a no-go of the third kind, and of a kind no
second try could cure, which is why the feed was rewritten and proven again.

**Launch A needs payrolls and hires to be go, and they are.** The Jobs Report is complete without
the employers feed: `print` never reads it, and `crown` is the only function that does.

## 6. The first day

Nothing is called by the launch pipeline after deployment, so the feeds do not exist until somebody
creates them. Every call below is open to anyone; none needs a privilege, and the team's wallet is
only the first to make them.

```sh
export QUESTIONS=...     # the three addresses the launch created, from its ContractsLaunched event
export JOBS_REPORT=...
export PAYROLL=...
export PAYROLLS=0x4bf83605cd50e9658472bde9be314bb3848a563301fa793328bef17ad2a07b61
export HIRES=0xfde22d9c1b97b7ce9763dff388a66366f9012d4ba7c57c3239377a75532bee4d
export EMPLOYERS=0x22ad8df0e0af07aa59e29aa7f5540e0022fbfda0651ccae3eccb968553a14835
```

Before anything else, read back what was deployed and compare it with section 2:

```sh
cast call $QUESTIONS "INTAKE()(address)" --rpc-url "$RPC"
cast call $QUESTIONS "IMD()(address)" --rpc-url "$RPC"
cast call $QUESTIONS "oracleSigner()(address)" --rpc-url "$RPC"
cast call $JOBS_REPORT "QUESTIONS()(address)" --rpc-url "$RPC"
cast call $PAYROLL "QUESTIONS()(address)" --rpc-url "$RPC"
cast call $PAYROLL "FEED_A()(bytes32)" --rpc-url "$RPC"    # payrolls; FEED_B hires; FEED_C employers
```

### Step 1. Create the three feeds

Three transactions to `Questions`, each with the calldata below as its whole input. The calldata is
`createFeed(params, qPrefix, tail)` for the feed's fixture file;
`test_runbook_documentedCalldataIsWhatTheFixturesGive` compares each block with the fixtures byte
for byte, and `test_runbook_documentedCalldataCreatesTheManifestFeeds` sends each to a fresh
`Questions` and gets the three ids of section 2. To print them again after a change:
`forge test --match-test test_runbook_printsTheCalldata -vv` (it prints, it sends nothing). To read
one before sending it:
`cast decode-calldata "createFeed((bytes32,uint64,uint8,uint16,uint16,uint16,uint32,uint32,uint32,uint16,bool,bool,uint96,uint96,uint8,address,uint256,bytes),bytes,bytes)" <calldata>`.

```sh
cast send $QUESTIONS <calldata> --rpc-url "$RPC" $WALLET
```

On a mainnet fork the three calls used about 892,000 gas (payrolls), 820,000 (hires) and 1,120,000
(employers); the fork suite logs them. Creating a feed that already exists returns its id and
changes nothing, so it does not matter who gets there first.

payrolls:

<!-- createFeed:payrolls -->
```text
0x8320d106000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000005a06f7261636c652e72657175657374406f7261636c652d310000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000151800000000000000000000000000000000000000000000000000000000000001b580000000000000000000000000000000000000000000000000000000000005460000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000001bc16d674ec8000000000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000240000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b77b22616e7377657254797065223a2275696e74323536222c22636861696e4964223a312c22646566696e6974696f6e73223a7b22726563697065223a227b5c226b696e645c223a5c226c6f672d73756d5c222c5c22616464726573735c223a5c223078643334613939626330663637616531626264363363363630653664306230646430336532363362375c222c5c226576656e745c223a5c226576656e74205472616e73666572286164647265737320696e64657865642066726f6d2c206164647265737320696e646578656420746f2c2075696e743235362076616c7565295c222c5c2273756d4172675c223a5c2276616c75655c222c5c226162735c223a66616c73652c5c2266696c7465725c223a7b5c22746f5c223a5c223078346530666135376264653732363037393335363533376532663334643637316539663431616462635c227d7d202d207772697465207265636970652065786163746c7920746869732c206576656e74207465787420696e636c756465642e227d2c227175657374696f6e223a2257686174206973207468652073756d206f66207468652076616c756520617267756d656e74206f66206576657279205472616e73666572286164647265737320696e64657865642066726f6d2c206164647265737320696e646578656420746f2c2075696e743235362076616c756529206576656e7420656d69747465642062792074686520746f6b656e20636f6e7472616374203078643334613939626330663637616531626264363363363630653664306230646430336532363362372077686f736520746f20617267756d656e742069732030783465306661353762646537323630373933353635333765326633346436373165396634316164626320696e207468652077696e646f773f222c2276223a312c2277696e646f77223a7b2266726f6d426c6f636b223a00000000000000000000000000000000000000000000000000000000000000000000000000000000562c2265766964656e6365223a22636861696e222c2270616e656c53697a65223a372c2271756f72756d223a352c22746f6c6572616e6365427073223a302c2276616c6964466f725365636f6e6473223a38363430307d00000000000000000000
```

hires:

<!-- createFeed:hires -->
```text
0x8320d106000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000005606f7261636c652e72657175657374406f7261636c652d310000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000151800000000000000000000000000000000000000000000000000000000000001b580000000000000000000000000000000000000000000000000000000000005460000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000001bc16d674ec8000000000000000000000000000000000000000000000000000000b1a2bc2ec5000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000026f7b22616e7377657254797065223a2275696e74323536222c22636861696e4964223a312c22646566696e6974696f6e73223a7b22726563697065223a227b5c226b696e645c223a5c226c6f672d636f756e745c222c5c22616464726573735c223a5c223078643334613939626330663637616531626264363363363630653664306230646430336532363362375c222c5c226576656e745c223a5c226576656e74205472616e73666572286164647265737320696e64657865642066726f6d2c206164647265737320696e646578656420746f2c2075696e743235362076616c7565295c222c5c2266696c7465725c223a7b5c22746f5c223a5c223078346530666135376264653732363037393335363533376532663334643637316539663431616462635c227d7d202d207772697465207265636970652065786163746c7920746869732c206576656e74207465787420696e636c756465642e227d2c227175657374696f6e223a22486f77206d616e79205472616e73666572286164647265737320696e64657865642066726f6d2c206164647265737320696e646578656420746f2c2075696e743235362076616c756529206576656e7473206469642074686520746f6b656e20636f6e74726163742030786433346139396263306636376165316262643633633636306536643062306464303365323633623720656d69742077686f736520746f20617267756d656e742069732030783465306661353762646537323630373933353635333765326633346436373165396634316164626320696e207468652077696e646f773f222c2276223a312c2277696e646f77223a7b2266726f6d426c6f636b223a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000562c2265766964656e6365223a22636861696e222c2270616e656c53697a65223a372c2271756f72756d223a352c22746f6c6572616e6365427073223a302c2276616c6964466f725365636f6e6473223a38363430307d00000000000000000000
```

employers:

<!-- createFeed:employers -->
```text
0x8320d106000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000007206f7261636c652e72657175657374406f7261636c652d31000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000015180000000000000000000000000000000000000000000000000000000000000bf68000000000000000000000000000000000000000000000000000000000000c4e0000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000001bc16d674ec8000000000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000240000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004367b22616e7377657254797065223a22616464726573735b5d222c22636861696e4964223a312c22646566696e6974696f6e73223a7b226d6574686f64223a225265616420746865205472616e73666572286164647265737320696e64657865642066726f6d2c206164647265737320696e646578656420746f2c2075696e743235362076616c756529206c6f677320656d697474656420627920307864333461393962633066363761653162626436336336363065366430623064643033653236336237206f6e20457468657265756d206d61696e6e657420696e2074686520626c6f636b2077696e646f772c206b6565702074686f73652077686f736520746f206973203078346530666135376264653732363037393335363533376532663334643637316539663431616462632c206164642075702076616c7565207065722066726f6d20616464726573732c206f72646572206279207468617420746f74616c2066726f6d206c61726765737420746f20736d616c6c6573742077697468207469657320627920617363656e64696e6720616464726573732c20616e6420616e73776572207468652066697273742033206164647265737365732e222c22736f75726365223a22457468657265756d206d61696e6e6574206576656e74206c6f6773206f6e6c792c20726561642066726f6d20616e792066756c6c206e6f64652e204e6f2077656273697465206f7220696e6465782e227d2c2265766964656e6365223a2270616e656c222c2268656164223a332c227175657374696f6e223a225768696368207468726565206164647265737365732073656e7420746865206d6f737420494d442028746f6b656e20636f6e7472616374203078643334613939626330663637616531626264363363363630653664306230646430336532363362372920746f20307834653066613537626465373236303739333536353337653266333464363731653966343161646263206f6e20457468657265756d206d61696e6e657420696e207468652077696e646f773f2052616e6b2073656e64657273206279207468652073756d206f662076616c7565206f766572205472616e73666572286164647265737320696e64657865642066726f6d2c206164647265737320696e646578656420746f2c2075696e743235362076616c756529206576656e7473206f66207468617420636f6e74726163742077686f736520746f20617267756d656e74206973203078346530666135376264653732363037393335363533376532663334643637316539663431616462632c2067726f757065642062792066726f6d3b20616e737765722065786163746c792074686520746f702033206164647265737365732c206c6172676573742066697273742c207469657320627920617363656e64696e6720616464726573732e222c2276223a312c2277696e646f77223a7b2266726f6d426c6f636b223a0000000000000000000000000000000000000000000000000000000000000000000000000000000000322c2270616e656c53697a65223a372c2271756f72756d223a352c2276616c6964466f725365636f6e6473223a38363430307d0000000000000000000000000000
```

Check: `cast call $QUESTIONS "feedCount()(uint256)" --rpc-url "$RPC"` is 3 and
`cast call $QUESTIONS "costOf(bytes32)(uint256)" $PAYROLLS --rpc-url "$RPC"` is 550000000000000000
(the price of 0.5 IMD plus the tip of 0.05).

### Step 2. Fund the meters

A request costs the meter 0.55 IMD: 0.5 to the Intake, never refunded, and 0.05 set aside as the
keeper's tip, which comes back to the meter if the round fails. Until Payroll has revenue, the
meters are funded from a wallet. One runway is 14 requests for each daily feed (7.7 IMD) and 4 for
the weekly one (2.2 IMD): 17.6 IMD in all.

```sh
cast send $IMD "approve(address,uint256)" $QUESTIONS 17600000000000000000 --rpc-url "$RPC" $WALLET
cast send $QUESTIONS "fund(bytes32,uint256)" $PAYROLLS  7700000000000000000 --rpc-url "$RPC" $WALLET
cast send $QUESTIONS "fund(bytes32,uint256)" $HIRES     7700000000000000000 --rpc-url "$RPC" $WALLET
cast send $QUESTIONS "fund(bytes32,uint256)" $EMPLOYERS 2200000000000000000 --rpc-url "$RPC" $WALLET
```

The funder holds shares of each meter and can take back whatever the meter has not spent, at any
time, with `defund(bytes32,uint256)`; `type(uint256).max` as the share count takes everything.
Later, 20% of what Payroll books becomes feed budget, and `fundFeeds()` puts a runway of Payroll's
own on each meter. Payroll counts only its own position, not what the wallet holds there, so the
wallet's IMD is needed only until Payroll has budget, and can be withdrawn whenever the wallet
likes.

All three proof requests were go (section 5), so all three meters are funded.

### Step 3. The first requests

Each request is a transaction of its own. Never batch two, and never send one through a contract
that also buys from the Intake in the same transaction: IdentityMD's service serves only the first
request of a transaction. A request that is not served costs the meter 0.5 IMD, and its round
stays open, with the feed unable to ask again, until somebody hands an answer in (payrolls and
hires only, from thirty minutes after the request) or closes it (36 h 5 min 1 s after the request).

Send payrolls and hires so that they land in the same block (two transactions, consecutive nonces):
their windows are then identical and every count is exact for its print's period.

```sh
cast call $QUESTIONS "canRequest(bytes32)(bool,uint8,uint256,uint64,uint64)" $PAYROLLS --rpc-url "$RPC"
cast send $QUESTIONS "request(bytes32)" $PAYROLLS  --rpc-url "$RPC" $WALLET
cast send $QUESTIONS "request(bytes32)" $HIRES     --rpc-url "$RPC" $WALLET
cast send $QUESTIONS "request(bytes32)" $EMPLOYERS --rpc-url "$RPC" $WALLET
```

`canRequest` returns whether a request would go through and, if not, why (the second value: 0 none,
1 unknown feed, 2 already asked in this transaction, 3 round pending, 4 too soon, 5 no blocks, 6
gate closed, 7 not sold, 8 price above the cap, 9 meter too low). On a mainnet fork, against the
live Intake (version 2), a first request used about 423,000 gas (payrolls), 418,000 (hires) and
451,000 (employers).

### Step 4. The answers

The Intake's writer delivers each answer by calling `onOracleResult` on `Questions`. Nobody has to
do anything. The oracle answered our three proofs in one to five minutes; the writer's call can
come much later (on 13 October 2026 we saw one arrive four hours after its request). While
`https://api.imd.fun/intake/1/<transaction>` shows a request as `completing`, its answer exists and
is on its way: do not close that round. A payrolls or hires answer does not have to wait for the
writer: from thirty minutes after the request anyone may hand it in (section 7). An employers
answer does have to wait, and the writer has the full silence deadline and its signed validity. To see an answer arrive:

```sh
cast call $QUESTIONS "latest(bytes32)(uint256,uint64,uint64,uint64,uint64)" $PAYROLLS --rpc-url "$RPC"
cast call $QUESTIONS "feedState(bytes32)((bool,uint64,uint64,uint64,uint64,uint8,bool,bytes32,uint64,uint256,uint256,uint256,uint8))" $PAYROLLS --rpc-url "$RPC"
```

### Step 5. Print, and crown

```sh
cast send $JOBS_REPORT "print()" --rpc-url "$RPC" $WALLET
cast call $JOBS_REPORT "printCount()(uint256)" --rpc-url "$RPC"
```

`print` copies every newly answered payrolls and hires round into the report. It never reads the
employers feed. When an employers round has an answer, anyone may publish its top three by handing
in the attested list, which the contract checks against the hash `Questions` stored:

```sh
# ANSWER is attestation.answer from https://api.imd.fun/oracle/requests/<id> for that round
cast send $JOBS_REPORT "crown(uint64,bytes)" 1 $ANSWER --rpc-url "$RPC" $WALLET
```

## 7. Every day after

A keeper is any account that makes these calls. It needs ETH for gas and nothing else; no call
below takes IMD from the keeper. All of them can be made by several keepers at once: the second
caller's transaction reverts or does nothing.

| When | Call | Notes |
|---|---|---|
| Once a day (every 7,000 blocks, 23 h 20 min) | `Questions.request(PAYROLLS)` and `Questions.request(HIRES)`, two transactions for the same block | Ask `canRequest` first. Each answered round earns the caller 0.05 IMD. |
| After each answer | `JobsReport.print()` | Free of any condition; a call with nothing new changes nothing. |
| Once a week (every 49,000 blocks) | `Questions.request(EMPLOYERS)`, then `JobsReport.crown(round, answer)` once it is answered | Optional: the report is complete without it. |
| About once an hour | `Payroll.drip()` | `stream()` returns `dueNow`; call when it is not zero. It is zero inside the ten-minute gap and while sIMD has no stakers, the two cases in which the call would revert. An hourly drip keeps pace with vesting. |
| When IMD reached Payroll by plain transfer | `Payroll.book()` | `unbooked()` says how much is waiting. |
| When Payroll's position on a meter is below its runway, and at least once a fortnight | `Payroll.fundFeeds()` | `feedShortfalls()` says what each meter would be offered. This is also the only call that releases feed budget whose wait is over, after it has served the meters: `feedBudget()` shows that amount as `releasableNow`. |
| Thirty minutes after a payrolls or hires request, if its answer has not been stored | `Questions.submit(feedId, attestation, signature)` | `canSubmit` returns true. Hands in the oracle's signed answer without waiting for the Intake's writer; see below this table. The opener keeps the round's tip. |
| When a round will not be answered | `Questions.abandon(feedId)` | `canAbandon` returns the step: 1 means a first call that only starts a 30-minute wait, 2 means the call closes the round. 36 h 5 min 1 s after the request, and not before, one call always closes it. Not while the Intake's service still shows the request as `completing`: an answer that arrives after the round was closed is refused. |
| When it likes | `Questions.collectTips()` | Pays the caller the tips it has earned. `tipsOf(address)` shows earned and pending. |

A round the Intake completed without an answer (refused, or the panel did not agree) takes two
`abandon` calls thirty minutes apart, or one call 36 h 5 min 1 s after the request. After a failed
round the feed waits twice as long before it may ask again, four times after two in a row, up to
32 times; the first answer puts the cadence back.

A payrolls or hires round does not have to wait for the Intake's writer, and a round the service
never served can be rescued instead of abandoned. Thirty minutes after the request
`canSubmit(feedId)` turns true, and anyone who holds an answer the oracle signed for `Questions` to
the round's question can hand it in with `submit(feedId, attestation, signature)`. That answers the
round, leaves the cadence as it was, and credits the opener's tip. Anyone may help deliver the
answer; the submission itself has no separate reward. There are two cases:

- *The request was served and the writer is late.* The Intake read of section 5 shows the request
  as `completing` and names the oracle request (`admission.result.requestId`);
  `https://api.imd.fun/oracle/requests/<id>` holds its `attestation` and `signature`. We have not
  yet done this with a request of the launched contract: the proof requests named no callback, so
  their answers were signed for no consumer (`docs/THREATS.md`, section 9).
- *The request was never served.* There is no answer to fetch. Anyone who buys the same body from
  the oracle over HTTP, with `consumer` set to `{chainId: 1, verifyingContract: <Questions>}`, gets
  one. The exact body of the pending round is in the Intake's `Requested` event for it; `roundOf`
  gives its window and `roundRequest` its question hash.

`submit` takes the attestation's fields in the order of the struct in
`src/questions/OracleAttestation.sol`, with `answerType` as its code (3 for `uint256`).

That exists for payrolls and hires only. The employers feed is judged by a panel, and `Questions`
refuses `submit` for such a feed: only the Intake's own callback can answer its rounds, and it has
the full silence deadline and its signed validity. An employers round that is not delivered in that time can be closed by anyone; it
then fails, costs its meter the price, and doubles the feed's wait.

Seat owners and their agents are paid to whoever owns the seat at the moment of the claim: `Payroll.claimSeat(tokenId)`, `claimSeats(tokenIds)` (at most 200 ids per call) and
`claimTip(agentId)`. Anyone may initiate claims for an ordinary wallet. A contract holding a
seat must initiate its own claims, except that anyone may recycle Payroll's own share. Batch
claims skip other contract holders. A passive escrow leaves the funds owed until the seat moves
to a holder that can claim; claims never select an arbitrary recipient.

## 8. What can go wrong on the day, and what happens then

| Event | What the contracts do |
|---|---|
| Nobody creates a feed | `fund` reverts for that feed, Payroll skips it (`costOf` is zero), the report stays empty. Payroll's feed budget waits 14 to 28 days and then goes to stakers. Nothing is lost. |
| A feed's body is refused by the oracle, or its panel does not agree | Each request costs its meter 0.5 IMD and the round fails. The back-off slows the spending. Funders can take the rest out at any time. Section 5 found this out for the first employers body before launch, for 0.5 IMD. |
| The employers feed never answers | The Jobs Report is unaffected. Its meter holds at most 2.2 IMD of Payroll's budget at a time. Its rounds cannot be rescued with `submit`. |
| The Intake's writer delivers an answer hours late | The round stays pending and the answer is stored when it comes, as long as nobody has closed the round: anyone may, 36 h 5 min 1 s after the request. For payrolls and hires anyone can hand the answer in from thirty minutes on instead. |
| The Intake's writer is later than the full silence deadline with an employers answer | Anyone may close the round. The answer is then refused when it comes, the meter has paid for it, and the feed waits two cadences before it asks again. No `submit` can make up for it. |
| The service never serves a request | The feed cannot ask again while the round is pending. A payrolls or hires round can be answered through `submit` from thirty minutes on; any round can be closed 36 h 5 min 1 s after the request. |
| Nobody calls `fundFeeds` | Payroll's positions on the meters are not topped up, and feed budget whose wait is over stays in Payroll. Nothing is lost: the first call does both. |
| The Intake's price rises above 2 IMD | Requests stop (`canRequest` says price above the cap) until it falls. Meters stay redeemable. |
| IdentityMD rotates the oracle signer or replaces the Intake | No new answer is accepted. Rounds fail and back off; meters stay redeemable; Payroll's other functions are unaffected. The three contracts must be launched again to resume the feeds. |
| The Intake's callback gas is lowered below what the callback needs | The answer is not stored by the callback. For payrolls and hires anyone can hand it in with `submit`; an employers round fails. The callback used 116,622 gas at most in our tests, against 200,000 today. |
