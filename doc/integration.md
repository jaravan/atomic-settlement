# Integration notes

What a client has to get right that the contracts cannot enforce. The design documents
give the reasons; this document gives the rules. Section references are to
[design-settlement.md](design-settlement.md) unless marked otherwise.

---

## 1. Who does what

| Party | Registry | Tokens | `DvPSettlement` |
| --- | --- | --- | --- |
| Seller | approved, with a tier | holds the bonds; `AssetToken.approve(dvp, assetAmount)` | `propose`, `cancel` |
| Buyer | approved, with a tier | holds the cash; `TokenizedCash.approve(dvp, cashAmount)` | `settle` |
| `DvPSettlement` | never onboarded | the spender on both legs; checked for sanctions only | — |

---

## 2. Before anything can settle

- **Both parties need a tier, not only an approval.** Onboarding is
  `approve(account, expiry, orgId)` and `setTier(account, tier)` on the registry.
  `isApproved` alone fails the cash leg with `TierUnset` (cash section 4).
- **Tier limits must be set on `TokenizedCash`.** An unconfigured tier reads as zero and
  refuses everything. `INSTITUTIONAL` is normally `NO_LIMIT` (cash section 4).
- **Approvals expire.** A lapsed party on either side fails with `NotApproved`.

---

## 3. The sequence

```
SELLER                                        BUYER
──────────────────────────────────            ──────────────────────────────────
1. AssetToken.approve(dvp, assetAmount)
2. dvp.propose(terms) → tradeId
                                              3. sees TradeProposed
                                              4. computes termsHash from ITS OWN record  (§4)
                                              5. dvp.canSettle(tradeId, termsHash)      optional
                                              6. TokenizedCash.approve(dvp, cashAmount)
                                              7. dvp.settle(tradeId, termsHash)
```

- The seller's allowance stands open from step 1 until settle, cancel or expiry. One
  holding can back two proposals, and the second to settle reverts, so size the allowance
  to what is on offer (section 3).
- The buyer's window is steps 6 and 7, two transactions back to back (section 3).

```solidity
struct Terms {
    address buyer;
    address cashToken;
    bytes3  currency;     // what you expect cashToken to be, e.g. "EUR"
    uint256 cashAmount;
    address assetToken;
    bytes12 isin;         // what you expect assetToken to be
    uint256 assetAmount;
    uint64  deadline;     // unix seconds, must be in the future
}
```

`settle` reads each token's identifier and refuses a mismatch with `WrongCurrency` /
`WrongInstrument` (section 6).

---

## 4. The terms hash

`settle` requires the buyer to state the terms it agreed, as a hash. Compute it from your
own trade record (section 2):

```
termsHash = keccak256(abi.encode(
    chainId,          // uint256
    dvpAddress,       // address
    tradeId,          // uint256
    seller,           // address
    buyer,            // address
    cashToken,        // address
    currency,         // bytes3
    cashAmount,       // uint256
    assetToken,       // address
    isin,             // bytes12
    assetAmount,      // uint256
    deadline          // uint64
))
```

`hashTerms(tradeId, seller, terms)` on the contract is a reference implementation for
verifying yours during development. Do not read the proposal back with `trades(tradeId)`
and hash that in production: it always matches and asserts nothing.

---

## 5. Reading `canSettle`

```solidity
function canSettle(uint256 tradeId, bytes32 termsHash) external view returns (bool ok, bytes4 reason);
```

`reason` is the selector of the error `settle` would revert with. Checks run in this
order and stop at the first failure (section 5). Selectors are `bytes4(keccak256(signature))`
and can be regenerated with `cast sig`.

