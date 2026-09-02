# Changelog

## Unreleased

### Performance
* Nested BSON read hashes and arrays set `initial_capacity` from document byte size (empty nested docs stay capacity 0). Create/update builders pre-size `IO::Memory` from Hash/Array size. `{_id: ObjectId}` filters on get/update/patch/remove are a 22-byte document (no 64-byte Builder IO). Nested Hash/Array writes use bson.cr `Builder#document` / `#array` (same parent IO, no child BSON.build per nested object). Query operator documents and id `$in`/`$nin` arrays write on the parent filter Builder. Patch `$set` is one parent Builder (pre-sized IO, no child BSON then assign).

### Changed
* `shard.yml` uses GitHub: **alumna ~> 0.5.10**, **cryomongo ~> 0.17.4** (bson.cr **0.9.2** via cryomongo). No path deps. No `shard.override.yml`. CI is the published repo root (sqlite-style checkout plus standalone `mongo:8.0`). AdapterSuite flags stay `expect_incremental_ids: false`, `mixed_sort: :bson`.

### Added
* GitHub Actions CI (format, single-thread spec, preview_mt spec, kcov, codecov placeholders). Standalone `mongo:8.0` service. Checkout layout so path deps `../backend` and `../cryomongo` resolve. README for install, quick start, types, query, indexes, `id` vs `_id`, AdapterSuite, and security.
* Shard skeleton: `Alumna::MongoAdapter` constructor, `Alumna.mongo` helpers.
* CRUD against MongoDB 8.0: create, get, update, patch, remove, and find with skip/limit/sort/select. AnyData ↔ BSON, ObjectId `id`, Mongo error mapping.
* Query operators (`$eq` `$ne` `$gt` `$gte` `$lt` `$lte` `$in` `$nin`), nested paths, array fields, `id` / `_id` filters. Unknown query fields return 400.
* `create_indexes!` writes MongoDB indexes from unique fields, indexed fields, and schema indexes (nested paths and compound unique included). Stable names so duplicate key 11000 maps to 422 with the field path when the server names the index.
* Specs for identity, BSON read/write, CRUD, query operators, indexes/uniqueness, error mapping, and `Alumna.mongo`. kcov on `src/` is 100%.
* AdapterSuite compliance specs (`expect_incremental_ids: false`, `mixed_sort: :bson`). The factory drops the collection every example. Unique indexes stay in extra specs, not in the suite factory.

### Fixed
* Duplicate key 11000 from cryomongo `Mongo::Error::CommandWrite` (insert/update writeErrors) maps to 422, same as `Mongo::Error::Command`.
