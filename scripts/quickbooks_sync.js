#!/usr/bin/env node
/**
 * quickbooks_sync.js
 * Full sync: QuickBooks Online -> Supabase
 *
 * Syncs 16 QB entities into public.quickbooks_* tables:
 *   Customer, Invoice, Payment, Item, Account, Purchase, Vendor, Bill,
 *   CreditMemo, JournalEntry, Transfer, Deposit, RefundReceipt,
 *   PaymentMethod, TaxCode, Term
 *
 * Usage:
 *   node scripts/quickbooks_sync.js [--dry-run]
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const https = require('https');
const querystring = require('querystring');

const QB_CLIENT_ID       = process.env.QB_CLIENT_ID;
const QB_CLIENT_SECRET   = process.env.QB_CLIENT_SECRET;
let   QB_REFRESH_TOKEN   = process.env.QB_REFRESH_TOKEN;
const QB_REALM_ID        = process.env.QB_REALM_ID || '9341455565415723';
const SUPABASE_PAT       = process.env.SUPABASE_PAT;
const PROJECT_ID         = 'infbofuilnqqviyjlwul';
const DRY_RUN            = process.argv.includes('--dry-run');

if (!QB_CLIENT_ID || !QB_CLIENT_SECRET || !QB_REFRESH_TOKEN) {
  console.error('Missing QB_CLIENT_ID, QB_CLIENT_SECRET, or QB_REFRESH_TOKEN in .env');
  process.exit(1);
}
if (!SUPABASE_PAT) {
  console.error('Missing SUPABASE_PAT in .env');
  process.exit(1);
}

let QB_ACCESS_TOKEN = null;
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ─── Helpers ──────────────────────────────────────────────────────────────────

function esc(s) {
  if (s === null || s === undefined) return 'NULL';
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function escJson(obj) {
  if (obj === null || obj === undefined) return 'NULL';
  return "'" + JSON.stringify(obj).replace(/'/g, "''") + "'::jsonb";
}

function safeNum(v) {
  if (v === null || v === undefined) return 'NULL';
  const n = Number(v);
  return isNaN(n) ? 'NULL' : String(n);
}

function safeBool(v) {
  if (v === null || v === undefined) return 'NULL';
  if (v === true || v === 'true') return 'true';
  if (v === false || v === 'false') return 'false';
  return 'NULL';
}

function deepGet(obj, path) {
  if (!obj || !path) return null;
  const parts = path.split('.');
  let cur = obj;
  for (const p of parts) {
    if (cur === null || cur === undefined) return null;
    cur = cur[p];
  }
  return cur !== undefined ? cur : null;
}

function httpsRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, headers: res.headers, body: JSON.parse(data) }); }
        catch (e) {
          // Token endpoint may return form-encoded on error
          resolve({ status: res.statusCode, headers: res.headers, body: data });
        }
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

// ─── OAuth2 Token Refresh ─────────────────────────────────────────────────────

async function refreshAccessToken() {
  console.log('[OAuth] Exchanging refresh_token for access_token...');
  const basicAuth = Buffer.from(`${QB_CLIENT_ID}:${QB_CLIENT_SECRET}`).toString('base64');
  const postBody = querystring.stringify({
    grant_type: 'refresh_token',
    refresh_token: QB_REFRESH_TOKEN,
  });

  const { status, body } = await httpsRequest({
    hostname: 'oauth.platform.intuit.com',
    path: '/oauth2/v1/tokens/bearer',
    method: 'POST',
    headers: {
      'Authorization': `Basic ${basicAuth}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
      'Content-Length': Buffer.byteLength(postBody),
    },
  }, postBody);

  if (status !== 200 || !body.access_token) {
    console.error('=== QB OAuth Token Refresh FAILED ===');
    console.error(`Status: ${status}`);
    console.error('Response:', typeof body === 'string' ? body : JSON.stringify(body, null, 2));
    console.error('');
    console.error('To fix: generate a new refresh token from the QuickBooks developer portal');
    console.error('and update QB_REFRESH_TOKEN in your .env file.');
    process.exit(1);
  }

  QB_ACCESS_TOKEN = body.access_token;
  // Store the new refresh token in memory for this session
  if (body.refresh_token && body.refresh_token !== QB_REFRESH_TOKEN) {
    console.log('[OAuth] New refresh_token received (use it to update .env if needed)');
    QB_REFRESH_TOKEN = body.refresh_token;
  }
  console.log(`[OAuth] Access token obtained (expires in ${body.expires_in}s)`);
}

// ─── QuickBooks API ───────────────────────────────────────────────────────────

async function qbQuery(entity, startPosition = 1, maxResults = 1000) {
  const query = `SELECT * FROM ${entity} STARTPOSITION ${startPosition} MAXRESULTS ${maxResults}`;
  const encodedQuery = encodeURIComponent(query);
  const path = `/v3/company/${QB_REALM_ID}/query?query=${encodedQuery}&minorversion=73`;

  const { status, body } = await httpsRequest({
    hostname: 'quickbooks.api.intuit.com',
    path,
    method: 'GET',
    headers: {
      'Authorization': `Bearer ${QB_ACCESS_TOKEN}`,
      'Accept': 'application/json',
    },
  });

  if (status === 401) {
    // Token expired mid-run, try refreshing once
    console.log(`[QB] 401 on ${entity} query, refreshing token...`);
    await refreshAccessToken();
    return qbQuery(entity, startPosition, maxResults);
  }

  if (status !== 200) {
    throw new Error(`QB API ${status} for ${entity}: ${JSON.stringify(body).slice(0, 300)}`);
  }

  return body;
}

async function fetchAllRecords(entity) {
  const all = [];
  let startPosition = 1;
  const maxResults = 1000;

  while (true) {
    const data = await qbQuery(entity, startPosition, maxResults);
    const response = data.QueryResponse || {};
    const records = response[entity] || [];
    all.push(...records);

    if (records.length < maxResults) break;
    startPosition += maxResults;
    await sleep(200); // Rate limit courtesy
  }

  return all;
}

// ─── Supabase SQL ─────────────────────────────────────────────────────────────

async function runSQL(query) {
  if (DRY_RUN) {
    console.log('  [DRY RUN]', query.slice(0, 120) + (query.length > 120 ? '...' : ''));
    return [];
  }
  const bodyStr = JSON.stringify({ query });
  const { status, body } = await httpsRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT_ID}/database/query`,
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${SUPABASE_PAT}`,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(bodyStr),
    },
  }, bodyStr);
  if (body && body.message) throw new Error(body.message);
  return body;
}

async function batchUpsert(table, columns, rows, conflictTarget) {
  if (rows.length === 0) return 0;
  const BATCH = 200;
  let n = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH);
    const values = batch.map(r => `(${r.join(', ')})`).join(',\n');
    const updateCols = columns.filter(c => !conflictTarget.includes(c));
    const setClauses = updateCols.map(c => `${c} = EXCLUDED.${c}`).join(', ');
    await runSQL(
      `INSERT INTO ${table} (${columns.join(', ')}) VALUES\n${values}\n`
      + `ON CONFLICT ${conflictTarget} DO UPDATE SET ${setClauses}`
    );
    n += batch.length;
    await sleep(60);
  }
  return n;
}

// ─── Table Creation ───────────────────────────────────────────────────────────

async function ensureTables() {
  console.log('[Setup] Ensuring all quickbooks_* tables exist...');

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_customers (
      qb_id TEXT PRIMARY KEY,
      display_name TEXT,
      company_name TEXT,
      given_name TEXT,
      family_name TEXT,
      email TEXT,
      phone TEXT,
      mobile TEXT,
      balance NUMERIC,
      is_active BOOLEAN,
      billing_address_line1 TEXT,
      billing_address_city TEXT,
      billing_address_state TEXT,
      billing_address_postal_code TEXT,
      billing_address_country TEXT,
      shipping_address_line1 TEXT,
      shipping_address_city TEXT,
      shipping_address_state TEXT,
      shipping_address_postal_code TEXT,
      shipping_address_country TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_invoices (
      qb_id TEXT PRIMARY KEY,
      doc_number TEXT,
      customer_id TEXT,
      customer_name TEXT,
      txn_date DATE,
      due_date DATE,
      total_amt NUMERIC,
      balance NUMERIC,
      status TEXT,
      email_status TEXT,
      print_status TEXT,
      sales_term_id TEXT,
      deposit NUMERIC,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_payments (
      qb_id TEXT PRIMARY KEY,
      customer_id TEXT,
      customer_name TEXT,
      txn_date DATE,
      total_amt NUMERIC,
      unapplied_amt NUMERIC,
      payment_method TEXT,
      payment_ref_num TEXT,
      deposit_to_account_id TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_items (
      qb_id TEXT PRIMARY KEY,
      name TEXT,
      description TEXT,
      item_type TEXT,
      unit_price NUMERIC,
      purchase_cost NUMERIC,
      income_account_id TEXT,
      expense_account_id TEXT,
      is_active BOOLEAN,
      taxable BOOLEAN,
      sku TEXT,
      qty_on_hand NUMERIC,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_accounts (
      qb_id TEXT PRIMARY KEY,
      name TEXT,
      account_type TEXT,
      account_sub_type TEXT,
      classification TEXT,
      current_balance NUMERIC,
      currency TEXT,
      is_active BOOLEAN,
      fully_qualified_name TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_purchases (
      qb_id TEXT PRIMARY KEY,
      payment_type TEXT,
      txn_date DATE,
      total_amt NUMERIC,
      account_id TEXT,
      entity_id TEXT,
      entity_type TEXT,
      entity_name TEXT,
      doc_number TEXT,
      private_note TEXT,
      credit BOOLEAN,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_vendors (
      qb_id TEXT PRIMARY KEY,
      display_name TEXT,
      company_name TEXT,
      given_name TEXT,
      family_name TEXT,
      email TEXT,
      phone TEXT,
      mobile TEXT,
      balance NUMERIC,
      is_active BOOLEAN,
      is_1099 BOOLEAN,
      billing_address_line1 TEXT,
      billing_address_city TEXT,
      billing_address_state TEXT,
      billing_address_postal_code TEXT,
      billing_address_country TEXT,
      tax_identifier TEXT,
      acct_num TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_bills (
      qb_id TEXT PRIMARY KEY,
      vendor_id TEXT,
      vendor_name TEXT,
      txn_date DATE,
      due_date DATE,
      total_amt NUMERIC,
      balance NUMERIC,
      doc_number TEXT,
      private_note TEXT,
      ap_account_id TEXT,
      sales_term_id TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_credit_memos (
      qb_id TEXT PRIMARY KEY,
      customer_id TEXT,
      customer_name TEXT,
      txn_date DATE,
      total_amt NUMERIC,
      remaining_credit NUMERIC,
      doc_number TEXT,
      private_note TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_journal_entries (
      qb_id TEXT PRIMARY KEY,
      txn_date DATE,
      doc_number TEXT,
      total_amt NUMERIC,
      adjustment BOOLEAN,
      private_note TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_transfers (
      qb_id TEXT PRIMARY KEY,
      txn_date DATE,
      amount NUMERIC,
      from_account_id TEXT,
      from_account_name TEXT,
      to_account_id TEXT,
      to_account_name TEXT,
      private_note TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_deposits (
      qb_id TEXT PRIMARY KEY,
      txn_date DATE,
      total_amt NUMERIC,
      deposit_to_account_id TEXT,
      deposit_to_account_name TEXT,
      private_note TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_refund_receipts (
      qb_id TEXT PRIMARY KEY,
      customer_id TEXT,
      customer_name TEXT,
      txn_date DATE,
      total_amt NUMERIC,
      doc_number TEXT,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_payment_methods (
      qb_id TEXT PRIMARY KEY,
      name TEXT,
      payment_type TEXT,
      is_active BOOLEAN,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_tax_codes (
      qb_id TEXT PRIMARY KEY,
      name TEXT,
      description TEXT,
      is_active BOOLEAN,
      taxable BOOLEAN,
      tax_group BOOLEAN,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_terms (
      qb_id TEXT PRIMARY KEY,
      name TEXT,
      due_days INTEGER,
      discount_percent NUMERIC,
      discount_days INTEGER,
      is_active BOOLEAN,
      created_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ,
      raw_json JSONB,
      synced_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS public.quickbooks_sync_log (
      id SERIAL PRIMARY KEY,
      entity TEXT NOT NULL,
      records_synced INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'success',
      error_message TEXT,
      started_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ DEFAULT NOW(),
      duration_ms INTEGER
    )
  `);

  console.log('[Setup] All tables ensured.');
}

// ─── Entity Mappers ───────────────────────────────────────────────────────────

function mapCustomer(r) {
  return [
    esc(String(r.Id)),
    esc(r.DisplayName),
    esc(r.CompanyName),
    esc(r.GivenName),
    esc(r.FamilyName),
    esc(deepGet(r, 'PrimaryEmailAddr.Address')),
    esc(deepGet(r, 'PrimaryPhone.FreeFormNumber')),
    esc(deepGet(r, 'Mobile.FreeFormNumber')),
    safeNum(r.Balance),
    safeBool(r.Active),
    esc(deepGet(r, 'BillAddr.Line1')),
    esc(deepGet(r, 'BillAddr.City')),
    esc(deepGet(r, 'BillAddr.CountrySubDivisionCode')),
    esc(deepGet(r, 'BillAddr.PostalCode')),
    esc(deepGet(r, 'BillAddr.Country')),
    esc(deepGet(r, 'ShipAddr.Line1')),
    esc(deepGet(r, 'ShipAddr.City')),
    esc(deepGet(r, 'ShipAddr.CountrySubDivisionCode')),
    esc(deepGet(r, 'ShipAddr.PostalCode')),
    esc(deepGet(r, 'ShipAddr.Country')),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapInvoice(r) {
  const balance = r.Balance !== undefined ? Number(r.Balance) : null;
  const status = balance === null ? null : (balance === 0 ? 'Paid' : 'Open');
  return [
    esc(String(r.Id)),
    esc(r.DocNumber),
    esc(deepGet(r, 'CustomerRef.value')),
    esc(deepGet(r, 'CustomerRef.name')),
    esc(r.TxnDate),
    esc(r.DueDate),
    safeNum(r.TotalAmt),
    safeNum(r.Balance),
    esc(status),
    esc(r.EmailStatus),
    esc(r.PrintStatus),
    esc(deepGet(r, 'SalesTermRef.value')),
    safeNum(r.Deposit),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapPayment(r) {
  return [
    esc(String(r.Id)),
    esc(deepGet(r, 'CustomerRef.value')),
    esc(deepGet(r, 'CustomerRef.name')),
    esc(r.TxnDate),
    safeNum(r.TotalAmt),
    safeNum(r.UnappliedAmt),
    esc(deepGet(r, 'PaymentMethodRef.name')),
    esc(r.PaymentRefNum),
    esc(deepGet(r, 'DepositToAccountRef.value')),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapItem(r) {
  return [
    esc(String(r.Id)),
    esc(r.Name),
    esc(r.Description),
    esc(r.Type),
    safeNum(r.UnitPrice),
    safeNum(r.PurchaseCost),
    esc(deepGet(r, 'IncomeAccountRef.value')),
    esc(deepGet(r, 'ExpenseAccountRef.value')),
    safeBool(r.Active),
    safeBool(r.Taxable),
    esc(r.Sku),
    safeNum(r.QtyOnHand),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapAccount(r) {
  return [
    esc(String(r.Id)),
    esc(r.Name),
    esc(r.AccountType),
    esc(r.AccountSubType),
    esc(r.Classification),
    safeNum(r.CurrentBalance),
    esc(deepGet(r, 'CurrencyRef.value')),
    safeBool(r.Active),
    esc(r.FullyQualifiedName),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapPurchase(r) {
  return [
    esc(String(r.Id)),
    esc(r.PaymentType),
    esc(r.TxnDate),
    safeNum(r.TotalAmt),
    esc(deepGet(r, 'AccountRef.value')),
    esc(deepGet(r, 'EntityRef.value')),
    esc(deepGet(r, 'EntityRef.type')),
    esc(deepGet(r, 'EntityRef.name')),
    esc(r.DocNumber),
    esc(r.PrivateNote),
    safeBool(r.Credit),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapVendor(r) {
  return [
    esc(String(r.Id)),
    esc(r.DisplayName),
    esc(r.CompanyName),
    esc(r.GivenName),
    esc(r.FamilyName),
    esc(deepGet(r, 'PrimaryEmailAddr.Address')),
    esc(deepGet(r, 'PrimaryPhone.FreeFormNumber')),
    esc(deepGet(r, 'Mobile.FreeFormNumber')),
    safeNum(r.Balance),
    safeBool(r.Active),
    safeBool(r.Vendor1099),
    esc(deepGet(r, 'BillAddr.Line1')),
    esc(deepGet(r, 'BillAddr.City')),
    esc(deepGet(r, 'BillAddr.CountrySubDivisionCode')),
    esc(deepGet(r, 'BillAddr.PostalCode')),
    esc(deepGet(r, 'BillAddr.Country')),
    esc(r.TaxIdentifier),
    esc(r.AcctNum),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapBill(r) {
  return [
    esc(String(r.Id)),
    esc(deepGet(r, 'VendorRef.value')),
    esc(deepGet(r, 'VendorRef.name')),
    esc(r.TxnDate),
    esc(r.DueDate),
    safeNum(r.TotalAmt),
    safeNum(r.Balance),
    esc(r.DocNumber),
    esc(r.PrivateNote),
    esc(deepGet(r, 'APAccountRef.value')),
    esc(deepGet(r, 'SalesTermRef.value')),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapCreditMemo(r) {
  return [
    esc(String(r.Id)),
    esc(deepGet(r, 'CustomerRef.value')),
    esc(deepGet(r, 'CustomerRef.name')),
    esc(r.TxnDate),
    safeNum(r.TotalAmt),
    safeNum(r.RemainingCredit),
    esc(r.DocNumber),
    esc(r.PrivateNote),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapJournalEntry(r) {
  return [
    esc(String(r.Id)),
    esc(r.TxnDate),
    esc(r.DocNumber),
    safeNum(r.TotalAmt),
    safeBool(r.Adjustment),
    esc(r.PrivateNote),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapTransfer(r) {
  return [
    esc(String(r.Id)),
    esc(r.TxnDate),
    safeNum(r.Amount),
    esc(deepGet(r, 'FromAccountRef.value')),
    esc(deepGet(r, 'FromAccountRef.name')),
    esc(deepGet(r, 'ToAccountRef.value')),
    esc(deepGet(r, 'ToAccountRef.name')),
    esc(r.PrivateNote),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapDeposit(r) {
  return [
    esc(String(r.Id)),
    esc(r.TxnDate),
    safeNum(r.TotalAmt),
    esc(deepGet(r, 'DepositToAccountRef.value')),
    esc(deepGet(r, 'DepositToAccountRef.name')),
    esc(r.PrivateNote),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapRefundReceipt(r) {
  return [
    esc(String(r.Id)),
    esc(deepGet(r, 'CustomerRef.value')),
    esc(deepGet(r, 'CustomerRef.name')),
    esc(r.TxnDate),
    safeNum(r.TotalAmt),
    esc(r.DocNumber),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapPaymentMethod(r) {
  return [
    esc(String(r.Id)),
    esc(r.Name),
    esc(r.Type),
    safeBool(r.Active),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapTaxCode(r) {
  return [
    esc(String(r.Id)),
    esc(r.Name),
    esc(r.Description),
    safeBool(r.Active),
    safeBool(r.Taxable),
    safeBool(r.TaxGroup),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

function mapTerm(r) {
  return [
    esc(String(r.Id)),
    esc(r.Name),
    safeNum(r.DueDays),
    safeNum(r.DiscountPercent),
    safeNum(r.DiscountDays),
    safeBool(r.Active),
    esc(deepGet(r, 'MetaData.CreateTime')),
    esc(deepGet(r, 'MetaData.LastUpdatedTime')),
    escJson(r),
    'NOW()',
  ];
}

// ─── Entity Configuration ─────────────────────────────────────────────────────

const ENTITIES = [
  {
    qbEntity: 'Customer',
    table: 'public.quickbooks_customers',
    columns: [
      'qb_id', 'display_name', 'company_name', 'given_name', 'family_name',
      'email', 'phone', 'mobile', 'balance', 'is_active',
      'billing_address_line1', 'billing_address_city', 'billing_address_state',
      'billing_address_postal_code', 'billing_address_country',
      'shipping_address_line1', 'shipping_address_city', 'shipping_address_state',
      'shipping_address_postal_code', 'shipping_address_country',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapCustomer,
  },
  {
    qbEntity: 'Invoice',
    table: 'public.quickbooks_invoices',
    columns: [
      'qb_id', 'doc_number', 'customer_id', 'customer_name',
      'txn_date', 'due_date', 'total_amt', 'balance', 'status',
      'email_status', 'print_status', 'sales_term_id', 'deposit',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapInvoice,
  },
  {
    qbEntity: 'Payment',
    table: 'public.quickbooks_payments',
    columns: [
      'qb_id', 'customer_id', 'customer_name', 'txn_date',
      'total_amt', 'unapplied_amt', 'payment_method', 'payment_ref_num',
      'deposit_to_account_id',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapPayment,
  },
  {
    qbEntity: 'Item',
    table: 'public.quickbooks_items',
    columns: [
      'qb_id', 'name', 'description', 'item_type', 'unit_price',
      'purchase_cost', 'income_account_id', 'expense_account_id',
      'is_active', 'taxable', 'sku', 'qty_on_hand',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapItem,
  },
  {
    qbEntity: 'Account',
    table: 'public.quickbooks_accounts',
    columns: [
      'qb_id', 'name', 'account_type', 'account_sub_type', 'classification',
      'current_balance', 'currency', 'is_active', 'fully_qualified_name',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapAccount,
  },
  {
    qbEntity: 'Purchase',
    table: 'public.quickbooks_purchases',
    columns: [
      'qb_id', 'payment_type', 'txn_date', 'total_amt', 'account_id',
      'entity_id', 'entity_type', 'entity_name', 'doc_number',
      'private_note', 'credit',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapPurchase,
  },
  {
    qbEntity: 'Vendor',
    table: 'public.quickbooks_vendors',
    columns: [
      'qb_id', 'display_name', 'company_name', 'given_name', 'family_name',
      'email', 'phone', 'mobile', 'balance', 'is_active', 'is_1099',
      'billing_address_line1', 'billing_address_city', 'billing_address_state',
      'billing_address_postal_code', 'billing_address_country',
      'tax_identifier', 'acct_num',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapVendor,
  },
  {
    qbEntity: 'Bill',
    table: 'public.quickbooks_bills',
    columns: [
      'qb_id', 'vendor_id', 'vendor_name', 'txn_date', 'due_date',
      'total_amt', 'balance', 'doc_number', 'private_note',
      'ap_account_id', 'sales_term_id',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapBill,
  },
  {
    qbEntity: 'CreditMemo',
    table: 'public.quickbooks_credit_memos',
    columns: [
      'qb_id', 'customer_id', 'customer_name', 'txn_date',
      'total_amt', 'remaining_credit', 'doc_number', 'private_note',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapCreditMemo,
  },
  {
    qbEntity: 'JournalEntry',
    table: 'public.quickbooks_journal_entries',
    columns: [
      'qb_id', 'txn_date', 'doc_number', 'total_amt', 'adjustment',
      'private_note',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapJournalEntry,
  },
  {
    qbEntity: 'Transfer',
    table: 'public.quickbooks_transfers',
    columns: [
      'qb_id', 'txn_date', 'amount', 'from_account_id', 'from_account_name',
      'to_account_id', 'to_account_name', 'private_note',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapTransfer,
  },
  {
    qbEntity: 'Deposit',
    table: 'public.quickbooks_deposits',
    columns: [
      'qb_id', 'txn_date', 'total_amt', 'deposit_to_account_id',
      'deposit_to_account_name', 'private_note',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapDeposit,
  },
  {
    qbEntity: 'RefundReceipt',
    table: 'public.quickbooks_refund_receipts',
    columns: [
      'qb_id', 'customer_id', 'customer_name', 'txn_date',
      'total_amt', 'doc_number',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapRefundReceipt,
  },
  {
    qbEntity: 'PaymentMethod',
    table: 'public.quickbooks_payment_methods',
    columns: [
      'qb_id', 'name', 'payment_type', 'is_active',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapPaymentMethod,
  },
  {
    qbEntity: 'TaxCode',
    table: 'public.quickbooks_tax_codes',
    columns: [
      'qb_id', 'name', 'description', 'is_active', 'taxable', 'tax_group',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapTaxCode,
  },
  {
    qbEntity: 'Term',
    table: 'public.quickbooks_terms',
    columns: [
      'qb_id', 'name', 'due_days', 'discount_percent', 'discount_days',
      'is_active',
      'created_at', 'updated_at', 'raw_json', 'synced_at',
    ],
    mapper: mapTerm,
  },
];

// ─── Sync One Entity ──────────────────────────────────────────────────────────

async function syncEntity(config) {
  const { qbEntity, table, columns, mapper } = config;
  const entityStart = Date.now();

  try {
    const records = await fetchAllRecords(qbEntity);
    console.log(`  ${qbEntity}: fetched ${records.length} records from QB`);

    if (records.length === 0) {
      await logSync(qbEntity, 0, 'success', null, entityStart);
      return 0;
    }

    const rows = records.map(mapper);
    const n = await batchUpsert(table, columns, rows, '(qb_id)');
    console.log(`  ${qbEntity}: upserted ${n} rows into ${table}`);

    await logSync(qbEntity, n, 'success', null, entityStart);
    return n;
  } catch (err) {
    console.error(`  ${qbEntity}: ERROR - ${err.message}`);
    await logSync(qbEntity, 0, 'error', err.message, entityStart);
    return 0;
  }
}

async function logSync(entity, count, status, errorMsg, startMs) {
  const durationMs = Date.now() - startMs;
  try {
    await runSQL(`
      INSERT INTO public.quickbooks_sync_log (entity, records_synced, status, error_message, started_at, completed_at, duration_ms)
      VALUES (${esc(entity)}, ${count}, ${esc(status)}, ${esc(errorMsg)}, to_timestamp(${startMs / 1000}), NOW(), ${durationMs})
    `);
  } catch (e) {
    console.error(`  [log] Failed to write sync log for ${entity}: ${e.message}`);
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const syncStart = Date.now();
  const NOW = new Date().toISOString();

  console.log('================================================================');
  console.log(`QuickBooks sync started  |  ${NOW}`);
  console.log(`Realm ID: ${QB_REALM_ID}`);
  if (DRY_RUN) console.log('DRY RUN -- no writes');
  console.log('================================================================');

  // Step 1: OAuth token refresh
  await refreshAccessToken();

  // Step 2: Ensure all tables exist
  await ensureTables();

  // Step 3: Sync each entity
  console.log('\n[Syncing entities]');
  let totalRows = 0;
  const results = [];

  for (const entity of ENTITIES) {
    const count = await syncEntity(entity);
    totalRows += count;
    results.push({ entity: entity.qbEntity, count });
    await sleep(300); // Rate limit between entities
  }

  // Summary
  const elapsed = ((Date.now() - syncStart) / 1000).toFixed(1);
  console.log('\n================================================================');
  console.log('SYNC SUMMARY');
  console.log('----------------------------------------------------------------');
  for (const r of results) {
    console.log(`  ${r.entity.padEnd(20)} ${String(r.count).padStart(6)} rows`);
  }
  console.log('----------------------------------------------------------------');
  console.log(`Total: ${totalRows.toLocaleString()} rows  |  Duration: ${elapsed}s`);
  console.log('================================================================');
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