| Order | Source | Selector | Error | Meaning |
| --- | --- | --- | --- | --- |
| 1 | settlement | `0xa93022f3` | `TradeNotOpen(uint256,uint8)` | never proposed, settled, or cancelled |
| 2 | settlement | `0x93a3a0b7` | `TradeExpired(uint256,uint64)` | deadline passed |
| 3 | settlement | `0x7b1cb83b` | `TermsMismatch(uint256)` | your hash ≠ the seller's terms |
| 4 | settlement | `0x5d4cb4a4` | `WrongCurrency(address,bytes3,bytes3)` | `cashToken` is not the currency named |
| 5 | settlement | `0xf0597c19` | `WrongInstrument(address,bytes12,bytes12)` | `assetToken` is not the ISIN named |
| 6 | cash leg | `0xfb8f41b2` | `ERC20InsufficientAllowance` | buyer's allowance short |
| 6 | cash leg | `0xf65c34a1` | `SpenderSanctioned(address)` | the settlement contract is sanctioned |
| 6 | cash leg | `0x0ca968d8` | `NotApproved(address)` | buyer or seller not approved |
| 6 | cash leg | `0x23f7b28c` | `SenderFrozen(address)` | buyer frozen |
| 6 | cash leg | `0x4c7367dc` | `TierUnset(address)` | buyer has no tier |
| 6 | cash leg | `0x86a9ae24` | `TransactionLimitExceeded(…)` | buyer's per-transaction cap |
| 6 | cash leg | `0xef6aa729` | `DailyLimitExceeded(…)` | buyer's daily cap, resets 00:00 UTC |
| 6 | cash leg | `0xe450d38c` | `ERC20InsufficientBalance` | buyer short of cash |
| 6 | cash leg | `0xd93c0665` | `EnforcedPause()` | cash token paused |
| 7 | asset leg | as above, minus tier and limit errors | | seller side |

**Shared selectors.** `SenderFrozen`, `NotApproved`, `SpenderSanctioned`, `EnforcedPause`
and the ERC-20 errors have the same signature on both tokens, so the same selector, and
`canSettle` does not say which leg raised it. The cash leg is checked first: `SenderFrozen`
from it means the buyer, from the asset leg the seller; `NotApproved` from the cash leg
can be either party, since it checks both. To attribute an error to a party, ask the legs
directly:

```solidity
cash.canTransferFrom(dvp, buyer, seller, cashAmount)
asset.canTransferFrom(dvp, seller, buyer, assetAmount)
```

`NotBuyer` is never returned: the view assumes the named buyer will call.

---

## 6. The log

| Event | When |
| --- | --- |
| `TradeProposed(tradeId, seller, buyer, cashToken, cashAmount, assetToken, assetAmount, deadline)` | `propose` |
| `TradeSettled(tradeId, seller, buyer, cashToken, cashAmount, assetToken, assetAmount)` | `settle` |
| `TradeCancelled(tradeId, seller, buyer)` | `cancel` |

`tradeId`, `seller` and `buyer` are indexed on all three.

Nothing is emitted on expiry or on a failed settle (section 8). Compute expiry from
`TradeProposed.deadline` and treat a reverted `settle` as a fail. `trades(id).status` stays
`PROPOSED` after expiry.

---

## 7. Amounts

| Token | `decimals()` | EUR 10,000,000 / 100 bonds |
| --- | --- | --- |
| `TokenizedCash` | 6 | `10_000_000_000_000` |
| `AssetToken` | 0 | `100` |

`currency` is a left-aligned `bytes3` (`"EUR"` is `0x455552`) and `isin` a left-aligned
`bytes12`. Pass them as bytes, not numbers.

---

## 8. Checklist

- [ ] `termsHash` computed from the buyer's own record, never from `trades(id)`
- [ ] Seller's `AssetToken` allowance covers only what is on offer
- [ ] Both parties have a tier on the registry, not only an approval
- [ ] `TokenizedCash` tier limits configured
- [ ] `ISSUER_ROLE` and `COMPLIANCE_OFFICER_ROLE` on different parties, on each token
- [ ] Expiry computed from `deadline`, not awaited as an event
- [ ] A reverted `settle` treated as a fail
- [ ] Amounts in token units: six decimals for cash, zero for bonds
