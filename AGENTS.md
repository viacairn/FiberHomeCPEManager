# Agent instructions

## Before every task

Before executing each task in this repository, read this `AGENTS.md` in full and follow its instructions.

## Testing

Always run `./script/test.sh` instead of bare `swift test` so the project's macOS SDK and `SwiftUIMacros` plugin paths are configured properly.

## Scope and complexity

Before adding complexity for a speculative or vanishingly unlikely race or security edge case, explain the concrete failure mode, likelihood, and complexity cost to the user and get their buy-in. Do not silently expand scope for theoretical robustness.
