# Launch adaptation

The three contracts remain `Questions`, `JobsReport`, and `Payroll`, in that order, with the
constructor arguments supplied in `docs/LAUNCH.md`. No constructor or feed id changed. There is
no launch token, owner, admin, setter, proxy, initializer, or post-deployment configuration call.
The constructors remain nonpayable, use static arguments, and make no external call or code
check. No deployment or broadcast was attempted; IdentityMD's deployment stage performs that
step. No `launch.json` was written.

No factory-compatibility source change was needed. The source changes below address the audit
supplied with this assignment. Existing compiler configuration, dependencies, and protocol
attestation code were retained.

## Imported audit: reproduction and disposition

### `2ab3a604a08ad2228fab5998880e3954c9693a2cd07625237b196ddffff1add9` — keeper tip

Reproduced. Before the change, a different account submitted the public signature at thirty
minutes and received the opener's 0.05 IMD tip. The regression failed with
`opener lost its tip: 0 != 50000000000000000`.

In `src/questions/Questions.sol`, both callback and submission now settle the reserved tip to
the recorded opener. The internal `earner` parameter and its alternate recipient were removed.
`RoundAnswered.deliveredBy` still records the actual caller, while the recipient is always the
keeper from `RoundOpened`. Failed rounds still return their tip to the meter; no tip is paid
merely for asking, and no tip can be collected twice.

Tests: `test/questions/QuestionsLaunchAudit.t.sol`, `QuestionsTips.t.sol`,
`QuestionsRequest.t.sol`, and the tip conservation model in `QuestionsInvariant.t.sol`.
The supplied standalone proof was also copied to disposable `test/scratch/` for checking.

Trade-off: submission earns no separate reward. The oracle's UUID differs from the Intake id,
so the contract cannot distinguish the paid round's answer from another matching purchase.
An opener therefore also keeps the tip if its unserved request is rescued with a separately
bought answer. The existing regression for that case now explicitly asserts this rule.

### `a89a358156234a1e39fb3109849d6cf4ce08ac46b592e396e86b54c462b96f8c` — premature closure

Reproduced. A stranger could close an unfinished panel-evidence round at exactly twelve hours,
before a still-valid answer was delivered. The regression failed with
`observer discarded an unfinished request at twelve hours`.

In `Questions.sol`, the silence path in `_abandonStep` now waits until:

```text
requestedAt + ABANDON_AFTER_SILENCE + feed.validFor + ISSUED_AT_TOLERANCE + 1
```

The existing twelve hours allow for signing, followed by the full requested answer validity,
five minutes of permitted signing-clock skew, and one second for inclusive signature expiry.
For all three house feeds the deadline is **36 hours, 5 minutes, 1 second** after the request.
`abandon` and `canAbandon` share this calculation. A completed request still has the existing
thirty-minute recovery wait, capped by the full silence deadline. An unavailable Intake still
cannot prevent eventual abandonment.

Tests: the original twelve-hour sequence, the actual employers feed through signed expiry,
and 256 fuzz cases over the 60-second to 30-day validity range, checking expiry, expiry + 1,
views, callback delivery, tip return, and failure accounting. Existing boundary, failed-Intake,
backoff, meter, invariant and integration tests use the full deadline. The two fork tests that
assert the deadline were updated to the same formula.

This fixes the supplied timing reproduction and extends protection to answers signed within
the twelve-hour allowance. It is not an unbounded delivery guarantee: an oracle that signs
later, or a writer that delivers after the full deadline, can still lose an answer once the
round is closed. The Intake exposes neither a pending attestation nor its expiry. A finite
recovery deadline is retained so an unavailable service cannot block a feed forever. The longer
wait can delay the next daily request. Funders can redeem unspent meter balances throughout.

### `a7e63b8cd49ce710626abdf17f56d942258adc4ff83bef72afb48e1ce6d3496d` — fixed signer

Reproduced as the explicitly requested immutable dependency, and retained. A different key is
rejected; adding non-ERC-1271 code to the configured signer makes plain signatures fail. Tests
in `QuestionsLaunchAudit.t.sol` verify `BadSignature`, no replay consumption, a failed Intake
delivery, and continued redemption of unspent meter funds.

This informational report itself says it is not a defect against the brief. Its proposed signer
rotation authority would contradict the explicit absence of an owner, admin or setter, and the
fixed manifest. `src/questions/OracleAttestation.sol` remains the supplied canonical protocol
code. Signer rotation requires a new launch; no alternate key, registry, or authority was
invented. More precisely, code on the signer invokes ERC-1271: compatible validating code can
still accept signatures, whereas arbitrary code or a delegation without ERC-1271 support cannot.

### `4e16393fe68cb7416e2ffc990c13676dedd8c9ddc6eb564df32006fcbf83378f` — escrow claims

Reproduced with a deployed contract that cannot release ERC-20 funds. Before the change,
`claimSeat`, `claimSeats`, and `claimTip` each paid that escrow at an observer's request.
All three new protection assertions failed against the original source.

