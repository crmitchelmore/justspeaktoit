# Platform qualification gates

These checks provide advisory merge-gate candidates. This change does not edit
repository rulesets. The owner must approve activation separately after the
exact check names and outcomes are observed. Keep the existing Apple checks
and strict branch freshness when deciding whether to require these contexts.

| Context | Required work |
| --- | --- |
| Windows x64 gate | Pinned runtime, native x64 build/tests, portable macOS and Linux |
| Windows ARM64 gate | Native ARM64, standalone bundle execution and MSIX lifecycle |
| Windows distribution gate | macOS cross-build, native x64 execution, standalone bundle and MSIX lifecycle |
| Linux desktop gate | Pinned runtime, GTK build/tests, X11/Wayland and integrations |
| Linux Flatpak gate (optional policy) | Fresh installed bundle checks, or explicitly selected authenticated trusted retest |

Every in-scope pull request starts each workflow regardless of changed paths;
existing target-branch scopes remain. PR classification reads
[the canonical filter file](../.github/desktop-platform-paths.yml) only from the
event's immutable repository-owned base commit, so head policy edits cannot
exclude their own source changes. A base predating that file explicitly
commissions all platforms. Existing unreadable, malformed or incomplete policy
fails closed; policy edits match every lane's trusted self-path pattern. Main push
filters are matching projections checked by the lightweight contract suite.
Documentation, Apple-only and no-change pull requests may intentionally skip
unrelated native work. Manual dispatch and matching main pushes select work.

Each same-workflow terminal job runs with `always()`, no checkout and no token
permissions. It rejects classifier failure, missing/invalid output, and failed,
cancelled, missing or unexpectedly skipped mandatory work. Only a successful
classifier's explicit unrelated-PR decision admits skipped work. Existing
platform jobs, signing policy, caches, artifact names and concurrency remain.

The optional Flatpak gate distinguishes fresh builds from manual trusted
retests. Both source-run inputs must be valid to choose a retest; it retains
successful-source, exact source/merge-parent, package-input and override checks.
A manual retest never substitutes automatically for a relevant PR's fresh-build
gate. Relevant fork PRs cannot run the privileged build and fail visibly; use a
reviewed repository-owned PR. Unrelated fork PRs may pass an explicit path
exclusion. Requiring this fifth context needs an owner decision about that fork
process. No sandbox or credential permissions are added.

`Platform gate contract` runs lightweight Node tests against the actual inline
predicates and selector shell scripts, covering relevant/unrelated changes,
invalid input, failure, cancellation, missing results and intentional skips.
These checks establish orchestration behavior. Native installation, physical
hardware, public signing, updates and release acceptance remain separate.

Before activation, observe exact contexts from real PR runs, retain positive,
negative and fork evidence, reread the live ruleset, review its preservation
diff, and obtain the owner's explicit policy approval. A future merge queue
needs explicit `merge_group` triggers and classification before activation.
