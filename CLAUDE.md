# Notes for AI agents working in this repo

## Benchmarks / experiment harnesses (tmp/)

- Do NOT route benchmark model calls through groq or cerebras on OpenRouter.
  Benches are not latency sensitive; pick other providers (e.g. deepinfra,
  together, nebius).
- Make API requests in parallel when a bench has many independent trials
  (a small worker pool is enough), but keep rate limits in mind: implement
  back-off and retry on 429/5xx instead of hammering.
- API keys are already set as environment variables; there is no need to
  source ~/.secrets.

## Morph (fast apply)

- Use Morph through OpenRouter (model `morph/morph-v3-fast`) until further
  notice, both in production config and in benches. The direct Morph API is
  rate limited on the current plan.
