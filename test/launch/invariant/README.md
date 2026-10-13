# Launch lifecycle tests

`LaunchLifecycleInvariant.t.sol` runs the actual Questions, JobsReport and Payroll logic together,
using all three checked house-feed fixtures and 2,000 seats. The external token, staking vault,
seat registry, adapter and Intake use local mocks; no network, fork or environment mutation is needed.
The pre-existing protocol-vector conformance tests remain the independent check of signature encoding.

The handler drives 18 actions across three funded actors: payments, donations, tips, booking,
meter sponsorship and redemption, Payroll top-ups, requests, valid and invalid answers,
missed-callback recovery, abandonment, keeper collection, ownership changes, claims, dripping,
price/time changes, printing and crowning. Four representative seats include the first and last
mainnet token ids, and can move between wallets, a passive escrow, an active contract wallet and
Payroll itself. Other seats continue accruing their equal share without claiming.

The three invariants check:

- External inputs equal both contracts' custody plus payments to the Intake and recipients.
  Separate ghost balances check each actor, keeper, contract wallet and staking vault; Payroll
  funding Questions is an internal transfer and is not double-counted as an exit.
- Meter assets cover all redemptions and keeper liabilities. Tips match recorded request outcomes,
  recovery never rewards the submitting observer, and every terminal round remains unchanged.
- Every report entry corresponds to an answered round with the same value and window. Windows
  do not overlap within either series; a paired count belongs to only one print and shares more
  than half of each window. Report totals equal their entries.

After each random sequence, the report queue is drained and every answered daily round must appear;
all individual funders then redeem their full positions, including while rounds remain pending.
The deterministic handler test exercises success, rejection, recovery, expiry, escrow protection,
wallet claims, recycling and repeated calls. It requires nonzero progress counters. The campaign
uses 256 runs of depth 96 with unexpected handler reverts treated as failures, configured inline.
QuestionsHarness is the existing harness: it only resets the transient request flag between
simulated transactions. No round, balance or application storage is planted by these tests.

`../LaunchTransferFailures.t.sol` injects reverting or false-returning token transfers after the
token has updated its own balances. It checks rollback and successful retry for incoming payments,
gift funding, single/batch seat payouts, aged tips, stream drips, meter redemptions and keeper
collections. It also covers tokens with no return data and every guarded money entry point under
reentrancy. These injected faults test atomicity; they do not claim mainnet IMD has transfer hooks.

Run the additions with:

```sh
forge test --match-path test/launch/LaunchTransferFailures.t.sol
forge test --match-path test/launch/invariant/LaunchLifecycleInvariant.t.sol
```
