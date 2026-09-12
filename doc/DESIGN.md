# Design

## Scope

Atomic delivery-versus-payment settlement on a permissioned EVM network: the two legs of a
trade and the contract that moves them together, so the asset changes hands if and only if
the cash does. Compliance is enforced by the tokens themselves.

Settlement only. Counterparties are found and prices agreed off-chain before any contract
here is called. Markets already separate the two: trading happens on a venue, settlement at
a depository, and this is the depository half
([settlement section 11](design-settlement.md#11-what-this-contract-does-not-do)).

| Contract        | Role                                                               |
| --------------- | ------------------------------------------------------------------ |
| `TokenizedCash` | the cash leg: commercial bank money or a simplified wholesale CBDC |
| `AssetToken`    | the asset leg: a single bond issue                                 |
| `DvPSettlement` | executes both transfers in one transaction, or neither             |

All three read compliance state from
[`upgradeable-kyc-registry`](https://github.com/jaravan/upgradeable-kyc-registry), a
separate repository consumed as a pinned submodule.

Per-contract design notes: [Tokenized Cash](design-cash.md), [Asset Token](design-asset.md),
[Settlement](design-settlement.md). For building a client: [Integration notes](integration.md).

### The problem

Bank A buys a bond from Bank B. The bond moves B to A and the cash moves A to B. If the two
transfers are separate, whichever party moves first is exposed until the other side moves.
That exposure is settlement risk. Each transfer is called a leg: the bond side is the asset
leg, the cash side is the cash leg.

Delivery versus payment (DvP) ties the two legs together so that both happen or neither
does.

### Where DvP runs today

DvP predates blockchains and is how regulated markets have settled for decades.

- **Foreign exchange.** Both legs are cash, so it is called payment versus payment (PvP).
  [CLS](https://www.cls-group.com/) has run PvP since 2002 and settled an average of USD
  7.9 trillion per day across 18 currencies in H1 2025
  ([CLS interim report, 30 June 2025](https://www.cls-group.com/media/3xpprf1f/cls_2025_interim-report.pdf)).
- **Securities.** [SIX Digital Exchange](https://www.six-group.com/en/products-services/securities-services/digital-assets/digital-securities.html)
  (SDX) is a regulated central securities depository running on DLT. Issuers include the
  World Bank, UBS and the City of Lugano; bonds settle atomically against tokenised CHF and
  EUR ([SIX](https://www.six-group.com/en/products-services/securities-services/knowledge-hub/digital-assets/digital-bonds-in-practice.html)).

The Swiss National Bank distinguishes two ways to settle the cash leg
([SNB FAQ](https://www.snb.ch/en/services-events/digital-services/faq-overview/qas_helvetia)):

- **RTGS link.** The asset settles on the DLT platform and the cash settles in central bank
  money on the conventional payment system (SIC). Two infrastructures, so atomicity is
  partial.
- **Integrated settlement.** Wholesale CBDC is issued onto the DLT platform, and the cash
  leg settles there directly.

[Project Helvetia](https://www.snb.ch/en/the-snb/mandates-goals/payment-transactions/projekt_helvetia)
is the SNB's live pilot of the integrated model, running until at least June 2028. That is
the model this repository implements: cash as a token on the same ledger as the asset, and
one transaction that moves both.

### How it works on-chain

An EVM transaction either succeeds in full or reverts in full. `DvPSettlement` performs
both transfers in one call:

```
seller B ──approve(settlement, 100 bonds)───▶ AssetToken      ← asset leg
seller B ──propose(buyer A, 1,000,000 for 100, deadline)──▶ DvPSettlement
                                                              returns a tradeId,
                                                              moves nothing

buyer A  ──approve(settlement, 1,000,000)───▶ TokenizedCash   ← cash leg

           DvPSettlement.settle(tradeId, termsHash)   ← one transaction
                        │
                        ├── cash.transferFrom(A → B, 1,000,000)
                        └── asset.transferFrom(B → A, 100)

           both succeed, or the whole transaction reverts
```

Each bank grants the settlement contract an allowance. The seller records the terms with
`propose`, which moves nothing. The buyer's `settle` restates the terms as a hash and
executes; nothing moves unless the two statements agree. Terms are recorded on-chain first
because an allowance authorises an amount, not a trade
([settlement section 2](design-settlement.md#2-a-trade-is-agreed-before-it-settles)).

An allowance is permission, not escrow. `approve` moves nothing and locks nothing; the
approving party can still spend the balance elsewhere, in which case `transferFrom` fails
on insufficient balance and the settlement reverts. The buyer keeps its exposure short by
sending `approve` and `settle` back to back. The seller's allowance has to stand from
`propose` until the trade settles or expires, which is one reason every proposal carries a
deadline ([settlement section 4](design-settlement.md#4-every-proposal-expires)).
EIP-2612 `permit` would fold both approvals into the settlement transaction; it is
deferred, not rejected ([cash section 9](design-cash.md#no-permit-eip-2612-for-now)).

**Escrow is not an option.** An escrowing contract would receive the cash, making it the
`to` of a transfer, and `to` must be approved in the registry. A contract cannot be. So
`DvPSettlement` moves cash directly from buyer to seller and the bond directly from seller
to buyer, and never holds either. Any other settlement contract built on these tokens has
the same constraint.

### What this means for KYC

The cash token is used two ways: a direct `transfer` from one party to another, and a
`transferFrom` by the settlement contract as half of a trade. The second case shapes the
compliance rules.

On a settlement, the token sees `DvPSettlement` as the spender. A contract cannot be
KYC'd: there is no person or company behind the address for a compliance team to verify.
So the settlement contract is never approved in the registry, and the token cannot require
the spender to be approved, or every settlement would fail.

Nothing else is relaxed. Direct payments are unaffected, since the spender is the sender's
own approved wallet. Both banks are checked in full as `from` and `to`. The spender is
exempt from `isApproved` and nothing else; it is still checked against the sanctions list
([cash section 3](design-cash.md#3-who-gets-checked-on-a-transfer),
[asset section 3](design-asset.md#3-who-gets-checked-on-a-transfer)).

---

## How the three fit together

**Dependencies run one way.** `DvPSettlement` depends on both tokens; both tokens depend on
the registry; nothing depends on `DvPSettlement`.

**Only the registry is upgradeable.** Compliance rules change, so the registry is UUPS
upgradeable and separately governed. The tokens are not: a unit of currency does not
change, and a bond changes less. The settlement contract is not either; it holds no
balances, so replacing it is a redeployment rather than a migration
([settlement section 10](design-settlement.md#10-not-upgradeable)).

**Compliance is enforced by the tokens, not the settlement contract.** `settle` calls
`transferFrom` and each token checks the registry itself, at settlement time. Duplicating
the checks in the settlement contract would create a second copy of the rules that could
drift from the first. The settlement contract is token-agnostic and lets either leg refuse.

**The two legs check different things.** Both require buyer and seller to be approved,
both block a frozen sender, and both check the spender for sanctions. Only the cash leg
reads a tier, because only the cash leg has transfer limits; a daily cap is an AML control
on money, and the asset leg has none
([asset section 4](design-asset.md#4-no-transfer-limits)). An address can therefore be
eligible to hold the bond but unable to pay for it, in which case the trade fails on the
cash leg with the cash leg's error.

**The registry is a separate repository**, pinned as a submodule, because it is
independently governed and upgradeable. Both tokens inherit its upgrade governance as their
trust root ([cash section 1](design-cash.md#what-immutable-does-not-buy)), so the system
has one trust assumption rather than two.
