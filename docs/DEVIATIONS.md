# Where this launch departs from IdentityMD's guidance, and why

IdentityMD publishes guidance for contracts that buy oracle answers (the oracle-consumer skill and
its reference contracts `OracleAttestation.sol`, `OracleIntakeConsumer.sol` and the conformance
test) and for contracts-only launches (the `evm_contracts` launch skill). This document lists every
place where the three contracts do something else, the reason, and what the choice costs. A reader
who disagrees with a reason has the whole trade in front of them.

What is followed without change comes first, because it is the larger part.

## Followed as written

- `src/questions/OracleAttestation.sol` is the protocol's library and base contract, copied byte
  for byte. The attestation struct, the type string and the EIP-712 domain (`IdentityMD Oracle`,
  version `2`, this chain, this contract) are the protocol's.
- `test/questions/OracleConsumerConformance.t.sol` is the protocol's conformance test, in the text
  delivered with version 2 of the Intake, with only its imports and the way the consumer is
  deployed adapted (a script writes it from the reference and can check it:
  `test/fixtures/questions/tools/build_conformance.py`). It passes: our verification reproduces the
  protocol's digest and accepts the protocol's signature.
- The Intake in the manifest is version 2 (`0xa43e6f75ee006411f79ac1c84120606c2330de82`), the one
  the guidance names for anything new.
- The callback has the protocol's parameter types and selector (`0x510379c7`), accepts calls from
  the Intake only, only for a request this contract made and has not settled, verifies and stores,
  and acts on nothing. A "no", a zero and an empty list are stored, not reverted. It used at most
  116,622 gas in our tests against the 200,000 it is given.
- The contract approves exactly the live price inside the call that asks, and promises no refund.
- Every constructor is nonpayable, takes only static arguments (at most nine), makes no external
  call and checks no code size. Nothing is called after deployment. There is no proxy, no
  initializer, no pausing and no minting, and no DELEGATECALL, CALLCODE or SELFDESTRUCT.

## D1. No owner, so nothing is owner-settable

**Guidance.** "Every one of these is constructor input and owner-settable, never a constant: the
intake, the delivery contract, the action id, the asset and price (set together), the signer. A new
action version or a moved price must not need a redeploy." The reference consumer is `Ownable` and
has `setIntake`, `setSigner`, `setAction`, `setPayment`, `setBody`, `setFailureHook` and `withdraw`.
The launch skill fills owner roles with `$owner`.

**What we do.** None of the three contracts has an owner, and the manifest has no `$owner`. In
`Questions` the Intake, the IMD token and the oracle signer are constructor arguments and stay
fixed. What has to move with the protocol is read when it is needed instead of being set by
somebody:

- the price is read from `Intake.priceOf` at every request, under a cap each feed sets for itself
  (2 IMD on the house feeds), so a moved price needs no redeploy while it stays under the cap;
- the action id is a parameter of each feed, so a new action version is used by creating new
  feeds, with no change to `Questions`.

**Why.** An owner who can replace the signer can make any feed say anything, and an owner who can
replace the Intake or call `withdraw` can take the meters' IMD. This product's claim is that
nobody can. A key held by us would be the largest risk in the launch, and the easiest one to
remove.

**What it costs.** If IdentityMD rotates the oracle signer, replaces the Intake, or raises the
price above a feed's cap for good, the feeds stop getting answers. No money is lost when that
happens: rounds fail and back off, every funder can take back what a meter has not spent, and
Payroll's other functions do not depend on `Questions`. To resume, the three contracts have to be
launched again; feed ids are content-addressed, so the same feeds have the same ids in a new
`Questions`, but `JobsReport` starts a new record. The same holds if the signer's account ever gets
code: signatures are then checked through ERC-1271 and plain signatures stop verifying.

A new action version is only half covered: new feeds can use it, but `JobsReport` and `Payroll` are
bound to the three feed ids in their constructors and would need a new launch to follow new feeds.

## D2. No failure hook, although the Intake is version 2

**Guidance.** "Use version 2 for anything new: it has everything version 1 has, plus
`requestWithFailure`." Version 2 can call a second function on the callback target when a request
is refused or ends without an answer: `onOracleFailure(requestId, status, reason, agreed,
answered, signature)`. The reference consumer implements it behind an owner-set `failureHook` flag.
And: "every pending request still needs a deadline after which its requester can clear it: a
failure call can run out of gas or never come."

**What we do.** `Questions` is launched against version 2 and asks with plain `request`, as it would
against version 1. It names no failure function and has no `onOracleFailure`. Every pending round
has a deadline instead: `abandon` closes it after the request plus twelve hours, the feed's
`validFor`, five minutes of clock tolerance and one second, or thirty minutes after the Intake's completion of the request was first seen with nothing
stored. Anyone may call it, not only the requester. And for the two daily feeds anyone may `submit`
the answer the callback missed or has not brought, from thirty minutes after the request.

**Why.**

