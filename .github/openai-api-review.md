# OpenAI API reviews

`OpenAI API Review` posts an advisory PR review using `gpt-6.1-sol` through the
Responses API. This uses the API organization associated with
`OPENAI_REVIEW_API_KEY`, including eligible claimed ChatGPT subscription API
credits. It does not use Codex CLI or signed-in Codex usage.

Automatic reviews run on non-draft PRs targeting main from owner/member/collaborator
branches in this repository, including new commits. Maintainers can select
**Actions → OpenAI API Review → Run workflow** and enter an open PR number for a
manual review, including forks. Each head commit gets at most one completed bot
review. Existing CI and other reviewers remain independent; this is not a merge
approval or a required gate.

The workflow checks out only the trusted base commit, never runs PR code, and
sends GitHub text patches as untrusted data. It excludes obvious credential files
and key patterns, binary/unavailable patches, and patches beyond a 100,000-character
aggregate cap. Secret detection is best effort; do not commit secrets. Reviews
explicitly disclose omitted files and missing full-file context. Stale results
are discarded. Incomplete API responses fail instead of reporting a clean review.

Each run makes at most one model request with a 5,000-output-token limit, including
reasoning. No automatic paid-request retries. API failures appear in Actions logs;
re-run the job to retry. A failed post or discarded stale response can still incur
API usage. Job timeout: 10 minutes. Concurrent reviews for the same PR serialize.

The restricted key needs Responses API write access. Store it as the repository
Actions secret `OPENAI_REVIEW_API_KEY`; never place it in source. Manage its saved
copy in the 1Password Agent vault using the existing service account. The API
organization currently has auto-reload off. OpenAI consumes applicable promotional
credits first, then other available API balance; this workflow does not enforce
a subscription-credit-only ledger or a monthly dollar ceiling. Monitor the linked
organization's billing and disable this workflow if you want to stop review spend.

Validation: `python3 .github/scripts/test_openai_api_review.py` and
`actionlint .github/workflows/openai-api-review.yml`.

References: [subscription API credits](https://developers.openai.com/api/docs/guides/chatgpt-api-credits),
[Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create).
