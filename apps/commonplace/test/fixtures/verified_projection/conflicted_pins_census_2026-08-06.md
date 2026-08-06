# Conflicted-projection census — CX-6scm acceptance-test input

**Recorded 2026-08-06.** Permanent artifact: after the CX-6scm fix ships, working
out which pins were undecidable *before* the ruling requires reconstructing the
pre-fix world. This file is that record.

## What is being compared

Two ways to answer "what did this document look like at this commit", both extant today:

- **Path A — chain replay.** `Commonplace.Tree.DocBuilder.reconstruct_doc_at/4`
  (`apps/commonplace/lib/commonplace/tree/doc_builder.ex:233`): walk `commit_log`
  from `:latest` to the target, `trim_to_latest_snapshot/1`, drop genesis, fold
  `Yelixer.Encoding.apply_update/2`.
- **Path B — single-commit read.** Apply that one commit's own `update` bytes to a
  fresh `Yelixer.Doc`. This is the pattern the chit spec §8.5 says pins must use
  ("pins are read PER-COMMIT, never chain-replayed"). **It has no public API.** The
  only implementation is `defp Commonplace.Reflog.Restore.single_commit_doc/3`
  (`apps/commonplace/lib/commonplace/reflog/restore.ex:262`). `grep -rn
  'reconstruct_snapshot_at\|snapshot_at('` over `apps/` returns zero hits.

Where the two disagree, the store contains no field saying which is correct. That
undecidability is what CX-6scm resolves; these are the pins it must decide.

`sha256` values are over `Yelixer.Encoding.encode_update/1` of the materialised doc
— the same bytes a byte-identical git export would hash.

## Provenance

| | |
|---|---|
| Source | live serve `commonplace_dev@commonplace`, enforce mode, **read-only** |
| Snapshot API | `CubDB.back_up/2` (read-consistent), taken 2026-08-06T05:58:26Z |
| Snapshot size | 537,156,628 bytes, one `0.cub`, written in 17,187 ms |
| Serve perturbation | `:code.all_loaded` **685 before → 685 after**; newly loaded `[]`; unloaded `[]` |
| `is_loaded` gate | `Commonplace.Store.CommitStore` ✓, `CubDB` ✓ — checked before any call |
| Measurement | offline, fresh OS processes, against the copy only |
| Backup disposition | deleted after measurement (see "Reproducing") |
| Code base | worktree of `/home/jes/commonplace` at `0af9595` |

Corpus at snapshot time: **5,182 documents**
(`c_legacy_empty` 4,108 · `b_modern_regular` 735 · `d_mixed_legacy_to_modern` 236 ·
`e_snapshot_legacy` 80 · `e_snapshot_mixed` 18 · `git_bridge` 3 ·
`e_snapshot_modern` 1 · `genesis_only` 1 — sums to 5,182) ·
content classes (`content_doc` 2,713 · `dir_schema` 2384 · `other_content` 72 ·
`outline_view` 8 · `empty_doc` 5 — sums to 5,182) · head-reconstruct failures **0**.

---

## Part 1 — the conflicted pins (Path A ≠ Path B)

Sample: the same **82 documents** measured on 2026-08-05 (depth ≤ 1200, ≥6 per
(metadata × content) cell, plus the two docs named in the sizing brief), pinned at
~25 % / ~50 % / 100 % of chain depth.

**210 pin attempts · 163 comparable (both paths returned bytes) ·
27 disagree.**

The 47 non-comparable attempts were checked rather than assumed: **all
47 are genesis pins**, Path A `:ok` on every one, Path B `{:error, …}` on every one
— `{:malformed_update, "no function clause matching in Yelixer.Encoding.decode_uint/3"}`,
from decoding a zero-byte `update`. (There are 48 genesis pins in the sample;
exactly 1 carries decodable bytes and is therefore comparable.) **Path A returned
`{:ok, _}` for all 210 attempts** — availability is not the defect; agreement is.

