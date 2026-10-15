// timing.js: the build (pg_temp) vs the live client.get_client_activity on real clients, both switch states
const fs = require('fs'), path = require('path'); const { query } = require('./query.js');
const sub = (s) => s.replace(/__CFG__/g, 'pg_temp.activity_cfg').replace(/__S__/g, 'pg_temp').replace(/__FN__/g, 'pg_temp.get_client_activity');
const ids = process.argv.slice(2).map(Number);
const sql = `
create temp table activity_cfg as select table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order, false as is_system from audit.entity_render_config
 where table_name not in ('properties','jobs','line_items','gdos','client_contacts','client_jobber_contacts','client_locations','invoices');
${sub(fs.readFileSync(path.join(__dirname, 'config_rows.sql'), 'utf8'))}
${sub(fs.readFileSync(path.join(__dirname, 'helpers.sql'), 'utf8'))}
${sub(fs.readFileSync(path.join(__dirname, 'function.sql'), 'utf8'))}
select set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","email":"fred@ayache.com","role":"authenticated"}', false);
do $t$ declare t timestamptz; r jsonb := '[]'; n int; c bigint; inc boolean; begin
  foreach c in array array[${ids.join(',')}]::bigint[] loop foreach inc in array array[false,true] loop
    t := clock_timestamp(); select count(*) into n from client.get_client_activity(c, inc);
    r := r || jsonb_build_object('client', c, 'inc', inc, 'fn', 'live', 'n', n, 'ms', round(extract(epoch from clock_timestamp()-t)*1000));
    t := clock_timestamp(); select count(*) into n from pg_temp.get_client_activity(c, inc);
    r := r || jsonb_build_object('client', c, 'inc', inc, 'fn', 'new', 'n', n, 'ms', round(extract(epoch from clock_timestamp()-t)*1000),
                                 'visits', (select count(*) from pg_temp.get_client_activity(c, inc) x where x.area = 'visit'));
  end loop; end loop;
  raise exception 'TIMING:%', r::text;
end $t$;`;
query(sql).then((r) => { const m = String(r.error).match(/TIMING:(\[.*?\])/s); console.log(m ? JSON.parse(m[1].replace(/\\"/g, '"')).map((x) => JSON.stringify(x)).join('\n') : String(r.error).slice(0, 800)); });
