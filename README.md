# Alumna MongoDB Adapter

[![Crystal CI](https://github.com/alumna/mongodb/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/mongodb/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

MongoDB adapter for the [Alumna Backend Framework](https://github.com/alumna/backend). `Alumna::MongoAdapter` implements `Alumna::Service` against MongoDB 8.0.

---

## Table of Contents
1. [Installation](#1-installation)
2. [Quick Start](#2-quick-start)
3. [Type Mapping](#3-type-mapping)
4. [Querying and Filtering](#4-querying-and-filtering)
5. [Indexes and Uniqueness](#5-indexes-and-uniqueness)
6. [`id` vs `_id`](#6-id-vs-_id)
7. [Testing](#7-testing)
8. [Security](#8-security)
9. [License](#9-license)

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

`Alumna.mongo` is the same as `Alumna::MongoAdapter.new`. The block form yields `with svc` so you can mount rules:

```crystal
products = Alumna.mongo(client, "shop", "products", ProductSchema) do
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
| `id` — String, 24 hex characters | `_id` — `BSON::ObjectId` |

The adapter translates at the boundary. It does not store a field named `id` in the collection.

- **create:** ignores incoming `id` / `_id`, generates an ObjectId, returns hex `id`.
- **get:** missing, invalid hex, or unknown id → `nil` (HTTP 404 through `Service`).
- **update / patch / remove:** nil id → 400; invalid hex or missing document → 404.

---

## 7. Testing

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

Specs use `ENV["MONGODB_URI"]? || "mongodb://127.0.0.1:27017"`. No replica set. No auth required for local tests.

---

## 8. Security

There is no SQL. The adapter talks BSON to MongoDB.

Every filter, `$sort`, and `$select` field must exist on the schema (or be `id` / `_id`). Unknown fields return **400**. That is stricter than MemoryAdapter, which treats unknown filters as strings.

Do not send passwords in error messages. Network and other Mongo errors become **500** with a short message.

---

## 9. License

MIT
