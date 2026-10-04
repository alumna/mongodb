# Alumna MongoDB Adapter — roadmap

What this adapter shipped, and what is still open. GitHub CI runs four MongoDB 8.0 topologies (standalone, replica set, sharded, load-balanced). Coverage (kcov) stays one standalone job.

## Delivered

### 1.0.0-beta (2026-10-04)

* Opt-in client-side encryption (FLE1, local KMS).
* `encryption:` on `MongoAdapter.new` / `Alumna.mongo`.
* Marked fields are plaintext AnyData after auto-decrypt. Storage is BSON binary `0x06`.
* Requires cryomongo **>= 1.0.0-beta**. Live encryption runs when libmongocrypt and crypt_shared are present. GitHub CI vendors libmongocrypt, downloads `mongo_crypt_v1.so`, and runs those examples.

### 0.10.0 (2026-09-03)
* GridFS helpers (`#grid_fs`).
* Four-topology GitHub CI (standalone, replica set, sharded, load-balanced).
* Alumna backend **~> 0.6.1**.

### 0.9.0 (2026-09-03)
* Added `MongoAdapter#watch` (replica set or mongos).
* Standalone `#watch` raises `WatchError`.
* Resume token is cloned BSON **Bytes**. Pass it as `resume_after:`.

### 0.8.2 (2026-09-03)
* Added `MongoAdapter#transaction` (replica set or mongos).
* Standalone `#transaction` raises `TransactionError`.
* CRUD in the block uses the fiber session. Nested `#transaction` raises.

### 0.8.1 (2026-09-03)
* Alumna backend **~> 0.6.0**.

### 0.8.0 (2026-09-03)
* CRUD, query operators, nested `$set` / `$unset`, indexes, uniqueness **422**.
* AdapterSuite (`expect_incremental_ids: false`, `mixed_sort: :bson`).
* GitHub CI and kcov 100% on `src/`.

## Next
* Adapter notes for `MONGODB-AWS` / `MONGODB-OIDC` when cryomongo implements those mechanisms (the URI may be enough).
