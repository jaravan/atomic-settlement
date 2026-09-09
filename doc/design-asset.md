# Asset Token — Design

The asset leg: an ERC-20 standing for a single bond issue, with compliance enforced by the
contract rather than by the systems around it.

The things all three contracts have to agree on (settlement risk, DvP, and why the
contract in the middle of a settlement can never be KYC'd) are in [Design](DESIGN.md). The
cash leg is in [Tokenized Cash](design-cash.md).

Where this token and the cash token agree, this document says so and links to the argument
instead of making it again. The length is spent on the places a security has to behave
differently from money.

| Question                                   | Cash                              | Asset                         | Section          |
| ------------------------------------------ | --------------------------------- | ----------------------------- | ---------------- |
| Source of compliance state                 | registry, `immutable`             | same registry, same decision  | [1][s1]          |
| `from` and `to` checked, spender sanctions | yes                               | yes, unchanged                | [3][s3]          |
| Freeze, pause                              | yes                               | yes, unchanged                | [5][s5], [6][s6] |
| Per-tier transfer limits                   | yes, the longest section          | none                          | [4][s4]          |
| Tier read on a transfer                    | yes                               | no, nothing consumes it       | [4][s4]          |
| Taking tokens without consent              | burn, so supply falls             | forced transfer, supply fixed | [8][s8]          |
| `decimals()`                               | 6                                 | 0                             | [9][s9]          |
| Instrument identity                        | [ISO 4217][iso4217] currency code | [ISO 6166][iso6166] ISIN      | [9][s9]          |

[s1]: #1-compliance-state-lives-in-the-registry-not-the-token
[s3]: #3-who-gets-checked-on-a-transfer
[s4]: #4-no-transfer-limits
[s5]: #5-freeze
[s6]: #6-pause
[s8]: #8-a-bond-cannot-be-destroyed-and-recreated
[s9]: #9-denomination-and-instrument-identity
[iso4217]: https://en.wikipedia.org/wiki/ISO_4217
[iso6166]: https://en.wikipedia.org/wiki/International_Securities_Identification_Number
[iso3166]: https://en.wikipedia.org/wiki/ISO_3166-1

Three of those rows are the real content. The rest is recorded so the shared decisions are
visible rather than assumed.

---

## 1. Compliance state lives in the registry, not the token

Unchanged from the cash leg. No local KYC state; admission and sanctions are read from
[`upgradeable-kyc-registry`](https://github.com/jaravan/upgradeable-kyc-registry) through
`IKYCRegistryV2`, and the address is set in the constructor and never changes. The
argument, the rejected local whitelist, and the limits of what `immutable` buys you are in
[cash section 1](design-cash.md#1-compliance-state-lives-in-the-registry-not-the-token),
and they apply here word for word.

One point only becomes visible once there are two tokens. Both legs read the _same_
registry contract, so a settlement checks each bank against one source of truth rather
than two that can disagree. A bank approved for cash and unapproved for securities is not
a state this system can reach. If either token kept a local list, that state would exist,
and a settlement is exactly where it would surface.

There is a consequence that [section 8](#8-a-bond-cannot-be-destroyed-and-recreated)
depends on. This token inherits the registry's upgrade governance as its trust root, in
the same way the cash token does
([cash section 1](design-cash.md#what-immutable-does-not-buy)). Both tokens share that
root, so the settlement contract has one trust assumption to reason about rather than two.

---

## 2. Roles

```
   DEFAULT_ADMIN_ROLE            grant/revoke every role
          │                      cold: whatever multisig ceremony governs changes
          │ grants and revokes
          │
          ├──▶ ISSUER_ROLE               mint · burn            issue and redemption
          │                              forceTransfer          frozen accounts only
          │
          ├──▶ COMPLIANCE_OFFICER_ROLE   freeze · unfreeze      one address    HOT
          │
          └──▶ PAUSER_ROLE               pause · unpause        whole contract HOT
```

Four roles, `AccessControl`, split by how fast each key has to be reachable. All of that
is [cash section 2](design-cash.md#2-roles). Two differences matter.

`DEFAULT_ADMIN_ROLE` has no limit setter here, because there are no limits
([section 4](#4-no-transfer-limits)). It goes back to being purely a role-granting root,
which is the property the cash doc gave up reluctantly.

The second difference is about tempo, and it is easy to miss because the role has the same
name on both tokens. A cash issuer mints continuously: every deposit of reserves is a
mint. A securities issuer mints once, at issue, and burns once, at redemption. In between,
on an instrument that might run for ten years, the key is used only for a court-ordered
forced transfer ([section 8](#8-a-bond-cannot-be-destroyed-and-recreated)), which is by
nature rare. A key used twice in the life of an instrument should be stored like one. The
contract cannot enforce that, so the deploy runbook has to say it.

The deployment constraint carries over unchanged: `ISSUER_ROLE` and
`COMPLIANCE_OFFICER_ROLE` must sit with different parties, or the two-key control in
[section 8](#8-a-bond-cannot-be-destroyed-and-recreated) collapses to a single actor. The
contract enforces the sequence, since `forceTransfer` reverts unless a freeze is already
in place, but it has no way to tell whether the two roles belong to the same person. The
deploy script asserts it.

---

## 3. Who gets checked on a transfer

```
transfer       from ─────────────────▶ to         the sender is also the
               isApproved              isApproved   spender, so there is
               not frozen                           nothing more to check

transferFrom   spender        directs the move, never holds the security
               !isSanctioned  ← and nothing else: a contract can
                    │           never be isApproved
                    ▼
               from ─────────────────▶ to
               isApproved              isApproved
               not frozen
```

Identical to [cash section 3](design-cash.md#3-who-gets-checked-on-a-transfer), spender
exemption included. A settlement contract cannot be KYC'd, so requiring
`isApproved(msg.sender)` would fail every settlement rather than some of them, while
`isSanctioned(msg.sender)` still stops a sanctioned party directing a delivery it does not
hold.

There is one check the cash leg makes and this one skips: `tierOf`. Nothing on this token
consumes a tier, so nothing reads one, and an `UNSET` tier does not block a transfer here.
That diverges from [cash section 4](design-cash.md#an-unset-tier-reverts), and it has a
consequence worth naming. An address can be eligible to hold this bond while being unable
to move cash. A DvP trade with such a party fails on the cash leg, with the cash leg's
tier error, so classification failures all surface in one place instead of two.

> The obvious objection is that classification ought to matter _more_ for a security, not
> less. In substance that is true; suitability is a securities idea before it is a
> payments one. But the securities version of the question is "who may hold **this**
> instrument", and the registry's three tiers do not answer it. A bond restricted to
> professional investors in the EEA is not the same statement as `INSTITUTIONAL`.
> Requiring a non-`UNSET` tier here would gate nothing while looking like it gated
> something, which is the failure [cash section 4](design-cash.md#an-unset-tier-reverts)
> calls enforcement in appearance and a default in fact. The control that would actually
> do the job is a per-instrument eligibility gate, which
> [section 10](#10-what-this-contract-does-not-do) defers openly rather than smuggling in
> a tier check as a stand-in.

OpenZeppelin routes `transfer` and `transferFrom` through `_update`, which in v5.6.1 is
the only `virtual` hook on the transfer path; `_transfer`, `_mint` and `_burn` cannot be
overridden. Every check therefore goes in one place, and
[section 8](#8-a-bond-cannot-be-destroyed-and-recreated) has to bypass it explicitly
rather than routing around it:

```solidity
// Runs for transfer, transferFrom, mint, burn and forceTransfer.
function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0) && !_forcing) {
        /* isApproved(from), not frozen. Skipped on a burn, and on a forced transfer (section 8) */
    }
    if (to != address(0)) {
        /* isApproved(to). Also covers the mint and forced-transfer recipients */
    }
    super._update(from, to, value);
}

// Only transferFrom pays for the spender check.
function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    if (registry.isSanctioned(msg.sender)) revert SpenderSanctioned(msg.sender);
    return super.transferFrom(from, to, value);
}
```

Why a burn skips the sender-side checks is
[cash section 3](design-cash.md#3-who-gets-checked-on-a-transfer)'s argument unchanged: a
burn delivers to nobody, so there is no counterparty to protect, and `address(0)` has no
record to look up. Why a forced transfer skips them is
[section 8](#8-a-bond-cannot-be-destroyed-and-recreated), and it is the one place the two
tokens' `_update` differ.

The recipient is never exempt. A forced transfer delivers real securities to a real party,
so `isApproved(to)` runs on it like any other delivery. The bypass is sender-side only,
and only for the sender a freeze has already identified.

### Previewing the checks

```solidity
function canTransfer(address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
function canTransferFrom(address spender, address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
```

Same as [cash section 3](design-cash.md#previewing-the-checks), and for the same reason: a
settlement contract needs to know whether a delivery would succeed without asking the
registry itself, which would duplicate these rules outside the token
([settlement section 5](design-settlement.md#5-compliance-stays-in-the-tokens)). One
internal predicate serves both the preview and the enforcement, and `reason` is the
selector of the error the real call would revert with.

The answers are cheaper here than on the cash leg, because there is no tier to read and no
daily total to accumulate ([section 4](#4-no-transfer-limits)). A forced transfer
([section 8](#8-a-bond-cannot-be-destroyed-and-recreated)) has no preview: it bypasses the
sender-side checks by design, so there is no question to ask.

### Freezing does not clear allowances

Unchanged from [cash section 3](design-cash.md#freezing-does-not-clear-allowances). A
freeze blocks outbound transfers and the allowance survives it, unusable. Deleting
allowances on freeze is rejected for the same two reasons: they cannot be enumerated
on-chain, and a hot-key action should not do something irreversible.

---

## 4. No transfer limits

This token has no per-transaction cap and no per-day cap. The longest section of the cash
design ([cash section 4](design-cash.md#4-transfer-limits)) has no counterpart here.

A daily cap on money is an AML control. Its job is to make structuring expensive: breaking
one large payment into many small ones to stay under a reporting threshold. The rules it
enforces are written about money, per calendar day, and the cash leg follows them.

A bond is not the vehicle for that. Moving securities does not launder anything by itself.
The laundering surface of a bond trade is the cash on the other side of it, and that leg
already carries the cap. A second cap on the asset leg catches no crime the cash leg
misses. What it does catch is a legitimate delivery, for a reason no regulation states,
which is the ground on which [cash section 4](design-cash.md#4-transfer-limits) rejected
the rolling 24-hour window.

Three things follow, and all three are improvements:

- No accumulator slot. The packed `(day, spent)` read and write that the cash leg pays on
  every transfer simply does not exist here ([section 11](#11-gas)).
- No `tierOf` call, because nothing consumes the tier
  ([section 3](#3-who-gets-checked-on-a-transfer)).
- The asset leg can never fail a settlement on a limit.
  [Cash section 4](design-cash.md#a-cap-can-be-set-to-no-cap) had to introduce a
  `NO_LIMIT` sentinel because a wholesale settlement burns through the paying bank's whole
  daily allowance in one transaction. The delivering party has no equivalent exposure, so
  it needs no sentinel to escape one.

**Rejected: a per-transaction cap as a fat-finger guard.** A ceiling on a single delivery
would catch a mistyped quantity, and that is a real operational risk. The problem is where
you would set it. It has to sit above the largest legitimate trade, and for a bond issue
the largest legitimate trade is the entire issue: a primary allocation moves the whole
outstanding amount to one party on day one. Set the ceiling above that and it catches
nothing; set it below and issuance breaks. The check belongs in whatever system submits
the trade, where the expected size is actually known.

**Rejected: limits per instrument instead of per tier.** This runs into the same objection
[cash section 4](design-cash.md#limits-are-set-per-tier-never-per-address) raises against
per-address overrides, that they scatter a policy nobody can read whole. It also has a
problem of its own: each bond is already its own contract, so "per instrument" is the
finest granularity available, and it still answers no rule anyone has written down.

---

## 5. Freeze

Unchanged from [cash section 5](design-cash.md#5-freeze). `COMPLIANCE_OFFICER_ROLE` can
freeze any address; a frozen address cannot send but can still receive; freeze and
unfreeze emit a `bytes32` reason code rather than a string.

Blocking inbound would hurt more here than on the cash leg. A freeze landing between a
trade's two legs cannot strand anything, since the whole transaction reverts, but a freeze
on a party expecting delivery would fail an unrelated counterparty's settlement. On the
asset leg that counterparty has usually already committed the cash side to a settlement
window.

Freeze is also the precondition for `forceTransfer`
([section 8](#8-a-bond-cannot-be-destroyed-and-recreated)), the same way it gates
`burnFrom` on the cash leg. Nothing about the freeze itself changes. It blocks outbound
transfers, it is reversible, and a compliance officer acting alone still cannot move
anything. What changes is that it is now the first of two keys, which is why the reason
code carries more weight than it would for a block on its own.

---

## 6. Pause

Unchanged from [cash section 6](design-cash.md#6-pause). `PAUSER_ROLE` halts transfers,
mints, burns, `approve` and `forceTransfer`. Views stay readable.

What differs is blast radius, not mechanism. Pausing the cash token halts a payment
system. Pausing an asset token halts trading in one instrument: every DvP trade with this
bond as a leg reverts, and trades in every other instrument carry on. That is the right
granularity for an instrument-specific incident, such as a disputed issuance or a
corporate action gone wrong, and it is another reason each issue gets its own contract
([section 9](#9-denomination-and-instrument-identity)).

---

## 7. Issuance and redemption

`ISSUER_ROLE` only, and the invariant is that total supply equals the issue size.

`mint(to, value)` is issuance, and the recipient must be `isApproved`
([section 3](#3-who-gets-checked-on-a-transfer)). For a bond this normally happens once:
the full issue is minted to the arranger, or to the initial allottees at the primary
allocation.

`burn(value)` is redemption, and it takes only from the issuer's own balance. To redeem,
the holder delivers the bond to the issuer and the issuer burns it. Every cooperative
redemption goes this way, including the whole issue at maturity.

There is no `burnFrom`. The cash leg has one for a target that will not cooperate
([cash section 7](design-cash.md#7-mint-and-burn)); this token answers the same
requirement with `forceTransfer`, and
[section 8](#8-a-bond-cannot-be-destroyed-and-recreated) is about why.

A non-cooperative redemption composes out of the two primitives. Mandatory redemption of a
holder who will not deliver is `forceTransfer(holder → issuer)` followed by `burn`. The
bonds reach the issuer first, and supply falls only once they are actually held there. Two
transactions, both attributed, and no moment at which the outstanding amount is wrong.
That one primitive covers both the court order and the mandatory call is a good sign it is
the right primitive.

On the burn path, access control is the whole of the protection. Because a burn skips the
sender-side checks ([section 3](#3-who-gets-checked-on-a-transfer)), nothing in `_update`
stops a balance being reduced without its holder's consent. As on the cash leg there is no
public burn entry point, and it is worth an explicit test: no address without
`ISSUER_ROLE` can reduce any balance it does not own.

---

## 8. A bond cannot be destroyed and recreated

This is the one decision where this token does the opposite of the cash token, so it is
set out in full rather than by reference.

### The situation

A court orders that someone's holdings be handed to someone else. That someone will not
cooperate. They will not sign anything, and by the time a court order exists they are
usually frozen and often sanctioned. A contract has two ways to carry this out:

1. **Destroy and recreate.** Delete their 100 bonds, create 100 new ones for the new
   owner.
2. **Force a move.** Move the 100 bonds straight from one to the other, with no signature
   from the holder.

### Why the cash leg chose destroy-and-recreate

[Cash section 9](design-cash.md#no-role-can-redirect-another-holders-tokens) picked the
first option deliberately. Destroying 100 and creating 100 makes the total amount of money
in existence dip and then rise, and that shows up in every supply reconciliation. A
seizure can never be mistaken for an ordinary payment. Being loud is the whole idea.

### Why the same choice is wrong here

A bond issue is a fixed legal quantity. If the issuer sold 1,000 bonds then there must
always be exactly 1,000 on the ledger, and that number gets reconciled against the terms
of the issue by the issuer, by the paying agent, and by anyone holding the instrument.

Run destroy-and-recreate on it:

```
before        1,000 bonds exist   ✅ matches the issue size
after burn      900 bonds exist   ❌ 100 bonds have vanished from a fixed issue
after mint    1,000 bonds exist   ✅ matches again
```

For the gap between those two transactions, the ledger says the issue is 900 while the
paperwork says 1,000. Anything reconciling the two sees a break. And if the second
transaction fails, gets delayed, or goes out with the wrong amount, the break is
permanent: the contract has quietly changed the size of a security.

So the same mechanism is a feature for money and a defect for a bond. Money has no correct
total. It is created and destroyed all day, and a dip carries information precisely
because the total is expected to move. A bond has exactly one correct total, and any
movement in it is itself the alarm.

### Decision

`forceTransfer(from, to, value, reason)`, restricted to `ISSUER_ROLE`, reverting unless
`from` is already frozen.

```solidity
function forceTransfer(address from, address to, uint256 value, bytes32 reason)
    external onlyRole(ISSUER_ROLE) whenNotPaused
{
    if (!frozen[from]) revert AccountNotFrozen(from);   // the first key must have acted
    _forcing = true;                                     // section 3: sender-side checks skipped
    _transfer(from, to, value);                          // _update still runs isApproved(to)
    _forcing = false;
    emit ForcedTransfer(from, to, value, reason, msg.sender);
}
```

The two-key control is unchanged. Only the final step differs:

| Step | Cash                                                  | Asset                               |
| ---- | ----------------------------------------------------- | ----------------------------------- |
| 1    | `COMPLIANCE_OFFICER_ROLE` freezes, with a reason code | the same                            |
| 2    | `ISSUER_ROLE` calls `burnFrom`                        | `ISSUER_ROLE` calls `forceTransfer` |
| 3    | `ISSUER_ROLE` mints to the new owner                  | not needed, and that is the point   |

Neither key completes a seizure alone, and neither can do it quietly. The freeze emits a
reason code, the forced transfer emits its own event naming the acting issuer, the reason
and both parties, and the target has to be frozen first, in public, in a separate
transaction from a separate key.

A forced transfer is also distinguishable from an ordinary one, which is the property
[cash section 9](design-cash.md#no-role-can-redirect-another-holders-tokens) was worried
about losing when it rejected `seize(from, to)`. It emits `ForcedTransfer` alongside the
ERC-20 `Transfer`, so a seizure is a distinct event type in the log rather than a payment
with an odd-looking sender. The cash doc's objection was that a one-call seizure is
indistinguishable from a transfer. That is true of the ERC-20 event, and the answer is to
emit a second one, not to move supply.

### Why `_forcing` is a flag, and what it costs

In OpenZeppelin v5.6.1, `_update` is the only `virtual` hook on the transfer path, and
`_transfer`, `_mint` and `_burn` cannot be overridden. There is therefore no way to route
a forced transfer around the compliance checks. It has to tell `_update` to skip them, and
the flag is that instruction. Four things about it:

- The bypass is sender-side only. `isApproved(to)` still runs
  ([section 3](#3-who-gets-checked-on-a-transfer)).
- It is unreachable except through this function. `_forcing` is private, set and cleared
  within a single call, and nothing external executes in between, since `super._update`
  calls out to nobody. There is no reentrancy window in which the flag is observable.
- It costs a storage write on a path used approximately never, which is a good place to
  put a cost. Where the deployment's compiler and EVM version allow it, transient storage
  (EIP-1153) fits naturally and makes even that negligible.
- It is worth a test that the flag reads false after every path, reverting ones included.

### What this costs

A compromised `ISSUER_ROLE` key together with a compromised `COMPLIANCE_OFFICER_ROLE` key
can move any holding on this instrument to an address of their choosing. That is a real
power and this document will not pretend otherwise.

Compared with the cash leg's version it is worse in one way and better in another. Worse,
because the tokens survive: cash seized by a compromised pair is destroyed and re-minted,
and a total supply that moves is a signal an automated reconciliation can pick up, whereas
here the outstanding amount never changes and the only signal is the event. Better,
because it is only a transfer. The pair cannot inflate or deflate the issue, so the
instrument itself cannot be falsified, and a holder register rebuilt from events still
sums to the issue size.

The power is bounded rather than eliminated: two keys held by two teams, a public freeze
that has to come first, and a dedicated event type. Holders own a claim that can be moved
only through that sequence.

**Rejected: keeping `burnFrom` as well, for symmetry with the cash leg.** A second
non-consensual path is a second thing to secure, and the one case it would serve is a
non-cooperative redemption, which already composes out of `forceTransfer` and `burn`
([section 7](#7-issuance-and-redemption)) without ever putting the outstanding amount into
a wrong state.

---

## 9. Denomination and instrument identity

### `decimals() == 0`

A bond is not divisible. It is issued in a minimum denomination, EUR 100,000 nominal being
typical for a wholesale issue, and a holding is a whole number of those. There is no such
thing as half a bond, so a balance of `100` means one hundred bonds and nothing else.

This is the mirror image of [cash section 8](design-cash.md#8-decimals-and-denomination).
The cash leg needs six decimals because interest and pro-rata allocations do not divide
evenly and the remainder has to land somewhere. The asset leg has the opposite
requirement: divisibility is not a precision the instrument lacks, it is a property the
instrument must not have. Setting `decimals()` to 0 makes that structural instead of a
convention someone has to remember.

It also makes fractional settlement impossible, which is correct. A DvP trade for 100.5
bonds is not a rounding problem to solve, it is a malformed trade, and it should fail as
one.

The tradeoff is tooling. Wallets and explorers that assume 18 decimals will display a
zero-decimal token oddly. On a permissioned network with known participants and known
tooling that is an integration note. On a public chain it would be a stronger objection.

### An `immutable` ISIN

The contract records its own instrument identity as an `immutable bytes12` holding the
[ISO 6166][iso6166] ISIN: twelve characters, being a two-letter country code, nine
alphanumerics and a check digit.

The reasoning is the cash leg's ISO 4217 code again. A settlement contract handling more
than one asset leg can read the ISIN and confirm it is delivering the instrument the trade
names, rather than trusting that whoever configured it wired up the right address. Two
bond issues from the same issuer differ by nothing an address reveals.

Each issue is its own deployment. An ERC-20 has a single balance mapping and no way to
keep two instruments apart inside it, so the identity is fixed at deployment, which is
what allows it to be `immutable`. This is also what gives [section 6](#6-pause) its
granularity: pausing one instrument leaves the others running.

The twelfth character of an ISIN is a Luhn check over the first eleven, and the contract
does not validate it. Those twelve bytes are a constructor argument set once, and the
deploy script validates them off-chain, along with asserting that `ISSUER_ROLE` and
`COMPLIANCE_OFFICER_ROLE` are different addresses ([section 2](#2-roles)). Putting a Luhn
implementation on-chain to check a constant would be contract code guarding against a typo
in a script.

---

## 10. What this contract does not do

### Not upgradeable

No proxy, for [cash section 9](design-cash.md#not-upgradeable)'s reasons, and with more
force behind them. A unit of currency does not change. The terms of a bond change even
less: issue size, denomination and identity are fixed at issue by the documentation the
instrument is sold under. A contract whose behaviour can be altered under a stable address
is a poor representation of something whose defining property is that it cannot be. If the
rules have to change, that is a new instrument.

### No coupons, no corporate actions

No coupon payments, no maturity redemption logic, no calls, no conversions. This token is
a transferable claim and nothing more: mint at issue, transfer, burn at redemption.

That is what "a simplified security" means in the [README](../README.md), and it is a
scope decision rather than an oversight. The subject of this repository is settlement,
moving two legs atomically, not instrument lifecycle. A coupon is a periodic payment in
the cash token driven by a paying agent, and it is a separate contract with a separate
design if it ever gets built. Building it here would double the surface the settlement
document has to reason about, and buy nothing for the thing actually being demonstrated.

### No eligibility gate, deferred rather than rejected

This is the strongest candidate for the next thing the token gains, so it is recorded as a
deferral.

Securities are routinely restricted by holder jurisdiction, through private placements,
Regulation S and prospectus exemptions. The registry already exposes
`jurisdictionOf(address) → bytes2`, an [ISO 3166-1][iso3166] code that neither token reads
today. A per-instrument allowlist of permitted jurisdictions, checked on `to` in
`_update`, would enforce "this bond may only be held in the EEA" on-chain rather than in
whatever system submits the trade. It is a real control answering a real rule, which is
the test [section 4](#4-no-transfer-limits) applied to transfer limits and they failed.

What it costs is a new kind of state. Everything
[section 1](#1-compliance-state-lives-in-the-registry-not-the-token) relies on is
per-holder state owned by the registry. An eligibility list is per-instrument policy owned
by the token, and once one exists this document owes a section on it: who sets it, at what
tempo, against which key, and whether changing it after issue can strand a holder who was
eligible when they bought. That last question has no obvious answer. The honest options
are to block the transfer, to grandfather existing holders, or to forbid changes after
issue, and each is a decision someone could reasonably disagree with.

It is deferred on the same grounds as
[`permit`](design-cash.md#no-permit-eip-2612-for-now). The argument for it is good, and it
should be written as its own section once the token is otherwise finished rather than
folded in next to first principles. [section 3](#3-who-gets-checked-on-a-transfer) states
the consequence of its absence so that the gap is not mistaken for something nobody
thought about.

### No `permit` (EIP-2612), for now

Unchanged from [cash section 9](design-cash.md#no-permit-eip-2612-for-now). This is the
asset side of the same settlement, so the atomicity argument applies identically: both
legs would need it, or a settlement still carries one stale allowance. That the two tokens
have to adopt it together is itself a reason to decide it once, for both, instead of
twice.

### No holder cap

Rejected. A maximum investor count is a genuine constraint under some private-placement
exemptions, but enforcing it on-chain means a holder-count accumulator on the transfer
path, incremented on a first receipt and decremented when a balance hits zero. That is
storage and arithmetic on every transfer, to enforce a rule this instrument has not been
given. It is the same shape as [cash section 4](design-cash.md#4-transfer-limits)'s
rejection of the rolling window, and it would sit more naturally on top of the eligibility
gate above than on its own.

---

## 11. Gas

| path            | registry calls                         | count | vs. the cash leg     |
| --------------- | -------------------------------------- | ----- | -------------------- |
| `transfer`      | `isApproved(from)`, `isApproved(to)`   | **2** | one fewer (`tierOf`) |
| `transferFrom`  | the above plus `isSanctioned(spender)` | **3** | one fewer (`tierOf`) |
| `mint`          | `isApproved(to)`                       | **1** | same                 |
| `burn`          | none, the sender side is skipped       | **0** | same                 |
| `forceTransfer` | `isApproved(to)`                       | **1** | no counterpart       |

There is also no accumulator. The packed `(day, spent)` slot the cash leg reads and writes
on every transfer does not exist here ([section 4](#4-no-transfer-limits)), so this token
is cheaper than the cash leg on every path: one fewer `STATICCALL` into the registry
proxy, and one fewer storage read/write.

None of it is measured yet. The commitment is the same one
[cash section 10](design-cash.md#10-gas) makes: a `forge snapshot` committed to the repo
and gated in CI, compared against a vanilla ERC-20 baseline. If the registry round trips
turn out to dominate, the `complianceOf(address) → (bool approved, bool sanctioned, Tier
tier)` getter discussed there would fold two or three calls into one here too. Note that
this token wants only two of that getter's three fields, which is itself an argument for
measuring before shaping a shared interface around one consumer.

A settlement pays for both legs. The number that decides whether the network meets its
settlement window is not either token's transfer cost but the sum of the two plus the
settlement contract's own overhead. That measurement belongs to
[settlement section 12](design-settlement.md#12-gas), which puts the total at seven
registry round trips per settlement.

On a permissioned Besu network gas price is zero or near zero, so this is a throughput
question rather than a cost one.

---

## Summary of decisions

| #  | Decision                                                                                 |
| -- | ---------------------------------------------------------------------------------------- |
| 1  | No local KYC state; same registry as the cash leg, address `immutable`                   |
| 2  | Same four roles; `ISSUER_ROLE` is a cold key here, used twice in the instrument's life   |
| 3  | `from` and `to` fully checked, spender for sanctions only; no `tierOf` read              |
| 4  | No transfer limits: an AML control on money, and the cash leg already carries it         |
| 5  | Freeze blocks outbound, allows inbound, emits a reason code, and gates `forceTransfer`   |
| 6  | Pause halts one instrument, not the network                                              |
| 7  | `mint` at issue, `burn` from the issuer's own balance only; no `burnFrom`                |
| 8  | `forceTransfer` rather than burn-and-mint, because a fixed issue size must never move    |
| 9  | `decimals() == 0`, plus an `immutable` ISO 6166 ISIN; one deployment per issue           |
| 10 | Not upgradeable; no coupons; eligibility gate and `permit` deferred; holder cap rejected |
