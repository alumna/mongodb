# Alumna MongoDB Adapter — roadmap

What this adapter shipped, and what is still open. GitHub CI stays standalone `mongo:8.0`.

## Delivered

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
* Change streams (opt-in, replica set).
* GridFS.
* Client-side encryption.
