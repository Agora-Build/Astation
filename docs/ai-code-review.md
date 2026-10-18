# Automated code reviews

The Codex reviewer uses the Responses API with `gpt-6.1-sol` and
`reasoning.effort: "xhigh"`. Repository variables can override these defaults:

| Repository variable | Default |
| --- | --- |
| `CODEX_REVIEW_MODEL` | `gpt-6.1-sol` |
| `CODEX_REVIEW_REASONING_EFFORT` | `xhigh` |

The workflow reads the gateway URL and credential from `OPENAI_BASE_URL` and
`OPENAI_API_KEY` secrets. Model access depends on the account behind that gateway.
An HTTP 400 saying a model is not supported with a ChatGPT account means the
upstream account rejected that model; changing reasoning effort does not fix it.
Check the model's availability on that account before switching to another model.

Codex has a 32,768-token output budget, shared between internal reasoning and
the visible review, and a ten-minute API timeout. An incomplete response fails
the job instead of posting a partial review. Claude keeps its separate model,
API format, and 4,096-token output budget.

Reviews run only after the required CI jobs succeed and use trusted tooling
from the default branch. A workflow rerun against a merged PR skips review;
verify gateway access against an eligible, open PR. A local request-body test
confirms configuration, but does not establish upstream account access.

Official model and reasoning documentation:

- <https://developers.openai.com/api/docs/models/gpt-6.1-sol>
- <https://developers.openai.com/api/docs/guides/reasoning>
