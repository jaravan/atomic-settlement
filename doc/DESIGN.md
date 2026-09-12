# Design

## Scope

Atomic delivery-versus-payment settlement on a permissioned EVM network: both legs of a
trade and the contract that moves them together, so the asset changes hands if and only if
the cash does. Compliance is enforced by the tokens themselves, not by the systems around
them.

**Settlement only.** Counterparties are found and prices agreed off-chain, on a trading
venue or over the phone, before any contract here is called. Real markets separate the two
the same way — trade on a venue, settle at a depository — and this is the depository half
([settlement section 11](design-settlement.md#11-what-this-contract-does-not-do)).

| Contract        | Role                                                                      |
| --------------- | ------------------------------------------------------------------------- |
| `TokenizedCash` | the cash leg; could represent commercial bank money, or a simplified CBDC |
| `AssetToken`    | the asset leg; a simplified security, standing in for the issuer's own    |
| `DvPSettlement` | moves both legs in one transaction, or neither                            |

All three read compliance state from
[`upgradeable-kyc-registry`](https://github.com/jaravan/upgradeable-kyc-registry), a
separate repository consumed as a pinned submodule.

Design notes per contract:

- [Tokenized Cash](design-cash.md) — the cash leg
- [Asset Token](design-asset.md) — the asset leg
- [Settlement](design-settlement.md) — the contract that moves both legs

For building a client against them: [Integration notes](integration.md) — what a caller
has to get right that the contracts cannot enforce.

### The problem

- **Every trade is two transfers in opposite directions.** Bank A buys a bond from Bank B.
  The bond moves B to A; the money moves A to B.
- **They do not naturally happen at the same instant.** If A sends money first, then for a
  moment A has paid and holds nothing. If B fails right then, A has lost it. Sending the
  bond first just moves the same exposure onto B.
- This exposure is called **settlement risk**.

> The industry calls each of those two transfers a **leg**. The bond side is the _asset
> leg_, the money side is the _cash leg_. It is just a word for "one half of the trade".
> **This repository builds both legs, and the contract that moves them together.**

### The Delivery versus Payment (DvP) mechanism

Tie the two transfers together so that both happen or neither does.

- _Delivery_ is the bond, _payment_ is the money, _versus_ means neither moves without the
  other
- No gap, so no exposure

### Where DvP runs today

DvP is not a blockchain idea. It is how regulated markets have worked for decades.

**Foreign exchange.** Money on both sides, so it is called payment versus payment (PvP).

- [CLS](https://www.cls-group.com/) launched in 2002 to eliminate FX settlement risk
- Settled an average of **USD 7.9 trillion per day across 18 currencies** in H1 2025
  ([CLS interim report, 30 June 2025](https://www.cls-group.com/media/3xpprf1f/cls_2025_interim-report.pdf))

**Securities.** Asset on one side, money on the other. This is DvP proper.

- [SIX Digital Exchange](https://www.six-group.com/en/products-services/securities-services/digital-assets/digital-securities.html)
  (SDX) is a regulated central securities depository running on DLT
- Live issuers include the World Bank, UBS, and the City of Lugano, which has issued three
  digital bonds
  ([SIX](https://www.six-group.com/en/products-services/securities-services/knowledge-hub/digital-assets/digital-bonds-in-practice.html))
- Bonds "settle atomically in the SDX CSD against tokenized CHF and EUR" (same source)

**Two ways to settle the cash leg.** The Swiss National Bank names both
([SNB FAQ](https://www.snb.ch/en/services-events/digital-services/faq-overview/qas_helvetia)):

- **RTGS link.** "Assets are settled on a DLT platform, while the cash side is settled in
  traditional central bank money on the established Swiss Interbank Clearing (SIC) payment
  system." Two infrastructures, so the atomicity is only partial
- **Integrated settlement.** "By issuing CBDC on the DLT-based SIX Digital Asset Platform,
  the cash-side settlement of the assets can occur directly on the Digital Asset Platform"

**Project Helvetia** is the SNB's live pilot of the second model
([SNB](https://www.snb.ch/en/the-snb/mandates-goals/payment-transactions/projekt_helvetia)):

- Wholesale CBDC is issued onto the SDX platform, so financial institutions "can use it to
  settle transactions involving tokenised assets directly with wCBDC"
- Participation requires "a sight deposit account with the SNB" and admission to SIC
- Runs until at least June 2028

**That integrated model is what this repository builds.** Money as a token on the same
ledger as the asset, and one transaction that moves both.

### How it works on-chain

A transaction either fully succeeds or fully reverts, so "at the same time" is free. A
**settlement contract** — here `DvPSettlement` — does both transfers in one call:

```
seller B ──approve(settlement, 100 bonds)───▶ AssetToken      ← asset leg
seller B ──propose(buyer A, 1,000,000 for 100, deadline)──▶ DvPSettlement
                                                              returns a tradeId,
                                                              moves nothing

buyer A  ──approve(settlement, 1,000,000)───▶ TokenizedCash   ← cash leg

           DvPSettlement.settle(tradeId, termsHash)   ← one transaction
                        │                             the buyer asserts the terms
                        │
                        ├── cash.transferFrom(A → B, 1,000,000)
                        └── asset.transferFrom(B → A, 100)

           both succeed, or the whole transaction reverts
```

- Each bank grants the settlement contract an **allowance**: permission to move a set
  amount on their behalf
- **Settling takes two calls, and only the second moves value.** The seller proposes the
  terms, and the buyer's `settle` restates them and is both the acceptance and the
  execution. Two independent assertions of one trade, and nothing moves unless they agree.
  `propose` records terms and moves nothing, so the atomicity above is untouched. Terms
  must be recorded on-chain first, because an allowance authorises an amount and not a
  trade
  ([settlement section 2](design-settlement.md#2-a-trade-is-agreed-before-it-settles))
- The contract calls `transferFrom` on each token
- If either leg fails (A is frozen, B lacks the bonds) the whole transaction reverts

> **An allowance is permission, not escrow.** `approve` moves no money and locks nothing.
> It writes one record, `allowance[BankA][settlement] = 1,000,000`, and Bank A keeps full
> control of the funds. A can approve and then spend the same money elsewhere;
> `transferFrom` later fails on insufficient balance and the settlement reverts. Nothing is
> lost, but the settlement fails. The buyer keeps its window down to seconds by sending
> `approve` and `settle` back-to-back, two transactions it submits itself at a moment it
> chooses. The seller cannot: its allowance has to stand from `propose` until the trade
> settles or expires, which is one of the reasons every proposal carries a deadline
> ([settlement section 4](design-settlement.md#4-every-proposal-expires)).
> [Cash section 9](design-cash.md#no-permit-eip-2612-for-now) covers why the obvious way to
> close that gap — EIP-2612 `permit`, folding both approvals into the settlement
> transaction — is deferred rather than adopted.

**Escrow is not an alternative here**, so this is a requirement on the settlement contract
rather than a preference. An escrowing contract takes custody first: the cash moves into
it, making it the `to` of a transfer, and `to` must be `isApproved` — which a contract can
never be, so the funding call would always revert. The spender exemption in
[cash section 3](design-cash.md#3-who-gets-checked-on-a-transfer) relaxes `isApproved` for
`msg.sender` only; widening it to recipients would mean whitelisting contract addresses,
exactly what [cash section 1](design-cash.md#1-compliance-state-lives-in-the-registry-not-the-token)
rejects. `DvPSettlement` therefore moves cash directly from buyer to seller, and the bond
straight back, never taking custody of either leg. Any other settlement contract built
against either token must do the same.

### Two ways the cash moves

The cash token is used two ways:

1. **Direct payment.** One party pays another. A plain `transfer`, no intermediary. The
   ordinary case, and probably most of the volume.
2. **Settlement.** The settlement contract moves the cash as one half of a trade, using
   `transferFrom`.

The second case is where the real design work happens. A direct payment behaves the same
way whichever rules the cash leg settles on. A settlement is different: write the
compliance checks the obvious way and it stops working altogether.

### What this means for KYC

- `DvPSettlement` is the one calling `transferFrom`, so the cash token sees it as the
  **spender**
- **A contract cannot be KYC'd.** KYC means a compliance team verified a person or a
  company; there is nobody behind a contract address to verify
- So the settlement contract will never be approved in the registry
- Therefore the cash token **cannot require the spender to be approved**. Every settlement
  runs through a contract, so `require(isApproved(msg.sender))` would fail on all of them,
  not just some

Nothing else is relaxed:

- Direct payments are unaffected. In a plain `transfer` the spender is the sender's own
  wallet, which is approved
- The two banks are still checked in full, as `from` and `to`
- Only the contract in the middle is exempt, and only from `isApproved`

[Cash section 3](design-cash.md#3-who-gets-checked-on-a-transfer) gives the exact rule, and
[asset section 3](design-asset.md#3-who-gets-checked-on-a-transfer) is identical. The
exemption is a property of the system, not of the cash leg.

---

## How the three fit together

**The dependency runs one way.** `DvPSettlement` depends on both tokens; both tokens depend
on the registry; never the reverse.

**Only the registry is upgradeable.** Compliance rules evolve, so it is UUPS-upgradeable and
separately governed. Nothing else is. A unit of currency does not change, the terms of a
bond change less still, and settlement workflows do evolve but the contract that runs them
holds no balances, so replacing it is a redeployment rather than a migration
([settlement section 10](design-settlement.md#10-not-upgradeable)).

**Compliance is enforced by the tokens, not by the settlement contract.** `settle()` calls
`transferFrom` and each token checks the registry itself, so the checks happen at
settlement time rather than only at account opening. Re-implementing them in the settlement
contract would create a second source of truth that drifts from the first, and the
settlement path is precisely where that drift would go unnoticed. The settlement contract
stays token-agnostic and lets either leg refuse.

**The two legs do not check the same things**, and the settlement contract does not need to
know which is which. Both require buyer and seller to be approved, both block a frozen
sender, and both check the settlement contract for sanctions as the spender. Only the cash
leg reads a tier, because only the cash leg enforces transfer limits: a daily cap is an AML
control on money, and the asset leg deliberately carries none
([asset section 4](design-asset.md#4-no-transfer-limits)). One consequence is worth
carrying at this level. An address can be eligible to hold the bond while unable to move
cash, so a trade with such a party fails on the cash leg, with the cash leg's own error.
Classification failures surface in one place rather than two.

**The registry stays a separate repository**, consumed as a pinned submodule. It is
independently governed and UUPS-upgradeable, so which commit is under review has to be
explicit — see [_What `immutable` does not buy_](design-cash.md#what-immutable-does-not-buy).
Both tokens inherit its upgrade governance as their trust root, so the settlement contract
rests on one trust assumption rather than two.