| doc id | pinned commit id | pin / depth | metadata class | content class | sha256 Path A (chain replay) | sha256 Path B (single-commit) | divergence shape | vs 2026-08-05 |
|---|---|---|---|---|---|---|---|---|
| `6b0bc5e4-2544-41c6-85a4-21299af65968` | `a2253a149df08215164e28d8dc95cc6a12727c104f11bf953bc4cd8439484b6b` | 2/13 (p25) | c_legacy_empty | outline_view | `e8aa57cc59603cc45808fc0aad411b5eed71c4bc683dcbb6dfdb8dfed152e34c` | `1b4c459dcc930df9a9e95ff584c08999f70f1d943bb986f9242509b836dcb4fb` | bytes A=935 B=750 delta=185 | unchanged |
| `6b0bc5e4-2544-41c6-85a4-21299af65968` | `5a464c1d5add804fc1713fe0213da30a961a8f5c89bdb4fb9e95f1f54b6c4746` | 5/13 (p50) | c_legacy_empty | outline_view | `4165009f45c4d73481e541f7ef77be86f24386c431668683fe4c8c4f72645560` | `9ba158577edaa88e4bfa5a4b6815a14d18d1b7fc4ff54c16b004bfa30cf04e4f` | bytes A=3709 B=1414 delta=2295 | unchanged |
| `6b0bc5e4-2544-41c6-85a4-21299af65968` | `ac35c1682bb0261e96756cbf5cdf3acb5f3d3ff48205c6dca0aeb8462d3b361c` | 12/13 (p100) | c_legacy_empty | outline_view | `2b29a88982851dc5f05a7b1495423c23c430259bfc13424c19b10b2801cd23a1` | `e79d4c168fbdc524aba02fdba6911c9546faea30b00d06b464e7636203a3127c` | bytes A=13562 B=740 delta=12822 | unchanged |
| `8d29ca50-54eb-4fe1-8419-88efd8d3a66a` | `3d8551a7b220ddbc7b395f69501a94a021bd450c8aa227d3fb0b88737335e38a` | 10/45 (p25) | c_legacy_empty | outline_view | `2b358b657ce7d69edbbe5b2cc77b3644bddcd600a49b7063bca8201953e4125c` | `045c40e342d4d9923d83f65a5fd6a5b69241ec50ccc10e00e478058653888729` | bytes A=8830 B=738 delta=8092 | unchanged |
| `8d29ca50-54eb-4fe1-8419-88efd8d3a66a` | `0a98cf2e799ccff36555b4e90a05ad6ca197fe3276995e989141bcbcb079c40b` | 21/45 (p50) | c_legacy_empty | outline_view | `27c8a15ea35a7cc777fcd02a88268b033415a5ae45efbe1f274ec6b664aba1b0` | `dbbfb8ad15e7cc4dfa565cc0b21dd042532b43993c247ab29b6627d352ab0b7f` | bytes A=17718 B=1018 delta=16700 | unchanged |
| `8d29ca50-54eb-4fe1-8419-88efd8d3a66a` | `083a822566df9b4b2fb1369d9c94d14738ca285705aec92553f2884599d24df4` | 44/45 (p100) | c_legacy_empty | outline_view | `dc68b12028f517e6d64087835538932fc78de696835087a3bde9d240b35bf655` | `2493d07b312be397f6d68ab6adbfd3d9471bfc98a169aed9a5b713b963a118ca` | bytes A=51837 B=906 delta=50931 | unchanged |
| `9741c5b4-684f-4962-be6e-346054b45220` | `97257c285d1c2e2e047e782e85d26cd4e4ce52f05e4571a0eb9d32f2d63b3cf1` | 2/3 (p100) | c_legacy_empty | outline_view | `29ceed21a3b54bc6550b1320833392ed9ac89ad9e4a547e472f8b00137f0b89b` | `0ce776cf9d2d73369f6d79f2b929e68ec396bde4d5189b30d796e94bf4a80767` | bytes A=1577 B=1503 delta=74 | unchanged |
| `ad4078eb-44ef-4b2d-a2a1-365ee6331569` | `f82bd96d30022876b42105e5f8c3b86444851c96c6d521293c42650b9dbb56c5` | 4/5 (p100) | c_legacy_empty | outline_view | `4dbce56bea724b611d5ade19cbb6ef6cd271cc0f9e2b02584bbd51e67e2c16f2` | `003a11d7b6e538ea49691e5b8b6276ce996e4218a971a98e7378cc9c28709130` | bytes A=2292 B=716 delta=1576 | unchanged |
| `c4689f8c-9312-4a0d-adc0-810b40d9c365` | `4076d1fd4b6369772ce35f37c2b021087655d2d82cbbee0ac76d42d2f7eee5bd` | 8/36 (p25) | c_legacy_empty | outline_view | `8cb83712c084cee73727507b24a182f67b7f4b6ce45e6d87362ccdec0fe1fa47` | `17677654e77980cb8827435194e4380e85f6f6683cd5b85f9533215a4106ea2c` | bytes A=15670 B=612 delta=15058 | unchanged |
| `c4689f8c-9312-4a0d-adc0-810b40d9c365` | `885dad641a5bde72e5f15d28115b2606e44864fb5bb74c7c27ca115ba898fd93` | 17/36 (p50) | c_legacy_empty | outline_view | `e67a330209fbbd4aec53baf6e43568c08cf70fa733e2b8f2c5fa115ebd3c4483` | `7815fc25caa73f64bbb1a4bcc146550d007ede8eae2407ce99bc44af8b726c9d` | bytes A=37717 B=1292 delta=36425 | unchanged |
| `c4689f8c-9312-4a0d-adc0-810b40d9c365` | `e701f5614f74ca5c0abafaa3a416482438157aa18039ea9e64672e0b15135fcc` | 35/36 (p100) | c_legacy_empty | outline_view | `e2df30a256d56d7a84707946f2420f09d9ade30436e79afda2967cc5641b182c` | `6dace567e2dabbd2d4c56c92bfcbb6875ee8ecaea831433f88eb6a142be7a11c` | bytes A=60049 B=1330 delta=58719 | unchanged |
| `08d6aa73-25e9-4de4-a7af-7be1f197c9a1` | `55d07520995a6e78adc7d2738424b595a906cd3b63fef3de1d27321f79f700bd` | 239/481 (p50) | e_snapshot_legacy | content_doc | `7fffa654dc76f9227f3008ce55793f9d2e491dd0e02e4d0411669b4362c97df3` | `5b162188eaa14f53799162494512ec025312cb8dda8f1b58f998fe90920c19d7` | bytes A=798 B=827 delta=-29 | unchanged |
| `29efbc57-71f7-4d7e-928b-a0c4d7987cb7` | `1240599f994312452bf8d8d5f7310d13457ccbd03227a8dd3bf7cd591ef7a71f` | 44/183 (p25) | e_snapshot_legacy | content_doc | `17350a13c0a8fc5a3c1e60d07126bdbdeb6ded309454b21da6e2add0d9d158b5` | `d9d00cd0d69154ce7280f4dc4c6a666bad194d2b6d75951f0258aac84dbcbc75` | bytes A=1144 B=1153 delta=-9 | unchanged |
| `29efbc57-71f7-4d7e-928b-a0c4d7987cb7` | `d73d6efaf9b513c49aec54152c035ed2ad89b5e6eaa52aa6a87ac72867ce537d` | 90/183 (p50) | e_snapshot_legacy | content_doc | `0e8054ac7aca4f9fe4668e57ade8f25052dc88bc10c0ede225bc9d2df4bf6885` | `98cf88d564bc03e8447dfab36f0660e66781504df78c88674d514651040c2bcb` | bytes A=2110 B=2119 delta=-9 | unchanged |
| `29efbc57-71f7-4d7e-928b-a0c4d7987cb7` | `d24dd1cebacc4d2438f1717da87d708a80ed6077b2c7a22cbc151a20535a9c67` | 182/183 (p100) | e_snapshot_legacy | content_doc | `6a0cf0cd389b0e0cb6aca90ff4c72fb3afb3046c304dfd020e226d7dd632058e` | `fd8397f92e00ef9e9828186b2b9aaab0bb7c5fab60f05950d44970511193fabb` | bytes A=1768 B=1797 delta=-29 | unchanged |
| `41633420-5907-4ecd-a6d6-ec6c891a0db8` | `8445f610141d2d04cc3e21ca89134b53c57c78baea07556d12ef79495c80a053` | 46/188 (p25) | e_snapshot_legacy | content_doc | `68faa03d7fecd7a0ee3613b54df8abe1c0499d3f631f1378ace7fb5acce61c20` | `0911aa77509d8819928c5fe5830d1b1147a4a6ffde3a1a9ee67b7ebea063ac68` | bytes A=1182 B=1191 delta=-9 | unchanged |
| `41633420-5907-4ecd-a6d6-ec6c891a0db8` | `4d3b143b48bba17bcf107045f6353f670e83593078edcf45ee9626575cdbcd24` | 93/188 (p50) | e_snapshot_legacy | content_doc | `fc6726ed87bc8d4c55f316ba46870c9966194b3c2b2f18326dcf46843206a30d` | `f72dc3b6a6a559176c0ea1fc7444625a84f2a75b16a55762a85bd79f36b2acaa` | bytes A=2140 B=2178 delta=-38 | unchanged |
| `b9a3ca49-3798-43aa-bac1-18bcca58f37a` | `05e30e830a9c4ef1e41887d214f3338617befc3c5eaebe7b8e6aeaa44d16f8c7` | 44/183 (p25) | e_snapshot_legacy | content_doc | `d1a8bc1df84eb56f6fdbbff91282cba7ab2e4d4bc966e1cc87dc6f83f3bad44d` | `ffea501eeb2558516638b7156011a2f07aab849f313d8680000c18fd525255aa` | bytes A=1140 B=1149 delta=-9 | unchanged |
| `b9a3ca49-3798-43aa-bac1-18bcca58f37a` | `3eb6765bc990cc1624341fe161ec9c84e022dbda9a99e0236142e44e2e954b48` | 90/183 (p50) | e_snapshot_legacy | content_doc | `a160d49c365b4c1ea36a2ca0c52dcec0037d77d96051e9795723b52e536d93f7` | `52e4464ceacb776bd661ee77415b9b096a3b5411a708d4c4fe2bdc12d4fbd151` | bytes A=2106 B=2115 delta=-9 | unchanged |
| `bd1006b5-d64d-4981-9a43-3751273dfe3a` | `e54526fb9fe2efa21e2949aea7b06eee299f3e2d758ec2103a90f436b4951e46` | 51/209 (p25) | e_snapshot_legacy | content_doc | `dd7b624a5c537254daabc312c9f20f6361cc66920361b05daa7f92240c0a7210` | `2c93faaee41bf276d020134e67f118242aa92dfecd7dace0c30d6b20e550484a` | bytes A=1262 B=1300 delta=-38 | unchanged |
| `bd1006b5-d64d-4981-9a43-3751273dfe3a` | `5a7525fc0afe5c64f2efdbcbd62e6a46e83c1f0a47b290602ea8d1ec62f1dd29` | 103/209 (p50) | e_snapshot_legacy | content_doc | `9c5316c6cb30a36c5a32fb2b28278d0d55edd02be18c81be2c196740e8badf09` | `a2c4b687a32c42bc771bbef4577beb6f9936fd981700ab1814a1a8759ccff35f` | bytes A=2354 B=2392 delta=-38 | unchanged |
| `80636aca-3475-4888-90ba-c6b64a6dd43b` | `92d8e35bafe111fc1ecfd3838ee98ad214ebd49553d5c7e7649d5a7fe024ab86` | 9999/10000 (p100) | e_snapshot_legacy | dir_schema | `64b6aa13c9e8923d6ac698b464857841e23640481299fc207518ad13a268289f` | `420a4b9afb50981c4809f01d809e4ea8e4a355362153d7daf7bf5f703e651507` | entries A=1 B=2; A-missing=["bartleby"]; A-extra=[] | unchanged |
| `9f4cde3d-5046-4b8d-94f7-cb0dcbb8c9f8` | `a7a3bff891effe38fc83390178f0a9a1fead6bae42c8b5a697cb134cd8b62c4e` | 415/833 (p50) | e_snapshot_legacy | dir_schema | `b36f1861f958aaadd18c5d69fa1544bc6f2e94de0c3a7b92e58132d09488d379` | `091877ccb187105ce05bc8ebc11d1dc02fe2165188d65e8c777517fdb0194cb9` | entries A=412 B=412; A-missing=[]; A-extra=[] | unchanged (pin index moved 413->415: chain grew 829->833) |
| `4d872927-55f2-49e5-a391-c9f15270deaa` | `11b718ef91d8227486e68c8d4189532d18923e0060e3b180dc7854526d3a5528` | 25/104 (p25) | e_snapshot_legacy | outline_view | `1261606acd6f866e1509f24498723c4ca7cdaca959098e3e22c9e82253a6a0c5` | `cace116dd6ec90a5cd908ea4de211956e849089d3afce68bc3fc260973955edc` | bytes A=45365 B=906 delta=44459 | unchanged |
| `4d872927-55f2-49e5-a391-c9f15270deaa` | `e6f67b7e3d01d10462ecc0093c7abff99783e8dd10b9c0f3676e7e8498834044` | 51/104 (p50) | e_snapshot_legacy | outline_view | `68d037aae56de23bfe543f3d4889e92b921bf8e4157332eff13a117a4c041680` | `cfab9a935e8df9e2df6df2028c09661abae6d69f573512ed5250f0352773e73f` | bytes A=91785 B=1798 delta=89987 | unchanged |
| `4d872927-55f2-49e5-a391-c9f15270deaa` | `ec77d8163526f1597aeec1a793fe1e2208a03c3e20e5df7da3d2cfb23c45dacd` | 103/104 (p100) | e_snapshot_legacy | outline_view | `7804825cdd625c2c8ed161d22a026edfb0ca00b4eb9f50f4a1102db9cd3d8cd7` | `3bf7495213713579cbe7b5905ad463acc36f8974dc6278182cf13f1e642479e6` | bytes A=1384 B=1235 delta=149 | unchanged |
| `a30e8a7f-01fb-4664-a4a9-8698d1f895d9` | `c9c00b478eb215f8a47662bb352bf418bf5c593b539f3cb2bafef4c487195418` | 1/2 (p100) | genesis_only | empty_doc | `96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7` | `c5deb7036c1fdb0cddb53d87ebc6e3fe623e8d60d7b31b9b912087a6e6a059b6` | bytes A=2 B=153 delta=-151 | unchanged |

