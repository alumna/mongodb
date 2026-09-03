# Alumna MongoDB Adapter

[![Crystal CI](https://github.com/alumna/mongodb/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/mongodb/actions/workflows/ci.yml) [![codecov](https://codecov.io/github/alumna/mongodb/graph/badge.svg?token=dFAHQ7KKzO)](https://codecov.io/github/alumna/mongodb) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fmongodb%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/mongodb)

MongoDB adapter for the [Alumna Backend Framework](https://github.com/alumna/backend). `Alumna::MongoAdapter` implements `Alumna::Service` against MongoDB 8.0.

See [ROADMAP.md](ROADMAP.md) for what each version shipped and what is still open.

---

## Table of Contents
1. [Installation](#1-installation)
2. [Quick Start](#2-quick-start)
3. [Type Mapping](#3-type-mapping)
4. [Querying and Filtering](#4-querying-and-filtering)
5. [Indexes and Uniqueness](#5-indexes-and-uniqueness)
6. [`id` vs `_id`](#6-id-vs-_id)
7. [Transactions](#7-transactions)
8. [GridFS](#8-gridfs)
9. [Change streams](#9-change-streams)
10. [Testing](#10-testing)
11. [Security](#11-security)
12. [License](#12-license)

---

## 1. Installation

Add it to your `shard.yml`:

```yaml
dependencies:
  alumna:
    github: alumna/backend
  alumna-mongodb:
    github: alumna/mongodb
```

Then run `shards install`.

Needs MongoDB **8.0**.

---

## 2. Quick Start

Define a schema, open one `Mongo::Client` for the process, then mount the adapter.

```crystal
require "alumna"
require "alumna-mongodb"

ProductSchema = Alumna::Schema.new
  .str("title", min_length: 2)
  .float("price")
  .bool("is_published", required: false)
  .array("tags", of: :str, required: false)
  .hash("user", required: false) do |u|
    u.str("name")
    u.int("age")
  end

client = Mongo::Client.new("mongodb://127.0.0.1:27017")

app = Alumna::App.new

products = Alumna.mongo(client, "shop", "products", ProductSchema)
products.create_indexes!

app.use("/products", products)
app.listen(3000)
```

`Alumna.mongo` is the same as `Alumna::MongoAdapter.new`. Arguments, in order:

- **`client`** (`Mongo::Client`) - one client for the process. Do not open a new client per request.
- **`database`** (`String`) - MongoDB database name. In the example, `"shop"`.
- **`collection`** (`String`) - collection name inside that database. In the example, `"products"`.
- **`schema`** (`Alumna::Schema`) - required. Field list, indexes, and typed filters. The adapter raises `ArgumentError` if this is missing.
- **`max_limit`** (`Int32?`, default `nil`) - optional. When set, a client `$limit` above this value is clamped. `nil` means no adapter clamp. App `max_query_limit` may also clamp. The effective limit is the tighter of the two.

The block form yields `with svc` so you can mount rules:

```crystal
products = Alumna.mongo(client, "shop", "products", ProductSchema) do
  before validate, on: :write
end
```

You can pass `max_limit` before the block:

```crystal
products = Alumna.mongo(client, "shop", "products", ProductSchema, max_limit: 100) do
  before validate, on: :write
end
```

Call `create_indexes!` at boot. That writes unique and indexed fields from the schema.

You now have REST `GET`, `POST`, `PUT`, `PATCH`, and `DELETE` on `/products`.

---

## 3. Type Mapping

Records are Alumna `AnyData` in the service, BSON in MongoDB. Conversion happens only in the adapter.

`AnyData` is `Nil | Bool | Int64 | Float64 | String | Time | Bytes | Array(AnyData) | Hash(String, AnyData)`. It has no `Int32` and no `BSON::ObjectId`.

| AnyData | BSON |
|---|---|
| Nil | null (only if the key is present) |
| Bool | boolean |
| Int64 | int64 |
| Float64 | double |
| String | string |
| Time | datetime (UTC milliseconds) |
| Bytes | binary |
| Array | array |
| Hash | document |

On read:

- `_id` ObjectId becomes `"id"` as a 24-character hex string. The hash does not also include `_id`.
- BSON Int32 becomes Int64.
- Other ObjectId values become hex strings.
- DateTime becomes `Time` (or `nil` if the value is outside Crystal's range).

Keys missing in `ctx.data` are not written. The adapter does not invent defaults.

---

## 4. Querying and Filtering

Alumna query operators map to native MongoDB filters. Nested fields use dot paths (`user.name`).

**Exact match:**
```http
GET /products?is_published=true
```

**Comparison (`$gt`, `$gte`, `$lt`, `$lte`, `$ne`):**
```http
GET /products?price[$gt]=50&price[$lte]=199.99
```

**Lists (`$in`, `$nin`):**
```http
GET /products?title[$in]=Laptop,Mouse,Keyboard
```

**Nested field:**
```http
GET /products?user.name=Ada
```

**Array field:** `{ tags: "tech" }` matches a document whose `tags` array contains `"tech"`. Native `$ne` / `$nin` mean no element equals / none in the list.

**Sort, skip, limit, select:**
```http
GET /products?$sort=price:-1&$limit=10&$skip=20&$select=id,title,price
```

- `$sort`: `id` maps to `_id`. Missing values sort like MongoDB (nulls first on ascending). Mixed types use BSON order. Arrays sort by min element, so `2`, `"10"`, `[1]` becomes `[[1], 2, "10"]`. That is not SQLite/MemoryAdapter order.
- No `$limit` means all matches. The adapter does not add a default limit.
- `$select` always includes `id`.

Unknown filter, sort, or select fields return **400**.

`id` / `_id` in a filter: if the string is valid ObjectId hex, the query uses `_id` as ObjectId. If not, the filter matches nothing (empty list), not a 500.

---

## 5. Indexes and Uniqueness

`create_indexes!` builds MongoDB indexes from:

- fields with `unique: true` or `indexed: true` (including nested paths like `profile.handle`)
- schema-level `.index(["a", "b"], unique: true)` (compound)

Index names are stable (`uniq_products_email`, `idx_products_role`). Dots in the name become `_`; the index key stays `"profile.handle"`. `id` / `_id` already has MongoDB's unique index; the adapter does not add a second one.

Duplicate key **11000** becomes **422** with `"already exists"` on the field path when the server error includes ` index: NAME`.

v1 indexes are not sparse. Two documents that omit the same unique field also conflict (**422**).

---

## 6. `id` vs `_id`

| Alumna | MongoDB |
|---|---|
| `id` - String, 24 hex characters | `_id` - `BSON::ObjectId` |

The adapter translates at the boundary. It does not store a field named `id` in the collection.

- **create:** ignores incoming `id` / `_id`, generates an ObjectId, returns hex `id`.
- **get:** missing, invalid hex, or unknown id → `nil` (HTTP 404 through `Service`).
- **update / patch / remove:** nil id → 400; invalid hex or missing document → 404.
- **update:** full replace. A remaining key that contains `.` returns **400**. Replace is a document, not a path update.
- **patch:** `$set` of provided keys. A dotted key that matches a schema nested path (`user.name`) updates that nested field. Unknown nested path (`nope.x`, `user.nope`) returns **400**. `id` / `_id` are ignored. The returned record is a nested hash, not a top-level key named `user.name`.
- **patch `$unset`:** reserved key.
  - Value is a path string or a list of path strings.
  - The adapter strips it and sends MongoDB `$unset` (same command as `$set` when both appear).
  - Unknown path returns **400**.
  - JSON null on a field is `$set` of null, not unset.
  - `id` / `_id` in the list are ignored.
  - HTTP `validate` with `strict: true` skips reserved key `$unset`. It is not a schema field. Unknown real fields still return **422**.

Path `ctx.id` is always the adapter. Bad hex is 404 / nil, not 422.

Apps may set `.str("id", format: :object_id)` (or another body field) so invalid ObjectId hex in **body** fields returns 422. That does not change path `ctx.id`.

---

## 7. Transactions

`MongoAdapter#transaction` runs the block in one MongoDB transaction.

You need a **clustered** topology (replica set, mongos, or load-balanced). A standalone server raises `Alumna::MongoAdapter::TransactionError`.

Connect with `replicaSet` in the URI, or use mongos / `loadBalanced=true`:

```crystal
client = Mongo::Client.new("mongodb://127.0.0.1:27017/?replicaSet=rs0")
products = Alumna.mongo(client, "shop", "products", ProductSchema)
```

CRUD (`find`, `get`, `create`, `update`, `patch`, `remove`) on that fiber uses the session, so you do not pass a session into Service methods. Other fibers and other clients do not see those writes until commit.

```crystal
products.transaction do
  created = products.create(create_ctx)
  if created.is_a?(Alumna::ServiceError)
    created
  else
    products.patch(patch_ctx)
  end
end
```

The last value of the block is what `#transaction` sees. A `ServiceError` aborts. Any other value commits.

- The adapter aborts if the block raises, and the exception continues.
- Nested `#transaction` on the same fiber raises `TransactionError`.
- `create_indexes!` does not join the transaction.
- Do not use `return` inside the block. That leaves the enclosing method, so the adapter never sees the result.

---

## 8. GridFS

`MongoAdapter#grid_fs` configures an opt-in GridFS bucket.

The helper exposes upload/download/delete/rename by file `id` (ObjectId hex `String`) or by filename where the driver supports it.

File document fields returned from download and upload:

`id`, `filename`, `length`, `chunkSize`, `uploadDate`, and optional `metadata` (`Hash(String, AnyData)`).

Errors:

* Invalid file id hex and missing files raise `Alumna::MongoAdapter::GridFSError` with `status 404`.
* Other Mongo errors raise `Alumna::MongoAdapter::GridFSError` with `status 500`.

Example:

```crystal
gridfs = products.grid_fs(bucket_name: "fs", chunk_size_bytes: 8_i32)

upload = gridfs.open_upload_stream("file.txt", metadata: Alumna.hash(author: "Ada"))
upload.io << "some bytes"
upload.close

dest = IO::Memory.new
file = gridfs.download_to_stream(upload.id, dest)
dest.rewind
puts dest.gets_to_end

gridfs.delete(upload.id)
```

---
## 9. Change streams

`MongoAdapter#watch` listens for inserts, updates, replaces, and deletes on this adapter’s collection.

You need a **clustered** topology (replica set, mongos, or load-balanced). A standalone server raises `Alumna::MongoAdapter::WatchError`.

Connect with `replicaSet` in the URI, or use mongos / `loadBalanced=true` (same as transactions).

Events are `Hash(String, AnyData)` with snake_case keys:

| Key | Meaning |
|---|---|
| `operation_type` | `"insert"`, `"update"`, `"replace"`, `"delete"`, … |
| `resume_token` | Cloned BSON bytes. Pass them as `resume_after:` to continue. |
| `document_id` | Alumna `id` hex from `documentKey._id` |
| `document_key` | Document key with `_id` mapped to `id` |
| `full_document` | Stored document when MongoDB sends it (`to_record`) |
| `ns` | `{ "db" => …, "coll" => … }` when present |

The resume token is **Bytes**, not a String. It is a clone of the event `_id` BSON. `BSON.new(bytes)` is how the adapter sends `resume_after` to the driver.

Prefer the block form. It closes the cursor in `ensure`:

```crystal
products.watch(max_await_time_ms: 1000_i64) do |event|
  puts event["operation_type"]
  puts event["document_id"]
end
```

If you keep the wrapper, you must call `#close`. `#next` waits. `#try_next` polls (returns `nil` when idle):

```crystal
stream = products.watch(max_await_time_ms: 1000_i64)
begin
  products.create(create_ctx)
  if event = stream.try_next
    token = event["resume_token"] # Bytes
    later = products.watch(resume_after: token.as(Bytes))
    later.close
  end
ensure
  stream.close
end
```

Optional arguments: `resume_after` (Bytes), `max_await_time_ms`, `full_document` (`"updateLookup"` so an update event includes `full_document`).

The collection should exist before `#watch`. Create one document first if you just dropped it.

---

## 10. Testing

Use Alumna `AdapterSuite`. MongoDB ids are ObjectId hex, not `"1"`, `"2"`. Mixed `$sort` follows BSON, not SQLite.

```crystal
require "alumna/testing"
require "alumna-mongodb"

MONGODB_URI   = ENV["MONGODB_URI"]? || "mongodb://127.0.0.1:27017"
SHARED_CLIENT = Mongo::Client.new(MONGODB_URI)
TEST_DB       = "alumna_test"

Alumna::Testing::AdapterSuite.run(
  "Alumna::MongoAdapter",
  expect_incremental_ids: false,
  mixed_sort: :bson,
) do
  SHARED_CLIENT[TEST_DB]["adapter_test"].drop

  schema = Alumna::Schema.new(strict: false)
    .str("title")
    .float("price")

  Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "adapter_test", schema)
end
```

Drop the collection in the factory. It runs inside every example.

Pass `expect_incremental_ids: false` and `mixed_sort: :bson`. Do not use the sqlite/memory defaults.

Specs use `ENV["MONGODB_URI"]? || "mongodb://127.0.0.1:27017"`. Set `MONGODB_URI` and `TOPOLOGY` **before** the process (`SHARED_CLIENT` is created at spec load). No auth required for local tests.

`TOPOLOGY` is `standalone`, `replicaset`, `sharded`, or `load-balanced`. GitHub CI is the source of truth for that env. Local runs may omit it; then the suite looks at the URI (`replicaSet=` / `loadBalanced=true`) and hello.

GitHub CI runs four topologies in parallel (`fail-fast: false`). Each cell starts MongoDB with cryomongo’s `docker-topology.sh` after `shards install` (`lib/cryomongo/scripts/docker-topology.sh`). Load-balanced also starts HAProxy. Coverage (kcov) stays one standalone job.

- CRUD, indexes, AdapterSuite, and GridFS run on all four.
- Live `#transaction` / `#watch` run when `clustered?` (replica set, sharded, or load-balanced). They skip on standalone.
- Standalone-only “raises on standalone” examples run only when `standalone?`.
- Do not skip CRUD or GridFS by topology.

Example replica set run:

```bash
TOPOLOGY=replicaset MONGODB_URI='mongodb://127.0.0.1:27017/?replicaSet=rs0' crystal spec
```

Standalone `#transaction` raises `TransactionError`. Standalone `#watch` raises `WatchError`.

---

## 11. Security

There is no SQL. The adapter talks BSON to MongoDB.

Every filter, `$sort`, and `$select` field must exist on the schema (or be `id` / `_id`). Unknown fields return **400**. That is stricter than MemoryAdapter, which treats unknown filters as strings.

A patch key that contains `.` must match a schema nested path. Unknown nested paths return **400**. Update still rejects dotted keys.

A patch `"$unset"` path must exist on the schema. Unknown `$unset` paths return **400**. JSON null is not unset.

Do not send passwords in error messages. Network and other Mongo errors become **500** with a short message.

---

## 12. License

MIT
