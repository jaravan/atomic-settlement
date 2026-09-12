# Asset Token — Design

The asset leg: an ERC-20 standing for a single bond issue, with compliance enforced by the
contract itself.

What the three contracts share is in [Design](DESIGN.md); the cash leg is in
[Tokenized Cash](design-cash.md). Where this token makes the same decision as the cash
token, this document says so and links to the argument. The length is spent on the places
a security has to behave differently from money.

| Question                                   | Cash                              | Asset                         | Section          |
| ------------------------------------------ | --------------------------------- | ----------------------------- | ---------------- |
| Source of compliance state                 | registry, `immutable`             | same                          | [1][s1]          |
| `from` and `to` checked, spender sanctions | yes                               | same                          | [3][s3]          |
| Freeze, pause                              | yes                               | same                          | [5][s5], [6][s6] |
| Per-tier transfer limits                   | yes                               | none                          | [4][s4]          |
| Tier read on a transfer                    | yes                               | no                            | [4][s4]          |
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

---

## 1. Compliance state lives in the registry, not the token

Unchanged from [cash section 1](design-cash.md#1-compliance-state-lives-in-the-registry-not-the-token):
no local KYC state, admission and sanctions read from the registry through
`IKYCRegistryV2`, address `immutable`. The limits of what `immutable` buys
([cash section 1](design-cash.md#what-immutable-does-not-buy)) apply here too.

Both legs read the same registry contract, so a bank approved for cash and unapproved for
securities is not a state this system can reach, and the settlement contract has one trust
assumption rather than two.

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

Four roles, `AccessControl`, split by team and tempo as in
[cash section 2](design-cash.md#2-roles). Two differences.

`DEFAULT_ADMIN_ROLE` has no limit setter, because there are no limits
([section 4](#4-no-transfer-limits)). It is purely a role-granting root.

`ISSUER_ROLE` has a different tempo despite the same name. A cash issuer mints
continuously; a securities issuer mints once at issue, burns once at redemption, and in
between uses the key only for a court-ordered forced transfer
([section 8](#8-a-bond-cannot-be-destroyed-and-recreated)). It should be stored as a cold
key. The deployment constraint carries over: `ISSUER_ROLE` and `COMPLIANCE_OFFICER_ROLE`
must sit with different parties, and the deploy script asserts it.

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
exemption included, with one check fewer: nothing here reads `tierOf`, and an `UNSET`
tier does not block a transfer. An address can therefore be eligible to hold this bond
while unable to move cash; a DvP trade with such a party fails on the cash leg with the
cash leg's tier error.

Suitability is a securities idea, so the natural objection is that a tier should matter
more here. But the securities question is "who may hold this instrument", and the
registry's three tiers do not answer it: a bond restricted to professional investors in
the EEA is not the same statement as `INSTITUTIONAL`. Requiring a tier here would gate
nothing while appearing to. The control that would do the job is a per-instrument
eligibility gate, deferred in [section 10](#10-what-this-contract-does-not-do).

OpenZeppelin v5.6.1 routes every balance change through `_update`, the only virtual hook
on the path, so every check lives there.
[Section 8](#8-a-bond-cannot-be-destroyed-and-recreated) calls the parent's `_update`
directly, so the override below never runs for a forced transfer:

```solidity
// Runs for transfer, transferFrom, mint and burn. Not for forceTransfer (section 8).
function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {
        /* isApproved(from), not frozen. Skipped on a burn */
    }
    if (to != address(0)) {
        /* isApproved(to). Also covers the mint recipient */
    }
    super._update(from, to, value);
}

// Only transferFrom pays for the spender check.
function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    if (registry.isSanctioned(msg.sender)) revert SpenderSanctioned(msg.sender);
    return super.transferFrom(from, to, value);
}
```

A burn skips the sender-side checks because it delivers to nobody; a forced transfer
skips them for section 8's reason. The recipient is never exempt: `isApproved(to)` runs on
a forced transfer like any other delivery.

### Previewing the checks

```solidity
function canTransfer(address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
function canTransferFrom(address spender, address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
```

Same as [cash section 3](design-cash.md#previewing-the-checks): one internal predicate
serves both the preview and the enforcement, and `reason` is the selector of the error the
real call would revert with. A forced transfer has no preview; it bypasses the sender-side
checks by design.

### Freezing does not clear allowances

Unchanged from [cash section 3](design-cash.md#freezing-does-not-clear-allowances).

---

## 4. No transfer limits

No per-transaction cap and no per-day cap. The longest section of the cash design
([cash section 4](design-cash.md#4-transfer-limits)) has no counterpart here.

A daily cap on money is an AML control against structuring. Moving securities launders
nothing by itself; the laundering surface of a bond trade is the cash on the other side,
and that leg already carries the cap. A second cap here would catch no crime the cash leg
misses and would block legitimate deliveries for a reason no regulation states. So there
is no accumulator slot ([section 11](#11-gas)), no `tierOf` call, and no way for the asset
leg to fail a settlement on a limit.

A per-transaction cap as a fat-finger guard was rejected. It would have to sit above the
largest legitimate delivery, and for a bond issue that is the entire issue, moved to the
arranger on day one. The check belongs in the system that submits the trade, where the
expected size is known.

---

## 5. Freeze

Unchanged from [cash section 5](design-cash.md#5-freeze): `COMPLIANCE_OFFICER_ROLE` can
freeze any address; a frozen address cannot send but can still receive; freeze and
unfreeze emit a `bytes32` reason code.

Blocking inbound would hurt more here: a freeze on a party expecting delivery would fail
a counterparty that has usually already committed the cash side to a settlement window.
Freeze is the precondition for `forceTransfer`
([section 8](#8-a-bond-cannot-be-destroyed-and-recreated)), as it is for `burnFrom` on the
cash leg.

---

## 6. Pause

Unchanged from [cash section 6](design-cash.md#6-pause): `PAUSER_ROLE` halts transfers,
mints, burns, `approve` and `forceTransfer`. Views stay readable.

What differs is blast radius. Pausing the cash token halts a payment system. Pausing an
asset token halts trading in one instrument: every DvP trade with this bond as a leg
reverts, and trades in every other instrument carry on. That is the right granularity for
an instrument-specific incident such as a disputed issuance, and it is one reason each
issue gets its own contract ([section 9](#9-denomination-and-instrument-identity)).

---

## 7. Issuance and redemption

`ISSUER_ROLE` only. The invariant is that total supply equals the issue size.

`mint(to, value)` is issuance; the recipient must be `isApproved`. For a bond this
normally happens once, to the arranger or the initial allottees. `burn(value)` is
redemption and takes only from the issuer's own balance: the holder delivers the bond to
the issuer and the issuer burns it, including the whole issue at maturity.

There is no `burnFrom`. The cash leg has one for a target that will not cooperate
([cash section 7](design-cash.md#7-mint-and-burn)); this token answers the same
requirement with `forceTransfer` ([section 8](#8-a-bond-cannot-be-destroyed-and-recreated)).
A non-cooperative redemption is `forceTransfer(holder → issuer)` followed by `burn`, so
supply falls only once the bonds are held by the issuer.

As on the cash leg, access control is the only protection against a balance being reduced
without consent, and the test suite asserts that no address without `ISSUER_ROLE` can
reduce a balance it does not own.

---

## 8. A bond cannot be destroyed and recreated

The one decision where this token does the opposite of the cash token.

### The situation

A court orders that a holder's bonds be handed to someone else, and the holder will not
cooperate. A contract has two ways to carry this out: destroy their 100 bonds and create
100 new ones for the new owner, or move the 100 bonds directly with no signature from the
holder.

### Why the cash leg chose destroy-and-recreate

[Cash section 9](design-cash.md#no-role-can-redirect-another-holders-tokens) picked the
first. Destroying 100 and creating 100 makes total supply dip and rise, which shows up in
every supply reconciliation, so a seizure can never be mistaken for a payment.

### Why the same choice is wrong here

A bond issue is a fixed legal quantity. If the issuer sold 1,000 bonds there must always
be exactly 1,000 on the ledger, and that number is reconciled against the terms of the
issue by the issuer, the paying agent, and every holder.

```
before        1,000 bonds exist   ✅ matches the issue size
after burn      900 bonds exist   ❌ 100 bonds have vanished from a fixed issue
after mint    1,000 bonds exist   ✅ matches again
```

Between the two transactions the ledger says 900 while the paperwork says 1,000. If the
second transaction fails or carries the wrong amount, the contract has changed the size of
a security. Money has no correct total, so a dip carries information; a bond has exactly
one correct total, and any movement in it is itself the alarm.

### Decision

`forceTransfer(from, to, value, reason)`, restricted to `ISSUER_ROLE`, reverting unless
`from` is already frozen.

```solidity
function forceTransfer(address from, address to, uint256 value, bytes32 reason)
    external onlyRole(ISSUER_ROLE) whenNotPaused
{
    if (!frozen[from]) revert AccountNotFrozen(from);   // the first key must have acted
    if (to == address(0)) revert ERC20InvalidReceiver(address(0));
    _checkRecipient(to);                                 // isApproved(to): the one check kept
    super._update(from, to, value);                      // ERC20's own: this contract's override is not run
    emit ForcedTransfer(from, to, value, reason, msg.sender);
}
```

The two-key control is unchanged; only the final step differs:

| Step | Cash                                                  | Asset                               |
| ---- | ----------------------------------------------------- | ----------------------------------- |
| 1    | `COMPLIANCE_OFFICER_ROLE` freezes, with a reason code | the same                            |
| 2    | `ISSUER_ROLE` calls `burnFrom`                        | `ISSUER_ROLE` calls `forceTransfer` |
| 3    | `ISSUER_ROLE` mints to the new owner                  | not needed                          |

The cash doc rejected a one-call `seize(from, to)` because in the logs it is
indistinguishable from a transfer. The answer here is a second event, `ForcedTransfer`,
naming the acting issuer, the reason and both parties, rather than a supply change.

### How the bypass works

`super._update` inside `forceTransfer` resolves to `ERC20._update`, so this contract's
override, where every compliance check lives, is not on the call path. The sender-side
checks are skipped without any flag or state. The one rule that still applies,
`isApproved(to)`, goes through the same private function `_update` uses, so there is one
copy of the rule. `super._update` would burn if `to` were zero, which is what this section
exists to prevent, so the zero-recipient guard is applied explicitly.

### What this costs

A compromised `ISSUER_ROLE` key together with a compromised `COMPLIANCE_OFFICER_ROLE` key
can move any holding on this instrument. Compared with the cash leg that is worse in one
way, because the only signal is the event rather than a supply change a reconciliation
would catch, and better in another, because the pair cannot inflate or deflate the issue.
The power is bounded by two keys held by two teams, a public freeze first, and a dedicated
event type.

Keeping `burnFrom` as well was rejected: a second non-consensual path is a second thing to
secure, and its one use already composes out of `forceTransfer` and `burn`
([section 7](#7-issuance-and-redemption)).

---

## 9. Denomination and instrument identity

### `decimals() == 0`

A bond is issued in a minimum denomination, typically EUR 100,000 nominal for a wholesale
issue, and a holding is a whole number of those. A balance of `100` means one hundred
bonds. Where the cash leg needs six decimals to absorb rounding
([cash section 8](design-cash.md#8-decimals-and-denomination)), divisibility is a property
this instrument must not have, and zero decimals makes that structural: a trade for 100.5
bonds is malformed and fails as such. The cost is tooling that assumes 18 decimals, which
on a permissioned network with known tooling is an integration note.

### An `immutable` ISIN

The contract records its instrument identity as an `immutable bytes12` holding the
[ISO 6166][iso6166] ISIN, for the same reason the cash leg records an ISO 4217 code: the
settlement contract reads it and confirms it is delivering the instrument the trade names.
Two bond issues from the same issuer differ by nothing an address reveals. Each issue is
its own deployment, since an ERC-20 has one balance mapping, which is also what gives
[section 6](#6-pause) its granularity.

The ISIN's check digit is validated by the deploy script, off-chain, along with the role
separation in [section 2](#2-roles). A Luhn implementation on-chain would be contract code
guarding against a typo in a script.

---

## 10. What this contract does not do

### Not upgradeable

No proxy, for [cash section 9](design-cash.md#not-upgradeable)'s reasons, with more force:
issue size, denomination and identity are fixed by the documentation the instrument is
sold under. If the rules have to change, that is a new instrument.

### No coupons, no corporate actions

No coupon payments, no maturity logic, no calls, no conversions. This token is a
transferable claim: mint at issue, transfer, burn at redemption. That is what "a simplified
security" means in the [README](../README.md). A coupon is a periodic payment in the cash
token driven by a paying agent, and it is a separate contract if it is ever built.

### No eligibility gate, deferred rather than rejected

The strongest candidate for the next thing this token gains.

Securities are routinely restricted by holder jurisdiction, through private placements,
Regulation S and prospectus exemptions. The registry already exposes
`jurisdictionOf(address) → bytes2`, an [ISO 3166-1][iso3166] code that neither token reads
today. A per-instrument allowlist of permitted jurisdictions, checked on `to` in `_update`,
would enforce "this bond may only be held in the EEA" on-chain. Unlike transfer limits
([section 4](#4-no-transfer-limits)), it answers a rule that exists.

What it costs is a new kind of state: per-instrument policy owned by the token, where
everything in [section 1](#1-compliance-state-lives-in-the-registry-not-the-token) is
per-holder state owned by the registry. It raises questions of who sets it, against which
key, and what happens to a holder who was eligible when they bought and is not after a
change. It is deferred on the same terms as
[`permit`](design-cash.md#no-permit-eip-2612-for-now).

### No `permit` (EIP-2612), for now

Unchanged from [cash section 9](design-cash.md#no-permit-eip-2612-for-now). Both legs
would need it, or a settlement still carries one stale allowance, so it is decided once for
both.

### No holder cap

Rejected. A maximum investor count is a real constraint under some private-placement
exemptions, but enforcing it on-chain means a holder-count accumulator on every transfer,
to enforce a rule this instrument has not been given. If it is ever needed it sits on top
of the eligibility gate above.

---

## 11. Gas

| path            | registry calls                         | count | vs. the cash leg     |
| --------------- | -------------------------------------- | ----- | -------------------- |
| `transfer`      | `isApproved(from)`, `isApproved(to)`   | 2     | one fewer (`tierOf`) |
| `transferFrom`  | the above plus `isSanctioned(spender)` | 3     | one fewer (`tierOf`) |
| `mint`          | `isApproved(to)`                       | 1     | same                 |
| `burn`          | none; the sender side is skipped       | 0     | same                 |
| `forceTransfer` | `isApproved(to)`                       | 1     | no counterpart       |

There is also no accumulator slot ([section 4](#4-no-transfer-limits)), so this token is
cheaper than the cash leg on every path: one fewer `STATICCALL` into the registry proxy
and one fewer storage read/write.

### Measured

`test/Gas.t.sol` (`AssetGasTest`), under the same conditions as the cash leg: mock registry
behind a `delegatecall` proxy, cold then warm, base transaction cost excluded.

| `transfer`                        |   cold |   warm | registry calls |
| --------------------------------- | -----: | -----: | -------------: |
| vanilla ERC-20                    | 18,888 |  4,788 |              0 |
| **asset**                         | 41,118 | 10,018 |              2 |
| cash, `NO_LIMIT` tier             | 49,412 | 12,312 |              3 |
| cash, capped tier                 | 73,391 | 14,391 |              3 |

| other asset paths     |   cold |   warm |
| --------------------- | -----: | -----: |
| `transferFrom`        | 47,736 | 12,633 |
| `mint`                | 36,376 |  9,273 |
| `burn`                |      - |  6,749 |
| `forceTransfer`       | 33,456 |      - |

- **The dropped `tierOf` is worth 8,294 cold.** Asset `transfer` against cash `NO_LIMIT` is
  the cleanest comparison: identical paths except for that one call, and the gap is one
  registry round trip through the proxy.
- **A forced transfer is cheaper than an ordinary one** (33,456 against 41,118). It skips
  `isApproved(from)` and the freeze read, since this contract's `_update` override is not
  on its call path (section 8); the recipient check is the only registry call left.

Against the real registry (`test/AssetTokenRegistry.t.sol`): 40,425 cold, 11,325 warm,
within 2% of the mock, as on the cash leg.

A settlement pays for both legs plus the settlement contract's own overhead. That total,
seven registry round trips per settlement, is measured in
[settlement section 12](design-settlement.md#12-gas). On a permissioned Besu network the
gas price is zero or near zero, so this is a throughput figure rather than a cost.

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
