-- UAE VAT-compliant invoice system
-- Run this entire script once in the Supabase SQL editor (Project: lpeqgtxghwprazgyoxpq)
-- before deploying any of the client-side invoice code in index.html.
--
-- RWC TRN: 104556479400003
-- VAT treatment: international freight = zero-rated (0%), forwarding fees &
-- local services = standard-rated (5%), disbursements = no VAT (out of scope).

-- ═══════════════════════════════════════════════════
-- 1. clients: TRN + billing address
-- ═══════════════════════════════════════════════════
alter table clients
  add column if not exists trn text,
  add column if not exists billing_address text;

alter table clients drop constraint if exists clients_trn_format_chk;
alter table clients
  add constraint clients_trn_format_chk
  check (trn is null or trn ~ '^[0-9]{15}$');

-- ═══════════════════════════════════════════════════
-- 2. invoices (also stores credit notes, via document_type)
-- ═══════════════════════════════════════════════════
create table if not exists invoices (
  id                   uuid primary key default gen_random_uuid(),
  document_type        text not null default 'invoice' check (document_type in ('invoice','credit_note')),
  invoice_number       text unique,                    -- null until issued, e.g. RWC-INV-2026-0001 / RWC-CN-2026-0001
  status               text not null default 'draft' check (status in ('draft','issued','void')),

  client_id            uuid not null references clients(id),
  shipment_id          uuid references shipments(id),  -- nullable: ad-hoc invoices not tied to one job file are allowed

  currency             text not null default 'AED',
  fx_rate_to_aed       numeric not null default 1,      -- AED per 1 unit of `currency`

  subtotal             numeric not null default 0,
  vat_total            numeric not null default 0,
  grand_total          numeric not null default 0,

  supplier_trn         text not null default '104556479400003',
  customer_trn         text,                            -- snapshot of clients.trn at issue time
  billing_address      text,                            -- snapshot of clients.billing_address at issue time

  issue_date           date,
  notes                text,

  created_by           text not null,
  created_at           timestamptz not null default now(),
  issued_by            text,
  issued_at            timestamptz,

  original_invoice_id  uuid references invoices(id),    -- populated only when document_type = 'credit_note'

  updated_at           timestamptz not null default now()
);

create index if not exists invoices_client_id_idx on invoices(client_id);
create index if not exists invoices_shipment_id_idx on invoices(shipment_id);
create index if not exists invoices_status_idx on invoices(status);
create index if not exists invoices_original_invoice_id_idx on invoices(original_invoice_id);

alter table invoices drop constraint if exists invoices_void_only_draft_chk;
alter table invoices
  add constraint invoices_void_only_draft_chk
  check (status <> 'void' or invoice_number is null);

-- ═══════════════════════════════════════════════════
-- 3. invoice_line_items
-- ═══════════════════════════════════════════════════
create table if not exists invoice_line_items (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references invoices(id) on delete cascade,
  sort_order       int not null default 0,
  description      text not null,
  quantity         numeric not null default 1,
  unit_rate        numeric not null default 0,
  vat_category     text not null check (vat_category in ('international_freight','forwarding_local_services','disbursement')),
  vat_rate         numeric not null default 0,
  line_subtotal    numeric not null default 0,
  line_vat_amount  numeric not null default 0,
  line_total       numeric not null default 0
);

create index if not exists invoice_line_items_invoice_id_idx on invoice_line_items(invoice_id);

-- ═══════════════════════════════════════════════════
-- 4. Atomic sequential numbering — sequences never reset (global,
--    monotonic) so the FTA "no gaps in a numbering series" requirement
--    can never be violated by a forgotten/mistimed year-boundary reset.
--    The calendar year in the formatted number is just a display label.
-- ═══════════════════════════════════════════════════
create sequence if not exists invoice_number_seq start 1;
create sequence if not exists credit_note_number_seq start 1;

