#!/usr/bin/env node
/**
 * publish_collection.js — push postman/gdo-reporting-bot.postman_collection.json into the Postman
 * workspace through the Postman API, then read it back and prove it landed.
 *
 *   POSTMAN_API_KEY=... POSTMAN_COLLECTION_UID=... node scripts/postman/publish_collection.js
 *
 * Runs from the postman-doc-drift workflow on every push to main that touches postman/**, after the
 * README->description sync check has passed. Fred, 2026-09-18: "everytime we do an update on the
 * docs it should also update as well". Until this existed the workspace copy was a hand re-import
 * (Import -> file -> Replace), which also minted a NEW collection uid every time and broke every
 * saved link; a PUT keeps the uid.
 *
 * Exit 0 = pushed and verified. Exit 1 = Postman refused or the read-back differs. Exit 2 = this
 * script cannot run (no key, no uid, unreadable file). Never prints the key.
 *
 * ⚠ A PUT replaces the whole collection definition, so the INITIAL value of every collection
 *   variable becomes what the file holds (rpaBotKey: blank). Keep the key in the
 *   "UnclogMe - RPA (Prod)" ENVIRONMENT, which this never touches.
 * ⚠ Read-back is the proof, not the 200: the response to a PUT echoes ids, not content.
 */
const fs = require('fs')
const path = require('path')

const ROOT = path.resolve(__dirname, '../..')
const COLLECTION = path.join(ROOT, 'postman/gdo-reporting-bot.postman_collection.json')
const key = process.env.POSTMAN_API_KEY
const uid = process.env.POSTMAN_COLLECTION_UID
if (!key) { console.error('BROKEN: POSTMAN_API_KEY is not set'); process.exit(2) }
if (!uid || !/^\d+-[0-9a-f-]{36}$/.test(uid)) { console.error('BROKEN: POSTMAN_COLLECTION_UID missing or not <owner>-<uuid>: ' + JSON.stringify(uid)); process.exit(2) }

let local
try { local = JSON.parse(fs.readFileSync(COLLECTION, 'utf8')) } catch (e) { console.error('BROKEN: cannot read the collection: ' + e.message); process.exit(2) }

const countRequests = (items) => (items || []).reduce((n, it) => n + (it.item ? countRequests(it.item) : 1), 0)
const folderNames = (items) => (items || []).filter((it) => it.item).map((it) => it.name)
const localRequests = countRequests(local.item)
if (localRequests < 10) { console.error('BROKEN: only ' + localRequests + ' requests in the local file, implausible'); process.exit(2) }

const api = async (method, body) => {
  const r = await fetch('https://api.getpostman.com/collections/' + uid, {
    method,
    headers: { 'X-Api-Key': key, 'Content-Type': 'application/json', 'Accept': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await r.text()
  let json = null
  try { json = JSON.parse(text) } catch { /* keep text */ }
  return { status: r.status, json, text: text.slice(0, 400) }
}

;(async () => {
  // 1. PUT. The API wants the v2.1 collection wrapped in { collection }.
  const put = await api('PUT', { collection: local })
  if (put.status !== 200) {
    const why = put.status === 401 ? 'the API key is invalid or revoked'
      : put.status === 403 ? 'the key holder cannot edit this collection'
      : put.status === 404 ? 'no collection with that uid (was it deleted or re-imported under a new uid?)'
      : put.status === 429 ? 'Postman API rate limit'
      : 'unexpected response'
    console.error('FAILED: PUT returned ' + put.status + ' (' + why + '): ' + put.text)
    process.exit(1)
  }
  console.log('PUT 200: ' + (put.json && put.json.collection ? put.json.collection.name + ' uid ' + put.json.collection.uid : 'ok'))

  // 2. Read back and compare what matters: the description, the request count, the folder names.
  const got = await api('GET')
  if (got.status !== 200 || !got.json || !got.json.collection) {
    console.error('FAILED: read-back GET returned ' + got.status + ': ' + got.text)
    process.exit(1)
  }
  const remote = got.json.collection
  const problems = []
  if (remote.info.description !== local.info.description) problems.push('info.description differs after the push')
  const rc = countRequests(remote.item)
  if (rc !== localRequests) problems.push('request count differs: remote ' + rc + ' vs local ' + localRequests)
  const lf = folderNames(local.item).join(' | '), rf = folderNames(remote.item).join(' | ')
  if (lf !== rf) problems.push('folder names differ: remote [' + rf + '] vs local [' + lf + ']')
  if (problems.length) {
    console.error('FAILED: pushed, but the read-back does not match:\n  - ' + problems.join('\n  - '))
    process.exit(1)
  }
  console.log('VERIFIED: description ' + remote.info.description.length + ' chars, ' + rc + ' requests, folders [' + rf + ']')
})().catch((e) => { console.error('FAILED: ' + (e && e.message ? e.message : e)); process.exit(1) })
