# Notes for AI agents working in this repo

## Never mix in content from the user's other projects

This repo is a public fork. Content from whatever the user happens to be
editing (papers, coursework, private repos) must NOT end up in it: not in
tests, not in fixtures, not in code comments, not in commit messages, not in
reports/. This includes rewording it. A real session's log is a fine thing to
reason from and a bad thing to paste.

When a bug report comes with a real snippet, reproduce the *shape* of the
failure with a synthetic example in a neutral domain, ideally one drawn from
this codebase (nvim/Lua config, a JSON blob, a function signature). Named
entities from the user's work -- project names, model names, dataset names,
table headers, section titles -- are the part that must not survive the
translation.

## Benchmarks / experiment harnesses (tmp/)

- Latency is a production concern, not a testing one. For gpt-oss and every
  other model, pick the slower and cheaper provider whenever the call is part
  of a bench, a test, or an experiment; fast providers are only worth paying
  for on the interactive paths a user actually waits on.
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
