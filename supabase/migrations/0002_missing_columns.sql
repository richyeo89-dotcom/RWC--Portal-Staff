-- Consolidated column audit for RWC Portal (index.html)
-- Adds every column the client-side code expects on tables that predate
-- this migrations/ folder (created via a hand-run "Files SQL migration"
-- that was never committed to this repo — see index.html error strings
-- referencing "have you run the Files SQL migration?").
--
-- Idempotent: every table uses `create table if not exists` with only an
-- `id` column, and every column uses `add column if not exists`, so this
-- is safe to re-run even though most of these tables/columns almost
-- certainly already exist live. It will only create what's actually
-- missing.
--
-- `clients`, `invoices`, and `invoice_line_items` are fully covered by
-- 0001_invoices.sql already and are intentionally omitted here.

-- ═══════════════════════════════════════════════════
-- shipments
-- ═══════════════════════════════════════════════════
create table if not exists shipments (id uuid primary key default gen_random_uuid());
alter table shipments
  add column if not exists rwc_ref           text,
  add column if not exists client_id         uuid references clients(id),
  add column if not exists mode              text,
  add column if not exists status            text,
  add column if not exists origin            text,
  add column if not exists destination       text,
  add column if not exists file_number       text,
  add column if not exists file_status       text,
  add column if not exists ops_checklist     jsonb,
  add column if not exists latest_update     text,
  add column if not exists quoted_by         text,
  add column if not exists assigned_to       text,
  add column if not exists etd               date,
  add column if not exists eta               date,
  add column if not exists carrier           text,
  add column if not exists vessel            text,
  add column if not exists container_number  text,
  add column if not exists bl_number         text,
  add column if not exists commodity         text,
  add column if not exists weight_volume     text,
  add column if not exists t49_container     text,
  add column if not exists agent_name        text,
  add column if not exists created_at        timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- quotes
-- ═══════════════════════════════════════════════════
create table if not exists quotes (id uuid primary key default gen_random_uuid());
alter table quotes
  add column if not exists client_id      uuid references clients(id),
  add column if not exists mode           text,
  add column if not exists origin         text,
  add column if not exists destination    text,
  add column if not exists cargo_details  text,
  add column if not exists status         text,
  add column if not exists created_at     timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- quote_log
-- ═══════════════════════════════════════════════════
create table if not exists quote_log (id uuid primary key default gen_random_uuid());
alter table quote_log
  add column if not exists type        text,
  add column if not exists ref         text,
  add column if not exists company     text,
  add column if not exists contact     text,
  add column if not exists email       text,
  add column if not exists mode        text,
  add column if not exists mode_icon   text,
  add column if not exists origin      text,
  add column if not exists dest        text,
  add column if not exists total       text,
  add column if not exists date        text,
  add column if not exists status      text,
  add column if not exists file_number text,
  add column if not exists data_json   jsonb,
  add column if not exists created_at  timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- delegations
-- ═══════════════════════════════════════════════════
create table if not exists delegations (id uuid primary key default gen_random_uuid());
alter table delegations
  add column if not exists from_email text,
  add column if not exists to_email   text,
  add column if not exists from_date  date,
  add column if not exists to_date    date,
  add column if not exists active     boolean not null default true;

-- ═══════════════════════════════════════════════════
-- documents
-- ═══════════════════════════════════════════════════
create table if not exists documents (id uuid primary key default gen_random_uuid());
alter table documents
  add column if not exists shipment_id uuid references shipments(id),
  add column if not exists client_id   uuid references clients(id),
  add column if not exists name        text,
  add column if not exists doc_type    text,
  add column if not exists file_url    text,
  add column if not exists uploaded_by text,
  add column if not exists created_at  timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- messages
-- ═══════════════════════════════════════════════════
create table if not exists messages (id uuid primary key default gen_random_uuid());
alter table messages
  add column if not exists shipment_id uuid references shipments(id),
  add column if not exists client_id   uuid references clients(id),
  add column if not exists sender_type text,
  add column if not exists sender_name text,
  add column if not exists message     text,
  add column if not exists created_at  timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- file_notes
-- ═══════════════════════════════════════════════════
create table if not exists file_notes (id uuid primary key default gen_random_uuid());
alter table file_notes
  add column if not exists shipment_id        uuid references shipments(id),
  add column if not exists body               text,
  add column if not exists author             text,
  add column if not exists is_client_visible  boolean not null default false,
  add column if not exists created_at         timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- file_documents
-- ═══════════════════════════════════════════════════
create table if not exists file_documents (id uuid primary key default gen_random_uuid());
alter table file_documents
  add column if not exists shipment_id  uuid references shipments(id),
  add column if not exists doc_type     text,
  add column if not exists file_name    text,
  add column if not exists file_url     text,
  add column if not exists storage_path text,
  add column if not exists created_at   timestamptz not null default now();

-- ═══════════════════════════════════════════════════
-- file_clearance
-- ═══════════════════════════════════════════════════
create table if not exists file_clearance (id uuid primary key default gen_random_uuid());
alter table file_clearance
  add column if not exists shipment_id uuid references shipments(id),
  add column if not exists checklist   jsonb,
  add column if not exists costs       jsonb;
