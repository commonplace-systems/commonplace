// Full roundtrip: Yelixer -> Yjs -> Yelixer
// 1. Read Yelixer update, apply to Yjs doc
// 2. Make an edit in Yjs
// 3. Encode and save for Yelixer to read back
import * as Y from '../../yjs/src/index.js'
import fs from 'fs'

// Step 1: Load Yelixer update
const yelixerUpdate = new Uint8Array(fs.readFileSync('test/fixtures/yelixer_text_update.bin'))
const doc = new Y.Doc({ gc: false })
doc.clientID = 200
Y.applyUpdate(doc, yelixerUpdate)

console.log('After Yelixer update:', doc.get('text').toString())

// Step 2: Make a Yjs edit
doc.transact(() => {
  const text = doc.get('text')
  text.insert(text.length, ' and yjs')
})

console.log('After Yjs edit:', doc.get('text').toString())

// Step 3: Encode full state and save
const fullUpdate = Y.encodeStateAsUpdate(doc)
fs.writeFileSync('test/fixtures/roundtrip_yjs_update.bin', Buffer.from(fullUpdate))
fs.writeFileSync('test/fixtures/roundtrip_expected.txt', doc.get('text').toString())

console.log('Saved roundtrip_yjs_update.bin:', fullUpdate.byteLength, 'bytes')
console.log('Expected text:', doc.get('text').toString())