- `abandon` and `submit` already cover every case the failure call would. A refused request and a
  request whose panel did not agree are completed by the Intake with status 1 or 2; `abandon` reads
  that completion from `Intake.requests(id)` (the fourth field, `completed`, which version 2 keeps
  exactly as version 1 had it) and closes the round. A request that is never completed is closed
  by the full silence deadline, which a failure call could not replace: the guidance itself says the
  deadline is still needed.
- The failure call is unsigned. The guidance: "the values are unsigned: never move money on them",
  and "until failures are signed, `reason`, `agreed` and `answered` are the writer's word". Closing
  a round returns its tip to the meter and doubles the feed's wait, and a failure call acted on at
  once would do both the moment the writer said so. `abandon` gives the writer's word less: its
  completion of a request starts thirty minutes in which, for the daily feeds, anyone can still
  hand in the real answer, and only then may the round be closed; the full silence deadline needs
  nobody's word at all.
- The original build was 22,963 bytes against our gate of 23,000. A second entry point
  for the Intake adds a sender check, lookup and event, and we would not trade a view or a check away for a message `abandon` does not need.
- The flag in the reference is owner-set, and there is no owner (D1).

**What it costs.** A refused or unanswered request needs an `abandon` call to notice it.
The house feeds' full silence deadline is now 36 h 5 min 1 s, following the launch audit; the
extra time preserves a timely signed answer's validity. Pending rounds can delay the next daily
request. An oracle signing later than the twelve-hour allowance, or a writer missing the full
deadline, can still lose an answer after closure (`docs/THREATS.md`, Q8). Nobody is told the
failure reason on chain here; it is in the Intake's event and the service's API.

**Shown by.** `test_fork_houseFeedBuysARealRequestAndTakesTheCallback` (after our request the live
version 2 Intake holds no failure selector for it), `test_fork_abandonReadsTheLiveIntake` (the
writer completes with status 2 and the failure's arguments: nothing is called, `abandon` reads the
completion and closes the round), `test_launch_stateChangingFunctionsAreExactlyTheDocumentedOnes`
(`Questions` has no entry point beyond the documented ten).

## D3. An answer is marked used per feed, not per contract

**Guidance.** "`a.requestId` is the oracle request's UUID … Consume one of them, once." The base
contract offers `_consume`, one flag per request id for the whole contract.

**What we do.** `_consume` is not called. `Questions` keeps the mark per feed
(`usedBy[oracleRequestId][feedId]`) and still sets the base contract's `consumed` flag, so a reader
and the conformance test see that the attestation was acted on.

**Why.** `Questions` holds many feeds, and anyone can create a feed with the same question as
another. With one flag for the contract, handing a feed's answer to a copy of that feed made the
feed that paid for it lose it (found by our first reviewer, reproduced, and fixed this way).

**What it costs.** One attestation can answer one round of each of two feeds that asked the same
question about the same blocks. Each paid for a request of its own.

## D4. `agreed` is checked against a floor each feed chooses

**Guidance.** "Require `agreed >= quorum` and that the panel and quorum are at least what the
contract asked for."

**What we do.** The panel and quorum floors are enforced as written. For `agreed`, a feed created
with `minAgreed` equal to its quorum gets exactly the guidance's rule. A feed may instead choose a
lower `minAgreed`, down to 1, to also accept a chain-evidence answer that the oracle settled by
rerunning the members' recipe when their answers split.

**Why.** The protocol documents that case (`agreed` below `quorum` only for chain evidence), and a
feed about plain chain facts may want it. **The three house feeds do not use it**: their
`minAgreed` is their quorum. For the employers feed, which a panel judges, nothing else would make
sense: there is no rerun to settle a split, so the panel's own agreement is the whole answer.

## D5. `submit` is narrower than the guidance's, and wider in one way

**Guidance.** "If your callback reverted … give the contract a public `submit` that takes the same
attestation, so anyone can hand it over again."

**What we do.** `submit` exists, with three conditions the guidance does not have. The feed must pin
its question hash. The question must not be one a panel judges. And the Intake must have completed
the round's own request, or thirty minutes must have passed since the request. It is wider in two
ways. It takes any attestation the oracle signed for this contract to the same question about the
same blocks, not only the one that answered the feed's own request. And after those thirty minutes
it does not wait for the callback to have failed: it also takes an answer the Intake's writer has
simply not delivered yet.

**Why.** Nothing on chain ties an attestation to the request a round paid for (the attestation's
id is the oracle's, not the Intake's), so "the same attestation" cannot be enforced. The three
conditions are what bounds that: the callback goes first, for thirty minutes or until the Intake
has completed the request, and `submit` is closed for any question a panel judges. The thirty
minutes exist for a request the service never serves, which could otherwise only fail, and for an
answer the oracle has signed that the Intake's writer is late to deliver: on 13 October 2026 the
oracle answered within minutes and the writer was hours behind it (`docs/THREATS.md`, Q8).

