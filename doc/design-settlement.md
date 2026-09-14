# Settlement — Design

`DvPSettlement`: one transaction that moves both legs of a trade, or neither.

Why atomic settlement matters is covered in [Design](DESIGN.md). The two legs are
[Tokenized Cash](design-cash.md) and [Asset Token](design-asset.md). This doc covers the
contract between them.

Most of the design falls out of three constraints: the contract can't hold anything
([section 1](#1-the-contract-holds-nothing)), an ERC-20 allowance authorises an amount
rather than a trade ([section 2](#2-a-trade-is-agreed-before-it-settles)), and the
contract is the spender on both tokens, which is why it must not be upgradeable
([section 10](#10-not-upgradeable)).

---

## 1. The contract holds nothing

No balances, no escrow, no custody of either leg. Cash goes directly from buyer to seller
and the bond directly from seller to buyer. The only state is the record of proposed
trades.

The tokens force this. An escrowing contract would be the `to` of a transfer, `to` has to
be approved in the registry, and a contract can't be
([Design](DESIGN.md#how-the-three-fit-together)). Two useful side effects: the contract
can never itself be the reason a trade fails a compliance check, and there's almost no
state to lose on redeploy ([section 10](#10-not-upgradeable)).

---

## 2. A trade is agreed before it settles

An allowance authorises an amount, not a trade. Suppose the terms were passed in calldata:

```solidity
settle(buyer, seller, cashToken, cashAmount, assetToken, assetAmount)
```

Bank A has approved 1,000,000 cash and Bank B has approved 100 bonds. Anyone who can see
those allowances can call `settle(A → B, 1,000,000 cash, B → A, 1 bond)`, and every
compliance check passes. Atomicity only guarantees the two legs move together; it says
nothing about the terms being what anyone agreed. Each party's version of the trade has
to get on-chain somehow, and without signatures (deferred along with `permit`,
[cash section 9](design-cash.md#no-permit-eip-2612-for-now)) that means either stored
state or an assertion in the call that's authenticated by `msg.sender`.

### Stored terms are only half of it

Storing the seller's terms stops a stranger from choosing them. It does nothing about the
seller typing 10,000,000 instead of 1,000,000, or the buyer settling proposal 48 when it
meant 47. A CSD catches both by matching two independent instructions. So `settle` also
carries the buyer's version of the terms, as a hash:

```solidity
settle(uint256 tradeId, bytes32 termsHash)
```

The contract recomputes the hash from the stored proposal and reverts on any difference.
The seller records terms it can't execute; the buyer asserts terms as it executes. The
hash covers `tradeId`, the contract address and the chain id as well as the terms, so two
proposals with identical terms can't accept each other's hash.

The buyer has to compute its hash from its own record. If a client reads the proposal back
with `trades(id)` and hashes that, it has compared a value to itself. The contract can't
enforce this; the [integration notes](integration.md#4-the-terms-hash) spell it out.

---

## 3. Lifecycle

### The seller proposes, the buyer settles

| Party  | Sends | Receives | Calls               |
| ------ | ----- | -------- | ------------------- |
| Seller | asset | cash     | `propose`, `cancel` |
| Buyer  | cash  | asset    | `settle`            |

Both parties have to approve this contract before a settlement can succeed, but they hold
that approval open for very different lengths of time. The seller's allowance stands from
`propose` until the trade settles, is cancelled, or expires. The buyer sends `approve` and
`settle` back to back, so its window is seconds.

The direction comes from the cash leg's daily cap
([cash section 4](design-cash.md#4-transfer-limits)): a running total that the payer's
other transfers eat into and that resets at 00:00 UTC. A cash payer that settles can read
its remaining headroom and spend it in the same transaction; one that proposed would have
its limit tested at a moment it didn't choose. The asset leg has no equivalent moving
precondition. Where `INSTITUTIONAL` is `NO_LIMIT`, which is the normal case, the direction
makes no difference. It's fixed rather than configurable because one direction is easier
to reason about; a direction flag is the obvious change if operating experience calls for
it. The counter-argument, for the record: in practice settlement fails are delivery fails
far more often than cash fails.

A proposal is a settlement instruction, not an offer. The price was agreed elsewhere
([section 11](#11-what-this-contract-does-not-do)).

```
                  propose(...)
                       │
                       ▼
                  ┌──────────┐ settle(id, hash) ┌─────────┐
                  │ PROPOSED │─────────────────▶│ SETTLED │  both legs moved
                  └──────────┘    buyer only    └─────────┘
                    │      │
      cancel(id)    │      │   deadline passes
      seller only   │      │   no transaction needed
                    ▼      ▼
              ┌───────────┐ ┌─────────┐
              │ CANCELLED │ │ EXPIRED │
              └───────────┘ └─────────┘
```

```solidity
propose(terms) → tradeId     // the seller only
settle(tradeId, termsHash)   // the named buyer only
cancel(tradeId)              // the seller only, while still PROPOSED
```

- **Acceptance and execution are one call.** Splitting them would open a window where both
  parties have agreed and nothing has moved, which is exactly the exposure DvP is meant to
  remove.
- **Only the named buyer can settle.** If anyone could execute a proposal, the terms would
  be back in the hands of whoever moves first.
- **Only the seller can cancel**, and only while the trade is `PROPOSED`. The buyer declines
  by doing nothing until the deadline. An expired trade can still be cancelled.
- **A proposal is not a reservation.** Nothing is locked. One holding can back two open
  proposals; the first to settle uses the allowance and the second reverts with the token's
  own error.
- **Settled and cancelled are terminal.** No trade executes twice.
- **`propose` is permissionless.** Any address can record a proposal naming any buyer. The
  buyer only settles ids it recognises and the hash check rejects everything else, so this
  is log noise rather than a risk.

### `tradeId` is a counter

A monotonically increasing `uint256` assigned by `propose`. Using a hash of the terms was
rejected because two identical trades between the same parties would collide, and the
second couldn't be proposed while the first was open.

---

## 4. Every proposal expires

`deadline` is required. An open-ended proposal is a free option: the buyer holds the right
but not the obligation to settle at yesterday's price whenever today's moves in its favour.
A deadline makes it an offer that lapses. It also bounds the queue of live proposals, which
is what makes redeployment cheap ([section 10](#10-not-upgradeable)).

Expiry costs no transaction. `settle` checks `block.timestamp <= deadline`, so an expired
trade is unusable without anyone having to mark it. The record stays in storage.

### A fail costs the buyer nothing, and that is a real gap

A deadline caps how long the option runs; it doesn't price it. The buyer can decline to
settle and pay nothing. Production settlement systems don't tolerate costless fails; CSDR
penalties exist for exactly this. It's acceptable here because every party is a named
institution, so the remedy is contractual, and because pricing a fail on-chain needs either
a margin deposit (which is escrow, [section 1](#1-the-contract-holds-nothing)) or the
authority to move the failing party's cash outside a settlement. If a network needs
on-chain settlement discipline, that's a margin contract alongside this one, holding the
deposits this one can't.

---

## 5. Compliance stays in the tokens

`settle` calls `transferFrom` on each token and each token checks the registry itself. This
contract makes no registry calls and doesn't know what a tier is. Re-implementing the
checks here would be a second copy of the rules, and the settlement path is where drift
between the two would go unnoticed. A settlement that fails comes back with the token's own
error: a tier limit, a freeze, a missing approval.

### Checking a trade before settling it

Enforcement lives in the tokens, but finding out that a trade can't settle by watching
`settle` revert is a bad way to find out. Each token exposes a preview:

```solidity
// on TokenizedCash and on AssetToken
function canTransferFrom(address spender, address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
```

`canSettle` composes them and still reads no registry:

```solidity
function canSettle(uint256 tradeId, bytes32 termsHash)
    external view returns (bool ok, bytes4 reason);
```

It runs the same checks in the same order `settle` would: status, deadline, terms hash,
currency and ISIN, then the cash leg's preview, then the asset leg's. In each token the
preview and the enforcement run the same internal predicate, so they can't disagree
([cash section 3](design-cash.md#previewing-the-checks),
[asset section 3](design-asset.md#previewing-the-checks)). `reason` is the selector of the
custom error the real call would revert with, decodable against the ABI the caller already
has, so there's no separate list of reason codes to keep in sync. It's a view over state
that can change in the next block: it answers "would this settle now" and names the cause
when the answer is no.

---

## 6. The trade names the instruments, and settlement verifies them

A proposal records the expected currency and ISIN alongside the two token addresses.
`settle` reads each token's immutable identifier and reverts on a mismatch:

```solidity
if (cash.currency() != trade.currency)  revert WrongCurrency(...);
if (asset.isin()    != trade.isin)      revert WrongInstrument(...);
```

This is separate from the terms hash. The hash says buyer and seller mean the same trade;
this check says the addresses in that trade are the instruments it names. Two parties can
agree on a token address that isn't the bond they think it is — two token addresses tell a
human reviewer nothing, and two bond issues from the same issuer look identical at the
address level. Both tokens made their identifier `immutable` so this check is possible
([cash section 8](design-cash.md#8-decimals-and-denomination),
[asset section 9](design-asset.md#9-denomination-and-instrument-identity)). The cost is two
immutable reads.

---

## 7. Effects before interactions

`settle` marks the trade `SETTLED` before calling either token:

```solidity
trade.status = Status.SETTLED;                  // effect
cash.transferFrom(buyer, seller, cashAmount);   // interaction
asset.transferFrom(seller, buyer, assetAmount); // interaction
```

A token that called back into `settle` would find a trade that's no longer `PROPOSED`.
Neither token here has a callback, so this costs nothing today; it's written this way so
the contract doesn't depend on that staying true, and so it can be pointed at a token it
didn't ship with. A separate reentrancy guard was rejected: the state machine already is
one, and a `nonReentrant` modifier would add a storage slot and suggest the ordering above
doesn't matter.

The cash leg goes first. Either order is atomic; the cash leg has more checks and is more
likely to refuse, so failing on it first does less work before reverting.

`settle` treats a `false` return from either `transferFrom` as a failure and reverts with
`TransferFailed`. Neither token here returns `false`; the check is for a token this
contract didn't ship with. A token that returns no data at all reverts on ABI decoding
rather than with `TransferFailed`, which is still a revert.

---

## 8. Events

```solidity
event TradeProposed(
    uint256 indexed tradeId,
    address indexed seller,
    address indexed buyer,
    address cashToken,  uint256 cashAmount,
    address assetToken, uint256 assetAmount,
    uint64  deadline
);

event TradeSettled(
    uint256 indexed tradeId,
    address indexed seller,
    address indexed buyer,
    address cashToken,  uint256 cashAmount,
    address assetToken, uint256 assetAmount
);

event TradeCancelled(
    uint256 indexed tradeId,
    address indexed seller,
    address indexed buyer
);
```

- **`TradeSettled` repeats the terms** rather than pointing at the proposal, so a
  reconciliation that only reads settlements can describe each one without joining back to
  an earlier event. [Section 11](#11-what-this-contract-does-not-do) rejects netting partly
  because every settlement is one trade in the log; this is what makes that true.
- **`tradeId`, `seller` and `buyer` are indexed on all three.** A member can filter for the
  trades it's party to without scanning. Three is the max for a non-anonymous event, so
  the token addresses aren't indexed.
- **No reason code on `TradeCancelled`.** The tokens attach one to freeze and forced
  transfer because those are discretionary compliance actions. A seller withdrawing its
  own proposal isn't.
- **Nothing is emitted on expiry or on a failed settlement.** Expiry costs no transaction,
  so there's nothing to emit from; a consumer computes it from `TradeProposed.deadline`.
  A failed settlement reverts, and a reverted transaction emits nothing. A monitoring
  system that assumes every terminal state has an event will miss two of the four.

---

## 9. Roles

None. No admin, no operator, no pauser. The contract holds no assets, sets no policy, and
can't override a token's refusal, so there's nothing to gate.

A pause was rejected: both tokens have one, and pausing either halts every trade that
touches it. An operator role that can settle on a buyer's behalf was rejected: that's the
calldata attack from [section 2](#2-a-trade-is-agreed-before-it-settles) with a role
attached.

---

## 10. Not upgradeable

No proxy. The argument is stronger here than for either token.

This contract is the spender on both tokens. It holds no balances, but it holds standing
authority to move other people's. An upgradeable settlement contract means whoever
controls the proxy admin can install an implementation that drains every allowance open
across the network at that moment. That's the largest blast radius in the system, larger
than either token's admin keys, which at least need a public freeze before a seizure.

Upgradeability also buys nothing here. A proxy earns its risk by avoiding migration cost,
and this contract only holds short-lived proposals that expire on their own
([section 4](#4-every-proposal-expires)). Shipping a new version is: deploy it, let the
proposal queue drain, point the next round of approvals at the new address.

If it were made upgradeable anyway, the proxy should sit behind a timelock long enough for
participants to see an upgrade queued and revoke their allowances before it lands.

---

## 11. What this contract does not do

- **No `permit`, for now.** Both tokens defer it
  ([cash section 9](design-cash.md#no-permit-eip-2612-for-now),
  [asset section 10](design-asset.md#10-what-this-contract-does-not-do)), and it has to
  land in both at once or a settlement still carries one stale allowance. Once it does,
  [section 2](#2-a-trade-is-agreed-before-it-settles) collapses into one transaction
  carrying both signatures and `propose` becomes optional. That's the next version of this
  contract worth building.
- **No partial fills.** A proposal settles in full or not at all.
- **No netting.** This is the biggest gap between this contract and how large-value
  settlement actually runs: gross settlement means every payer funds every trade in full,
  and multilateral netting can cut that by an order of magnitude. Gross is the starting
  point because atomic DvP against tokenised cash is gross per transaction by
  construction, and SIC, the payment system in [Design](DESIGN.md#where-dvp-runs-today),
  is an RTGS. Netting needs a cycle, a participant set, and an unwind on default; it
  belongs next to this contract, not inside it.
- **No multi-leg or basket trades.** Two legs, two tokens, one seller, one buyer.
- **No price, no oracle, no fees.** The proposal states two amounts. Whether the ratio is
  a fair price isn't this contract's problem.
- **No order book, no trade discovery.** Finding a counterparty and agreeing a price
  happen elsewhere.

What it does do is bilateral matching: the seller's proposal and the buyer's `termsHash`
are two independent assertions of the same trade. Unlike a CSD's matching there are no
tolerances and no repair. A mismatch is a revert and the fix is a new proposal.

---

## 12. Gas

A settlement is two `transferFrom` calls plus this contract's bookkeeping.

| cost                     | detail                                                      |
| ------------------------ | ----------------------------------------------------------- |
| registry calls from here | none                                                        |
| registry calls via cash  | 4 ([cash section 10](design-cash.md#10-gas))                |
| registry calls via asset | 3 ([asset section 11](design-asset.md#11-gas))              |
| this contract, `propose` | one trade record written                                    |
| this contract, `settle`  | one status write, two `immutable` reads, two external calls |

Seven registry round trips per settlement, each a `STATICCALL` into the registry's UUPS
proxy, so each one includes a `delegatecall` hop. This is the number that decides whether
the network meets its settlement window, and neither token doc can state it because
neither sees both legs.

### Measured

`test/Gas.t.sol` (`SettlementGasTest`): mock registry behind a `delegatecall` proxy, both
parties `INSTITUTIONAL` at `NO_LIMIT`, receiving balances non-zero so every write is
`nonzero -> nonzero`. `propose` and `settle` are separate transactions, as in production,
so the trade record is cold when `settle` reads it. Base transaction cost excluded.

| path                 |    cold |    warm |
| -------------------- | ------: | ------: |
| `propose`            | 155,703 | 146,384 |
| `settle`             | 112,865 |  55,665 |
| `cancel`             |       - |   4,217 |
| `canSettle` (view)   |  79,826 |       - |

- **A settlement costs less than the sum of its two legs.** The cash and asset
  `transferFrom` measured alone come to 47,736 + 49,412 = 97,148 cold, and `settle` adds a
  status write, two immutable reads and its own dispatch, yet lands at 112,865 rather than
  ~115,000. The second leg finds the registry proxy and both party accounts already warm
  from the first.
- **`propose` is the expensive call, and it's all storage.** Six slots written
  `0 -> nonzero` at ~22,100 each is ~133,000 of the 155,703. The `Trade` struct is ordered
  so the small fields pack next to `seller` and `buyer`; the first draft used seven slots
  and cost 177,555. Six is the minimum for four addresses and two full words.
- **Against the real registry** (`test/DvPSettlementRegistry.t.sol`), `settle` is 130,097
  cold, 15% above the mock. On a single transfer the two matched within 2% because the
  cold account access dominated, but the real registry costs ~1,700 more per call once
  warm (a fuller `Record`, ERC-7201 slot hashing, the proxy's implementation `SLOAD`), and
  a settlement makes seven calls, six of them warm. Plan against the production figure.
- **Throughput.** ~151,000 gas per settlement as a whole transaction against the real
  registry. At a 30M block limit that's roughly 198 settlements per block.
- **The seven round trips are 35,908 of the 130,097**, measured in isolation
  (`test/RegistryRoundTrips.t.sol`): one cold call and six warm, 28% of a settlement. A
  combined `complianceOf` call on the registry would fold seven into two and save maybe
  25,000, so about 20% of a settlement at best. Worth doing if 198 per block isn't enough,
  not before. The other 60% is the two ERC-20 transfers and this contract's record, which
  no registry change touches.

On a permissioned Besu network the gas price is zero or near zero, so gas per settlement is
a throughput figure rather than a cost: it sets settlements per block.

---

## Summary of decisions

| #  | Decision                                                                             |
| -- | ------------------------------------------------------------------------------------ |
| 1  | No custody, no balances; the contract is never a party to a transfer                 |
| 2  | Terms stored on propose and asserted again on settle; the two must match             |
| 3  | The seller proposes, the buyer settles; the direction is a default, not a necessity  |
| 4  | Every proposal expires; a fail still costs the buyer nothing, which is a known gap   |
| 5  | No registry calls from here; the tokens refuse, and `canSettle` previews the answer  |
| 6  | The trade names currency and ISIN, and settlement verifies both                      |
| 7  | Status written before the transfers; cash leg first because it's the likelier revert |
| 8  | Terms repeated in `TradeSettled`; no reason codes; nothing emitted on expiry or fail |
| 9  | No roles; nothing to gate                                                            |
| 10 | Not upgradeable; it's the spender on both tokens, and redeployment is cheap          |
| 11 | No `permit` yet, no partial fills, no netting, no baskets, no prices, no order book  |
