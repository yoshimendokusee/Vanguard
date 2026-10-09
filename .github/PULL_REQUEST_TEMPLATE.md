## Summary

Describe the problem, concrete trigger and resulting behavior.

## Feature/module and related task

Affected feature and app: watch / hub / dashboard / shared configuration.
Related issue or task:
Other developer modules affected:

## API contract changes

Describe changes to `docs/api-contract.md`, callers, validation and compatibility,
or write "None".

## Database and migrations

Describe schema changes, migration runner, populated upgrade/reopen/rollback tests
and pending queue preservation, or write "None". Never reset persistent storage.

## Validation

List checks actually run and results. List unrun checks, reasons and device/OS
details for native/hardware claims. Use synthetic data only.

Link the PR CI run. All six required checks must pass; CI alone does not approve a PR.

## Screenshots

For UI changes, include screenshots using synthetic data; otherwise write "N/A".

## Known limitations and integration risks

Document offline queue/ACK behavior, compatibility, security and any migration
or rollback procedure. Link changed architecture/API docs and related issues.

## Review checklist

- [ ] Existing functionality and unrelated changes preserved
- [ ] Relevant tests executed; unrun checks stated
- [ ] Contract/schema changes include affected callers and upgrade tests
- [ ] No secrets, signing keys, database files or patient data added
- [ ] Target features are distinguished from implemented/verified behavior
- [ ] Shared configuration/environment changes reviewed by an affected teammate
- [ ] All required CI checks passed on the current PR revision
- [ ] Another developer approved the latest changes; author approval does not count
- [ ] Review conversations resolved and branch updated with main
- [ ] Merge will be performed manually using squash; no automatic merge