### Concentration

- `c_legacy_empty` / `outline_view`: 11
- `e_snapshot_legacy` / `content_doc`: 10
- `e_snapshot_legacy` / `outline_view`: 3
- `e_snapshot_legacy` / `dir_schema`: 2
- `genesis_only` / `empty_doc`: 1

---

## Part 2 — the head-disagreement corpus (chain replay ≠ live schema read path)

Every `dir_schema` document in the corpus, at **head** (no historical pin involved),
comparing `DocBuilder.reconstruct_doc/3` (chain replay) against
`DocBuilder.reconstruct_snapshot/3` — the path the running system actually uses for
schema docs, and the one whose moduledoc says chain-replaying full snapshots is
unsafe.

**Denominator 2384 `dir_schema` docs · 80 disagree · 78 of those lose ≥1 entry ·
124 tree entries dropped by chain replay in total · 2 entries chain replay shows
that the live path does not.** By metadata class: `c_legacy_empty` 62 · `e_snapshot_legacy` 18.

Sanity check on the predicate: documents whose sha256 matches but whose entry sets
differ = **0**, so sha equality and entry-set equality coincide on this corpus and
the sha is a faithful key.

| doc id | depth | metadata class | sha256 live path (`reconstruct_snapshot`) | sha256 chain replay (`reconstruct_doc`) | entries dropped | dropped names | replay-only names |
|---|---|---|---|---|---|---|---|
| `f1774b3e-9275-47d6-8874-137c016f4d58` | 98 | c_legacy_empty | `898c2552f3772e45f467fc4b2beec22e811dcac5bfb605a9f0409f237a75f462` | `a57fc9b7c6f3fa5f7c58159f5a48cd8f661a3312621ed0c4f9f68340c7b88986` | 6 | ["__identities__", "__processes.json", "__reflog", "bartleby", "claude-code-ffa.bot", "claude-code.bot"] | [] |
| `3a6f7261-688b-422e-ac1b-ba10f72defc4` | 85 | c_legacy_empty | `6125a20fa0b641972d8149149e34b62e25945a4b7486a5014bb426eef830536f` | `757117ded135ec611af0213a3107661c16125d0ae15845a01b1e62f4e37db7eb` | 5 | ["__identities__", "__processes.json", "__reflog", "bartleby", "claude-code-f92.bot"] | [] |
| `426fd1d0-3ff4-4aba-b33d-9d4ea8af7403` | 104 | e_snapshot_legacy | `a3ef6928d32fa81db3628ceba93f7746ba5107cc6a63ace4dc8c55df98e981bf` | `cb684796fb0627cc1e8ed406612c94fbd3e81808b0692390cb538291a75fc8e4` | 5 | ["__identities__", "__processes.json", "__reflog", "bartleby", "claude-code.bot"] | [] |
| `2f64d369-5482-4a61-a367-b314451bc31d` | 92 | c_legacy_empty | `c7199adafa43fad732475998725e7fb31ef70ba7e2defceb2f41efd0512fb115` | `82a1fdcf769a7d180e034c54a93a9f027bbd829f01367821f4c03caea771e59c` | 5 | ["__identities__", "__processes.json", "__reflog", "bartleby", "claude-code.bot"] | [] |
| `81445280-d22f-437c-af5f-832ec6b9a18b` | 3 | c_legacy_empty | `bbe0090cb74c901a8da891f828af032d99f45f84f507a72cf0703d9c9873a744` | `69cc7b5904bf88696d72c3f9a7017c18d0454482ed1cbb834c929433b75f7614` | 5 | ["_compute", "_messages", "_messages.log", "_reactions", "_view.xml"] | [] |
| `6a717fca-c74a-4aa8-b953-47c6aa728735` | 92 | c_legacy_empty | `da201dbd7376a00d82e9a40275e45858b8c06ffc3ff2bb7326dd44512ea5f4e4` | `b3bc3832ff057f1866fcb3536d454dce9366284c9c27e70837006b1a00edb3a5` | 3 | ["__processes.json", "__reflog", "bartleby"] | [] |
| `c5f98297-19f0-453f-8f51-a924cc26b12b` | 79 | c_legacy_empty | `c14a832baaeb8fee819073e6054cb9c9297f002c546c7695b090a58b055bdf0a` | `d85233370d283a11667e025ce365bcd0cf514583cf003cf878a9f555902849ef` | 3 | ["__processes.json", "__reflog", "bartleby"] | [] |
| `35325ad4-58d6-4afe-8a69-0551a9f20fd7` | 72 | c_legacy_empty | `c881354485526fc1f62d0c80cdf3bb622b1389b440f73cd9fe326566f6bbd2b1` | `5c91c10a52ac49adc3fcac4b487d15d5bcdb6b5a511957b6c892137a12bae94f` | 3 | ["__reflog", "bartleby", "claude-code-75.bot"] | [] |
| `85937d0d-c84f-4e4a-9273-ff4f41b9b1df` | 5 | c_legacy_empty | `d475975b15186ee5898e17dbad614fa83c6ec6416d48c8176b622d8493fd0f46` | `60be53634cef95490ede09a63a3b5cef7ccbb0b4501320e3ae91a874eea9ff74` | 2 | ["output.txt", "prompts.txt"] | [] |
| `d45a55a2-4cb4-4ed6-829e-b10748b9ed46` | 5 | c_legacy_empty | `1e8c9872670bb7efb4e96884224424c458b8f0ec1b112e239d81d220ebb2c24a` | `1f06254eb16cd508ef970166665e8ba8c1efbf47913994cf70a562ff819faec3` | 2 | ["output.txt", "prompts.txt"] | [] |
| `c270d429-b7c3-4df0-94d4-b079966a0312` | 10000 | e_snapshot_legacy | `b78298dc42cac339c15b37fb45a69116f8de3be7932dd2c315c97010294a2b31` | `6eada118eadb2cc266c85bcd46909526c5dbc55ae8dd5cfadaa371172359f8f1` | 2 | ["__snapshot", "bartleby"] | [] |
| `e1b3cddf-c22c-4e32-b047-f9d3c255c30f` | 5 | c_legacy_empty | `3552bb5e679d84c62f4f8374c8d2c95623400b5fff215b7d55e5d920af93c5a6` | `c2975a3c73cde98faca2c06a6072251a7c8a1efb08a835e8b75b99006fadd79d` | 2 | ["output.txt", "prompts.txt"] | [] |
| `ccc505d5-7c24-4c08-bc36-764c6ac24aee` | 80 | c_legacy_empty | `0d83ee4ba4e93ecaf301ab4e78014ca5a9f16d975f5a54a7d8f4d190652247e2` | `52c54062cdff8dc9a1379fc1a55a10116e16f4afd056fc5469dd6826aa05d4f1` | 2 | ["__identities__", "claude-code.bot"] | [] |
| `fab997a7-f595-4a38-8448-5a1ca384b453` | 5 | c_legacy_empty | `f5a2dcca40e14dd625896ef2f34021ef7d71944fe8e6d416680985f3952a65ee` | `87c1dddd0981f2eb524cbbbb51442751cdc9e0ef8fd6c67d4e2a592174d793f2` | 2 | ["output.txt", "prompts.txt"] | [] |
| `4cd0a732-7488-432c-a65c-e22b53bfce47` | 5 | c_legacy_empty | `5f320d5f0b210c050b3b43bab35128693019bff71ebf3e872d5de195b8361a9f` | `03de40d4adaac23fd696a2b44f64e7f188a3ab8c7372e45c88dc778ea587932b` | 2 | ["output.txt", "prompts.txt"] | [] |
| `724af043-9d47-4fa4-a4f0-bec1124113de` | 5 | c_legacy_empty | `2a9fa716ae93086d1abef9d54280d878613f8dfe227ec048b22645a329cc54c1` | `c816e6c28212b32ac5b07921b38d21074af462940544575d5167dab6aced3710` | 2 | ["output.txt", "prompts.txt"] | [] |
| `8577646d-cb09-4077-bea7-889ea685bb7d` | 5 | c_legacy_empty | `038bfe82810591d80da8bd3a9d10fae4292c8417a0b71825b2d37d8124a83e23` | `34aacbfec74315c1b74d79ec2effd78b8432e7cf7ec11428577bc676d6e6a617` | 2 | ["output.txt", "prompts.txt"] | [] |
| `1d467ea8-9ce7-4258-b241-a24ed2098d81` | 5 | c_legacy_empty | `05dd5b3075fd41a1e83cd13139fd60b1bc47eaf8b1b911b9da224b1192424282` | `4d683e588867b1ba1ff8c07fe3ecec3f6f47aa76b6ca5190964b856de760ec6d` | 2 | ["output.txt", "prompts.txt"] | [] |
| `97af78ec-12ac-4fa9-8a61-71bbee1f9cb4` | 10000 | e_snapshot_legacy | `978ebe15c5f6818a1318f4d4968d118b2a83b917472cae4de173f61a4b6af8c0` | `df256a0c4dfa640f84771631b09dbaff28ecb6a16842db7d0d701a826a8dc8d2` | 2 | ["__snapshot", "bartleby"] | [] |
| `a89cdcb3-3070-4c83-93a6-5f46f7eb80b9` | 5 | c_legacy_empty | `cbd2b3865ce2f1a720d137d8779ae3bfe545cf3b46a0d9b628345f63c9dfca2c` | `6cb0e2dae405e702c52883ab1f33c69bba764148f3cc765fa89392dec5547531` | 2 | ["output.txt", "prompts.txt"] | [] |
| `3b93401f-1296-4767-90a1-1861e6fc516f` | 5 | c_legacy_empty | `f3725b097377b1a687e12529c5d2dd3eba1f59743318e4741d359a9af1dc125b` | `0a33f5e7f8f32c76b7139b0444f657a8b0b8e8bb452b64b13b211eb0596ca15d` | 2 | ["output.txt", "prompts.txt"] | [] |
| `01aec9ed-3c9e-4645-bae7-6faa1843de50` | 5 | c_legacy_empty | `e01c1c3a210c80af539d4bb3904451679915629ad33122fb19caebb0471210ad` | `8f88d40a85ede7f736658228ca5fdc7036d220b760da88a639d4b76a2b1322af` | 2 | ["output.txt", "prompts.txt"] | [] |
| `de071e39-f382-4095-b688-d0cc42e10679` | 10000 | e_snapshot_legacy | `cd13f2e82efd52c5c48b565bbafcd4a34078a2893f4aa3292aae143962b95771` | `e907cd6fa747f096f86ff8f70d6850ae5e32bdd2806c687ce8c6dc1d676de599` | 2 | ["__snapshot", "bartleby"] | [] |
| `4d9810a9-245c-48d9-a59b-a6689ef9e79f` | 10000 | e_snapshot_legacy | `11dcd61be9212bea529291c9ea95b2727e6f8098007b4682f45a3fa5f5f7fe7c` | `77303bae9f6be0ce73d63c0527ce1c9bd77840dfe5bd2c83104481ae7c77f6d1` | 2 | ["__snapshot", "bartleby"] | [] |
| `287c340c-f9f1-4525-b4ae-cce1699c15dd` | 10000 | e_snapshot_legacy | `e3f8343881f3e9dbf8e5704f449453b8de1d68320231863dc011fc63424e25cb` | `10141abf94b6424ab6ba1e29a042ff9e1462324e0128cddb91b8d3dad90a7bcb` | 2 | ["__snapshot", "bartleby"] | [] |
| `c0492b62-2414-442b-9186-36a591947739` | 10000 | e_snapshot_legacy | `93ab7c1bb39ad4e3c0398e7307c3b0acbbe7ec5e0c2311fbb15c8481ca784732` | `ffa3519865435eadc8e3d0bf1c70e2b99a5be02257a7f8fe94d7cb225e674dcd` | 2 | ["__snapshot", "bartleby"] | [] |
| `a90ab612-02d2-4266-a9ca-ea6a48b02f37` | 10000 | e_snapshot_legacy | `6ce1395fb7351919c2e6cc648f0f298f4833414ba0e5276ed434d86e41b80f51` | `1237ae161d1b79fe9e406370db52309f0c4ede4aa333034caed6192e465816a2` | 2 | ["__snapshot", "bartleby"] | [] |
| `afdb031e-f526-4585-9eb8-ff88c281730c` | 5 | c_legacy_empty | `0619adb49ed9519987ed7909a95963f963a0beb70bb4009f58b1a8e83ee42822` | `16908c67caa5815fc283a1ee8dee8dba1bb1a30722df384ce58c970a41f74cd6` | 1 | ["prompts.txt"] | [] |
| `80636aca-3475-4888-90ba-c6b64a6dd43b` | 10000 | e_snapshot_legacy | `420a4b9afb50981c4809f01d809e4ea8e4a355362153d7daf7bf5f703e651507` | `64b6aa13c9e8923d6ac698b464857841e23640481299fc207518ad13a268289f` | 1 | ["bartleby"] | [] |
| `500436a6-572b-437c-871d-e0f3abab51d0` | 6 | c_legacy_empty | `611bd1ad22726aeedab3b5cd6e4ade304daebb071725c6a95e2ab8fe7f077454` | `e548e9b7b55f58b250f59a5b926cbbf10800452629112aa2d3e4ce4a57928cd2` | 1 | ["output.txt"] | [] |
| `3853dd59-c470-41da-89a9-f5c3e686947e` | 4 | c_legacy_empty | `273cefc2564df2e81c5b989960755367ee21a389109cc362aba5cb4cb85302f1` | `e3639008e95a30e745b71f3861024630381a7bd7a76a71999c93fea916c4ae62` | 1 | ["server"] | [] |
| `f0863b58-0fa8-4d5d-a39d-0a017b2e02b2` | 4 | c_legacy_empty | `7e9a91b4e66ed97c91247201015359dd3a075469027cb6c05e35b75fcd5ac905` | `9c7406cabe45b2eb49e1535fdc7abfcda7079887489dabe357928024c3f54c04` | 1 | ["claude-code.bot"] | [] |
| `31f284ae-77a4-4db9-92d2-fcd47097ad91` | 93 | c_legacy_empty | `db6ad318a26481930813a84ec6e06c640c4b553d4bf6cb9511af7be063cf209e` | `d2284742bb4257d7d6bfef4ddbc2cbfb9ee873ab9ff76fa2e382ef8758e9717f` | 1 | ["claude-code-170.bot"] | [] |
| `bea0404c-f601-49cc-8791-4e49f4839c0b` | 4 | c_legacy_empty | `023c4ebe502874382b7be2f38e6417991de4de0f640d83399500a635a6d804ff` | `89cc2ab3d2862921d38fc026bb0c74a623b898fa6cda851add5f33575e3dbca6` | 1 | ["server"] | [] |
| `fdfa663d-0b10-45cd-be5b-e1b25139575a` | 5 | c_legacy_empty | `b5938f570b2f93b391b1019ba7915ec0ac7a12083070d59672ea8c5c3940066f` | `197aa6dee9fdb6cfbe6c0fdc3e57c80ab398a2e6ae84e3512c51df3aa733b881` | 1 | ["claude-code.bot"] | [] |
| `fff8b916-ab0f-429a-a38c-8d8edd179ed9` | 4 | c_legacy_empty | `42c8fbcb2162eb7f39862f98601e7e3aa94e9d3d5952b4139109f54cbfe1ee93` | `6473a1ab5ba29c96aaf5cb53816ec453af2421c61b31256f149e164492fc88cd` | 1 | ["claude-code.bot"] | [] |
| `5276626d-55b1-4bd4-9c03-443c93026f0a` | 10000 | e_snapshot_legacy | `14222980b5ea871441d75c28014fc1bbfb7e9143c18dc72615a229b36f45641e` | `351e5d85b1c27cfb2f1704a6ef303d29cdae4d40c1bb56e78554a3414e933168` | 1 | ["bartleby"] | [] |
| `b6ec6e36-5e5b-4abf-a974-bb2f0354d6b2` | 4 | c_legacy_empty | `0779af02fbc3db8f5ba5a1a4d6e9c9d8eb0b29d65defcc0a158bf427e2239ea1` | `c754d03c04bf65ef945624447d10f5aed9c819308c52d92e86856ee996ea65f6` | 1 | ["claude-code.bot"] | [] |
| `c6eee6e2-21c3-48e0-8a61-f3fc23ecb477` | 29 | c_legacy_empty | `f44afd5de64a3a00159cf8e46aa0f38966b908ccbf2c90843d88e1f38f212446` | `895f65fe2b4c32285773d98f4715f5b21faf9d167d6a687a222393a7985b7911` | 1 | ["__snapshot"] | [] |
| `8f5d1f62-fee7-4bb3-81d1-4d045625aa29` | 10000 | e_snapshot_legacy | `9a3360931caccaf832f90a140eead787abf29fb0f7f62f6edcc1aa5602327bfa` | `eb513b7a81777deec5f8fec73328fb158f88d00bb6ed8cbd72ca761e387ccd11` | 1 | ["bartleby"] | [] |
| `2d27f2e8-b69a-4adc-95eb-fabc83794949` | 4 | c_legacy_empty | `63ffd1f87fb4449817506fb26200c46d567ea97aa51d6ccae87919067a3451ac` | `e9e1e60eefbece248171b89ff47d13e62b008ed5d52d7ea5dee88584958ed8d1` | 1 | ["claude-code.bot"] | [] |
| `d72d13ee-a640-40e7-8f2d-4b7bc1254fc2` | 86 | c_legacy_empty | `8f3ec6ff07e9ff1eae9e8d321898ad1d41a2f8ae6e611b37643a9dc0713daaa3` | `62d298e531ac95c564869be848178935f9ba582c1ac8373d5fa76d74421a4cb7` | 1 | ["claude-code.bot"] | [] |
| `8b56c1cb-cd32-4bca-a819-50ce63ccd59d` | 4 | c_legacy_empty | `5c8273b6aea508513ac55a525ee9c1ed8ba17a778cdb1b019cbdd0d73c601d1a` | `8d6b414f7ad1271afb6dc4520fd4f88c13f835544af367f039177b872aa38892` | 1 | ["server"] | [] |
| `850bd02f-234a-4008-827a-17e56c5ceaf7` | 4 | c_legacy_empty | `3954732fa101329e2da1476a972e16d1890c9efd216e761c5ffe0030e3089bf8` | `90744cc1b6bfc8acc62c9116aee53041b9aa2aa712fcccda064df816f72e6110` | 1 | ["claude-code.bot"] | [] |
| `d9151c8b-dadb-48cd-953b-659be2bc37bb` | 4 | c_legacy_empty | `cbfba519fdc2d342f646bd28cc88f5b1cce5c06acc4dfd6d24345b747ea30b2f` | `77ff8c46c58c7f34cd877d6908c52ad7e9d9bc9d66bb02d5d1a84fac9f1ceaba` | 1 | ["server"] | [] |
| `2eb444dd-9973-47ea-b01c-4fe12dd9e255` | 5 | c_legacy_empty | `995c11fa181238a9e1f4dc67757f7181721d4ffbf3de8c502eaa8ec4a0c4fbac` | `142de7339d0742c1d70d9e113f3e4e58667328cd5634049aa373524d47aeb8ae` | 1 | ["prompts.txt"] | [] |
| `13fe04fb-16d9-430e-b9ee-b0b121fcff81` | 4 | c_legacy_empty | `5e640cb97f956aa5f2efc88be34aafb8723b17afb4ce95e6d6ed781553526ec0` | `c723747618dadc83103e001b8684b61c4dcae2e8071aab6f7058706c4beed198` | 1 | ["server"] | [] |
| `417f3d6e-c3d0-4d2f-aae7-3e018193537b` | 4 | c_legacy_empty | `8707df65d9ffbb457433204d4a5f842b939a1a0d64eed04072cfb0ea416fb243` | `a1f0588497230371870e5c291763c30a1e5cfef7a27e0aae26f212f5fa86b722` | 1 | ["claude-code.bot"] | [] |
| `88c433f3-870a-4e80-a681-a55f301cab1d` | 29 | c_legacy_empty | `e802ceeae29a8e578d3a6d030d41ca8da2f5d14d056fba253dd01d1ef19d59b8` | `1db054a406381a4ba4c98250f301a1f35266e830540ea26df2bbf0f559ccdf15` | 1 | ["__snapshot"] | [] |
| `da5736f0-54cb-45ed-836a-26b59d2558f1` | 4 | c_legacy_empty | `66ac537c20fefe8da532c3d9f9eeef810e32d8a4e908e31c6a7fe7e08ab1c4cf` | `14d3b28787357a6d0fc90e6e7a560100d4f571f288575a99f213be9b90db10c6` | 1 | ["server"] | [] |
| `3f760310-c6ac-41a9-ae53-e6fae493b463` | 10000 | e_snapshot_legacy | `bb707d46bc1b15b067f07aa1cff95f2565990f4d0b8a7e4ba26625c6aceec49b` | `c7c35a1677f8c3e0b478f6f19662a9644de1ace904d91853c69838b1c76b637c` | 1 | ["__snapshot"] | [] |
| `e9b63733-064c-411c-9d86-71a0c1b536ed` | 5 | c_legacy_empty | `ba34152cff981c4dd66140709080c74d8ab67cc22905df2815d51a652ed6cea3` | `7594a6aab82d573f9fc40d730a00e8417a90d1c61c131cef6b9559ae74efafbe` | 1 | ["claude-code.bot"] | [] |
| `5c745613-1762-417c-a135-eaeb33bf7ab5` | 4 | c_legacy_empty | `340dc1922298a822561b8fb131c0ae2868963a658ee22bcd9f78edd5e4640a6c` | `82ab227ef6a929f0d019e715b07776231a293f9a3d735f8369fc7c6eda4c6f07` | 1 | ["claude-code.bot"] | [] |
| `8bcaf483-8936-42db-9c24-0479d49a23d9` | 4 | c_legacy_empty | `2ddc2c3f87ac8e6431b1c7cab71716404f95c99202c5a5eab16da1d7842aac11` | `77dad1e5c63b5d8bef503c15ab3e0077efb4bf924a21877e1b6c092bf7bb331c` | 1 | ["claude-code.bot"] | [] |
| `315c174f-7cf0-40e7-96bb-7c2c649a1f63` | 10000 | e_snapshot_legacy | `b13f8388c926d2a3236d9c48b5f6a6eb2d0c5ec2e9367a7ae9dbfaa6d563cb33` | `5a339c322cf588f89a394b85bb117e9a645b9a9d6d2e358dfd113e233216e6fd` | 1 | ["bartleby"] | [] |
| `47cca6b2-35d1-4568-8f58-61d47be476e6` | 4 | c_legacy_empty | `052de5998169e9e7166f5a46cf779ff065c396ff3e7dfdee3db14b1b48f05fdd` | `f121c122c3282a66138dc4e0a953e80e614ec1654de831674421af241990847f` | 1 | ["server"] | [] |
| `22b4886a-a80d-47c1-b8b2-4159b0676caf` | 28 | c_legacy_empty | `d5cec8e2a30078e2c84169b33d97badfbbb231d6b272da8d8168c842bebe08c0` | `d698399e4492e67aa911cc57b8fbeaf1bd9d4b54c4dfe6bde1d46406aaea44a4` | 1 | ["__snapshot"] | [] |
| `155e8fb6-f366-40f6-8eb6-eceebf7bfb54` | 4 | c_legacy_empty | `2108ec24dd19006544202321f8e9732812472b7bbc3784597f122467fee175db` | `1f8ba89bbfb4d76c10a0f19b42d1b0c560d97eceae48d2984139945ec7603e33` | 1 | ["server"] | [] |
| `fea74634-a608-40ff-91e5-3657411c16de` | 4 | c_legacy_empty | `44b2f3018deb295ff9d482c9012f0a284efa4130bd048cbc296e035bdb07c8e2` | `0432adc68657677d97ebe122a240fcbe984f45627abddf22fbd771de88a95648` | 1 | ["server"] | [] |
| `83da8607-bcb1-4faf-8ce5-2a5deb9aa043` | 4 | c_legacy_empty | `bcb5815b5f2f09972028f541da38558c131527a79b95c552024d4f9c721766aa` | `e34add1f578e4d5bd40c5647e8a93b25a6e699c8c68c37234bc9561260687357` | 1 | ["claude-code.bot"] | [] |
| `69032ca9-ab6f-46b1-b386-200b114063e4` | 10000 | e_snapshot_legacy | `98a1ee6aa52e0caa4f7b2e405385663c8a6241e464ecdb816730c2c6236fe971` | `1511eeced4b32bdc6ca7679a3bedeaefb6c6ca22b3f92910a819f71d4ec262ee` | 1 | ["bartleby"] | [] |
| `29e5b8ab-2f68-452b-b1ba-4ce36e8fd112` | 4 | c_legacy_empty | `6ba6f7920a15000389dffdc03e9386a9a71714d040d88073a58be73696c52b85` | `e8c5b0677204da381f88c49fb8322b6ea16d9973141d012cb941c7020bfca9bd` | 1 | ["server"] | [] |
| `c819aeb8-8ce3-499c-a935-89c8df551861` | 4 | c_legacy_empty | `8f86a06606fc9b89040606600f48a3f1871b68c2d5f0c94252657ffc36c10d5a` | `0cdcfba122a5a78bb7adf57ae663e5e858b3b30d1697d162dd96839e88ebc0a2` | 1 | ["server"] | [] |
| `eb673fdc-edcf-47d9-b4c4-24cc3bd0690a` | 10000 | e_snapshot_legacy | `632d778e76f55f3f102a0a5ecc48242b6b100bac25b2e208aa82063f871cd71b` | `ce6999baafdd9c793d7bd5a1ac0fbc3c20aca353e26ebfe3dcfc8b3e6d0f2c87` | 1 | ["bartleby"] | [] |
| `d20eb888-41d3-4752-93c8-42f1bda375ef` | 10000 | e_snapshot_legacy | `dadf750c95ab8612841847c1acceee685f671f46057b7925cfde09cc12ece124` | `86891752cb17364aa853036157986cd8095ac0a7e8649f25913a4dceb2953919` | 1 | ["__snapshot"] | [] |
| `63a9a698-560f-4f09-8f8f-806ffcf51267` | 4 | c_legacy_empty | `2345da57df0cbec976b6c2ea0221c8fed3055ed1300515f4e71ad680f091b87e` | `cc156945aa77a31afa9f8d8dd3b99681022477beb95de5a45b40b36f3886a630` | 1 | ["claude-code.bot"] | [] |
| `30b928f8-75c5-4926-a31c-8cd8ccef77b0` | 4 | c_legacy_empty | `989ebc4452795e7bd1fc3406093d001fae74508ce849c27701a64a3bc2650f7f` | `fcc530ad7b0dceea90111c241e9909a42036f300953c15f816eebf895788e41b` | 1 | ["claude-code.bot"] | [] |
| `747c9749-b5a1-4bc5-8ba1-8ab19c5c682a` | 4 | c_legacy_empty | `8865d91c3192692faa8e9e532dd7bf3acd178756910c892d446f6572a9cf27cf` | `716292fbe52bedc016c01ce5666cd807e01602c670a11977b35f488c792a2da7` | 1 | ["claude-code.bot"] | [] |
| `fb8e083b-ae4b-42b3-97c9-f3df02ad5f96` | 29 | c_legacy_empty | `d57e6d4f281c66a3bcbb6daa3f67df140ace7f27d0ba421d7953e3b9ae78839b` | `11a1a85b29b79d6dbb394e968765b531c14f24fd12661ff7fc0aa0c663914574` | 1 | ["__snapshot"] | [] |
| `832594cf-505c-4450-a9a2-4053256e6200` | 4 | c_legacy_empty | `fcae4c1faffe8251805890a314d87daf5e11f73f5ab206ed5ee07a69664efb83` | `7ce3273b81b108a9ff2f9a2207463c75cac52f97a32cd70365a315fa777f7376` | 1 | ["server"] | [] |
| `82c9a03f-59c9-4e0f-bfc5-a131942f2ad1` | 5 | c_legacy_empty | `77130d99a015bf9515dd3e637493ff3579eb29b02382965e6025b82ec1ea5fed` | `96d3c98da1ac90f847031b97622eb681114f5b5842dd1e3c8d15ce05fd2f36a8` | 1 | ["prompts.txt"] | [] |
| `aef8335f-a603-42c0-95e1-1dd61809f15a` | 10000 | e_snapshot_legacy | `50bf1c71ff30e48e242406da5b9a83f0ccf7d255f7b9638af2c504f4f8e44550` | `9f738357a47bd0207fd6429b6c96daf65e6e27c62ca76cdb5e8990f7b9bb099a` | 1 | ["__snapshot"] | [] |
| `faa86cc5-5116-4d62-9c73-32b3e27fae1c` | 10000 | e_snapshot_legacy | `87acc95b443205fc05bfd255cf52ed87f9365ae284f84f13cc5381bdc80a4538` | `8158e716feffc67206cd96eeb7b314fdefaff8528531274677c205602303a69b` | 1 | ["bartleby"] | [] |
| `120b0299-5502-4e82-8058-7b626b08db27` | 29 | c_legacy_empty | `f8ab87b06a888d8fde2e6d51f6af26a495acd3ba26623ed530fa636ef1b15828` | `be3030970b9f684f838991581c7d3a43315b6070d8c27c685a54aa7a7e1a7f9f` | 1 | ["__snapshot"] | [] |
| `438f8994-0e2f-46c8-9a58-2533c75c1c24` | 4 | c_legacy_empty | `90fe0ba5d7db2ce4d3ea1fa99b4efb4f64c5389d8aa0cba71c081f4fe5272b78` | `29947e778052f51e5a45737f750b216b65272eefc47a39563434090e5b98cf86` | 1 | ["claude-code.bot"] | [] |
| `6e8319f4-1b45-472c-810b-90b1d5885a1e` | 4 | c_legacy_empty | `64fdccff9582ca529b7ed27264d116bcbed09be2a5a899d3230790ea29b82a73` | `3fa0b0609327cce7e8f44ebbd227a3c94dbd1f26af929f63e0f98003a84d1474` | 1 | ["claude-code.bot"] | [] |
| `2a01f001-d996-402a-a31f-e2e5965141dc` | 5 | c_legacy_empty | `e5b87c7e75e339dec5116186552de9ee59b1ff4f23ac7d44f5714d99fecd5e2b` | `f35a31be176c6c7e020e76e44033cbf361c45f1449fa65415ebb100b6c58feb9` | 1 | ["server"] | [] |
| `0e205392-fe98-45ce-b148-4af2af652ee7` | 4 | c_legacy_empty | `13a9957393b73744cdbe814e3e47e3e27355114ea98b0759ea8818c03be808f2` | `41fd2657be51df5682cd176358fe4250881cf8552779db4786acf76387582a9d` | 1 | ["server"] | [] |
| `a4f1be2a-3813-4c68-816d-40a8eaf4bbac` | 21 | c_legacy_empty | `5592f8b99f9fc9a1b9e51a3ca7f801a6561f28a576f6a08107d4a92b4d8135fc` | `50b2af10a250ceaf4d9779175a01a80002dc5f76e85aa9d0664c9fd775f6d8f8` | 0 | [] | ["chat"] |
| `92e8c43e-663a-4f9d-9ffc-2dc35c9aad39` | 4 | c_legacy_empty | `0c5e923e06302afd04b4b1e0e885fcc65732811c67433928e3314bad60f192b0` | `9e8d5983db39ab587e0eb07817f8761731c8e4e5406b9e01a05bdbf920a0db8c` | 0 | [] | ["pr-4a3b94b4"] |

