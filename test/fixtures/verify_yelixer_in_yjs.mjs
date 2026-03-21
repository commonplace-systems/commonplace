// Verify that Yjs can decode Yelixer-generated binary updates
import * as Y from '../../yjs/src/index.js'
import fs from 'fs'

let passed = 0
let failed = 0

function test(name, fn) {
  try {
    fn()
    console.log(`  PASS: ${name}`)
    passed++
  } catch (e) {
    console.log(`  FAIL: ${name}: ${e.message}`)
    failed++
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'Assertion failed')
}

console.log('Yjs decoding Yelixer updates:')

test('decode Yelixer text update', () => {
  const update = new Uint8Array(fs.readFileSync('test/fixtures/yelixer_text_update.bin'))
  const doc = new Y.Doc({ gc: false })
  Y.applyUpdate(doc, update)
  const text = doc.get('text').toString()
  assert(text === 'from elixir', `Expected "from elixir", got "${text}"`)
})

test('Yelixer state vector is valid', () => {
  const update = new Uint8Array(fs.readFileSync('test/fixtures/yelixer_text_update.bin'))
  const doc = new Y.Doc({ gc: false })
  Y.applyUpdate(doc, update)
  const sv = Y.encodeStateVector(doc)
  assert(sv.byteLength > 0, 'State vector should not be empty')
})

console.log(`\nResults: ${passed} passed, ${failed} failed`)
process.exit(failed > 0 ? 1 : 0)
