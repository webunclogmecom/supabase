// ============================================================================
// _shared/supabase-client.ts — Supabase client for Edge Functions
// ============================================================================
// Uses service-role key → bypasses RLS.  All webhook handlers share this.
// Environment variables SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// auto-injected by Supabase Edge Functions runtime.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

if (!supabaseUrl || !supabaseServiceKey) {
  throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env vars')
}

export const supabase = createClient(supabaseUrl, supabaseServiceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
})
