// Supabase Edge Function: wafeq-sync
//
// Pushes an issued RWC invoice to Wafeq (https://api.wafeq.com) and stores
// the returned Wafeq invoice id back on the `invoices` row.
//
// Called from index.html the same way as shipsgo-tracking / send-notification:
//   fetch(`${SUPABASE_URL}/functions/v1/wafeq-sync`, {
//     method: 'POST',
//     headers: { Authorization: `Bearer ${SUPABASE_KEY}`, 'Content-Type': 'application/json' },
//     body: JSON.stringify({ invoiceId })
//   })
//
// The Wafeq API key never touches the client — it lives only in this
// function's environment. Set it (and the org-specific account / tax-rate
// ids below) with:
//
//   supabase secrets set \
//     WAFEQ_API_KEY=... \
//     WAFEQ_ACCOUNT_INTL_FREIGHT=acc_... \
//     WAFEQ_ACCOUNT_LOCAL_SERVICES=acc_... \
//     WAFEQ_ACCOUNT_DISBURSEMENT=acc_... \
//     WAFEQ_TAX_RATE_ZERO_RATED=tax_... \
//     WAFEQ_TAX_RATE_STANDARD_5=tax_... \
//     WAFEQ_TAX_RATE_OUT_OF_SCOPE=tax_...
//
// The account/tax-rate ids are specific to RWC's Wafeq chart of accounts —
// look them up from the Wafeq dashboard (Settings → Chart of Accounts /
// Tax Rates) or via GET /v1/accounts/ and GET /v1/tax-rates/, then set them
// as secrets above. There is no sane default to guess here.
//
// Deploy with: supabase functions deploy wafeq-sync
// (add --no-verify-jwt if that's how shipsgo-tracking / send-notification
// are deployed, since the client calls this with the publishable key, not
// a user JWT.)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const WAFEQ_API_BASE = 'https://api.wafeq.com/v1';

const VAT_CATEGORY_ACCOUNT_ENV: Record<string, string> = {
  international_freight: 'WAFEQ_ACCOUNT_INTL_FREIGHT',
  forwarding_local_services: 'WAFEQ_ACCOUNT_LOCAL_SERVICES',
  disbursement: 'WAFEQ_ACCOUNT_DISBURSEMENT',
};

const VAT_CATEGORY_TAX_RATE_ENV: Record<string, string> = {
  international_freight: 'WAFEQ_TAX_RATE_ZERO_RATED',
  forwarding_local_services: 'WAFEQ_TAX_RATE_STANDARD_5',
  disbursement: 'WAFEQ_TAX_RATE_OUT_OF_SCOPE',
};

function wafeqHeaders(apiKey: string) {
  return {
    'Authorization': `Api-Key ${apiKey}`,
    'Content-Type': 'application/json',
  };
}

async function ensureWafeqContact(supabase: any, apiKey: string, client: any): Promise<string> {
  if (client.wafeq_contact_id) return client.wafeq_contact_id;

  const res = await fetch(`${WAFEQ_API_BASE}/contacts/`, {
    method: 'POST',
    headers: wafeqHeaders(apiKey),
    body: JSON.stringify({
      name: client.company_name,
      email: client.email || undefined,
      tax_registration_number: client.trn || undefined,
      relationship: ['Customer'],
      external_id: client.id,
    }),
  });
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`Wafeq contact creation failed: ${JSON.stringify(body)}`);
  }

  await supabase.from('clients').update({ wafeq_contact_id: body.id }).eq('id', client.id);
  return body.id;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ ok: false, error: 'POST only' }), { status: 405 });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const wafeqApiKey = Deno.env.get('WAFEQ_API_KEY');
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  try {
    if (!wafeqApiKey) throw new Error('WAFEQ_API_KEY is not configured');

    const { invoiceId } = await req.json();
    if (!invoiceId) throw new Error('invoiceId is required');

    const { data: inv, error: invErr } = await supabase
      .from('invoices')
      .select('*, clients(*), invoice_line_items(*)')
      .eq('id', invoiceId)
      .single();
    if (invErr || !inv) throw new Error(invErr?.message || 'Invoice not found');

    if (inv.status !== 'issued') {
      throw new Error('Only issued invoices can be synced to Wafeq');
    }
    if (inv.wafeq_invoice_id) {
      return new Response(JSON.stringify({ ok: true, wafeqInvoiceId: inv.wafeq_invoice_id, alreadySynced: true }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const contactId = await ensureWafeqContact(supabase, wafeqApiKey, inv.clients);

    const lineItems = (inv.invoice_line_items || []).sort((a: any, b: any) => a.sort_order - b.sort_order);

    const wafeqLineItems = lineItems.map((li: any) => {
      const accountEnvVar = VAT_CATEGORY_ACCOUNT_ENV[li.vat_category];
      const accountId = accountEnvVar && Deno.env.get(accountEnvVar);
      if (!accountId) {
        throw new Error(`Missing Wafeq account mapping for VAT category "${li.vat_category}" — set the ${accountEnvVar} secret`);
      }
      const taxRateEnvVar = VAT_CATEGORY_TAX_RATE_ENV[li.vat_category];
      const taxRateId = taxRateEnvVar && Deno.env.get(taxRateEnvVar);
      if (!taxRateId) {
        throw new Error(`Missing Wafeq tax rate mapping for VAT category "${li.vat_category}" — set the ${taxRateEnvVar} secret`);
      }
      return {
        account: accountId,
        description: li.description,
        quantity: li.quantity,
        unit_amount: li.unit_rate,
        tax_rate: taxRateId,
      };
    });

    const payload = {
      contact: contactId,
      currency: inv.currency,
      invoice_date: inv.issue_date,
      invoice_due_date: inv.issue_date,
      invoice_number: inv.invoice_number,
      notes: inv.notes || undefined,
      tax_amount_type: 'TAX_EXCLUSIVE',
      status: 'FINALIZED',
      line_items: wafeqLineItems,
    };

    const res = await fetch(`${WAFEQ_API_BASE}/invoices/`, {
      method: 'POST',
      headers: wafeqHeaders(wafeqApiKey),
      body: JSON.stringify(payload),
    });
    const body = await res.json();

    if (!res.ok) {
      const message = `Wafeq invoice creation failed (${res.status}): ${JSON.stringify(body)}`;
      await supabase.from('invoices').update({ wafeq_sync_error: message }).eq('id', invoiceId);
      throw new Error(message);
    }

    await supabase.from('invoices').update({
      wafeq_invoice_id: body.id,
      wafeq_synced_at: new Date().toISOString(),
      wafeq_sync_error: null,
    }).eq('id', invoiceId);

    return new Response(JSON.stringify({ ok: true, wafeqInvoiceId: body.id }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response(JSON.stringify({ ok: false, error: String(err?.message || err) }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});
