# Reserved Supabase migrations

Supabase is an approved target, not an implemented dependency. This directory
contains no SQL, deployable schema, RLS policy or migration runner.

When adding cloud sync, create versioned timestamp-named PostgreSQL migrations
using Supabase tooling, with roles, RLS, trusted delivery state and upgrade tests.
Use one globally unique report ID across transports and migrate legacy identity
safely. Keep service credentials on the server. Do not run SQLite migrations here
or apply anything to a remote database without explicit authorization.