---

## Membership drift, 2026-08-05 → 2026-08-06

New commits did land between the two snapshots (backup grew 536,902,676 → 537,156,628
bytes; corpus 5,166 → 5,182 docs, +16).

**Part 1 — no status changes.** Keyed on `{doc, pin label}`: **27 the same, 0 gone,
0 new.** Keyed on `{doc, pin index}`: 26 the same, 1 "gone", 1 "new" — the same pin,
whose index moved because one sampled document grew:
`9f4cde3d-5046-4b8d-94f7-cb0dcbb8c9f8`, depth **829 → 833**, so its 50 % pin moved
from index 413 to 415. No pin changed *status*: nothing that disagreed now agrees,
and nothing that agreed now disagrees.

**Part 2 — no drift in the aggregate.** 80 disagreements over 2384 docs today,
versus 80 over 2,376 on 2026-08-05; 124 entries dropped (124 then), 2 replay-only
(2 then), class split c_legacy_empty 62 / e_snapshot_legacy 18 (62 / 18 then). The 8 additional
`dir_schema` docs created since the first snapshot all agree.

### Evidence limitation, disclosed

Set-vs-set drift for Part 2 could not be computed. The 2026-08-05 derived copies
(`.chit-sizing-backup-2026-08-06T04-13-15-349317Z`, `.chit-sizing-work`,
`.chit-sizing-tamper`, all untracked directories under `/home/jes/commonplace`) were
gone when this pass ran — the first two removed by something other than this
measurement, and re-opening the emptied one produced a fresh 1,038-byte store whose
reads all returned `:none`. That briefly produced a **false zero** ("last night
dir_schema=2376 disagreements=0"), which is what surfaced the loss; it was caught
because the number contradicted a recorded prior result rather than because anything
alarmed. Part 1's drift is exact, because last night's per-pin verdicts were held in
a result file rather than only in the copy. Part 2's drift is therefore reported at
aggregate level only, and every figure above for Part 2 is measured on the
2026-08-06 snapshot.

## Reproducing

The 2026-08-06 backup was deleted after this file was written, per the standing rule
that these copies are not left on a disk at 87 % use. To regenerate: take a fresh
`CubDB.back_up/2` of the live `CommitStore`'s CubDB handle
(`:sys.get_state(Commonplace.Store.CommitStore).db`) — checking `:code.is_loaded/1`
for `CommitStore` and `CubDB` first, and recording `:code.all_loaded` counts either
side — then run the two comparisons above against the copy in a fresh OS process
with `:reader_lazy_snapshot_enabled` set to `false`.

That last knob is not optional: `DocBuilder.reconstruct_doc/3` calls
`maybe_lazy_snapshot/3`, which fires `Commonplace.SnapshotWorker.request/2` once the
post-trim chain reaches `:reader_lazy_snapshot_threshold` (default 100, default-on
outside `:test`). **Reading a deep document through that function mints a snapshot
commit.** `reconstruct_doc_at/4` does not. Part 2 uses `reconstruct_doc/3` and would
write against a live store.

---

## Attribution addendum (coordinator, 2026-08-06 ~06:0xZ)

The harness's disclosure above reports the deletion of the 2026-08-05
derived store copies as unattributable from its own command history.
**Attribution — stated as the coordinator's attestation from their own
session transcript, not as harness-verified fact:** the coordinating
session removed `.chit-sizing-work` and `.chit-sizing-tamper` during
the evening's disk-pressure cleanup (derived, recreatable), and
removed the provenance backup immediately after commonplace-plan
accepted the sizing report with "release the backup." The harness
independently corroborated the deletion WINDOW (last successful read
of the work copy ~05:35Z, found empty 06:05Z — containing the
coordinator's claimed cleanup time) without identifying the actor;
the attestation and the corroboration are different grades of claim
and are labeled as such on purpose. Under this attestation, no
unknown process was involved; the live store was never touched
(harness-verified: 643 MB, serve writing normally throughout). The false zero the
re-opened empty path produced remains the load-bearing lesson
(measurement opens must assert non-emptiness; create-on-open turns an
absent data source into a silently minted empty one), recorded in the
project's verification-discipline notes.
