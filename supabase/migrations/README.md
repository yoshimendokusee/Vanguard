# Supabase migrations

The watch's cloud sync uses `triage_reports`, keyed by the report UUID and
protected by Supabase Auth and row-level security. Apply
`20261009000000_create_triage_reports.sql` to your own Supabase project before
starting the watch with cloud configuration.

From the repository root, initialize/link the Supabase CLI to your project and
apply the committed migration:

```sh
supabase init
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
```

Review the migration and confirm the linked project before applying it. The
watch uses only the project's URL and publishable/anon key; never put a
service-role key in the app or source control. Authenticated users can access
only rows whose `user_id` is their own. RLS is not a substitute for protected
device storage or transport; use synthetic data until those controls are in
place.
