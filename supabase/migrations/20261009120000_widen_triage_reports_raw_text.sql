-- The watch queue and hub accept original transcripts up to 16,000 characters;
-- varchar(1000) made a single long report fail its whole upsert batch.
-- Widening a varchar limit is non-destructive and keeps existing rows.
alter table public.triage_reports
  alter column raw_text type varchar(16000);