**What it costs.** See `docs/THREATS.md`, Q3 and Q4: thirty minutes can be less than the oracle
itself takes. The opener now keeps the tip even when another account submits, including a
separately purchased matching answer: no on-chain field links its oracle UUID to the Intake id. One of the three house feeds pays the second condition's price: the employers feed is
judged by a panel (D10), so no answer to it can ever be handed in, and a round whose callback is
missed or comes after closure at the full silence deadline fails.

## D6. The question hash is built on chain from a rule we reconstructed

**Guidance.** "`questionHash` covers the question, the resolved block window and the definitions,
so a contract cannot compute it in advance when the window is relative. The pairing of an answer to
the intake request is the writer's."

**What we do.** Feeds ask with an explicit `{fromBlock, toBlock}` window, never a relative one, and
`Questions` computes the hash an answer must carry from the feed's own stored text
(`QuestionBody.sol`). An answer to any other question is refused. The pairing is therefore not left
to the writer.

**Why.** It is what lets a contract trust an answer without trusting who delivered it.

**What it costs.** The exact rule (keccak-256 of the canonical JSON of the question document, with
`definitions`, `evidence` and `head` present only in certain cases) is not published as a contract.
We reconstructed it and checked it against 23 attested requests and three bodies read back from the
Intake's events (`test/questions/QuestionHashFixtures.t.sol`). If the oracle changes the rule, a
feed that pins its hash refuses every answer from then on. The guidance now names a function of the
protocol's own package for the same computation (`oracleQuestionHash`, for an absolute window);
ours is the on-chain equivalent. The three proof requests of `docs/LAUNCH.md`, section 5, checked
the rule once more against the live oracle on 12 and 13 October 2026, for each house feed's own
text, with `definitions`, `evidence` and `head` in the hashed document: the hash built on chain was
the hash attested, three times out of three (`test/questions/HouseFeedProofs.t.sol`).

## D7. A feed's text is its creator's, not validated as JSON on chain

**Guidance.** "User text is untrusted. Validate it as UTF-8 and bound its length. JSON-escape it so
the body stays valid."

**What we do.** A request body is the feed's stored prefix, two block numbers written by the
contract, and the feed's stored tail. Nothing a caller of `request` supplies enters the body.
`createFeed` checks what it can: the prefix must begin with the feed's answer type and chain in
canonical form and end at the window; the tail must state the feed's panel size, quorum and
validity; the whole body must fit the Intake's 16,384 bytes. It does not parse the text as JSON.

**Why.** There is no template of ours that a user's text is inserted into: the whole question is
the feed creator's. A body that is not valid JSON is refused by the oracle, which costs that feed's
own funders and nobody else.

**What it costs.** A feed can be created whose every request is refused. `docs/THREATS.md`, Q11.

## D8. Same chain only

**Guidance.** A consumer may receive an answer on another chain through `IntakeDelivery`.

**What we do.** `Questions` accepts the callback from the Intake on its own chain only, and a feed
must be about the chain the contract is on. Block windows are counted in this chain's blocks and
the closing block's hash is read from this chain.

**Why.** Checking the closing block hash against the chain itself is one of the checks an answer
must pass; it has no equivalent for another chain.

## D9. No gas snapshot file

The pipeline's gas-and-size step writes `.gas-snapshot` and `artifacts/gas.md` itself. This
repository ships neither. Its measured sizes and gas figures are in `docs/LAUNCH.md` and
`README.md`, each beside the test that prints it.

## D10. One house feed rests on the panel's agreement, not on a recipe the oracle reruns

**Guidance.** "`evidence` `"panel"` for facts that are not on a chain, `"chain"` (the default) for
facts a recipe can reproduce from blocks." And, of any answer: "The truth of an answer is the
panel's, and its signature is one hot key's. Treat it as a strong signal for moderate value." The
brief of this build said the launch feeds use chain-evidence recipes only.

**What we do.** Payrolls and hires are chain evidence with a pinned recipe. The employers feed asks
a question about the chain, which addresses sent the fee payee the most IMD in seven days, with
`evidence` `panel`. The method is written out in the question's `definitions`; the oracle signs
what at least five of seven panel members agreed on and does not rerun anything.

**Why.** It is the only way the oracle will answer it. The fact is on the chain, but no recipe the
oracle offers reproduces it: its ranking recipe (`log-rank`) takes no filter, so it cannot rank
senders among the transfers to one recipient. We found that out by buying the request
(`docs/LAUNCH.md`, section 5): the panel agreed, the oracle's rerun without the filter did not
reproduce the panel, and nothing was signed. The same question with `evidence` `panel` was attested
on the first try, with the same three addresses.

**What it costs.** IdentityMD does not recompute this feed's answers, and `submit` is closed for it.
`docs/THREATS.md`, F4, says what that means and what depends on it: the weekly list of three and
nothing else. The Jobs Report prints without it, no money moves on it, and Payroll funds it last.
