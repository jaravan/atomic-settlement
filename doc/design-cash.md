# Tokenized Cash — Design

The cash leg: an ERC-20 representing commercial bank money, or a simplified CBDC, with
compliance enforced by the contract itself rather than by the systems around it.

What the three contracts have to agree on — settlement risk, DvP, and why the contract in
the middle of a settlement can never be KYC'd — is in [Design](DESIGN.md).

---

## 1. Compliance state lives in the registry, not the token

**Decision:** the token holds **no KYC state of its own**. Admission and classification are
read from [`upgradeable-kyc-registry`](https://github.com/jaravan/upgradeable-kyc-registry)
via `IKYCRegistryV2`.

```solidity
function isApproved(address) external view returns (bool);   // approved, unexpired, unsanctioned
function isSanctioned(address) external view returns (bool);
function tierOf(address) external view returns (Tier);       // UNSET, RETAIL, INSTITUTIONAL, CROSS_BORDER
```

The registry's three tiers are exactly the classification this token needs, so it does not
redefine them.

**Rejected:** a local whitelist managed by a compliance officer role on this contract.

- Duplicates state that already exists, and the duplicate drifts
- An address sanctioned in the registry would keep transacting here until someone
  remembered to mirror the change
- Would need mirroring into every future contract on the network

**Consequence:** `COMPLIANCE_OFFICER_ROLE` manages no whitelist. It manages freeze and
unfreeze, which is the one token-specific control that has to be exercised urgently.

### The registry address is `immutable`

Set in the constructor, never changeable.

- The registry is UUPS-upgradeable, so its address is already stable across its own
  upgrades. Repointing would only be needed for a full redeploy
- Reading an `immutable` costs no `SLOAD`, and this is read three times on a plain
  `transfer`, four on a `transferFrom` (section 10)
- A settable address is a governance attack surface on the most security-critical
  dependency: whoever can repoint it can point at a registry that approves everyone

**Tradeoff:** if the registry is ever redeployed at a new address, this token is migrated
rather than reconfigured. Consistent with it being non-upgradeable anyway.

### What `immutable` does not buy

It fixes _which_ contract is asked, not _what that contract answers_. The registry is
UUPS-upgradeable, so whoever holds its upgrade rights can ship an implementation where
`isApproved` returns true for everyone. That is the same outcome as repointing this token
at a hostile registry, reached through a door this contract does not control.

Two consequences worth stating rather than discovering:

- **This token inherits the registry's upgrade governance as its own trust root.** The
  security of every check in section 3 is bounded by whatever multisig or timelock guards
  `_authorizeUpgrade` over there. A reviewer assessing this token has to read that repo too;
  pinning the submodule (see `.gitmodules` and Dependabot) is what keeps the version under
  review explicit.
- **It is an availability dependency, not only an integrity one.** A registry upgrade that
  reverts or removes `tierOf` halts every transfer of this token, because section 4 requires
  a tier and section 3 requires an approval. There is no local fallback and deliberately no
  way to repoint, so the recovery path is a registry fix, not a token change.

Neither is an argument for making the address settable — that adds a second door without
closing the first, and the first at least sits behind a contract whose upgrade process is
itself designed and reviewed. It is an argument for the two repos being governed as one
system, and for the registry's admin keys being held at least as carefully as this token's.

---

## 2. Roles

```
   DEFAULT_ADMIN_ROLE            grant/revoke every role · set per-tier limits
          │                      cold: whatever multisig ceremony governs changes
          │ grants and revokes
          │
          ├──▶ ISSUER_ROLE               mint · burn            supply in and out
          │                              burnFrom               frozen accounts only
          │
          ├──▶ COMPLIANCE_OFFICER_ROLE   freeze · unfreeze      one address    HOT
          │
          └──▶ PAUSER_ROLE               pause · unpause        whole contract HOT
```

**Decision:** OpenZeppelin `AccessControl`, not `Ownable`. Issuance sits with treasury,
freezes with compliance, the emergency stop with operations. Different teams, different
approval chains; one key misrepresents how the institution works.

**Split by tempo, not only by team.** How fast a key must be reachable sets how hot it is
stored, and a hot key's powers should be as narrow as the job allows. An incident or a
sanctions hit has to be actionable in minutes; a role change does not.

**So limits are configured by admin, not by compliance.** Freezing is urgent and
per-address; limit policy is network-wide and changes perhaps once a year. Bundled, one
compromised hot key could raise every tier's cap and silently disable the mechanism section
4 exists to build — a far larger blast radius than freezing an address.

**Rejected:** a fifth role for limits. A dedicated key for a setter called once a year is
ceremony, not control. The cost is that admin is no longer purely a role-granting root.

**The separation is procedural, not cryptographic.** Admin can grant itself any role and
then mint, freeze or pause. What the split buys is that the grant happens first, as a
visible on-chain event; it does not make the other roles independent of admin.

**Deployment constraint:** `ISSUER_ROLE` and `COMPLIANCE_OFFICER_ROLE` must be held by
different parties, or the two-key control in section 9 reduces to a single actor. The
contract enforces the _sequence_ — `burnFrom` reverts unless a freeze is already in place —
but it cannot tell whether the two roles sit with the same person. The deploy script should
assert it.

---

## 3. Who gets checked on a transfer

```
transfer       from ─────────────────▶ to         the sender is also the
               isApproved              isApproved   spender, so there is
               not frozen                           nothing more to check


transferFrom   spender        directs the move, never holds the money
               !isSanctioned  ← and nothing else: a contract can
                    │           never be isApproved
                    ▼
               from ─────────────────▶ to
               isApproved              isApproved
               not frozen
```

**The spender is not required to be `isApproved`.** It cannot be: on a settlement the
spender is a contract, and a contract can never be approved in the registry
(see [_Scope_](DESIGN.md#scope)). Requiring it would fail every settlement, not just some.

**But sanctions are still checked on the spender.** A sanctioned party must not be able to
_direct_ money even when it holds none. The two checks differ in kind: `isSanctioned` is a
network-level block by the operator and can apply to any address at all, while `isApproved`
is an onboarding statement by one member's compliance team and can only be true for someone
that member onboarded. For an address that is nobody's customer, only the first means
anything.

Checking it costs nothing when it does not apply. The contract cannot tell a settlement
contract from a custodian or broker acting for a client: on the first the check passes
trivially, on the second — a real party with real sanctions exposure — it is the whole
point.

**Where the check lives.** OpenZeppelin routes `transfer` and `transferFrom` through
`_update`. The spender check does not go there, because on a direct `transfer` the spender
_is_ the sender, and `isApproved(from)` already implies not sanctioned. It goes on
`transferFrom` alone, so direct payments never pay for it:

```solidity
// Runs for transfer, transferFrom, mint and burn. The sender side is guarded only when the
// money is going somewhere -- a burn (to == 0) skips it; see below.
function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {/* isApproved(from), not frozen, tier limit */}
    if (to != address(0)) {/* isApproved(to) -- also covers the mint recipient */}
    super._update(from, to, value);
}

// Only transferFrom pays for the spender check.
function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    if (registry.isSanctioned(msg.sender)) revert SpenderSanctioned(msg.sender);
    return super.transferFrom(from, to, value);
}
```

**Why a burn skips the sender-side checks.** Those checks exist to stop money reaching a
party who should not have it. A burn delivers to nobody: the balance leaves circulation and
total supply falls. There is no counterparty to protect, and `address(0)` has no tier to
look up, so mint and burn are outside the tier limits either way — supply is governed by
`ISSUER_ROLE` (section 7), not by them.

Skipping them is also what makes `burnFrom` possible at all. Its target is frozen by
requirement and, in the case that matters, sanctioned as well; running `isApproved(from)`
and the freeze check on a burn would make the function revert in exactly the circumstances
it exists for. Nothing is loosened by this. `_update` was never what stopped an arbitrary
holder from burning — there is no public burn entry point, and both burn paths are
`ISSUER_ROLE`.

### Previewing the checks

The rules above are enforced when a transfer runs. A caller often needs the answer before
that, and a settlement contract needs it most of all: it cannot ask the registry itself
without duplicating this section
([settlement section 5](design-settlement.md#5-compliance-stays-in-the-tokens)).

```solidity
function canTransfer(address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
function canTransferFrom(address spender, address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
```

Two functions because the two paths check different things: only `transferFrom` looks at
the spender, and only it consults an allowance. Mirroring the split means a caller never
has to invent a spender to ask about a plain payment.

**The preview and the enforcement are the same predicate.** One internal function decides;
`_update` and `transferFrom` revert on what it returns, and these two hand it back
unchanged. A preview written separately would be a second copy of the rules in the one
place nobody would notice it drifting.

**`reason` is the selector of the error the real call would revert with**, not a code of
our own. There is then nothing to keep in step: the vocabulary is the error list itself.
The balance and allowance checks are included, so a caller gets the whole answer rather
than the compliance half of it.

These are views over state that can change in the next block. They answer "would this work
now", which is what an operator needs before submitting, not a guarantee.

### Freezing does not clear allowances

A freeze blocks outbound transfers, so `transferFrom` from a frozen account reverts. The
allowance itself stays put, unusable until the freeze lifts.

**Rejected:** deleting allowances on freeze. They cannot be enumerated on-chain, so it
could only ever be done for the ones someone happens to name. And freeze is a hot-key
action (section 2): blocking transfers is reversible, deleting approvals is not, so a
mistaken or compromised freeze would force the account to rebuild every counterparty
relationship.

---

## 4. Transfer limits

Two caps per tier, set by `DEFAULT_ADMIN_ROLE` (section 2): one per transaction, one per
calendar day. The per-transaction cap is a single comparison. The daily cap needs state.

**Chosen: a fixed calendar-day window.** Each sender carries a day number and a running
total. If the current day differs from the stored one the total resets; otherwise the
amount is added and checked against the tier's cap.

```
if (dailyLimit != NO_LIMIT) {                                  // see "A cap can be set to no cap"
    today = block.timestamp / 1 days
    if (usage.day != today) { usage.day = today; usage.spent = 0; }
    require(usage.spent + amount <= dailyLimit);
    usage.spent += amount;
}
```

O(1), no loops, one storage slot: a `uint40` day number and a `uint216` total pack into 256
bits.

**A calendar day is the intended meaning, not a compromise.** A sender can use one day's
allowance late and the next day's early, moving twice the cap either side of midnight. That
is two days' limits used on two days. Card schemes, payment mandates and AML aggregation
thresholds are all written per calendar day, and this follows them.

**The day is UTC.** `block.timestamp / 1 days` counts days from the Unix epoch, so the
window rolls at 00:00 UTC for every holder regardless of where they are. The rules being
followed here are written for a local business day, so on a network whose participants sit
in one timezone this is off by the local UTC offset, and on a network spanning several there
is no single answer to be off from. A local day would mean either a per-holder offset — more
state on the hot path, set by whom? — or a network-wide one, which is the same arbitrary
choice as UTC but harder to reason about from a block explorer. UTC is chosen because it is
the one boundary every participant computes identically.

**Rejected: a rolling 24-hour window.** A different control, and not the one specified
here. Enforcing it exactly means storing every `(timestamp, amount)` and pruning on each
transfer: unbounded storage, gas that scales with how busy a sender has been, and a cheap
way to inflate a victim's future costs. Unbounded loops in a transfer path are
disqualifying. Approximations avoid the loop but add arithmetic to every transfer and a
margin of error in both directions — to enforce a rule no regulation states.

### Limits are set per tier, never per address

One limit pair per tier, no per-address override. The entire policy is three entries,
readable in full: anyone can answer "what are our limits" from the contract without
enumerating holders. Per-address overrides scatter that policy across as many slots as
there are addresses, so nobody can see it whole again — and an override is a quiet way to
exempt one party, where a tier change is visible, attributed to the registry's KYC officer,
and reviewable. A customer who genuinely needs different limits is a classification
question: reclassify them, or argue for a new tier.

**Interface consequence:** the setter takes a `Tier`, not an `address`. Adding per-address
overrides later would be additive, so nothing here forecloses it.

### A cap can be set to no cap

Limits are enforced on `from`, and on a settlement `from` is the paying bank — the
settlement contract is only the spender. So a DvP trade consumes the payer's daily
allowance, and it consumes it in one transaction. A wholesale settlement is routinely larger
than any figure that would be a meaningful daily limit for a person, which leaves the token
with a choice between capping the use case it was built for and setting a number so large it
only pretends to be a control.

**Chosen: an explicit `NO_LIMIT` sentinel.** A tier whose cap is set to `NO_LIMIT`
(`type(uint256).max`) is uncapped, and the contract skips both the comparison and the
storage write for that tier — an uncapped sender never pays for the accumulator it does not
use. The point is legibility: reading the policy back gives `NO_LIMIT` rather than
`999,999,999,000000`, so nobody has to judge whether a very large number was a decision or a
typo.

**Zero means zero, so the contract fails closed.** An unconfigured tier reads as `0` and
cannot transfer at all. The sentinel is at the opposite end of the range from the default
precisely so that forgetting to configure a tier blocks transfers rather than silently
uncapping them.

**The cap means different things at different tiers**, and the doc should say so rather than
implying one uniform control:

- **`RETAIL`** — a genuine AML threshold. Binding, sized to the rules being followed, and
  the reason the mechanism exists at all.
- **`INSTITUTIONAL`** — normally `NO_LIMIT`. A daily cap on a settlement bank is not an AML
  control; if it binds at all it binds on a legitimate trade, and the failure mode is a
  failed settlement rather than a prevented crime. Where an operator does set one, it is a
  circuit breaker against runaway automation, and it should be sized as one.
- **`CROSS_BORDER`** — the operator's call, and the one tier where a cap may be doing real
  sanctions or capital-control work rather than fraud control.

**Consequence for the settlement contract:** a trade can still revert on the payer's limit
if an operator caps `INSTITUTIONAL`. That is a policy failure, not a protocol one, and it
surfaces as the limit error rather than as a mysterious settlement failure — which is the
argument for a distinct error per cause throughout this document.

### An `UNSET` tier reverts

Limits come from the tier, so a transfer needs one. If `tierOf(from)` is `UNSET` the
transfer reverts with its own error rather than falling back to a default.

Falling back to the strictest tier would let an unclassified address transact at a limit
nobody assigned it — enforcement in appearance, a default in fact. The registry already
says an unclassified address must not silently read as `RETAIL`, and a distinct error keeps
the cause legible: "no tier" is an onboarding problem, not a compliance breach.

**Consequence:** `isApproved` alone is not enough to transact — onboarding must set a tier
as well.

---

## 5. Freeze

**Decision:** `COMPLIANCE_OFFICER_ROLE` can freeze any address. A frozen address **cannot
send** but **can still receive** — matching how a frozen bank account behaves: incoming
payments land, the holder cannot move anything out. Blocking inbound would strand funds
already in flight and let a freeze fail an unrelated counterparty's settlement.

**Freeze and unfreeze emit a `bytes32` reason code**, not a string: one word instead of
unbounded calldata, and it forces an enumerated set a compliance system can query rather
than free text only a human can read.

**Freeze is also the precondition for `burnFrom`** (sections 7 and 9). Nothing about the
freeze itself changes — it still only blocks outbound transfers, and it is still
reversible — but it is now the first of the two keys a seizure needs, which is why the
reason code matters more than it would for a block alone. A compliance officer acting alone
still cannot destroy anything; freezing is what makes a later `ISSUER_ROLE` call possible,
in public, with a stated cause.

---

## 6. Pause

**Decision:** `PAUSER_ROLE` halts all transfers, mints and burns — `burnFrom` included.
OpenZeppelin `Pausable`.

Pause is a **network-incident** control — something is wrong with the contract or the
chain; freeze is the **per-address** instrument. Views stay readable while paused.
`approve` is also blocked: granting new spending authority during an incident serves no
purpose and could stage a drain for the moment the pause lifts.

---

## 7. Mint and burn

**Decision:** `ISSUER_ROLE` only. Mint represents money entering the system — a bank
depositing central bank reserves, or an issuer creating a liability; burn represents
withdrawal. The mint recipient must be `isApproved`, and no supply path consumes a tier
limit (section 3).

Two burn paths, for two different situations:

- **`burn(value)`** takes from the issuer's own balance. This is the ordinary redemption
  route: to withdraw from a customer, the customer transfers to the issuer first, then the
  issuer burns. Every cooperative redemption uses this and only this.
- **`burnFrom(account, value, reason)`** takes from a holder that has not consented. It
  **reverts unless `account` is frozen**, so `COMPLIANCE_OFFICER_ROLE` must have acted
  first, in a separate transaction from a separate key. It carries a `bytes32` reason code,
  the same enumerated set a freeze uses (section 5). Section 9 sets out why this exists and
  what it costs.

The frozen precondition is the whole control. Without it `burnFrom` would be an unaudited
way for one key to destroy anyone's holdings; with it, the destruction can only follow a
public, attributed, reversible act by a different role. Sender-side compliance checks do
not apply to either path (section 3), which is deliberate: a seizure target is typically
sanctioned, and requiring it to be `isApproved` would disable the function exactly when it
is needed.

All three paths emit events carrying the acting issuer, so every supply change is
attributed.

**`ISSUER_ROLE` on all three is the invariant that replaces the `_update` guard.** Because a
burn skips the sender-side checks (section 3), nothing in `_update` prevents a balance from
being reduced without its holder's consent — access control is the whole of the protection,
and there is no public burn entry point for a holder or anyone else. It is worth an explicit
test: no address without `ISSUER_ROLE` can reduce any balance it does not own.

---

## 8. Decimals and denomination

Balances are whole numbers. `decimals()` only says where to put the decimal point when one
is displayed.

**Decision: `decimals() == 6`.** One euro is 1,000,000 units, so the smallest amount the
token can hold is 0.000001 EUR — four digits finer than a cent.

**Why not 2**, one unit per cent? Because a cent cannot be split. Interest, pro-rata
allocations and price × quantity rarely divide evenly, so each one has to round to a whole
cent and the leftover has to go somewhere. Repeat that across a day of settlements and the
books stop reconciling. The four spare digits absorb it.

**Why not 18**, the EVM default? That is a habit inherited from ether, not a property of
money. It buys precision nobody needs, and it invites mistakes when an 18-decimal asset
token and this token appear in the same settlement.

**6** is also what tokenized fiat already uses: USDC and EURC both do.

**Also: the contract records its own currency** — `"EUR"`, `"USD"` — as an immutable
`bytes3` holding the ISO 4217 code.

Each deployment is one currency. A euro token and a dollar token are two separate
contracts, because an ERC-20 has a single balance mapping with no way to keep two
currencies apart inside it. The currency is therefore fixed when the contract is deployed,
which is why it can be `immutable`.

This matters when a settlement contract handles more than one cash leg. It can read the
code and confirm it is paying euros with euros, instead of trusting that whoever configured
it wired up the right address.

---

## 9. What this contract does not do

### Not upgradeable

No proxy. The compliance rules here are deliberate and fixed; if they must change, deploy a
new token and migrate balances through a controlled migration contract — a visible,
auditable event rather than a silent change of behaviour under a stable address. Upgrade
patterns are covered in `upgradeable-kyc-registry`, where they belong: the registry must
evolve because sanctions regimes and KYC requirements evolve. A unit of currency does not.

### No `permit` (EIP-2612), for now

The [scope section](DESIGN.md#scope) notes that an allowance is permission rather than
escrow, so a stale one is a settlement that fails. The buyer can hold that window down to
seconds by sending `approve` and `settle` back-to-back, but not to zero: they are calls to
two different contracts, so they are two transactions. The seller's window is wider still,
because its allowance has to stand from `propose` until the trade settles or expires
([settlement section 3](design-settlement.md#3-lifecycle)). That gap is exactly what
EIP-2612 closes: `permit` turns an approval into a signature, so a settlement contract can
carry both banks' signed approvals and do approve, approve and settle in one transaction.
There is then no window at all in which an allowance sits unused — which is the same
instinct that motivates DvP in the first place.

It is deferred rather than rejected. The argument for it is real, and stronger here than the
usual one: `permit` is normally sold as gasless approval via a relayer, a motivation that
mostly evaporates on a zero-gas permissioned network whose participants run their own nodes
and hold their own keys. What survives is the atomicity, and that is worth having.

What it costs is a signature scheme in a contract whose current surface is deliberately
small: an EIP-712 domain separator, a nonce per holder, deadline handling, and a
compliance-specific question this document would have to answer — a `permit` presented while
`approve` is paused (section 6) must be blocked too, or pause acquires a hole shaped exactly
like the drain it was meant to prevent. That is a section of its own, and it should be
written when the token is otherwise finished rather than folded in alongside first
principles.

**If it is added**, it goes in as `ERC20Permit` with `permit` gated by `whenNotPaused`, and
the spender sanctions check of section 3 stays where it is: `permit` grants authority,
`transferFrom` exercises it, and the check belongs at the point of exercise.

### No role can redirect another holder's tokens

There is no `seize(from, to)`. The one function that reaches into a balance without the
holder's consent is `burnFrom` (section 7), and it can only **destroy**. It names no
recipient, so the caller ends up holding nothing and total supply falls.

Two on-chain preconditions, both enforced by the contract:

- the target must **already be frozen**, which only `COMPLIANCE_OFFICER_ROLE` can do
- the call itself is **`ISSUER_ROLE`**

Section 2 requires those to be different parties, so a seizure is two transactions from two
keys, each emitting its own event: a freeze with a reason code, then a burn attributed to
the acting issuer. Neither key completes it alone, and neither can do it quietly.

**A court-ordered reassignment** is that burn followed by a mint to the new owner. Two
supply events rather than one transfer, on purpose: total supply visibly falls and rises,
so the movement appears in every supply reconciliation instead of reading as an ordinary
payment between two accounts.

**Rejected: no non-consensual path at all.** The stricter version of this rule allows burn
only from the issuer's own balance, and satisfies a court order by having the holder
transfer to the issuer first. It does not work. A holder under a seizure order is by
definition not cooperating, and freezing them — the first thing a court order calls for —
removes even the option. No sequence of calls reaches the balance, so the order cannot be
executed on-chain at all. Answering a foreseeable legal requirement with "impossible" is
not conservatism, it is an unfinished design.

**Rejected: `seize(from, to)` in one call.** One transaction, one key, and in the logs it
is indistinguishable from a transfer. The two-step shape gives up nothing an operator needs
and keeps the seizure legible.

**What this costs, stated plainly.** A compromised `ISSUER_ROLE` key together with a
compromised `COMPLIANCE_OFFICER_ROLE` key can extinguish any balance on the network and
re-mint it elsewhere. That is a real power and this document will not pretend otherwise. It
is bounded in three ways rather than eliminated: it takes two keys held by two teams, it
cannot touch an account that has not first been frozen in public, and it moves total supply
in both directions where an ordinary transfer would not. Holders own a claim that can be
extinguished only through that sequence — not a permission any single operator can revoke.

---

## 10. Gas

Against a vanilla ERC-20 baseline the compliance layer adds one packed storage read/write on
the transfer paths — the daily-usage slot from section 4, which mint and burn never touch and
a `NO_LIMIT` tier skips entirely — plus the registry calls below:

| path                | registry calls                                               |
| ------------------- | ------------------------------------------------------------ |
| `transfer`          | `isApproved(from)`, `isApproved(to)`, `tierOf(from)` — **3** |
| `transferFrom`      | the above plus `isSanctioned(spender)` — **4**               |
| `mint`              | `isApproved(to)` — **1**                                     |
| `burn` / `burnFrom` | none — the sender side is skipped on a burn (section 3)      |

Each is a `STATICCALL` into the registry's UUPS proxy, so each carries a `delegatecall` hop
to the implementation. Three or four of those on a hot path is the whole of the compliance
overhead, and it is the first thing to attack if the numbers come back badly.

**They could be collapsed, and that is a decision waiting on measurement — not a
constraint.** `IKYCRegistryV2` exposes no combined getter today, but the registry is ours:
`KYCRegistry.recordOf` already returns status, expiry and sanctioned flag in a single call,
and only `tierOf` lives in separate V2 storage. A
`complianceOf(address) → (bool approved, bool sanctioned, Tier tier)` would fold three or
four round trips into one, and the registry being UUPS-upgradeable means adding it is
additive rather than a redeploy.

It is deliberately not being added yet, for two reasons. Optimising a path nobody has
measured is how interfaces acquire methods that exist for a caller that turned out not to
need them. And a getter shaped for one consumer is a coupling between the two repos that
should be paid for by evidence, not by assumption — section 1 spends real design effort
keeping this token's dependency on the registry minimal and legible.

**Not yet measured.** The comparison against a vanilla ERC-20 will come from `forge
snapshot` output committed to the repo and gated in CI. If the compliance overhead threatens
the network's settlement window, `complianceOf` is the change to make, and this section
should record the before-and-after rather than the intention.

On a permissioned Besu network gas price is zero or near zero, so this is a **throughput**
question, not a cost one: gas per transfer determines transactions per block, which
determines whether the network meets its settlement window.

---

## Summary of decisions

| #   | Decision                                                                                   |
| --- | ------------------------------------------------------------------------------------------ |
| 1   | No local KYC state. Registry is the source of truth, address `immutable`                   |
| 2   | `AccessControl` with four roles, split by tempo; hot keys kept narrow                      |
| 3   | `from` and `to` fully checked; spender checked for sanctions only                          |
| 4   | Fixed UTC-day window, per tier only, `NO_LIMIT` sentinel, `UNSET` reverts                  |
| 5   | Freeze blocks outbound, allows inbound, emits a reason code                                |
| 6   | Pause halts transfers, mints, burns and `approve`                                          |
| 7   | Mint and burn restricted to `ISSUER_ROLE`; `burnFrom` needs a frozen target                |
| 8   | `decimals() == 6`, plus an immutable ISO 4217 `bytes3`                                     |
| 9   | Not upgradeable; no `permit` yet; the only non-consensual path destroys and needs two keys |
