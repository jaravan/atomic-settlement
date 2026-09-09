# Settlement — Design

`DvPSettlement`: one transaction that moves both legs of a trade, or neither.

Why atomic settlement matters and where it runs today is in [Design](DESIGN.md). The two
legs are [Tokenized Cash](design-cash.md) and [Asset Token](design-asset.md). This
document covers only the contract in the middle.

The design follows three facts about that contract:

| Fact                                           | Consequence                           | Section   |
| ---------------------------------------------- | ------------------------------------- | --------- |
| It holds no balances and takes no custody      | it can never be a party, only a mover | [1][s1]   |
| An allowance authorises an amount, not a trade | terms must be recorded on-chain first | [2][s2]   |
| It is the spender on both tokens               | it must not be upgradeable            | [10][s10] |

[s1]: #1-the-contract-holds-nothing
[s2]: #2-a-trade-is-agreed-before-it-settles
[s10]: #10-not-upgradeable

---

## 1. The contract holds nothing

No balances, no escrow, no custody of either leg. Cash moves directly from buyer to seller
and the bond directly from seller to buyer. The only state the contract keeps is a record
of proposed trades.

This is a requirement, not a preference. An escrowing contract would have to be the `to`
of a transfer, and `to` must be `isApproved`, which a contract can never be. The funding
call would revert every time. [Design](DESIGN.md#how-the-three-fit-together) sets out the
full argument.

Two things follow. The contract can never be the reason a trade fails a compliance check,
because it is never a party to one. And it has almost nothing to lose if it is redeployed,
which [section 10](#10-not-upgradeable) turns into the argument against a proxy.

---

## 2. A trade is agreed before it settles

An allowance authorises an **amount**, not a **trade**. That single fact decides the shape
of this contract.

Suppose the terms travelled in calldata:

```solidity
settle(buyer, seller, cashToken, cashAmount, assetToken, assetAmount)
```

Bank A has approved 1,000,000 cash. Bank B has approved 100 bonds. Anyone who can see
those two allowances calls:

```
settle(A → B, 1,000,000 cash,   B → A, 1 bond)
```

Both transfers succeed. Both tokens pass every compliance check: A and B are approved,
neither is frozen, the spender is not sanctioned. A has paid a million for one bond, and
no rule in either token document was broken.

**Atomicity guarantees the two legs move together. It says nothing about the terms being
the ones anyone agreed to.** Each party's version of the trade has to reach the chain
somehow, and there are three ways to carry one:

- **A signature.** EIP-712, the same machinery both tokens deferred with `permit`
  ([cash section 9](design-cash.md#no-permit-eip-2612-for-now)). Carries a party's terms
  without that party sending the transaction, which is what lets both arrive at once.
- **Stored state.** A party records its terms in an earlier transaction of its own, and
  they wait there.
- **An assertion in the call.** A party states its terms in the transaction it sends, and
  `msg.sender` is the authentication. No signature scheme, but it only works for the party
  actually sending.

`permit` is deferred, so signatures are out for now, and stored state is where this
document started. The next subsection is why stored state on its own is half a mechanism.

### Stored terms are only half of it

Storing the terms stops a stranger choosing them. It does nothing about the counterparty
choosing them, and on the shape above only one party ever states them. The seller writes
the proposal; the buyer sends an id. Two ordinary mistakes get through:

- The seller means 1,000,000 and types 10,000,000. The buyer does not read the proposal
  closely and settles. Every check in this document passes: right ISIN, right currency,
  both parties approved, neither frozen.
- The seller has proposals 47 and 48 open on different terms. The buyer means 47 and calls
  48.

Neither is an attack. Both are what settlement systems are built to catch, and the reason
they are built that way is that **neither side's version of a trade is authoritative on its
own.** A CSD matches two independent instructions and settles when they agree. On the shape
above there is only one instruction, and the buyer has no way to say what it thought it had
agreed to.

**So `settle` carries the terms the buyer believes it agreed, as a hash:**

```solidity
settle(uint256 tradeId, bytes32 termsHash)
```

The contract recomputes the hash from what it stored and reverts on any difference. One
argument and one comparison, and acceptance becomes a matched instruction rather than an
acknowledgement.

That is the third carrier from the list above, and using it is what makes the other two
work together rather than compete. The seller records terms it cannot execute; the buyer
asserts terms as it executes, authenticated by `msg.sender` rather than by a signature. Two
versions of one trade, arriving by different routes, compared before anything moves. It is
how this design gets CSD-style matching with no signature scheme in it, and it is why
`permit` would be an improvement to the ergonomics rather than a fix for a gap
([section 11](#11-what-this-contract-does-not-do)).

**`tradeId` goes inside the hash**, along with this contract's own address and the chain id.
Without the id, two proposals from the same seller on identical terms would each accept the
other's hash, and the second mistake above survives the fix. With it, a hash is an assertion
about one specific trade and is worthless against any other.

**The buyer's hash has to come from the buyer's own record**, not from reading the trade
back and hashing that. A client that fetches the stored terms and hashes them has written
an expensive way to compare a value to itself. This is the one place where the value of the
mechanism sits entirely in the caller rather than the contract, and it is worth saying in
the integration notes as loudly as here.

---

## 3. Lifecycle

### The seller proposes, the buyer settles

Every trade has an asset owner and a cash payer, and the contract fixes which of them
does what:

| Party  | Sends | Receives | Calls               |
| ------ | ----- | -------- | ------------------- |
| Seller | asset | cash     | `propose`, `cancel` |
| Buyer  | cash  | asset    | `settle`            |

The seller is the proposer. The buyer is the named counterparty, and the only address
that can settle the trade.

Both parties must have approved this contract before a settlement can succeed, but they
hold that approval open for very different lengths of time. The seller's allowance has to
stand from `propose` until the trade settles or expires. The buyer sends `approve` and
`settle` back-to-back, two transactions of its own, so its window is seconds rather than
hours. It cannot be zero: `approve` is a call to the cash token and `settle` a call to this
contract, and one transaction reaches one address.

That asymmetry is the argument for the direction chosen. The cash leg is the only one
carrying a precondition that moves while a proposal sits open: a daily cap held as a running
total, which the sender's own unrelated transfers consume and which resets at 00:00 UTC
([cash section 4](design-cash.md#4-transfer-limits)). The asset leg has no limits at all
([asset section 4](design-asset.md#4-no-transfer-limits)). A cash payer that proposed would
be committing to a transfer whose limit is tested at a moment it does not choose, against
headroom it may have spent in the meantime, possibly on the far side of a midnight reset. A
cash payer that settles reads its remaining headroom and spends it in the same transaction.

Where `INSTITUTIONAL` is `NO_LIMIT`, as it normally is, nothing binds and the direction
costs nothing either way ([cash section 4](design-cash.md#a-cap-can-be-set-to-no-cap)). It
is chosen for the case where an operator has set a cap, because that is the case where the
other direction produces a settlement that fails at a time neither party chose.

**So this is a default, not a structural necessity.** The contract would work with the
direction reversed and nothing else in this document depends on it. It is fixed rather
than configurable because one direction is easier to reason about than two, and because
the argument above, thin as it is when no cap binds, never points the other way.

**And it matters less than its length here suggests**, because the buyer asserts the terms
to settle ([section 2](#2-a-trade-is-agreed-before-it-settles)). Whichever side records the
trade first, both state it before anything moves. What the direction still decides is which
party carries an open allowance and which one's precondition is tested at a moment it did
not pick. That is a liquidity and operations question, not a question about who agreed to
what.

**A proposal is a settlement instruction, not an offer.** The price was agreed elsewhere
([section 11](#11-what-this-contract-does-not-do)), so the direction decides which party's
instruction stands open and which party's executes — not who is offering what to whom. The
buyer can still walk away by doing nothing until the deadline, which is what
[section 4](#4-every-proposal-expires) is about, but that is a settlement fail rather than a
declined offer.

**Deferred: a direction flag, so either party can propose.** It costs a field and doubles
the shapes a reader of a proposal has to check, which is why it is not here on day one. The
argument against the chosen direction is real and belongs on the record: settlement fails in
practice are delivery fails far more often than cash fails, which argues for testing the
seller's ability to deliver last rather than first. The counter is that the seller's holding
is consumed only by other proposals the seller wrote, while the buyer's daily cap is
consumed by activity outside this contract entirely and resets on a clock neither party
watches — one is self-inflicted, the other is invisible. That is a preference rather than a
proof, and the flag is what to add if operating experience says the other way round.

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
// the seller only
propose(buyer, cashToken, cashAmount, assetToken, assetAmount, deadline) → tradeId

settle(tradeId, termsHash)   // the named buyer only, asserting the terms it agreed
cancel(tradeId)              // the seller only, while still PROPOSED
```

**Acceptance and execution are the same call.** Splitting them would create a window in
which both parties have agreed and nothing has moved, which is the exposure DvP exists to
remove. `settle` is the acceptance, and `termsHash` is what makes it an acceptance of
something specific rather than of whatever is stored
([section 2](#2-a-trade-is-agreed-before-it-settles)).

**Only the named buyer can settle.** A proposal is an offer addressed to one party.
Letting anyone execute it would put the terms back in the hands of whoever moves first,
which is what [section 2](#2-a-trade-is-agreed-before-it-settles) rules out.

**Only the seller can cancel**, and only before settlement. The buyer does not need a
cancel: declining is doing nothing until the deadline.

**A proposal is not a reservation.** The seller's allowance is what makes delivery
possible, and nothing stops one holding backing two open proposals. The first to settle
consumes the allowance and the second reverts on the asset token's own error. Sizing
allowances to what is actually on offer is the seller's business, not this contract's.

**A settled or cancelled trade is terminal.** `settle` and `cancel` both revert unless the
trade is `PROPOSED` and unexpired, so no trade can execute twice.

### `tradeId` is a counter

A monotonically increasing `uint256`, assigned by `propose`.

**Rejected: a hash of the terms.** It makes two identical trades between the same parties
collide, so the second cannot be proposed while the first is open. A counter has no such
case to reason about, and no collision argument to get wrong.

---

## 4. Every proposal expires

`deadline` is required. There are no open-ended proposals.

**An unexpiring offer is a free option.** The buyer holds the right, but not the
obligation, to settle at yesterday's price whenever today's price moves in its favour. The
seller wrote that option without being paid for it, and cancelling requires noticing in
time.

A deadline turns it into an offer that lapses. It also bounds the queue of live proposals,
which is what makes redeployment cheap in [section 10](#10-not-upgradeable).

**Expiry costs no transaction.** `settle` checks `block.timestamp <= deadline`, so an
expired trade is dead without anyone paying to kill it. The record stays in storage,
harmless and unusable.

### A fail costs the buyer nothing, and that is a real gap

A deadline caps how long the option runs. It does not price it. The buyer can decline to
settle and pay nothing, and no penalty, fails charge or buy-in follows. Production
settlement systems do not tolerate that, because costless fails are what destroys
settlement discipline: CSDR penalties exist for exactly this reason.

Three things make it tolerable here, and none of them make it correct:

- **Every party is identified.** This is a permissioned network whose members are KYC'd in
  the registry, and a proposal names one counterparty. A fail is attributable to a named
  institution, and the remedy is contractual between two members of the same consortium.
  An anonymous market would have no such fallback.
- **Pricing a fail on-chain needs custody or spending authority.** A penalty means either
  holding a margin deposit, which is escrow and structurally impossible
  ([section 1](#1-the-contract-holds-nothing)), or granting this contract authority to
  move the failing party's cash outside a settlement. The second is a far larger power
  than settling trades, and it is not worth the benefit.
- **The seller is not in custody while it waits.** Its allowance stands open, but an
  allowance is permission and not escrow: the bonds stay its own and stay transferable
  elsewhere. What a fail costs the seller is optionality, not access to its own assets.

**What this does not excuse.** A fails regime is part of a working settlement system and
this contract has none. If a network needs settlement discipline enforced on-chain rather
than contractually, that is a margin contract sitting beside this one and holding the
deposits this one refuses to hold. It is not a feature to fold in here.

---

## 5. Compliance stays in the tokens

`settle` calls `transferFrom` on each token, and each token checks the registry itself.
**This contract makes no registry calls at all.** It does not know what a tier is.

Re-implementing the checks here would create a second source of truth, and the settlement
path is exactly where drift between the two would go unnoticed.

The practical benefit is legible failures. A settlement that fails comes back with the
token's own error: the buyer's tier limit, a freeze, a missing approval. The settlement
contract adds no error of its own for anything a token already refuses.

### Checking a trade before settling it

Enforcement belonging to the tokens means a trade's viability is discovered when `settle`
reverts. That is the right place to enforce and the wrong place to find out.

**The preview lives in the tokens too.** Each exposes the question it already answers:

```solidity
// on TokenizedCash and on AssetToken
function canTransferFrom(address spender, address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
```

`canSettle` then composes, and still reads no registry:

```solidity
function canSettle(uint256 tradeId, bytes32 termsHash)
    external view returns (bool ok, bytes4 reason);
// terms hash, status and deadline, then currency and ISIN, then cash and then asset:
// the same order settle checks them, so the view names the cause the transaction would
```

This is the only shape that keeps the paragraph above true. A preview implemented here
would have to know what a tier is, evaluate a daily cap, and rank the failures in the same
order the token does. That is the second source of truth this section rejects, and the
settlement path is exactly where the two would drift apart unnoticed.

**One predicate, two callers.** In each token the preview and the enforcement run the same
internal check; `_update` reverts on what it returns, `canTransferFrom` hands it back. They
cannot disagree, because there is only one of them. Keeping it that way is a structural
constraint on the implementation and an explicit test: for every rejection case, the view
and the transaction must name the same cause
([cash section 3](design-cash.md#previewing-the-checks),
[asset section 3](design-asset.md#previewing-the-checks)).

**The reason is an error selector, not a code.** `bytes4` holding the selector of the
custom error the real call would revert with, so there is no parallel vocabulary to keep in
step. A caller decodes it against the ABI it already has. Codes of our own would be new
machinery whose only job is to mirror the errors, which is drift with extra steps.

It is a view, so it costs nothing and guarantees nothing: state can change between the
call and the transaction. It answers "would this settle right now", which is what an
operator needs before submitting and what a member's own systems need in order to chase a
missing allowance or a freeze. With seven registry round trips
([section 12](#12-gas)) between a caller and the answer, "no" without a cause would mean
reading the chain by hand.

**The two legs do not check the same things**, and this contract does not need to know
which is which. Only the cash leg reads a tier, because only the cash leg has limits
([cash section 4](design-cash.md#4-transfer-limits),
[asset section 4](design-asset.md#4-no-transfer-limits)). Both check approval on buyer and
seller, both block a frozen sender, and both check this contract for sanctions as the
spender.

---

## 6. The trade names the instruments, and settlement verifies them

A proposal records the expected currency and the expected ISIN alongside the two token
addresses. `settle` reads each token's immutable identifier and reverts on a mismatch.

This is not what the terms hash already does. The hash says the buyer and the seller mean
the same trade; this check says the addresses in that trade really are the instruments it
names. Two parties can agree perfectly on a token address that is not the bond they think
it is, and the hash would match.

```solidity
if (cash.currency() != trade.currency)  revert WrongCurrency(...);
if (asset.isin()    != trade.isin)      revert WrongInstrument(...);
```

Two token addresses reveal nothing to a human reviewing a proposal. Two bond issues from
the same issuer, or a euro and a dollar token from the same bank, differ by nothing
legible. Both token documents made their identifier `immutable` precisely so a settlement
contract could check it ([cash section 8](design-cash.md#8-decimals-and-denomination),
[asset section 9](design-asset.md#9-denomination-and-instrument-identity)).

The cost is two `immutable` reads, which is close to nothing, and it converts a
misconfigured address from a settled wrong trade into a revert.

---

## 7. Effects before interactions

`settle` marks the trade `SETTLED` **before** it calls either token.

```solidity
trade.status = Status.SETTLED;              // effect
cash.transferFrom(buyer, seller, cashAmount);   // interaction
asset.transferFrom(seller, buyer, assetAmount); // interaction
```

Two external calls in one function is a reentrancy shape. Marking the trade settled first
means a token that calls back into `settle` finds a trade that is no longer `PROPOSED` and
reverts.

Both tokens are ours and neither has a callback, so this costs nothing today. It is
written this way so the contract does not depend on that remaining true, and so it can be
pointed at a token it did not ship with.

**The cash leg goes first.** Either order is atomic, so this is only about which revert is
cheaper on average. The cash leg carries more checks, including the tier read and the
daily limit, so it is the leg more likely to refuse. Failing on it first does less work
before reverting.

**Rejected: a reentrancy guard as well.** The state machine already provides one. A
`nonReentrant` modifier on top would add a storage slot and imply the ordering above is
not load-bearing.

---

## 8. Events

Both token documents specify their events deliberately: a `bytes32` reason code rather
than a string, and `ForcedTransfer` distinct from `Transfer` so a seizure never reads as a
payment. This contract owes the same, and owes it more than they do.
[Section 11](#11-what-this-contract-does-not-do) rejects netting on the grounds that every
settlement is one trade in the log. That argument is worth nothing unless the log says so.

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

**`TradeSettled` repeats the terms rather than pointing at the proposal.** A reconciliation
reading settlements alone can then describe each one without joining back to an earlier
event. That is what "one trade in the log" has to mean to be worth rejecting netting for.
The cost is four extra words of log data on a network where gas is a throughput question
rather than a price.

**Three indexed fields on each, and `tradeId` on all three.** Indexing both parties lets a
member filter the trades it is part of without scanning, and that includes cancellation:
the buyer is the party a withdrawn offer actually affects, so it has to be able to find
one addressed to it. Three is the maximum a non-anonymous event allows, so the token
addresses stay unindexed and are filtered on after retrieval.

**No reason codes.** The tokens attach one to freeze and to `forceTransfer` because those
are discretionary compliance acts and the chain should record why. Cancelling a proposal
is not: a seller withdrawing its own offer owes the log no justification. The asymmetry is
deliberate, not an oversight.

**Nothing is emitted on expiry, and nothing on failure.** Expiry costs no transaction
([section 4](#4-every-proposal-expires)), so there is no execution in which to emit; a
consumer computes it from `TradeProposed.deadline`. A failed settlement reverts, and a
reverted transaction emits nothing at all. Both absences are worth stating, because a
monitoring system built on the assumption that every terminal state has an event will
silently miss two of the four.

---

## 9. Roles

**There are none.** No admin, no operator, no pauser. The contract has no privileged
function, because it has nothing to privilege: it holds no assets, sets no policy, and
cannot override a token's refusal.

**Rejected: a pause.** Both tokens already have one
([cash section 6](design-cash.md#6-pause), [asset section 6](design-asset.md#6-pause)),
and pausing either halts every trade that touches it. A third pause would add a key
without adding a control.

**Rejected: an operator who can settle on behalf of a buyer.** That is the calldata
attack from [section 2](#2-a-trade-is-agreed-before-it-settles) with a role attached to
it.

---

## 10. Not upgradeable

No proxy. The argument is stronger here than for either token.

**This contract is the spender on both tokens.** It holds no balances, but it holds
standing authority to move other people's. An upgradeable settlement contract means
whoever controls the proxy admin can swap in an implementation that drains every allowance
open across the network at that moment. During a settlement window that is the largest
blast radius in the system, larger than either token's admin keys, which at least need a
public freeze first.

Making the one contract with spending authority over everyone the only upgradeable one
would invert the security model the two token documents spent their length building.

**And upgradeability buys nothing here.** A proxy earns its risk by avoiding migration
cost, and migration cost comes from state. The tokens cannot be redeployed cheaply because
balances would have to move; the registry cannot because records would. This contract
holds short-lived trade proposals that expire on their own
([section 4](#4-every-proposal-expires)). Shipping v2 is: deploy it, let the proposal
queue drain, and point the next round of approvals at the new address. No balance moves,
no holder is stranded, and nobody has to trust an upgrade key in the meantime.

So "settlement workflows evolve" is true, and it is not an argument for a proxy. It is an
argument that redeployment is cheap.

**If it were made upgradeable anyway**, the honest version is a proxy behind a timelock
long enough for participants to see an upgrade queued and revoke their allowances before
it lands. That is the property a timelock would be there to buy, and the document should
say so rather than treating the delay as ceremony.

---

## 11. What this contract does not do

**No `permit`, for now.** Both tokens defer it
([cash section 9](design-cash.md#no-permit-eip-2612-for-now),
[asset section 10](design-asset.md#10-what-this-contract-does-not-do)), and it has to be
adopted by both at once or a settlement still carries one stale allowance. When it lands,
the whole of [section 2](#2-a-trade-is-agreed-before-it-settles) collapses into one
transaction carrying both signatures, and `propose` becomes optional rather than required.
That is the version of this contract worth building next.

**No partial fills.** A proposal settles in full or not at all. Partial fills need a
remaining-quantity accumulator and a rule for what happens to the unfilled part, and
neither token has a matching notion of a partially delivered instrument.

**No netting**, and this is the widest gap between what this contract does and how
large-value settlement is actually run. Netting exists for liquidity: gross settlement
requires every payer to fund every trade in full, while multilateral netting can cut the
funding requirement by an order of magnitude. Participants on a gross system hold
correspondingly more cash, and "the log stays readable"
([section 8](#8-events)) is a thin answer to that at scale.

Two things make gross defensible as the starting point rather than a naive choice. Atomic
DvP against tokenised cash is gross per transaction by construction, which is the model
[Design](DESIGN.md#where-dvp-runs-today) describes, and the payment system it names, SIC,
is an RTGS: gross is in the name. And netting is not a variation on this contract, it is a
different one, with a netting cycle, a defined set of participants, and a failure mode
where a single default unwinds the whole cycle. It belongs beside this contract, not
inside it.

**No multi-leg or basket trades.** Two legs, two tokens, one seller and one buyer.

**No price, no oracle, no fees.** The proposal states two amounts. Whether their ratio is
a fair price is a question for whoever proposed it.

**No order book, no trade discovery.** Finding a counterparty and agreeing a price happen
elsewhere; this contract settles trades that are already agreed.

It does do **bilateral matching** in the settlement sense, which is a different thing: the
seller's proposal and the buyer's `termsHash` are two independent assertions of the same
trade, and nothing moves unless they agree
([section 2](#2-a-trade-is-agreed-before-it-settles)). What it lacks against a CSD's
matching is tolerance and repair. There are no matching tolerances, no partial matches, and
no way to amend a proposal: a mismatch is a revert, and the fix is a new proposal. For two
institutions that agreed a trade out of band, exact match or nothing is the right default,
and it is the only one that needs no rules about how far apart two versions may be.

---

## 12. Gas

A settlement is two `transferFrom` calls plus this contract's own bookkeeping.

| cost                     | detail                                                      |
| ------------------------ | ----------------------------------------------------------- |
| registry calls from here | none                                                        |
| registry calls via cash  | 4 ([cash section 10](design-cash.md#10-gas))                |
| registry calls via asset | 3 ([asset section 11](design-asset.md#11-gas))              |
| this contract, `propose` | one trade record written                                    |
| this contract, `settle`  | one status write, two `immutable` reads, two external calls |

**Seven registry round trips per settlement**, each a `STATICCALL` into the registry's
UUPS proxy and therefore each carrying a `delegatecall` hop. That is the number that
decides whether the network meets its settlement window, and no token document could state
it because neither sees both legs.

**Not yet measured.** A `forge snapshot` committed to the repo and gated in CI, as both
token documents promise. If seven round trips prove to be the bottleneck, the
`complianceOf` getter discussed in [cash section 10](design-cash.md#10-gas) would fold
them into two, and this is the measurement that should decide it.

On a permissioned Besu network gas price is zero or near zero, so this is a throughput
question rather than a cost one: gas per settlement sets settlements per block.

---

## Summary of decisions

| #  | Decision                                                                             |
| -- | ------------------------------------------------------------------------------------ |
| 1  | No custody, no balances; the contract is never a party to a transfer                 |
| 2  | Terms stored on propose and asserted again on settle; two instructions must match    |
| 3  | The seller proposes, the buyer settles; direction is a default, not a necessity      |
| 4  | Every proposal expires; a fail still costs the buyer nothing, and that is a gap      |
| 5  | No registry calls from here; the tokens refuse, and `canSettle` previews the answer  |
| 6  | The trade names currency and ISIN, and settlement verifies both                      |
| 7  | Status written before the transfers; cash leg first as the likelier revert           |
| 8  | Terms repeated in `TradeSettled`; no reason codes; nothing emitted on expiry or fail |
| 9  | No roles at all; nothing to privilege                                                |
| 10 | Not upgradeable; it is the spender on both tokens, and redeployment is cheap         |
| 11 | No `permit` yet, no partial fills, no netting, no baskets, no prices, no order book  |
