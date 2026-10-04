# Alumna MongoDB Adapter

[![Crystal CI](https://github.com/alumna/mongodb/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/mongodb/actions/workflows/ci.yml) [![codecov](https://codecov.io/github/alumna/mongodb/graph/badge.svg?token=dFAHQ7KKzO)](https://codecov.io/github/alumna/mongodb) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fmongodb%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/mongodb)

MongoDB adapter for the [Alumna Backend](https://github.com/alumna/backend). `Alumna::MongoAdapter` implements `Alumna::Service` against MongoDB 8.0, through [cryomongo](https://github.com/alumna/cryomongo) 1.0.0-beta.

Records are Alumna `AnyData` in the service and BSON in MongoDB. The adapter is the only place that converts between them.

See [ROADMAP.md](ROADMAP.md) for what each version shipped and what is still open.

---

## Table of Contents

1. [Installation](#1-installation)
2. [Quick start](#2-quick-start)
3. [Records](#3-records)
4. [Service methods](#4-service-methods)
5. [Queries](#5-queries)
6. [Indexes](#6-indexes)
7. [Transactions](#7-transactions)
8. [GridFS](#8-gridfs)
9. [Change streams](#9-change-streams)
10. [Client-side encryption](#10-client-side-encryption)
11. [Errors](#11-errors)
12. [Testing](#12-testing)
13. [Security](#13-security)
14. [License](#14-license)

---

## 1. Installation

### Shard

```yaml
dependencies:
  alumna:
    github: alumna/backend
    version: ">= 0.6.1"
  alumna-mongodb:
    github: alumna/mongodb
    version: ">= 1.0.0-beta"
```

Then `shards install`. Crystal >= 1.20.2. zstd needs `libzstd-dev` (cryomongo links it). snappy is pure Crystal.

The adapter depends on cryomongo `>= 1.0.0-beta`. You do not add cryomongo yourself unless the app also calls the driver. If you do, use that same requirement. bson.cr 0.9.3 comes with the driver. A BSON document is a class: assignment shares the document.

### Server

MongoDB 8.0. One `Mongo::Client` for the process. Do not open a client per request.

cryomongo 1.0.0-beta is Linux only. A Darwin compile of that driver raises.

### libmongocrypt

The driver links libmongocrypt 1.20.4 by default and stops compiling if that library is missing. Ubuntu 24.04 `libmongocrypt-dev` is too old to use as the system package.

After `shards install`:

```bash
lib/cryomongo/scripts/vendor-libmongocrypt.sh
```

The script writes gitignored `lib/cryomongo/vendor/libmongocrypt/`. `shards update` can delete that directory. Run the script again.

An app that never encrypts can skip the script and compile with `-Dwithout_libmongocrypt`. Constructing an encryption client then raises.

Automatic encryption also needs `mongo_crypt_v1.so`. That download is in [Libraries](#libraries).

---

## 2. Quick start

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

`Alumna.mongo` is `Alumna::MongoAdapter.new`. Arguments:

| Argument | Type | Role |
|---|---|---|
| `client` | `Mongo::Client` | The process client. |
| `database` | `String` | Database name. `"shop"` above. |
| `collection` | `String` | Collection inside that database. `"products"` above. |
| `schema` | `Alumna::Schema` | Required. Fields, indexes, and typed filters. Missing schema raises `ArgumentError`. |
| `max_limit` | `Int32?` | Default `nil`. When set, a client `$limit` above this value is clamped. `nil` means the adapter does not clamp. The app's `max_query_limit` may also clamp. The effective limit is the tighter of the two. |
| `encryption` | `MongoAdapter::Encryption?` | Default `nil`. See [Client-side encryption](#10-client-side-encryption). |

The block form yields the adapter so you can mount rules. `max_limit` and `encryption` are named arguments before the block:

```crystal
products = Alumna.mongo(client, "shop", "products", ProductSchema, max_limit: 100) do
  before validate, on: :write
end
```

Call `create_indexes!` at boot. It writes the indexes declared on the schema. It does not join a transaction.

`app.use` exposes REST `GET`, `POST`, `PUT`, `PATCH`, and `DELETE` on `/products`. Those routes call `find`, `create`, `update`, `patch`, `remove`, and `get`.

---

## 3. Records

### AnyData and BSON

`AnyData` is `Nil | Bool | Int64 | Float64 | String | Time | Bytes | Array(AnyData) | Hash(String, AnyData)`. It has no `Int32` and no `BSON::ObjectId`. Schema integers arrive as Int64. `Alumna.hash` builds a `Hash(String, AnyData)` and casts `Int32` / `Float32` for you. An `Array(String)` is not `AnyData` until you call `.to_any` (`tags: ["tech"].to_any`). A nested document is another `Alumna.hash`. A key such as `"user.name"` or `"$unset"` is not a Crystal named argument. Assign it on the hash after `Alumna.hash` returns.

| AnyData written | BSON stored |
|---|---|
| Nil, and the key is present | null |
| Bool | boolean |
| Int64 | int64 |
| Float64 | double |
| String | string |
| Time | datetime (UTC milliseconds) |
| Bytes | binary |
| Array | array |
| Hash | document |

A key that is absent from `ctx.data` is not written. The adapter does not invent defaults. `id` and `_id` in the body are ignored on write. The adapter sets `_id`.

### What a read returns

| BSON in the collection | AnyData the service sees |
|---|---|
| `_id` ObjectId | `"id"` as 24 hex characters. The hash does not also contain `_id`. |
| Int32 | Int64 |
| DateTime | `Time`, or `nil` when the instant is outside Crystal's range |
| Binary | `Bytes`, copied out of the document |
| ObjectId (any field other than the record `_id`) | hex string |
| UUID, Decimal128 | string |
| Regex | the pattern. Options are not returned. |
| MinKey, MaxKey, Undefined | `"$minKey"`, `"$maxKey"`, `"$undefined"` |
| Timestamp | `"<time>:<increment>"` |
| Code, Symbol | string |
| DBPointer | `"<name>:<oid>"` |

The adapter writes only the AnyData types in the first table. The extra rows are how it reads a document that something else stored.

---

## 4. Service methods

| Method | Success | Missing or bad id |
|---|---|---|
| `find` | `Array(Hash(String, AnyData))` | — |
| `get` | the record, or `nil` when the id is missing, not 24 hex, or unknown | `nil` (HTTP 404 through `Service`) |
| `create` | the record, with a new hex `id` | incoming `id` / `_id` are ignored |
| `update` | the replaced record | nil id → 400. Invalid hex or no document → 404. |
| `patch` | the patched record | nil id → 400. Invalid hex or no document → 404. |
| `remove` | `nil` | nil id → 400. Invalid hex or no document → 404. |

Mongo command failures on these methods return `Alumna::ServiceError`. They do not raise. See [Errors](#11-errors).

`update` replaces the document. A body key that contains `.` returns **400**. Replace is a document, not a path update.

`patch` sends `$set` of the body. `id` / `_id` are ignored.

### Calling a method from Crystal

HTTP builds the `RuleContext`. A script, a transaction block, or a spec builds one with `Alumna::Testing.build_ctx` (`require "alumna/testing"`):

```crystal
created = products.create(Alumna::Testing.build_ctx(
  service: products,
  method: Alumna::ServiceMethod::Create,
  data: Alumna.hash(title: "Laptop", price: 999.0),
))
raise created.message if created.is_a?(Alumna::ServiceError)
id = created["id"].as(String)
```

`create` returns the record or a `ServiceError`. After the `is_a?` check, `created` is the record and `id` is the 24-character hex string.

`get`, `update`, `patch`, and `remove` take that string as `id:`.

```crystal
products.get(Alumna::Testing.build_ctx(
  service: products,
  method: Alumna::ServiceMethod::Get,
  id: id,
))

products.patch(Alumna::Testing.build_ctx(
  service: products,
  method: Alumna::ServiceMethod::Patch,
  id: id,
  data: Alumna.hash(price: 899.0),
))

products.remove(Alumna::Testing.build_ctx(
  service: products,
  method: Alumna::ServiceMethod::Remove,
  id: id,
))
```

### `id` and `_id`

| Alumna | MongoDB |
|---|---|
| `id`, a 24-character hex string | `_id`, a `BSON::ObjectId` |

The collection does not store a field named `id`.

Path `ctx.id` is the adapter's id. Bad hex on `get` is `nil`. Bad hex on `update`, `patch`, and `remove` is 404. It is not 422.

A body field can still use the schema format. `.str("id", format: :object_id)` (or any other body field) makes invalid ObjectId hex in **that body field** return 422. It does not change path `ctx.id`.

In a filter, `id` and `_id` both query `_id`. Valid hex becomes an ObjectId. Anything else matches nothing (an empty list), not a 500. `$in` / `$nin` do that per element.

### Patch paths and `$unset`

A patch key that contains `.` is a MongoDB dotted `$set` when the schema has that nested path (`user.name`). The record you get back is a nested hash. It does not contain a top-level key `"user.name"`. An unknown nested path (`nope.x`, `user.nope`) returns **400**.

`"$unset"` is reserved:

- The value is one path string, or an array of path strings.
- The adapter removes the key from the body and sends MongoDB `$unset` in the same command as `$set` when both are present.
- `$unset` values on the wire are empty strings. MongoDB ignores the value.
- An unknown path returns **400**.
- JSON `null` on a field is `$set` of null, not unset.
- `id` / `_id` in the list are ignored.
- The returned record drops the nested field. An empty parent hash stays.
- HTTP `validate` with `strict: true` skips `"$unset"`. It is not a schema field. Unknown real fields still return **422**.

```crystal
patch = Alumna.hash(price: 10.0)
# "$unset" is not a Crystal named argument. Assign the key on the hash.
patch["$unset"] = ["user.age"] of Alumna::AnyData

products.patch(Alumna::Testing.build_ctx(
  service: products,
  method: Alumna::ServiceMethod::Patch,
  id: id,
  data: patch,
))
```

---

## 5. Queries

`find` reads `ctx.query`. Over HTTP that is the query string. From Crystal, pass the same keys in `params:`.

Operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`, `$in`, `$nin`. A bare `field=value` is `$eq`.

```http
GET /products?is_published=true
GET /products?price[$gt]=50&price[$lte]=199.99
GET /products?title[$in]=Laptop,Mouse,Keyboard
GET /products?user.name=Ada
GET /products?$sort=price:-1,title&$limit=10&$skip=20&$select=id,title,price
```

`$in` and `$nin` split the value on commas.

`$sort` is a comma-separated list of `field` or `field:direction`. Missing direction and any non-negative number sort ascending. A negative number sorts descending. `id` sorts `_id`.

The adapter does not invent a page size. With no `$limit`, and with the app's `default_query_limit` left at `nil`, `find` returns every match. A `$limit` the client sends is clamped by the app's `max_query_limit`, then by the adapter's `max_limit`. The smaller cap wins. `default_query_limit`, when set, is what a request uses when it sends no `$limit`, and that value is clamped the same way.

`$select` is a comma-separated field list. `id` is always included.

Unknown filter, sort, or select fields return **400**. A field must exist on the schema, or be `id` / `_id`. Nested fields use the schema path (`user.name`).

An array field matches by element. `{ tags: "tech" }` matches a document whose `tags` array contains `"tech"`. `$ne` and `$nin` on an array use MongoDB's meaning: no element equals the value, or no element is in the list.

Sort order is MongoDB's. Missing values sort as nulls (first when ascending). Mixed types use BSON type order. Arrays sort by their minimum element, so `2`, `"10"`, `[1]` becomes `[[1], 2, "10"]`. That is not SQLite or MemoryAdapter order.

---

## 6. Indexes

`create_indexes!` builds indexes from:

- a field with `unique: true` or `indexed: true`, including a nested path such as `profile.handle`
- `schema.index(["a", "b"], unique: true)` and `schema.index("role")` (one field or a compound list)

```crystal
UserSchema = Alumna::Schema.new
  .str("email", unique: true)
  .str("role", indexed: true)
  .index(["email", "role"])
```

Names are stable: `uniq_<collection>_<fields>` or `idx_<collection>_<fields>`. A dot in the name becomes `_`. The index key stays `"profile.handle"`. `id` / `_id` already has MongoDB's unique index. The adapter does not add a second one.

Duplicate key **11000** becomes **422**. The details hash is `{ "<field path>" => "already exists" }` when the server error contains ` index: NAME` and that name is one this adapter created. Otherwise the key is `"error"`.

These indexes are not sparse. Two documents that both omit the same unique field also conflict (**422**).

---

## 7. Transactions

`#transaction` runs the block in one MongoDB transaction on the current fiber.

The topology must be clustered: replica set, mongos, or load-balanced. Standalone raises `Alumna::MongoAdapter::TransactionError` with "MongoDB transactions need a replica set. Standalone servers cannot run them."

```crystal
client = Mongo::Client.new("mongodb://127.0.0.1:27017/?replicaSet=rs0")
products = Alumna.mongo(client, "shop", "products", ProductSchema)
```

`find`, `get`, `create`, `update`, `patch`, and `remove` on that fiber use the session. You do not pass a session into them. Other fibers do not see the writes until commit. The session map is per fiber, so two fibers on one adapter do not share a transaction.

```crystal
products.transaction do
  created = products.create(Alumna::Testing.build_ctx(
    service: products,
    method: Alumna::ServiceMethod::Create,
    data: Alumna.hash(title: "Laptop", price: 10.0),
  ))
  if created.is_a?(Alumna::ServiceError)
    created # returning ServiceError aborts
  else
    products.patch(Alumna::Testing.build_ctx(
      service: products,
      method: Alumna::ServiceMethod::Patch,
      id: created["id"].as(String),
      data: Alumna.hash(price: 12.0),
    ))
  end
end
```

The block's last value is what `#transaction` returns. A `ServiceError` aborts and is returned to the caller. Any other value commits. A raised exception aborts, and the exception continues. Nested `#transaction` on the same fiber raises `TransactionError` ("A transaction is already running on this fiber").

`create_indexes!` does not join the transaction. Do not `return` from inside the block. `return` leaves the method, and the adapter never sees the result.

---

## 8. GridFS

`#grid_fs` opens a bucket on this adapter's database. GridFS works on a standalone server.

```crystal
gridfs = products.grid_fs(bucket_name: "fs", chunk_size_bytes: 255 * 1024)
```

`bucket_name` defaults to `"fs"` (collections `fs.files` and `fs.chunks`). `chunk_size_bytes` defaults to 255 KiB, which is the driver's default.

File ids are ObjectId hex strings, the same shape as record `id`. Methods that take an id and receive hex that is not an ObjectId raise `GridFSError` with status **404**.

Each call accepts `timeout_ms : Int64?`.

### Upload

`open_upload_stream` returns a stream. Write to `io`, then `close`. The driver uploads on a background fiber. `close` waits and re-raises an upload error. `id` is the hex id. Pass `id:` to choose it. Omit `id:` and the adapter generates one.

```crystal
upload = gridfs.open_upload_stream(
  "file.txt",
  metadata: Alumna.hash(author: "Ada"),
  chunk_size_bytes: 255 * 1024,
)
upload.io << "some bytes"
upload.close
upload.id # 24 hex characters
```

`upload_from_stream` reads an `IO` to the end and returns the file document:

```crystal
file = gridfs.upload_from_stream("notes.txt", IO::Memory.new("hello"))
file["id"]
file["filename"] # "notes.txt"
```

Optional on both: `metadata` (`Hash(String, AnyData)`), `chunk_size_bytes`, `timeout_ms`, `id`.

### Download

Both download methods write the bytes into the `IO` you pass and return the file document.

```crystal
dest = IO::Memory.new
file = gridfs.download_to_stream(upload.id, dest)
dest.rewind
dest.gets_to_end

by_name = IO::Memory.new
gridfs.download_to_stream_by_name("file.txt", by_name, -1)
```

`download_to_stream_by_name` takes a revision. `-1` (the default) is the newest upload of that filename. `0` is the oldest. `1` is the next, and so on. A missing revision raises **404**.

The file document is `Hash(String, AnyData)`:

| Key | Meaning |
|---|---|
| `id` | ObjectId hex |
| `filename` | `String` |
| `length` | file size, Int64 |
| `chunkSize` | Int64 |
| `uploadDate` | `Time` |
| `metadata` | `Hash(String, AnyData)`, only when the upload set it |

### Delete and rename

| Method | Effect |
|---|---|
| `delete(id)` | Deletes that file. |
| `delete_by_name(filename)` | Deletes every file with that filename. |
| `rename(id, new_filename)` | Renames that file. |
| `rename_by_name(filename, new_filename)` | Renames every file with that filename. |

A missing id or filename raises `GridFSError` **404**. Other Mongo failures raise `GridFSError` **500**. The message does not include a password from the URI.

---

## 9. Change streams

`#watch` listens for inserts, updates, replaces, and deletes on this adapter's collection.

The topology must be clustered, same as transactions. Standalone raises `Alumna::MongoAdapter::WatchError` ("MongoDB change streams need a replica set. Standalone servers cannot run them.").

The collection should exist before `#watch`. If you just dropped it, insert one document first.

```crystal
products.watch(max_await_time_ms: 1000_i64) do |event|
  puts event["operation_type"]
  puts event["document_id"]
end
```

The block calls `#next` until the cursor is exhausted, then closes the stream. A live stream does not end after one event. For a single poll, keep the wrapper. `#next` waits. `#try_next` returns `nil` when this batch is empty and the stream is still open. You must `#close`.

```crystal
stream = products.watch(max_await_time_ms: 1000_i64, full_document: "updateLookup")
begin
  products.create(Alumna::Testing.build_ctx(
    service: products,
    method: Alumna::ServiceMethod::Create,
    data: Alumna.hash(title: "Laptop", price: 10.0),
  ))
  if event = stream.try_next
    token = event["resume_token"].as(Bytes)
    later = products.watch(resume_after: token)
    later.close
  end
ensure
  stream.close
end
```

Arguments, on both forms:

| Argument | Meaning |
|---|---|
| `resume_after` | `Bytes` from a previous event's `resume_token`, or from `ChangeStream#resume_token`. The adapter sends `BSON.new(bytes)`. A token that is not BSON raises `WatchError`. |
| `max_await_time_ms` | How long each `getMore` waits. |
| `full_document` | Driver option. `"updateLookup"` makes an update event include `full_document`. |

Events are `Hash(String, AnyData)`:

| Key | Meaning |
|---|---|
| `operation_type` | `"insert"`, `"update"`, `"replace"`, `"delete"`, and any other type the server sends |
| `resume_token` | Cloned BSON bytes of the event `_id`. Not a string. |
| `document_id` | Hex `id` from `documentKey._id` |
| `document_key` | Document key with `_id` mapped to `id` |
| `full_document` | The stored document, when the server sends it |
| `ns` | `{ "db" => …, "coll" => … }` when present |

`ChangeStream#resume_token` is the cursor's token. It is `nil` until the driver has one. `#close` is safe to call twice.

A driver error while opening or reading the stream raises `WatchError`. The message does not include a password from the URI.

---

## 10. Client-side encryption

Opt-in FLE1, local KMS only. Pass `encryption:` and the service methods stay `find`, `get`, `create`, `update`, `patch`, and `remove`.

Marked fields are stored as BSON binary subtype `0x06`. Auto-decrypt returns them as plaintext `AnyData` (a string, when you used the `fields` shorthand below). Do not encrypt `id` or `_id`. The schema is still required.

### Marking fields

`fields` maps a schema field name to an algorithm. The shorthand is for **string** fields. The adapter reuses the first data key in the vault, or creates one with the local master key.

```crystal
require "random/secure"

PeopleSchema = Alumna::Schema.new
  .str("name")
  .str("ssn", required: false)
  .str("note", required: false)

key = Random::Secure.random_bytes(96) # 96 bytes. Keep it. Without it the ciphertext cannot be read.

people = Alumna.mongo(
  client, "shop", "people", PeopleSchema,
  encryption: Alumna::MongoAdapter::Encryption.new(
    key_vault_namespace: "encryption.__keyVault",
    local_master_key: key,
    fields: {"ssn" => "deterministic", "note" => "random"},
  ),
)

created = people.create(Alumna::Testing.build_ctx(
  service: people,
  method: Alumna::ServiceMethod::Create,
  data: Alumna.hash(name: "Ada", ssn: "123-45-6789", note: "hello"),
))
raise created.message if created.is_a?(Alumna::ServiceError)
created["ssn"] # => "123-45-6789"

people.close
```

`"deterministic"` stores the same ciphertext for the same plaintext, so an equality filter on that field matches. `"random"` stores a different ciphertext each time, so an equality filter does not match. You can pass those words or the full algorithm name (`Alumna::MongoAdapter::Encryption::ALGORITHM_DETERMINISTIC` and `ALGORITHM_RANDOM`). Any other string raises `ArgumentError`.

`key_vault_namespace` is `database.collection`. A missing dot, or a dot at either end, raises `ArgumentError`. `local_master_key` must be 96 bytes. You need `fields` or `schema_map`. Passing neither raises `ArgumentError`.

`schema_map:` is a driver FLE1 BSON map. When it is set, it wins, and the adapter does not create a data key. Use it when a field is not a string, or when the key id is already chosen. `Encryption.schema_map(namespace, fields, key_id)` builds the string-field map. `key_id` is a UUID, BSON binary subtype `0x04`.

`Encryption.algorithm` normalizes `"deterministic"` / `"random"`. `Encryption.local_kms` builds the local KMS document the driver expects. `Encryption.new` calls both for you.

### The client the adapter opens

`encryption:` makes the adapter open a new `Mongo::Client` with `Mongo::AutoEncryption` for that collection. `#close` closes it. Call `#close` from the fiber that owns the adapter. Do not leave this client to the garbage collector. A finalizer runs on the GC thread, and destroying the mongocrypt handle there crashes the process.

`#close` does nothing when you did not pass `encryption:`. The process client stays open.

The new client needs a URI. Pass `uri:` when the real URI has credentials. If you omit it, the adapter rebuilds a URI from the topology seeds, and that URI has no user or password.

If the `Mongo::Client` you already hold is an auto-encryption client, omit `encryption:` and pass that client. The adapter then does not open a second one and does not own it.

### Libraries

cryomongo `>= 1.0.0-beta` defines `Mongo::AutoEncryption`. Install libmongocrypt as in [Installation](#libmongocrypt).

Automatic encryption also needs MongoDB's `crypt_shared` (`mongo_crypt_v1.so`). After `shards install`:

```bash
lib/cryomongo/scripts/download-crypt-shared.sh
```

The script prints `CRYPT_SHARED_LIB_PATH=...`. Point that variable, or `crypt_shared_lib_path:`, at the **file**, not at the directory. One process can load only one crypt_shared path. Give every encryption client in the process that same path.

On Ubuntu 22.04 the package distro is `ubuntu2204`. On 24.04 and 26.04 it is `ubuntu2404`. There is no `ubuntu2604` package. The `ubuntu2404` build needs glibc 2.38. It does not load on Ubuntu 22.04.

A missing library, or a path that is not a file, raises `Alumna::MongoAdapter::EncryptionError` when the adapter is constructed. Setup failures from the driver are the same exception.

### What this adapter does not encrypt

Cloud KMS (AWS, Azure, GCP, KMIP) is not in this adapter. Queryable Encryption is not in this adapter. Explicit `Mongo::ClientEncryption#encrypt` calls are a driver API. This adapter's path is automatic encryption of the fields you marked, on the service methods above.

---

## 11. Errors

`find`, `get`, `create`, `update`, `patch`, and `remove` return `Alumna::ServiceError` for a Mongo command failure. Callers branch on the type. These methods do not raise `Mongo::Error`.

| Situation | Result |
|---|---|
| Unknown query, sort, select, patch path, or `$unset` path | 400 |
| Nil id on update, patch, or remove | 400 |
| Unknown id, or id that is not 24 hex, on update, patch, or remove | 404 |
| Unknown id, or id that is not 24 hex, on get | `nil` |
| Duplicate key 11000 | 422, details `"already exists"` on the field path |
| Other `Mongo::Error` | 500. A `//user:password@` in the message is stripped to `//`. |
| Any other exception from the driver call | 500, message "Internal server error" |

`#transaction` returns a `ServiceError` when the block returns one. It raises `TransactionError` when the topology cannot run a transaction, when the block is nested, or when the driver fails the commit. Transient transaction errors are retried by the driver while the block is running.

`#watch` raises `WatchError`. GridFS raises `GridFSError` (404 or 500). Encryption raises `ArgumentError` for a bad key, namespace, algorithm, or empty field list, and `EncryptionError` when the library or the driver setup fails.

---

## 12. Testing

Use Alumna `AdapterSuite`. MongoDB ids are ObjectId hex, not `"1"`, `"2"`. Mixed `$sort` follows BSON, not SQLite.

Runnable programs live in [`examples/`](examples/README.md). `crystal spec` does not pick that folder up. A script is `crystal examples/quick_start.cr`. The compliance suite is:

```bash
crystal spec examples/adapter_suite.cr
```

The factory schema has to include every field the suite writes. `examples/adapter_suite.cr` is that schema. Pass `expect_incremental_ids: false` and `mixed_sort: :bson`. The sqlite and memory defaults do not match this adapter. Drop the collection inside the factory. The factory runs on every example.

Set `MONGODB_URI` and `TOPOLOGY` before the process starts. `SHARED_CLIENT` is created at spec load. Local specs need no auth.

`TOPOLOGY` is `standalone`, `replicaset`, `sharded`, or `load-balanced`. If it is unset, the suite reads the URI (`replicaSet=` / `loadBalanced=true`) and then `hello`.

GitHub CI runs those four topologies in parallel (`fail-fast: false`). Each cell starts MongoDB with `lib/cryomongo/scripts/docker-topology.sh` after `shards install`. Load-balanced also starts HAProxy. Coverage (kcov) is one standalone job, and it covers `src/` at 100%. The workflow vendors libmongocrypt, downloads `mongo_crypt_v1.so`, and runs the live encryption examples. The coverage job is Ubuntu 22.04 and uses the `ubuntu2204` crypt_shared build. The other jobs use the `ubuntu2404` build.

- CRUD, indexes, AdapterSuite, and GridFS run on all four.
- `#transaction` and `#watch` run when the topology is clustered. They skip on standalone.
- The "raises on standalone" examples run only when the topology is standalone.

```bash
TOPOLOGY=replicaset MONGODB_URI='mongodb://127.0.0.1:27017/?replicaSet=rs0' crystal spec
```

A gitignored `shard.override.yml` can point cryomongo at a local checkout while you work on the driver. Do not commit it. Shards 0.20 reports ambiguous bson sources if that file also sets a path for bson next to cryomongo's github bson.

---

## 13. Security

The adapter sends BSON. It does not build queries by concatenating strings.

Every filter, `$sort`, and `$select` field must exist on the schema, or be `id` / `_id`. Unknown fields return **400**. MemoryAdapter treats an unknown filter as a string. This adapter does not.

A patch key that contains `.` must match a schema nested path. An unknown path returns **400**. `update` rejects every dotted key.

A `"$unset"` path must exist on the schema. JSON null is not unset.

Error text does not include a URI password. See [Errors](#11-errors).

The local master key for field encryption is the app's secret. The adapter stores a copy on `Encryption` and sends it to the driver as the local KMS key. It is not written to the data collection.

---

## 14. License

MIT
