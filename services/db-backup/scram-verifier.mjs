// Turn a password into the Postgres SCRAM-SHA-256 verifier, so the plain password never reaches the server.
// Why: on Prod, log_statement = ddl and pgaudit logs role changes, so `ALTER ROLE ... PASSWORD 'plain'`
// typed into the SQL editor would land in the database logs in clear text. A verifier is a salted hash.
//
// Run it yourself, in your own terminal (the password is typed hidden and never printed):
//   node scram-verifier.mjs
// Paste the printed statement into the Supabase SQL editor. Put the SAME password in Railway (PGPASSWORD).
import crypto from 'node:crypto';

const b64 = (b) => Buffer.from(b).toString('base64');
const hmac = (key, msg) => crypto.createHmac('sha256', key).update(msg).digest();
const salted = (pw, salt, iter) => crypto.pbkdf2Sync(Buffer.from(pw, 'utf8'), salt, iter, 32, 'sha256');

export function verifier(password, salt = crypto.randomBytes(16), iter = 4096) {
  const sp = salted(password, salt, iter);
  const storedKey = crypto.createHash('sha256').update(hmac(sp, 'Client Key')).digest();
  const serverKey = hmac(sp, 'Server Key');
  return `SCRAM-SHA-256$${iter}:${b64(salt)}$${b64(storedKey)}:${b64(serverKey)}`;
}

// Self-check against RFC 7677 (user "user", password "pencil"): the same keys must reproduce the
// RFC's client proof and server signature, or nothing is printed.
function selfCheck() {
  const salt = Buffer.from('W22ZaJ0SNY7soEsUEjb6gQ==', 'base64');
  const sp = salted('pencil', salt, 4096);
  const clientKey = hmac(sp, 'Client Key');
  const storedKey = crypto.createHash('sha256').update(clientKey).digest();
  const authMsg = 'n=user,r=rOprNGfwEbeRWgbNEkqO,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0';
  const sig = hmac(storedKey, authMsg);
  const proof = Buffer.from(clientKey.map((x, i) => x ^ sig[i]));
  const serverSig = hmac(hmac(sp, 'Server Key'), authMsg);
  return b64(proof) === 'dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=' && b64(serverSig) === '6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=';
}

function readHidden(prompt) {
  return new Promise((resolve) => {
    process.stdout.write(prompt);
    const stdin = process.stdin; let pw = '';
    if (stdin.isTTY) stdin.setRawMode(true);
    stdin.resume(); stdin.setEncoding('utf8');
    stdin.on('data', function onData(ch) {
      for (const c of ch) {
        if (c === '\r' || c === '\n') { if (stdin.isTTY) stdin.setRawMode(false); stdin.pause(); stdin.removeListener('data', onData); process.stdout.write('\n'); return resolve(pw); }
        if (c === '\u0003') process.exit(130);
        if (c === '\u007f' || c === '\b') { pw = pw.slice(0, -1); continue; }
        pw += c;
      }
    });
  });
}

if (process.argv[1] && process.argv[1].endsWith('scram-verifier.mjs')) {
  if (!selfCheck()) { console.error('Self-check against RFC 7677 FAILED; not printing anything.'); process.exit(1); }
  if (process.argv[2] === '--self-check') { console.log('self-check ok'); process.exit(0); }
  const pw = await readHidden('Password for db_backup_reader (hidden): ');
  if (pw.length < 20) { console.error('Use at least 20 characters (generate it in your password manager).'); process.exit(1); }
  if (!/^[\x21-\x7e]+$/.test(pw)) { console.error('Use plain ASCII without spaces (letters, digits, symbols).'); process.exit(1); }
  console.log('\nPaste this into the Supabase SQL editor:\n');
  console.log(`ALTER ROLE db_backup_reader LOGIN PASSWORD '${verifier(pw)}';\n`);
}