create or replace function issue_invoice_number(p_invoice_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status   text;
  v_doc_type text;
  v_next     bigint;
  v_number   text;
  v_year     int := extract(year from now());
begin
  select status, document_type into v_status, v_doc_type
  from invoices where id = p_invoice_id for update;

  if v_status is null then
    raise exception 'Invoice % not found', p_invoice_id;
  end if;
  if v_status <> 'draft' then
    raise exception 'Invoice % is not a draft (status=%)', p_invoice_id, v_status;
  end if;
  if v_doc_type <> 'invoice' then
    raise exception 'Use issue_credit_note_number() for credit notes';
  end if;

  v_next := nextval('invoice_number_seq');
  v_number := 'RWC-INV-' || v_year || '-' || lpad(v_next::text, 4, '0');

  update invoices
    set invoice_number = v_number,
        status = 'issued',
        issue_date = current_date,
        issued_by = auth.jwt() ->> 'email',
        issued_at = now(),
        customer_trn = (select trn from clients where id = invoices.client_id),
        billing_address = (select billing_address from clients where id = invoices.client_id)
    where id = p_invoice_id;

  return v_number;
end;
$$;

create or replace function issue_credit_note_number(p_credit_note_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status          text;
  v_doc_type        text;
  v_original_id     uuid;
  v_original_status text;
  v_next            bigint;
  v_number          text;
  v_year            int := extract(year from now());
begin
  select status, document_type, original_invoice_id
    into v_status, v_doc_type, v_original_id
  from invoices where id = p_credit_note_id for update;

  if v_status is null then
    raise exception 'Credit note % not found', p_credit_note_id;
  end if;
  if v_status <> 'draft' then
    raise exception 'Credit note % is not a draft (status=%)', p_credit_note_id, v_status;
  end if;
  if v_doc_type <> 'credit_note' then
    raise exception 'Use issue_invoice_number() for invoices';
  end if;

  select status into v_original_status from invoices where id = v_original_id;
  if v_original_status is distinct from 'issued' then
    raise exception 'Original invoice must be issued before a credit note can be issued against it';
  end if;

  v_next := nextval('credit_note_number_seq');
  v_number := 'RWC-CN-' || v_year || '-' || lpad(v_next::text, 4, '0');

  update invoices
    set invoice_number = v_number,
        status = 'issued',
        issue_date = current_date,
        issued_by = auth.jwt() ->> 'email',
        issued_at = now()
    where id = p_credit_note_id;

  return v_number;
end;
$$;

grant execute on function issue_invoice_number(uuid) to authenticated;
grant execute on function issue_credit_note_number(uuid) to authenticated;

-- ═══════════════════════════════════════════════════
-- 5. RLS
--    NOTE: verify these compose correctly with whatever policies already
--    exist on `clients`/`shipments`/`quote_log` in this project — this repo
--    has no SQL files to confirm the current state, so treat this section
--    as a checklist to review in the dashboard, not a blind diff.
-- ═══════════════════════════════════════════════════
alter table invoices enable row level security;
alter table invoice_line_items enable row level security;

-- Any authenticated staff member may read/insert invoices and drafts.
-- Adjust the `is_staff` condition below to however staff auth is actually
-- scoped elsewhere in this project (e.g. a staff_members table is
-- recommended — see the risk note in the implementation plan/PR notes
-- about isAdmin() being client-side only).
drop policy if exists invoices_staff_select on invoices;
create policy invoices_staff_select on invoices
  for select
  using (auth.role() = 'authenticated');

drop policy if exists invoices_staff_insert on invoices;
create policy invoices_staff_insert on invoices
  for insert
  with check (auth.role() = 'authenticated');

-- Staff can only ever write DRAFTS directly — flipping status to 'issued'
-- is only possible via the SECURITY DEFINER RPCs above, which bypass this
-- check because they execute as the function owner.
drop policy if exists invoices_staff_update_draft_only on invoices;
create policy invoices_staff_update_draft_only on invoices
  for update
  using (status = 'draft')
  with check (status = 'draft');

drop policy if exists invoices_staff_delete_draft_only on invoices;
create policy invoices_staff_delete_draft_only on invoices
  for delete
  using (status = 'draft');

-- Clients may see only their own ISSUED invoices, never drafts.
-- Mirror whatever expression already scopes `shipments`/`quote_log` to the
-- logged-in client (verify in the dashboard) — this assumes clients.email
-- matches the authenticated user's email, consistent with clients.email
-- being the login identifier elsewhere in this app.
drop policy if exists invoices_client_select_own_issued on invoices;
create policy invoices_client_select_own_issued on invoices
  for select
  using (
    status = 'issued'
    and client_id = (select id from clients where email = auth.jwt() ->> 'email')
  );

drop policy if exists invoice_line_items_staff_all on invoice_line_items;
create policy invoice_line_items_staff_all on invoice_line_items
  for all
  using (auth.role() = 'authenticated')
  with check (
    exists (select 1 from invoices i where i.id = invoice_id and i.status = 'draft')
  );

drop policy if exists invoice_line_items_client_select on invoice_line_items;
create policy invoice_line_items_client_select on invoice_line_items
  for select
  using (
    exists (
      select 1 from invoices i
      where i.id = invoice_id
        and i.status = 'issued'
        and i.client_id = (select id from clients where email = auth.jwt() ->> 'email')
    )
  );
