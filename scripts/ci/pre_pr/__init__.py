"""scripts/pre-pr's checks as importable modules.

environment   the repository, output directory, host and git queries
swift_tests   the SwiftPM test-target graph and which unit tests a change selects
planner       which checks the CI Gate's pull-request jobs would run for a change
runner        one check's lifecycle: launch, wait, classify, undo side effects
summary       the PR-body Markdown record and its hidden pre-pr-summary marker
lock          the machine-wide lock that serialises runs

scripts/pre-pr owns the command line, the autofix pass and the run's order.
"""
