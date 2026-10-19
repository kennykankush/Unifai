# Unifai

Created: 2026-10-18. Status: initial vision from Warroom; implementation has not started. This document preserves Hadi’s intent for future development. It distinguishes the requested experience from proposed implementation choices.

Unifai is a personal hub for the AI tools you use, the computation you pay for, and the developments you care about. Open it to understand your spending, remaining balances, subscription allowances, and what changed across AI.

## The raw spark

Hadi described the initial problem on 2026-10-18:

> i need your help, i want to make a apple app or widget or status bar idk like a full status bar on all AI tools tracking
>
> im so lost, first of all my pain problem is iwant to cnnect to openrouter, deepseek api, claude api and codex and claude accounts and tally like current subscription and lifetime 'SPENDING' on ai 'COMPUTATION' if u get what i mean
>
> and i want to see as of today my blaances in all the sites i use etc etc you get what im ena?

He then expanded the idea:

> and for example the widget is  also including twitter updates etc like x.com all the ai algorithm for example i want the wdiget to also be my AI HUB if u get what i mean meaning, latest news, reset news, new harnesses , github watchetc etc if u get what i mean? like genuinly its like all things AI

The project name and destination are confirmed: Unifai, at `/Users/hamulia/dev/unifai`.

## The experience to build toward

Hadi is the first user. His AI spending and awareness are scattered across provider sites, subscription accounts, social feeds, and repositories. Unifai should make that whole situation understandable from one place.

The working experience promise is: “Show me my AI situation today, and what changed that deserves my attention.” This wording is an agent synthesis of the discussion.

The requested coverage includes:

| Area | What Hadi wants to understand |
| --- | --- |
| Spending | Current subscriptions and lifetime spending on AI computation, with useful period breakdowns |
| Balances | Credit remaining across the services he uses, including OpenRouter and DeepSeek |
| Accounts | Claude API, Claude subscription, and Codex account information, with their billing boundaries preserved |
| Availability | Usage allowances, resets, and changes affecting access; confirm the intended meaning of “reset news” |
| Updates | AI news, X posts, new harnesses, and GitHub activity or releases from followed projects |
| Discovery | Developments beyond his existing tools, preserving the ambition of “all things AI” |

## The proposed product shape

The current proposal is a macOS app with a menu bar companion and an optional widget. Hadi has not chosen the exact surface or technology stack.

The menu bar could show spending, balances, allowances, and urgent changes. An expanded panel could combine account status with a short briefing. The full app could contain history, subscriptions, source management, and discovery. A widget could show a chosen subset.

Two views could keep the breadth manageable: updates about accounts and tools you follow, and wider AI discovery. This organization is a proposal, not a decision to restrict coverage.

Connecting the information is a promising direction. A harness release that adds a provider you already fund could matter more than an unrelated announcement. Any such relevance explanation should link to its sources and distinguish interpretation from confirmed facts.

## How to count the money

Keep money paid, computation consumed, and credit remaining as separate measures. If you buy $100 of credit and consume $30, show $100 paid, $30 consumed, and $70 remaining. Do not report $130 as spending.

The accounting needs these distinctions:

- Subscription charges and additional usage charges
- Purchased credit and promotional credit
- Provider-reported costs and estimates derived from local usage
- Available history and missing history, including a coverage start date
- Separate accounts, organizations, and currencies

Usage included in a subscription must not become an additional cash expense through an estimated API price. Show equivalent API value separately if that becomes useful.

Lifetime spending requires historical records. A current balance alone cannot establish it. Use invoices, exports, or confirmed entries where provider reporting is insufficient, and show incomplete coverage honestly.

## The first workflow to test

The first prototype should test whether account monitoring and relevant updates belong together in daily use. This sequence is proposed:

1. Add an account and inspect which information its connector can retrieve.
2. See its balance or allowance, spending coverage, and last successful refresh.
3. Add subscription billing records where automatic retrieval is unavailable.
4. Follow selected repositories, official announcements, and AI sources.
5. Open Unifai to review account status and developments, with links to the original records.

Success means Hadi can understand his situation without checking each provider site and can find relevant changes without repeating the same news across feeds.

## System and trust boundaries

A possible system has provider connectors, a local financial ledger, news and release collectors, and shared views for the app, menu bar, and widget. Local storage is a starting proposal; sync and hosting remain undecided.

The first prototype should observe accounts and collect updates. Purchasing credits, changing plans, routing model requests, and posting messages are outside its proposed scope.

Use these boundaries when planning development:

- Keep credentials in macOS Keychain if the native app direction is adopted.
- Request the permissions needed for each connector and explain what they permit.
- Show the source, account, timestamp, and confidence of financial figures.
- Preserve the last successful reading when refreshes fail, with a visible stale state.
- Keep disconnected or unavailable accounts distinct from accounts with zero balances.
- Link news summaries to their sources and distinguish announcements from commentary or speculation.

## Evidence checked during the discussion

These sources were checked on 2026-10-18. They support initial feasibility, not a claim that every required integration is complete:

- [OpenRouter credit documentation](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits): purchased and used credit totals; this endpoint requires a management key.
- [DeepSeek balance documentation](https://api-docs.deepseek.com/api/get-user-balance/): current balances with purchased and promotional components.
- [Claude Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api): historical API usage and cost reporting with Admin API credentials. This does not establish consumer subscription billing coverage.
- [Official OpenAI usage guidance](https://learn.chatgpt.com/docs/pricing): account usage dashboards and Codex CLI status expose remaining limits. Integration and historical billing coverage need separate investigation.
- [CodexBar](https://github.com/steipete/CodexBar): an existing macOS reference for provider monitoring, balances, usage windows, and some cost reporting. Evaluate reuse before duplicating connectors.

## Open decisions and next steps

The next development pass should establish data coverage before committing to a broad interface:

1. Inventory Hadi’s actual accounts, plans, billing currencies, and historical records.
2. Map each connector to available fields, permissions, refresh limits, and missing history.
3. Check X access for the intended feed; a curated source feed and the personalized For You feed are different requirements.
4. Decide which GitHub events matter and how broad discovery should work.
5. Choose the first Mac surface and compare existing connector reuse with a new implementation.

Personal use versus a product for others, iPhone support, sync, storage, and the first build scope remain open. Creating this folder preserves the idea; it does not settle those choices.
