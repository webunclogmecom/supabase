// zero_visits_analysis.js
// Find Jobber clients with zero visits, cross-reference against Airtable visit data
const { newQuery } = require('./populate/lib/db');

// Airtable clients WITH visits (name: visitCount)
const airtableWithVisits = {
  'Pura Vida Flamingo':4, 'The Moore':4, 'The Carrot Express (Sunset Harbor)':6, 'Ceviche Inka':2,
  'Herzka Residence':15, 'NU Real Food':6, 'Soho Asian Bar and Grill':6, 'Street Kitchen':6,
  'Steak House':10, 'Pura Vida Brickell':5, 'Vincenzos Pizzeria':11, 'The carrot express Hollywood':6,
  'Lettuce and Tomato LLC':6, 'Bagel Boss Boca Raton':6, 'Fendi Chateau Residences':6, 'Bagel Cove':6,
  'Pura Vida Doral':7, 'Casa Neos':7, 'Maison Valentine':15, 'Bagel Boss Aventura':6,
  'Cafe Club':6, 'Yann Couvreur':6, 'The Fresh Carrot of Surfside':13, 'G7 Roof Top':6,
  'The carrot express Coral Gables':17, 'Pura Vida Pembroke Pines':5, '17 Restaurant and Sushi Bar':6,
  'Tends':13, 'Hummus Achla':4, 'Cook Unity':1, 'The Carrot Express Aventura':6,
  'La Plaza bakery':4, 'La Granja South Miami':12, 'Grove Kosher Fort Lauderdale':6,
  'The Carrot Express Downtown':6, 'La Granja Calle 8':12, 'The Shul':7, 'Aryeh Hochner':1,
  'Pura Vida Fisher Island':4, 'The Carrot Express Central Kitchen':5, 'Pura Vida Bay Harbor':6,
  'Flame':6, 'Street Bar':6, 'BH Gourmet':4, 'La Granja Allapattah':13,
  'Miami Fresk Fish Market':4, 'Espanola Cigars':6, 'The Carrot Express Brickell':6,
  'Hiros Sushi Express':7, 'AVA Coconout Grove':12, 'Myka':11, 'A La Carte':11,
  'The Carrot Express 71st Collins':20, 'Grove Kosher Boca Raton':6, 'Shaulson Lyft Station':11,
  'La Granja Downtown':12, 'Baoli Miami':6, 'Hikari Miami':6, 'Kosher Bagel Cove':6,
  'Kresy Kosher Pizza':7, 'Marie Blachere':6, 'Florida Food Eats Fialko Miami Beach':6,
  'Pura Vida Design District':4, 'Mutra':12, 'Mrs Pasta':6, 'Fresko Bakery':6, 'KC Market':4,
  'The Carrot Express Miami Shores':9, 'Pura Vida Miracle Mile':4, 'Pura Vida Delray':5,
  '41 Pizza and Bakery':1, 'Cowy Burger':10, 'Rice and Beans':4, 'Pura Vida Coconut Grove':11,
  'The Carrot Express Oakland Park':6, 'Florida Food Eats Fialko Surfside':11, 'Claudie':6,
  'Hebrew Academy':6, 'Sarahs Tent Market':6, 'Cafe Vert':4, 'The Carrot Express Boca Raton':6,
  'Lettuce Tomato Gastobar':7, 'Joshs Deli':6, '57 Ocean Residences':7, 'Shalom Haifa':4,
  'Neya':4, 'Puya Cantina':6, 'Pura Vida Sunset Harbor':4, 'Pura Vida Bakery':5,
  'The carrot express West Boca':6, 'Palomar':1, 'G7 Kitchen':14,
  'The Carrot Express South Miami':6, 'Chima Steakhouse':2, 'The Carrot Express Aventura Mall':15,
  'Happeas':12, 'One Oak BeachWalk':6, 'Daughter of Israel Mikvah':10, 'Ultra Padel Club':6,
  'Pura Vida Dadeland':4, 'Grove Kosher Harding Ave':12, 'Spaguetto':6, 'Yans Restaurant':16,
  'The Joyce':11, 'Barrel Wine Cheese':6, 'Cine Citta Cafe':3, 'Fresko':6,
  'Krudo Fish Market':13, 'The Carrot Express Coconut Grove':6, 'Pura Vida Esplanade':4,
  'Pummarola':8, 'Davinci':6, 'The Palm':6, 'The carrot express Kendall':5,
  'Grove Kosher Delray Beach':6, 'Miami Twist LLC':8, 'Le Basilic':5, 'What Soup':4,
  'Danziguer Kosher Catering':6, 'Bagel Boss Miami Beach':6, 'Bagel Boss':11,
  'Skinny Louie':1, 'Pamplemousse On the bay':6, 'Bagatelle':11, 'Kosh':6,
  'Ironside Cafe':1, 'Mila':12, 'La Granja 36 street':13,
  'The carrot express Pembroke Pines':0, 'The carrot express Plantation':0,
  'carrot express River Landing':0, 'carrot express Coconut Creek':0, 'carrot express Doral':0
};

// Normalize: lowercase, strip non-alphanumeric to spaces, collapse whitespace, trim
function normalize(s) {
  return s.toLowerCase().replace(/[^a-z0-9]/g, ' ').replace(/\s+/g, ' ').trim();
}

// Strip Jobber code prefix like "088-SH ", "147-OST ", "009-CN ", etc.
function stripPrefix(name) {
  return name.replace(/^\d{2,3}-[A-Z]{1,5}\s+/i, '').trim();
}