In `src/payroll/Payroll.sol`, `_claimAllowed` permits ordinary-wallet claims by anyone, and
requires a contract holding the seat to initiate its own claim. Single claims revert
`ContractOwnerMustClaim`; batch claims skip that seat and pay the others. Payroll's existing
self-owned-seat recycling remains permissionless because its recipient is the same contract
and the amount becomes bookable revenue. No arbitrary payout address or new state-changing
entry point was added.

Tests in `test/payroll/PayrollLaunchAudit.t.sol` cover all three forced-payment paths, restored
ownership and later payment, active contract-wallet claims, mixed batches, and protection from
sweeping while escrowed. `PayrollSeats.t.sol` retains the current-wallet-owner behavior test;
its former alleged escrow used an address without code, so the new regression uses an actual
deployed escrow instead. `src/interfaces/IPayroll.sol` changed only its claim documentation.

Unclaimed amounts still follow the NFT rather than its former economic owner. Delegated EOAs
have code and must initiate their own claims. Code checks cannot identify code still under
construction or a future contract address; those cases do not receive this escrow protection.

## Documentation and checks

`README.md`, `docs/LAUNCH.md`, `docs/THREATS.md`, `docs/DEVIATIONS.md`, and the affected NatSpec
now describe the opener's tip, full silence deadline, contract-holder claims and their limits.
`docs/AUDITS.md` links this adaptation while retaining the historical reports. The launch
manifest, addresses, feed definitions and their checked fixture blocks were not changed.

No imported report was dismissed as non-reproducible. The fixed-signer report is deliberately
retained under the brief's explicit ownership constraint; the bounded-timeout limitation is
stated above. No broader protocol redesign was made.

The unchanged compiler settings are solc 0.8.26, Cancun, optimizer 200 runs, via IR,
`bytecode_hash = "none"`, and no CBOR metadata. A separate size build with those settings reports:

| Contract | Runtime bytes | Initcode bytes | Initcode including arguments |
|---|---:|---:|---:|
| Questions | 22,233 | 23,642 | 23,738 |
| JobsReport | 9,320 | 9,618 | 9,746 |
| Payroll | 11,846 | 12,560 | 12,848 |

The project gates remain 23,000 runtime bytes and 46,000 initcode bytes; none was relaxed.
The canonical attestation source was compared byte for byte with the supplied reference, and
its exact copy was confirmed. The JSON manifest in `docs/LAUNCH.md` was compared with its
original value and is unchanged.

Local verification completed successfully:

- `forge build`: passed with the project's unchanged configuration (solc 0.8.26).
- `forge test`: **503 passed, 0 failed, 0 skipped**, across 49 suites. This includes one supplied
  proof in disposable `test/scratch/`; after scratch removal the submitted suite contains
  **502 tests in 48 suites**. Default fuzzing uses 256 runs; invariant settings remain 64 runs
  with depth 48.
- The 11 new audit tests pass, including fuzzed timeout boundaries. The original standalone
  tip-snipe proof also passes after the repair.
- All nine `LaunchManifest.t.sol` checks pass, including static constructor arguments, manifest
  order, empty-chain construction, no constructor calls/code checks, permitted entry points,
  forbidden-opcode scanning, and the original size/gas gates.
- Protocol conformance, saved real signatures, callback gas, conservation invariants, and the
  existing Payroll and JobsReport suites pass.

The final artifacts agree with the size table above. The canonical signature code and all 13
marker-delimited launch data blocks are unchanged. Verification was local: optional mainnet
fork tests and external static-analysis tools were not rerun for this adaptation. No dependency
was installed and no network access was required.

Supporting test changes:

| File | Why it changed |
|---|---|
| `test/questions/QuestionsFixture.sol` | Derive the default feed's full silence interval from the unchanged constants and its validity. |
| `test/questions/QuestionsAbandon.t.sol` | Assert the new boundary, completion cap and view/transaction agreement without weakening the failed-Intake or backoff tests. |
| `test/questions/HouseFeeds.t.sol` | Replace the twelve-hour-loss expectation with delivery through signed expiry for the real employers feed; check every house feed's new deadline. |
| `test/questions/QuestionsTips.t.sol` | Assert the opener is paid through both submission paths and the submitter cannot collect the reserved tip. |
| `test/questions/QuestionsRequest.t.sol` | Preserve unserved-request recovery tests and explicitly check the opener's tip on a separately purchased answer. |
| `test/questions/QuestionsInvariant.t.sol` | Track tips against openers, advance by the full deadline, and retain submission coverage using the amount earned through submission. |
| `test/payroll/integration/LaunchA.t.sol` | Round the full silence interval up to whole simulated twelve-second blocks, so the integration test actually reaches the deadline. |
| `test/questions/fork/QuestionsIntake.fork.t.sol`, `test/launch/fork/LaunchRehearsal.fork.t.sol` | Derive silence deadlines using each feed's validity rather than treating the signing allowance as the entire wait. |
| `test/payroll/PayrollSeats.t.sol` | Keep the ordinary-wallet transfer behavior test distinct from the new deployed-escrow regression. |
