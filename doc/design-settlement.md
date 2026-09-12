# Settlement — Design

`DvPSettlement`: one transaction that moves both legs of a trade, or neither.

Why atomic settlement matters is in [Design](DESIGN.md). The two legs are
[Tokenized Cash](design-cash.md) and [Asset Token](design-asset.md). This document covers
the contract in the middle.

Three facts about that contract drive the design:

| Fact                                           | Consequence                           | Section   |
| ---------------------------------------------- | ------------------------------------- | --------- |
| It holds no balances and takes no custody      | it is never a party, only a mover     | [1][s1]   |
| An allowance authorises an amount, not a trade | terms must be recorded on-chain first | [2][s2]   |
| It is the spender on both tokens               | it must not be upgradeable            | [10][s10] |

[s1]: #1-the-contract-holds-nothing
[s2]: #2-a-trade-is-agreed-before-it-settles
[s10]: #10-not-upgradeable

---

## 1. The contract holds nothing

No balances, no escrow, no custody of either leg. Cash moves directly from buyer to seller
and the bond directly from seller to buyer. The only state is the record of proposed
trades.

This is forced by the tokens. An escrowing contract would be the `to` of a transfer, and
`to` must be approved in the registry, which a contract cannot be
([Design](DESIGN.md#how-the-three-fit-together)). Two things follow: the contract can
never be the reason a trade fails a compliance check, and it has almost no state to lose
on redeployment ([section 10](#10-not-upgradeable)).

---

## 2. A trade is agreed before it settles

An allowance authorises an amount, not a trade. Suppose the terms travelled in calldata:

```solidity
settle(buyer, seller, cashToken, cashAmount, assetToken, assetAmount)
```

Bank A has approved 1,000,000 cash and Bank B has approved 100 bonds. Anyone who can see
those allowances can call `settle(A → B, 1,000,000 cash, B → A, 1 bond)`, and every
compliance check passes. Atomicity guarantees the two legs move together; it says nothing
about the terms being the ones anyone agreed to. Each party's version of the trade has to
reach the chain, and without signatures (deferred with `permit`,
[cash section 9](design-cash.md#no-permit-eip-2612-for-now)) that means stored state or an
assertion in the call authenticated by `msg.sender`.

### Stored terms are only half of it

Storing the seller's terms stops a stranger choosing them. It does nothing about the
seller mistyping 10,000,000 for 1,000,000, or the buyer settling proposal 48 when it meant
47. A CSD catches both by matching two independent instructions. So `settle` carries the
buyer's version of the terms, as a hash:

```solidity
settle(uint256 tradeId, bytes32 termsHash)
```

The contract recomputes the hash from the stored proposal and reverts on any difference.
The seller records terms it cannot execute; the buyer asserts terms as it executes. The
hash covers `tradeId`, this contract's address and the chain id as well as the terms, so
that two proposals on identical terms cannot accept each other's hash.

The buyer must compute its hash from its own record. A client that reads the proposal back
with `trades(id)` and hashes that has compared a value to itself. The contract cannot
enforce this; the [integration notes](integration.md#4-the-terms-hash) state it.

---

## 3. Lifecycle

### The seller proposes, the buyer settles

| Party  | Sends | Receives | Calls               |
| ------ | ----- | -------- | ------------------- |
| Seller | asset | cash     | `propose`, `cancel` |
| Buyer  | cash  | asset    | `settle`            |

Both parties must have approved this contract before a settlement can succeed, but they
hold that approval open for very different lengths of time. The seller's allowance stands
from `propose` until the trade settles, is cancelled, or expires. The buyer sends `approve`
and `settle` back to back, so its window is seconds.

The direction follows from the cash leg's daily cap
([cash section 4](design-cash.md#4-transfer-limits)): a running total that the payer's
other transfers consume and that resets at 00:00 UTC. A cash payer that settles reads its
remaining headroom and spends it in the same transaction; one that proposed would have its
limit tested at a moment it did not choose. The asset leg has no equivalent moving
precondition. Where `INSTITUTIONAL` is `NO_LIMIT`, as it normally is, the direction makes
no difference. It is fixed rather than configurable because one direction is simpler to
reason about; a direction flag is the change to make if operating experience calls for it.
The counter-argument, recorded here, is that settlement fails in practice are delivery
fails far more often than cash fails.

A proposal is a settlement instruction, not an offer; the price was agreed elsewhere
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

- **Acceptance and execution are one call.** Splitting them would create a window in
  which both parties have agreed and nothing has moved, which is the exposure DvP removes.
- **Only the named buyer can settle.** Letting anyone execute a proposal would put the
  terms back in the hands of whoever moves first.
- **Only the seller can cancel**, and only while the trade is `PROPOSED`. The buyer
  declines by doing nothing until the deadline. An expired trade can still be cancelled.
- **A proposal is not a reservation.** Nothing is locked. One holding can back two open
  proposals; the first to settle consumes the allowance and the second reverts on the
  token's own error.
- **Settled and cancelled are terminal.** No trade can execute twice.
- **`propose` is permissionless.** Any address can record a proposal naming any buyer. The
  buyer only settles ids it recognises and the hash check rejects anything else, so this
  is log noise rather than a risk.

### `tradeId` is a counter

A monotonically increasing `uint256` assigned by `propose`. A hash of the terms was
rejected because two identical trades between the same parties would collide, and the
second could not be proposed while the first was open.

---

## 4. Every proposal expires

`deadline` is required. An open-ended proposal is a free option: the buyer holds the right
but not the obligation to settle at yesterday's price whenever today's moves in its favour.
A deadline turns it into an offer that lapses. It also bounds the queue of live proposals,
which is what makes redeployment cheap in [section 10](#10-not-upgradeable).

Expiry costs no transaction. `settle` checks `block.timestamp <= deadline`, so an expired
trade is unusable without anyone having to mark it. The record stays in storage.

### A fail costs the buyer nothing, and that is a real gap

A deadline caps how long the option runs; it does not price it. The buyer can decline to
settle and pay nothing. Production settlement systems do not tolerate costless fails; CSDR
penalties exist for exactly this reason. It is tolerable here because every party is a
named institution, so the remedy is contractual, and because pricing a fail on-chain needs
either a margin deposit, which is escrow ([section 1](#1-the-contract-holds-nothing)), or
authority to move the failing party's cash outside a settlement. If a network needs
on-chain settlement discipline, that is a margin contract beside this one, holding the
deposits this one cannot hold.

---

## 5. Compliance stays in the tokens

`settle` calls `transferFrom` on each token and each token checks the registry itself. This
contract makes no registry calls and does not know what a tier is. Re-implementing the
checks here would create a second copy of the rules, and the settlement path is where drift
between the two would go unnoticed. A settlement that fails comes back with the token's own
error: a tier limit, a freeze, a missing approval.

### Checking a trade before settling it

Enforcement belongs in the tokens, but discovering that a trade cannot settle by watching
`settle` revert is the wrong place to find out. Each token exposes a preview:

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
preview and the enforcement run the same internal predicate, so they cannot disagree
([cash section 3](design-cash.md#previewing-the-checks),
[asset section 3](design-asset.md#previewing-the-checks)). `reason` is the selector of the
custom error the real call would revert with, decoded against the ABI the caller already
has; there is no separate vocabulary of reason codes to keep in step. It is a view over
state that can change in the next block: it answers "would this settle now" and names the
cause when the answer is no.

---

## 6. The trade names the instruments, and settlement verifies them

A proposal records the expected currency and ISIN alongside the two token addresses.
`settle` reads each token's immutable identifier and reverts on a mismatch:

```solidity
if (cash.currency() != trade.currency)  revert WrongCurrency(...);
if (asset.isin()    != trade.isin)      revert WrongInstrument(...);
```

This is separate from the terms hash. The hash says the buyer and the seller mean the same
trade; this check says the addresses in that trade are the instruments it names. Two
parties can agree on a token address that is not the bond they think it is. Two token
addresses tell a human reviewer nothing; two bond issues from the same issuer differ by
nothing legible. Both tokens made their identifier `immutable` so that this check is
possible ([cash section 8](design-cash.md#8-decimals-and-denomination),
[asset section 9](design-asset.md#9-denomination-and-instrument-identity)). The cost is two
immutable reads.

---

## 7. Effects before interactions

`settle` marks the trade `SETTLED` before it calls either token:

```solidity
trade.status = Status.SETTLED;                  // effect
cash.transferFrom(buyer, seller, cashAmount);   // interaction
asset.transferFrom(seller, buyer, assetAmount); // interaction
```

A token that called back into `settle` would find a trade that is no longer `PROPOSED`.
Neither token here has a callback, so this costs nothing today; it is written this way so
the contract does not depend on that remaining true, and so it can be pointed at a token it
did not ship with. A separate reentrancy guard was rejected: the state machine already
provides one, and a `nonReentrant` modifier would add a storage slot and suggest the
ordering above is not load-bearing.

The cash leg goes first. Either order is atomic; the cash leg carries more checks and is
the likelier to refuse, so failing on it first does less work before reverting.

`settle` treats a `false` return from either `transferFrom` as a failure and reverts with
`TransferFailed`. Neither token here returns `false`; the check is for a token this
contract did not ship with. A token that returns no data at all reverts on ABI decoding
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
  reconciliation reading settlements alone can describe each one without joining back to
  an earlier event. [Section 11](#11-what-this-contract-does-not-do) rejects netting partly
  on the grounds that every settlement is one trade in the log; this is what makes that
  true.
- **`tradeId`, `seller` and `buyer` are indexed on all three.** A member can filter the
  trades it is party to without scanning. Three is the maximum for a non-anonymous event,
  so the token addresses are unindexed.
- **No reason code on `TradeCancelled`.** The tokens attach one to freeze and forced
  transfer because those are discretionary compliance acts. A seller withdrawing its own
  proposal is not.
- **Nothing is emitted on expiry or on a failed settlement.** Expiry costs no transaction,
  so there is no execution in which to emit; a consumer computes it from
  `TradeProposed.deadline`. A failed settlement reverts, and a reverted transaction emits
  nothing. A monitoring system that assumes every terminal state has an event will miss
  two of the four.

---

## 9. Roles

None. No admin, no operator, no pauser. The contract holds no assets, sets no policy, and
cannot override a token's refusal, so there is nothing to privilege.

A pause was rejected: both tokens have one, and pausing either halts every trade that
touches it. An operator role that can settle on behalf of a buyer was rejected: it is the
calldata attack from [section 2](#2-a-trade-is-agreed-before-it-settles) with a role
attached.

---

## 10. Not upgradeable

No proxy. The argument is stronger here than for either token.

This contract is the spender on both tokens. It holds no balances, but it holds standing
authority to move other people's. An upgradeable settlement contract means whoever
controls the proxy admin can install an implementation that drains every allowance open
across the network at that moment. That is the largest blast radius in the system, larger
than either token's admin keys, which at least need a public freeze before a seizure.

Upgradeability also buys nothing here. A proxy earns its risk by avoiding migration cost,
and this contract holds only short-lived proposals that expire on their own
([section 4](#4-every-proposal-expires)). Shipping a new version is: deploy it, let the
proposal queue drain, and point the next round of approvals at the new address.

If it were made upgradeable anyway, the proxy should sit behind a timelock long enough for
participants to see an upgrade queued and revoke their allowances before it lands.

---

## 11. What this contract does not do

- **No `permit`, for now.** Both tokens defer it
  ([cash section 9](design-cash.md#no-permit-eip-2612-for-now),
  [asset section 10](design-asset.md#10-what-this-contract-does-not-do)), and it has to be
  adopted by both at once or a settlement still carries one stale allowance. When it lands,
  [section 2](#2-a-trade-is-agreed-before-it-settles) collapses into one transaction
  carrying both signatures, and `propose` becomes optional. That is the next version of
  this contract worth building.
- **No partial fills.** A proposal settles in full or not at all.
- **No netting.** This is the widest gap between this contract and how large-value
  settlement is run: gross settlement requires every payer to fund every trade in full,
  and multilateral netting can cut that by an order of magnitude. Gross is the starting
  point because atomic DvP against tokenised cash is gross per transaction by construction,
  and SIC, the payment system in [Design](DESIGN.md#where-dvp-runs-today), is an RTGS.
  Netting needs a cycle, a participant set, and an unwind on default; it belongs beside
  this contract, not inside it.
- **No multi-leg or basket trades.** Two legs, two tokens, one seller, one buyer.
- **No price, no oracle, no fees.** The proposal states two amounts. Whether their ratio is
  a fair price is not this contract's question.
- **No order book, no trade discovery.** Finding a counterparty and agreeing a price happen
  elsewhere.

What it does do is bilateral matching: the seller's proposal and the buyer's `termsHash`
are two independent assertions of the same trade. Unlike a CSD's matching it has no
tolerances and no repair: a mismatch is a revert and the fix is a new proposal.

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
proxy and therefore each carrying a `delegatecall` hop. This is the number that decides
whether the network meets its settlement window, and no token document could state it
because neither sees both legs.

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

- **A settlement costs less than its two legs summed.** The cash and asset `transferFrom`
  measured alone come to 47,736 + 49,412 = 97,148 cold, and `settle` adds a status write,
  two immutable reads and its own dispatch, yet lands at 112,865 rather than ~115,000. The
  second leg finds the registry proxy and both party accounts already warm from the first.
- **`propose` is the expensive call, and it is all storage.** Six slots written
  `0 -> nonzero` at ~22,100 each is ~133,000 of the 155,703. The `Trade` struct is ordered
  so the small fields pack beside `seller` and `buyer`; the first draft used seven slots and
  cost 177,555. Six is the minimum for four addresses and two full words.
- **Against the real registry** (`test/DvPSettlementRegistry.t.sol`), `settle` is 130,097
  cold, 15% above the mock. On a single transfer the two matched within 2% because the cold
  account access dominated, but the real registry costs ~1,700 more per call once warm (a
  fuller `Record`, ERC-7201 slot hashing, the proxy's implementation `SLOAD`), and a
  settlement makes seven calls of which six are warm. The production figure is the one to
  plan against.
- **Throughput.** ~151,000 gas per settlement as a whole transaction against the real
  registry. At a 30M block limit that is roughly 198 settlements per block.
- **The seven round trips are 35,908 of the 130,097**, measured in isolation
  (`test/RegistryRoundTrips.t.sol`): one cold call and six warm, 28% of a settlement. A
  combined `complianceOf` call on the registry would fold seven into two and save perhaps
  25,000, a ceiling of about 20% of a settlement. Worth doing if 198 per block is not
  enough, and not before. The other 60% is the two ERC-20 transfers and this contract's
  record, which no registry change touches.

On a permissioned Besu network the gas price is zero or near zero, so gas per settlement is
a throughput figure rather than a cost: it sets settlements per block.

---

## Summary of decisions

| #  | Decision                                                                             |
| -- | ------------------------------------------------------------------------------------ |
| 1  | No custody, no balances; the contract is never a party to a transfer                 |
| 2  | Terms stored on propose and asserted again on settle; the two must match             |
| 3  | The seller proposes, the buyer settles; direction is a default, not a necessity      |
| 4  | Every proposal expires; a fail still costs the buyer nothing, and that is a gap      |
| 5  | No registry calls from here; the tokens refuse, and `canSettle` previews the answer  |
| 6  | The trade names currency and ISIN, and settlement verifies both                      |
| 7  | Status written before the transfers; cash leg first as the likelier revert           |
| 8  | Terms repeated in `TradeSettled`; no reason codes; nothing emitted on expiry or fail |
| 9  | No roles; nothing to privilege                                                       |
| 10 | Not upgradeable; it is the spender on both tokens, and redeployment is cheap         |
| 11 | No `permit` yet, no partial fills, no netting, no baskets, no prices, no order book  |
