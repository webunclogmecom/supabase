CREATE OR REPLACE FUNCTION derm.check_page_geometry(p_dump_folder text, p_effective_page integer, p_bands jsonb, p_top_pct numeric DEFAULT NULL::numeric, p_bottom_pct numeric DEFAULT NULL::numeric)
 RETURNS TABLE(code text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  SELECT * FROM derm._page_geometry_violations($1,$2,$3,$4,$5);
$function$
