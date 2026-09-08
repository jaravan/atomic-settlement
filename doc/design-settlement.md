# Settlement — Design

`DvPSettlement`: one transaction that moves both legs of a trade, or neither.

Why atomic settlement matters and where it runs today is in [Design](DESIGN.md). The two
legs are [Tokenized Cash](design-cash.md) and [Asset Token](design-asset.md). This
document covers only the contract in the middle.

The design follows three facts about that contract:

| Fact                                           | Consequence                           | Section |
| ---------------------------------------------- | ------------------------------------- | ------- |
| It holds no balances and takes no custody      | it can never be a party, only a mover | [1][s1] |
| An allowance authorises an amount, not a trade | terms must be agreed on-chain first   | [2][s2] |
| It is the spender on both tokens               | it must not be upgradeable            | [9][s9] |

[s1]: #1-the-contract-holds-nothing
[s2]: #2-a-trade-is-agreed-before-it-settles
[s9]: #9-not-upgradeable

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
which [section 9](#9-not-upgradeable) turns into the argument against a proxy.

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
the ones anyone agreed to.** The agreed price has to live somewhere on-chain, and there
are only two places to put it:

- **Both parties' signatures in the call.** This is EIP-712, the same machinery both
  tokens deferred with `permit`
  ([cash section 9](design-cash.md#no-permit-eip-2612-for-now)).
- **Stored state.** One party records the terms, the other executes them.

Stored state, for now, and for the same reason the tokens deferred `permit`: signatures
are a section of their own, and the two tokens have to adopt them together
([section 10](#10-what-this-contract-does-not-do)).

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
stand from `propose` until the trade settles or expires. The buyer approves and settles in
the same breath.

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

**A proposal is a settlement instruction, not an offer.** The price was agreed elsewhere
([section 10](#10-what-this-contract-does-not-do)), so the direction decides which party's
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
                  ┌──────────┐   settle(id)    ┌─────────┐
                  │ PROPOSED │────────────────▶│ SETTLED │  both legs moved
                  └──────────┘   buyer only    └─────────┘
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

settle(tradeId)    // the named buyer only
cancel(tradeId)    // the seller only, while still PROPOSED
```

**Acceptance and execution are the same call.** Splitting them would create a window in
which both parties have agreed and nothing has moved, which is the exposure DvP exists to
remove. `settle` is the acceptance.

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
which is what makes redeployment cheap in [section 9](#9-not-upgradeable).

**Expiry costs no transaction.** `settle` checks `block.timestamp <= deadline`, so an
expired trade is dead without anyone paying to kill it. The record stays in storage,
harmless and unusable.

---

## 5. Compliance stays in the tokens

`settle` calls `transferFrom` on each token, and each token checks the registry itself.
**This contract makes no registry calls at all.** It does not know what a tier is.

Re-implementing the checks here would create a second source of truth, and the settlement
path is exactly where drift between the two would go unnoticed.

The practical benefit is legible failures. A settlement that fails comes back with the
token's own error: the buyer's tier limit, a freeze, a missing approval. The settlement
contract adds no error of its own for anything a token already refuses.

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

## 8. Roles

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

## 9. Not upgradeable

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

## 10. What this contract does not do

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

**No netting.** Settling a hundred trades by moving one net amount is a real efficiency
and a different contract. It also breaks the property that every settlement is one trade
in the log, which is what makes the audit trail readable.

**No multi-leg or basket trades.** Two legs, two tokens, one seller and one buyer.

**No price, no oracle, no fees.** The proposal states two amounts. Whether their ratio is
a fair price is a question for whoever proposed it.

**No matching or order book.** This contract settles agreed trades. Finding the
counterparty and agreeing the price happen elsewhere.

---

## 11. Gas

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

| #   | Decision                                                                           |
| --- | ---------------------------------------------------------------------------------- |
| 1   | No custody, no balances; the contract is never a party to a transfer               |
| 2   | Terms are stored before settlement, because an allowance authorises an amount only |
| 3   | The seller proposes, the buyer settles; settling is the acceptance                 |
| 4   | Every proposal carries a deadline, so no proposal is a free option                 |
| 5   | No registry calls from here; the tokens refuse, and their errors surface unchanged |
| 6   | The trade names currency and ISIN, and settlement verifies both                    |
| 7   | Status written before the transfers; cash leg first as the likelier revert         |
| 8   | No roles at all; nothing to privilege                                              |
| 9   | Not upgradeable; it is the spender on both tokens, and redeployment is cheap       |
| 10  | No `permit` yet, no partial fills, no netting, no baskets, no prices, no matching  |
