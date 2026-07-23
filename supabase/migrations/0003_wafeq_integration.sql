-- Wafeq accounting sync
-- Adds the columns needed to push issued invoices to Wafeq
-- (https://wafeq.com) via the `wafeq-sync` Edge Function and to remember
-- which Wafeq contact each RWC client maps to.
--
-- Run this in the Supabase SQL editor (Project: lpeqgtxghwprazgyoxpq),
-- same as 0001/0002.

alter table clients
  add column if not exists wafeq_contact_id text;

alter table invoices
  add column if not exists wafeq_invoice_id text,
  add column if not exists wafeq_synced_at  timestamptz,
  add column if not exists wafeq_sync_error text;
