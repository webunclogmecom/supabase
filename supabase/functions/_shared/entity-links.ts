// ============================================================================
// _shared/entity-links.ts — entity_source_links helpers for webhook handlers
// ============================================================================
// Mirrors sourceLinks.js logic from populate scripts but in Deno/TypeScript
// for Edge Function use.
//
// Entity types: client | property | visit | job | invoice | quote | employee |
//               vehicle | inspection | expense | derm_manifest | route |
//               receivable | lead
// Source systems: jobber | airtable | samsara | fillout | manual
// ============================================================================

import { supabase } from './supabase-client.ts'

export interface EntityLink {
  entity_type: string
  entity_id: number
  source_system: string
  source_id: string
  source_name?: string | null
  match_method?: string
  match_confidence?: number
}

/**
 * Upsert a single entity_source_link.
 * ON CONFLICT (entity_type, entity_id, source_system) → update source_id, synced_at.
 */
export async function upsertEntityLink(link: EntityLink): Promise<void> {
  const { error: upsertError } = await supabase
    .from('entity_source_links')
    .upsert(
      {
        entity_type: link.entity_type,
        entity_id: link.entity_id,
        source_system: link.source_system,
        source_id: String(link.source_id),
        source_name: link.source_name ?? null,
        match_method: link.match_method ?? 'webhook',
        match_confidence: link.match_confidence ?? 1.0,
        synced_at: new Date().toISOString(),
      },
      { onConflict: 'entity_type,entity_id,source_system' }
    )

  if (upsertError) {
    throw new Error(`entity_source_links upsert failed: ${upsertError.message}`)
  }
}

/**
 * Batch upsert multiple entity_source_links.
 */
export async function upsertEntityLinks(links: EntityLink[]): Promise<number> {
  if (!links.length) return 0

  const rows = links.map((l) => ({
    entity_type: l.entity_type,
    entity_id: l.entity_id,
    source_system: l.source_system,
    source_id: String(l.source_id),
    source_name: l.source_name ?? null,
    match_method: l.match_method ?? 'webhook',
    match_confidence: l.match_confidence ?? 1.0,
    synced_at: new Date().toISOString(),
  }))

  const { error } = await supabase
    .from('entity_source_links')
    .upsert(rows, { onConflict: 'entity_type,entity_id,source_system' })

  if (error) throw new Error(`entity_source_links batch upsert failed: ${error.message}`)
  return links.length
}

/**
 * Reverse lookup: find our entity_id from a source system's ID.
 * Returns null if not found.
 */
export async function findEntityBySourceId(
  entityType: string,
  sourceSystem: string,
  sourceId: string
): Promise<number | null> {
  const { data, error } = await supabase
    .from('entity_source_links')
    .select('entity_id')
    .eq('entity_type', entityType)
    .eq('source_system', sourceSystem)
    .eq('source_id', String(sourceId))
    .limit(1)
    .maybeSingle()

  if (error || !data) return null
  return data.entity_id
}

/**
 * Build a Map<source_id, entity_id> for one entity_type + source_system.
 * Call once at handler init to avoid N+1 queries.
 */
export async function buildSourceMap(
  entityType: string,
  sourceSystem: string
): Promise<Map<string, number>> {
  const map = new Map<string, number>()
  let offset = 0
  const PAGE = 1000

  while (true) {
    const { data, error } = await supabase
      .from('entity_source_links')
      .select('source_id, entity_id')
      .eq('entity_type', entityType)
      .eq('source_system', sourceSystem)
      .range(offset, offset + PAGE - 1)

    if (error) throw new Error(`buildSourceMap failed: ${error.message}`)
    if (!data || !data.length) break

    for (const row of data) {
      map.set(String(row.source_id), row.entity_id)
    }
    if (data.length < PAGE) break
    offset += PAGE
  }

  return map
}