// Build normalized Airtable name list (only those with visits > 0)
const atNamesWithVisits = Object.entries(airtableWithVisits)
  .filter(([_, count]) => count > 0)
  .map(([name, count]) => ({ original: name, normalized: normalize(name), count }));

(async () => {
  // 1. Get all client IDs that have at least one visit
  const clientsWithVisits = await newQuery(
    `SELECT DISTINCT data->'client'->>'id' AS client_id FROM raw.jobber_pull_visits`
  );
  const visitClientIds = new Set(clientsWithVisits.map(r => r.client_id));

  // 2. Get all clients
  const allClients = await newQuery(`
    SELECT
      data->>'id' AS id,
      data->>'companyName' AS company_name,
      data->>'firstName' AS first_name,
      data->>'lastName' AS last_name,
      data->'billingAddress'->>'city' AS city,
      data->>'balance' AS balance
    FROM raw.jobber_pull_clients
    ORDER BY data->>'companyName'
  `);

  // 3. Filter to zero-visit clients
  const zeroVisitClients = allClients.filter(c => !visitClientIds.has(c.id));

  console.log('Total Jobber clients:', allClients.length);
  console.log('Clients with Jobber visits:', visitClientIds.size);
  console.log('Clients with ZERO Jobber visits:', zeroVisitClients.length);
  console.log('');

  // 4. Match against Airtable names with visits > 0
  const keepList = [];
  const excludeList = [];

  for (const client of zeroVisitClients) {
    const rawName = client.company_name || ((client.first_name || '') + ' ' + (client.last_name || '')).trim();
    const stripped = stripPrefix(rawName);
    const normJobber = normalize(stripped);

    let matched = false;
    let matchedAT = null;

    for (const at of atNamesWithVisits) {
      // Exact normalized match
      if (normJobber === at.normalized) { matched = true; matchedAT = at; break; }

      // Contains match: the shorter must be a substantial portion of the longer
      // and must match on word boundaries (space-delimited) to avoid "kosh" matching "kosher"
      if (normJobber.length >= 4 && at.normalized.length >= 4) {
        const shorter = normJobber.length <= at.normalized.length ? normJobber : at.normalized;
        const longer = normJobber.length <= at.normalized.length ? at.normalized : normJobber;
        // Check word-boundary contains: shorter must appear as complete words in longer
        const shorterWords = shorter.split(' ');
        const longerWords = longer.split(' ');
        const allShorterWordsInLonger = shorterWords.every(sw => longerWords.some(lw => lw === sw));
        if (allShorterWordsInLonger && shorter.length >= longer.length * 0.4) {
          matched = true; matchedAT = at; break;
        }
      }

      // Token overlap: if >= 70% of tokens from either side appear in the other
      const jobberTokens = normJobber.split(' ').filter(t => t.length > 2);
      const atTokens = at.normalized.split(' ').filter(t => t.length > 2);
      if (jobberTokens.length > 0 && atTokens.length > 0) {
        const overlapA = jobberTokens.filter(t => atTokens.includes(t)).length;
        const overlapB = atTokens.filter(t => jobberTokens.includes(t)).length;
        if (overlapA >= Math.ceil(jobberTokens.length * 0.7) || overlapB >= Math.ceil(atTokens.length * 0.7)) {
          matched = true; matchedAT = at; break;
        }
      }
    }

    const balance = parseFloat(client.balance || 0);
    const city = client.city || '';

    if (matched) {
      keepList.push({ jobberName: rawName, stripped, airtableName: matchedAT.original, atVisits: matchedAT.count, city, balance });
    } else {
      excludeList.push({ jobberName: rawName, stripped, city, balance });
    }
  }

  // Sort exclude by balance descending
  excludeList.sort((a, b) => b.balance - a.balance);

  console.log('========================================');
  console.log('KEEP LIST - Zero Jobber visits BUT have Airtable visits');
  console.log('========================================');
  console.log('Count:', keepList.length);
  console.log('');
  for (const k of keepList) {
    const balStr = k.balance ? '  bal=$' + k.balance.toFixed(2) : '';
    console.log('  Jobber: ' + k.jobberName.padEnd(50) + ' -> AT: ' + k.airtableName + ' (' + k.atVisits + ' visits)' + balStr);
  }

  console.log('');
  console.log('========================================');
  console.log('EXCLUDE LIST - Zero visits in BOTH Jobber AND Airtable');
  console.log('Candidates for cleanup/archival - for Yan review');
  console.log('========================================');
  console.log('Count:', excludeList.length);
  console.log('');
  console.log('Name'.padEnd(45) + 'City'.padEnd(25) + 'Balance');
  console.log('-'.repeat(85));
  for (const e of excludeList) {
    const displayName = e.stripped || e.jobberName;
    const balStr = e.balance ? '$' + e.balance.toFixed(2) : '$0.00';
    console.log(displayName.padEnd(45) + (e.city || '(no city)').padEnd(25) + balStr);
  }

  // Summary
  const totalExcludeBalance = excludeList.reduce((s, e) => s + e.balance, 0);
  console.log('');
  console.log('--- Summary ---');
  console.log('Total EXCLUDE clients: ' + excludeList.length);
  console.log('Total EXCLUDE outstanding balance: $' + totalExcludeBalance.toFixed(2));
  console.log('Clients with balance > $0: ' + excludeList.filter(e => e.balance > 0).length);
})().catch(e => console.error(e));
