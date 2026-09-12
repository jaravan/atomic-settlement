# Tokenized Cash — Design

The cash leg: an ERC-20 representing commercial bank money or a simplified wholesale CBDC,
with compliance enforced by the contract itself.

What the three contracts share, including why the contract in the middle of a settlement
can never be KYC'd, is in [Design](DESIGN.md).

---

## 1. Compliance state lives in the registry, not the token

The token holds no KYC state of its own. Admission and classification are read from
[`upgradeable-kyc-registry`](https://github.com/jaravan/upgradeable-kyc-registry) through
`IKYCRegistryV2`:

```solidity
function isApproved(address) external view returns (bool);   // approved, unexpired, unsanctioned
function isSanctioned(address) external view returns (bool);
function tierOf(address) external view returns (Tier);       // UNSET, RETAIL, INSTITUTIONAL, CROSS_BORDER
```

A local whitelist was rejected: it duplicates state that already exists, and an address
sanctioned in the registry would keep transacting here until someone mirrored the change.
`COMPLIANCE_OFFICER_ROLE` therefore manages no whitelist, only freeze and unfreeze.

### The registry address is `immutable`

Set in the constructor, never changeable. The registry is UUPS-upgradeable, so its address
is stable across its own upgrades; reading an immutable costs no `SLOAD` on a path that
reads it three or four times (section 10); and a settable address would let whoever
controls it point the token at a registry that approves everyone. If the registry is ever
redeployed, this token is migrated rather than reconfigured.

### What `immutable` does not buy

It fixes which contract is asked, not what that contract answers. Whoever holds the
registry's upgrade rights can ship an implementation where `isApproved` returns true for
everyone, so this token inherits the registry's upgrade governance as its trust root, and a
review of this token has to include that repository at the pinned commit. The dependency
is also an availability one: a registry upgrade that breaks `tierOf` halts every transfer,
and with no way to repoint, the recovery path is a registry fix. The two repositories have
to be governed as one system.

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

OpenZeppelin `AccessControl`, not `Ownable`. Issuance sits with treasury, freezes with
compliance, the emergency stop with operations; different teams with different approval
chains.

The split is also by tempo. A sanctions hit or an incident has to be actionable in minutes,
so freeze and pause are hot keys, and a hot key's powers should be as narrow as the job
allows. Tier limits are set by admin rather than by the compliance officer for that reason:
limit policy is network-wide and changes rarely, and a compromised hot key that could raise
every tier's cap would have a much larger blast radius than one that can freeze an address.
A fifth role for limits was rejected as a dedicated key for a setter called once a year.

The separation is procedural, not cryptographic. Admin can grant itself any role and then
mint, freeze or pause. What the split buys is that the grant happens first, as a visible
on-chain event.

**Deployment constraint:** `ISSUER_ROLE` and `COMPLIANCE_OFFICER_ROLE` must be held by
different parties, or the two-key control in section 9 collapses to one actor. The contract
enforces the sequence (`burnFrom` reverts unless a freeze is in place) but cannot tell
whether both roles sit with the same person. The deploy script asserts it.

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

**The spender is not required to be `isApproved`.** On a settlement the spender is a
contract, and a contract cannot be approved in the registry
([Design](DESIGN.md#scope)). Requiring it would fail every settlement.

**The spender is still checked for sanctions.** A sanctioned party must not be able to
direct money even when it holds none. `isSanctioned` is a network-level block that can
apply to any address, where `isApproved` is an onboarding statement that can only be true
for someone's customer. On a settlement contract the check passes trivially; on a custodian
acting for a client it matters, and the token cannot tell the two apart.

**Where the check lives.** OpenZeppelin routes `transfer` and `transferFrom` through
`_update`. The spender check goes on `transferFrom` alone, because on a direct `transfer`
the spender is the sender and `isApproved(from)` already implies not sanctioned:

```solidity
// Runs for transfer, transferFrom, mint and burn.
function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {/* isApproved(from), not frozen, tier limit */}
    if (to != address(0)) {/* isApproved(to), which also covers the mint recipient */}
    super._update(from, to, value);
}

// Only transferFrom pays for the spender check.
function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    if (registry.isSanctioned(msg.sender)) revert SpenderSanctioned(msg.sender);
    return super.transferFrom(from, to, value);
}
```

**A burn skips the sender-side checks.** A burn delivers to nobody, so there is no
counterparty to protect, and `burnFrom` targets an account that is frozen and usually
sanctioned, so `isApproved(from)` would fail exactly when the function is needed. There is
no public burn entry point; both burn paths are `ISSUER_ROLE` (section 7).

### Previewing the checks

The settlement contract needs to know whether a transfer would succeed without asking the
registry itself ([settlement section 5](design-settlement.md#5-compliance-stays-in-the-tokens)).

```solidity
function canTransfer(address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
function canTransferFrom(address spender, address from, address to, uint256 value)
    external view returns (bool ok, bytes4 reason);
```

Two functions because only `transferFrom` has a spender and an allowance. The preview and
the enforcement run the same internal predicate, so they cannot drift. `reason` is the
selector of the error the real call would revert with; there is no separate vocabulary to
keep in step. Balance and allowance are included so the caller gets the whole answer. These
are views over state that can change in the next block.

### Freezing does not clear allowances

A freeze blocks outbound transfers, so `transferFrom` from a frozen account reverts and
the allowance sits unusable until the freeze lifts. Allowances cannot be enumerated
on-chain, and freeze is a hot-key action (section 2): blocking transfers is reversible,
deleting approvals is not.

---

## 4. Transfer limits

Two caps per tier, set by `DEFAULT_ADMIN_ROLE`: one per transaction, one per calendar day.
The per-transaction cap is a comparison. The daily cap needs state.

**A fixed calendar-day window.** Each sender carries a day number and a running total. If
the current day differs from the stored one the total resets; otherwise the amount is added
and checked against the cap.

```
if (dailyLimit != NO_LIMIT) {
    today = block.timestamp / 1 days
    if (usage.day != today) { usage.day = today; usage.spent = 0; }
    require(usage.spent + amount <= dailyLimit);
    usage.spent += amount;
}
```

O(1), one storage slot: a `uint40` day number and a `uint216` total pack into 256 bits.

A sender can use one day's allowance late and the next day's early. That is two days'
limits used on two days, which is what card schemes and AML aggregation thresholds mean by
a daily limit. The day is UTC: the rules are written for a local business day, but on a
multi-timezone network there is no single local day, and UTC is the one boundary every
participant computes identically.

A rolling 24-hour window was rejected. Enforcing it exactly means storing every
`(timestamp, amount)` and pruning on each transfer: unbounded storage and gas that scales
with how busy a sender has been. Approximations avoid the loop but add error in both
directions to enforce a rule no regulation states.

### Limits are set per tier, never per address

One limit pair per tier, no per-address override. The entire policy is three entries,
readable in full. An override is a quiet way to exempt one party, where a tier change is
visible and attributed to the registry's KYC officer. A customer who needs different limits
is a classification question. The setter takes a `Tier`, not an `address`.

### A cap can be set to no cap

On a settlement `from` is the paying bank, and a wholesale settlement is larger than any
meaningful daily limit for a person. A tier whose cap is `NO_LIMIT` (`type(uint256).max`)
is uncapped, and the contract skips both the comparison and the storage write. Reading the
policy back gives `NO_LIMIT` rather than a large number nobody can tell from a typo.

**Zero means zero.** An unconfigured tier reads as `0` and cannot transfer. The sentinel is
at the opposite end of the range from the default so that forgetting to configure a tier
blocks transfers rather than uncapping them.

The cap means different things at different tiers:

- **`RETAIL`**: an AML threshold, binding, and the reason the mechanism exists.
- **`INSTITUTIONAL`**: normally `NO_LIMIT`. A daily cap on a settlement bank is not an AML
  control; if it binds, it binds on a legitimate trade. Where an operator sets one it is a
  circuit breaker against runaway automation and should be sized as one.
- **`CROSS_BORDER`**: the operator's call, and the one tier where a cap may be doing
  sanctions or capital-control work.

### An `UNSET` tier reverts

If `tierOf(from)` is `UNSET` the transfer reverts with `TierUnset`. Falling back to the
strictest tier would let an unclassified address transact at a limit nobody assigned it.
`isApproved` alone is not enough to transact; onboarding must set a tier as well.

---

## 5. Freeze

`COMPLIANCE_OFFICER_ROLE` can freeze any address. A frozen address cannot send but can
still receive, which is how a frozen bank account behaves. Blocking inbound would strand
funds already in flight and let a freeze fail an unrelated counterparty's settlement.

Freeze and unfreeze emit a `bytes32` reason code rather than a string: one word instead of
unbounded calldata, and an enumerated set a compliance system can query.

Freeze is also the precondition for `burnFrom` (sections 7 and 9): the first of the two
keys a seizure needs. A compliance officer acting alone cannot destroy anything.

---

## 6. Pause

`PAUSER_ROLE` halts all transfers, mints and burns, `burnFrom` included. OpenZeppelin
`Pausable`. Pause is a network-incident control; freeze is the per-address instrument.
Views stay readable. `approve` is also blocked: granting new spending authority during an
incident serves no purpose and could stage a drain for the moment the pause lifts.

---

## 7. Mint and burn

`ISSUER_ROLE` only. Mint is money entering the system, a bank depositing reserves or an
issuer creating a liability; burn is withdrawal. The mint recipient must be `isApproved`,
and no supply path consumes a tier limit (section 3).

Two burn paths:

- **`burn(value)`** takes from the issuer's own balance. This is the ordinary redemption
  route: the customer transfers to the issuer, then the issuer burns.
- **`burnFrom(account, value, reason)`** takes from a holder that has not consented. It
  reverts unless `account` is frozen, so `COMPLIANCE_OFFICER_ROLE` must have acted first,
  from a separate key. It carries the same `bytes32` reason code a freeze does. Section 9
  covers why it exists.

The frozen precondition is the whole control: destruction can only follow a public,
attributed, reversible act by a different role. All three paths emit events carrying the
acting issuer. Because a burn skips the sender-side checks (section 3), access control is
the only protection against a balance being reduced without consent, and the test suite
asserts that no address without `ISSUER_ROLE` can reduce a balance it does not own.

---

## 8. Decimals and denomination

`decimals() == 6`. One euro is 1,000,000 units; the smallest amount the token can hold is
0.000001 EUR, four digits finer than a cent.

Not 2, because a cent cannot be split. Interest, pro-rata allocations and price × quantity
rarely divide evenly, so each would round to a whole cent and the leftover would accumulate
across a day of settlements. Not 18, because that is a habit inherited from ether rather
than a property of money, and it invites mistakes when an 18-decimal token and this one
appear in the same settlement. Six is what USDC and EURC use.

The contract also records its own currency as an immutable `bytes3` holding the ISO 4217
code. Each deployment is one currency: an ERC-20 has a single balance mapping and cannot
keep two currencies apart. The settlement contract reads the code to confirm it is paying
euros with euros rather than trusting whoever configured the address
([settlement section 6](design-settlement.md#6-the-trade-names-the-instruments-and-settlement-verifies-them)).

---

## 9. What this contract does not do

### Not upgradeable

No proxy. If the compliance rules must change, deploy a new token and migrate balances
through a migration contract: a visible, auditable event rather than a change of behaviour
under a stable address. The registry is upgradeable because sanctions regimes and KYC
requirements evolve. A unit of currency does not.

### No `permit` (EIP-2612), for now

An allowance sits open between `approve` and the settlement that uses it: seconds for the
buyer, and for the seller the whole life of the proposal
([settlement section 3](design-settlement.md#3-lifecycle)). `permit` turns an approval into
a signature, so the settlement contract could carry both banks' signed approvals and do
approve, approve and settle in one transaction. The usual argument for `permit`, gasless
approval via a relayer, does not apply on a zero-gas network; the atomicity does.

It is deferred because it adds a signature scheme (EIP-712 domain, nonces, deadlines) to a
deliberately small surface, and raises one compliance question: a `permit` presented while
`approve` is paused (section 6) must be blocked too. If added, it goes in as `ERC20Permit`
gated by `whenNotPaused`, and the spender sanctions check stays on `transferFrom`, the
point of exercise.

### No role can redirect another holder's tokens

There is no `seize(from, to)`. The one function that reaches into a balance without the
holder's consent is `burnFrom` (section 7), and it can only destroy. It names no recipient,
so the caller ends up holding nothing and total supply falls.

The target must already be frozen, which only `COMPLIANCE_OFFICER_ROLE` can do, and the
call itself is `ISSUER_ROLE`. Section 2 requires those to be different parties, so a
seizure is two transactions from two keys, each with its own event. A court-ordered
reassignment is that burn followed by a mint to the new owner: two supply events rather
than one transfer, so it appears in supply reconciliation instead of reading as a payment.

Two alternatives were rejected. No non-consensual path at all does not work: a holder under
a seizure order is not cooperating, and freezing them removes even the option of a
voluntary transfer, so the order could not be executed on-chain. A `seize(from, to)` in one
call is one transaction from one key, indistinguishable in the logs from a transfer.

The cost is that a compromised `ISSUER_ROLE` key together with a compromised
`COMPLIANCE_OFFICER_ROLE` key can extinguish any balance and re-mint it elsewhere. That
power is bounded rather than eliminated: two keys held by two teams, a public freeze first,
and a supply change in both directions that an ordinary transfer would not produce.

---

## 10. Gas

Against a vanilla ERC-20 the compliance layer adds one packed storage read/write on the
transfer paths (the daily-usage slot from section 4, which mint and burn never touch and a
`NO_LIMIT` tier skips) plus the registry calls below:

| path                | registry calls                                             |
| ------------------- | ---------------------------------------------------------- |
| `transfer`          | `isApproved(from)`, `isApproved(to)`, `tierOf(from)`: 3    |
| `transferFrom`      | the above plus `isSanctioned(spender)`: 4                  |
| `mint`              | `isApproved(to)`: 1                                        |
| `burn` / `burnFrom` | none; the sender side is skipped on a burn (section 3)     |

Each is a `STATICCALL` into the registry's UUPS proxy, so each carries a `delegatecall`
hop. A combined `complianceOf(address) → (approved, sanctioned, tier)` on the registry
would fold three or four round trips into one and can be added without a redeploy. It has
not been added yet; a getter shaped for one consumer couples the two repositories, and the
measurements below say what it would buy.

### Measured

`test/Gas.t.sol`, against an unmodified OpenZeppelin ERC-20 with the same decimals.
Registry reads go through a `delegatecall` proxy so the UUPS hop is included. Cold is the
first call, the state a real transaction starts from; warm is a second call in the same
transaction. Figures exclude the 21,000 base transaction cost.

| path                          |   cold |   warm | vs vanilla (cold) |
| ----------------------------- | -----: | -----: | ----------------: |
| vanilla `transfer`            | 18,888 |  4,788 |          baseline |
| `transfer`, `NO_LIMIT` tier   | 49,412 | 12,312 |          +30,524 |
| `transfer`, capped tier       | 73,391 | 14,391 |          +54,503 |
| `transferFrom`, capped tier   | 80,031 | 17,028 |          +61,143 |
| `mint`                        | 36,407 |  9,304 |                 - |
| `burn`                        |      - |  6,869 |                 - |
| `canTransfer` (view)          | 44,314 |      - |                 - |

- **The registry calls dominate, not the accumulator.** `NO_LIMIT` skips the daily slot
  and still costs +30,524 over vanilla, roughly 10,000 per `STATICCALL` once the cold
  account access and the proxy hop are paid. That is where `complianceOf` would act.
- **The daily accumulator costs +23,979 cold, +2,079 warm.** Almost all of the cold figure
  is the `0 -> nonzero` `SSTORE` the first time a sender transacts on a new day. Packing
  `DailyUsage` into one word (section 4) keeps this a single write.
- **`transferFrom` adds 6,640 over `transfer`**: `isSanctioned(spender)` plus the allowance
  read. Keeping that check off the direct path (section 3) saves about that much on every
  plain payment.

**Throughput.** A capped `transfer` is ~94,400 gas as a whole transaction against ~39,900
for a vanilla one. At a 30M block limit that is roughly 318 compliant transfers per block
against 752, so the compliance layer costs about 2.4x in throughput.

**Checked against the real registry.** `test/TokenizedCashRegistry.t.sol` runs the same
path against `KYCRegistryV2` behind a real ERC-1967 proxy:

| `transfer`                  |   cold |   warm |
| --------------------------- | -----: | -----: |
| mock + `delegatecall` proxy | 73,391 | 14,391 |
| real registry + UUPS proxy  | 73,126 | 16,126 |

Cold is within 0.4%, so the cold figure is dominated by the cross-contract calls rather
than by anything the registry does inside them. Warm is ~1,700 higher against the real
registry, the fuller `Record` it reads. The mock is a sound stand-in.

On a permissioned Besu network the gas price is zero or near zero, so gas per transfer is a
throughput figure: it sets transactions per block, which sets whether the network meets its
settlement window.

---

## Summary of decisions

| #   | Decision                                                                                   |
| --- | ------------------------------------------------------------------------------------------ |
| 1   | No local KYC state. Registry is the source of truth, address `immutable`                   |
| 2   | `AccessControl` with four roles, split by team and tempo; hot keys kept narrow             |
| 3   | `from` and `to` fully checked; spender checked for sanctions only                          |
| 4   | Fixed UTC-day window, per tier only, `NO_LIMIT` sentinel, `UNSET` reverts                  |
| 5   | Freeze blocks outbound, allows inbound, emits a reason code                                |
| 6   | Pause halts transfers, mints, burns and `approve`                                          |
| 7   | Mint and burn restricted to `ISSUER_ROLE`; `burnFrom` needs a frozen target                |
| 8   | `decimals() == 6`, plus an immutable ISO 4217 `bytes3`                                     |
| 9   | Not upgradeable; no `permit` yet; the only non-consensual path destroys and needs two keys |
