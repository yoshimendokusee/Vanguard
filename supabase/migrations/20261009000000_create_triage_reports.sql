create table public.triage_reports (
  report_id uuid primary key,
  user_id uuid not null default auth.uid()
    references auth.users (id) on delete cascade,
  watch_id varchar(64) not null,
  location varchar(200) not null check (length(btrim(location)) > 0),
  injuries varchar(300) not null check (length(btrim(injuries)) > 0),
  triage text not null check (
    triage in ('Immediate', 'Unassessed', 'Delayed', 'Minor', 'Deceased')
  ),
  patient_count integer not null check (patient_count between 1 and 99),
  age_group text not null check (
    age_group in ('Infant', 'Child', 'Adult', 'Elderly', 'Unspecified')
  ),
  eta_minutes integer check (eta_minutes between 1 and 720),
  raw_text varchar(1000) not null default '',
  created_at timestamptz not null,
  uploaded_at timestamptz not null default now()
);

alter table public.triage_reports enable row level security;

create policy "Users can read their own triage reports"
  on public.triage_reports
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can insert their own triage reports"
  on public.triage_reports
  for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users can update their own triage reports"
  on public.triage_reports
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

grant select, insert, update on public.triage_reports to authenticated;
