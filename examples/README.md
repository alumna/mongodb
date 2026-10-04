# Examples

Programs you can run from the adapter root. `crystal spec` without a path only reads `spec/`, so nothing in this folder runs in GitHub CI.

MongoDB 8.0 must already be listening. The default URI is `mongodb://127.0.0.1:27017/?replicaSet=rs0`. Override it with `MONGODB_URI`. Each process uses the database `alumna_examples` and drops it on exit.

Transactions and change streams need a replica set, mongos, or a load balancer. GridFS and CRUD do not.

Encryption needs `mongo_crypt_v1.so`. The script looks at `CRYPT_SHARED_LIB_PATH`, then `lib/cryomongo/tmp/mongo_crypt_v1.so`, then `/usr/local/lib/mongo_crypt_v1.so`. The download is `lib/cryomongo/scripts/download-crypt-shared.sh`. Point the variable at the file, not at the directory. One process can load only one crypt_shared path.

The compile also needs libmongocrypt, unless you pass `-Dwithout_libmongocrypt` and skip `encryption.cr`. After `shards install`, run `lib/cryomongo/scripts/vendor-libmongocrypt.sh`.

## Scripts

```bash
crystal examples/quick_start.cr
crystal examples/queries.cr
crystal examples/indexes.cr
crystal examples/transactions.cr
crystal examples/gridfs.cr
crystal examples/change_streams.cr
CRYPT_SHARED_LIB_PATH=lib/cryomongo/tmp/mongo_crypt_v1.so crystal examples/encryption.cr
crystal examples/http_app.cr
crystal examples/rules.cr
```

`quick_start.cr` is create, get, patch (`$unset` and a dotted path), remove, and `#close` when the adapter does not own the client.

`queries.cr` is `$gt`, `$in`, a nested field, an array element, `$sort`, `$select`, `max_limit`, an unknown field, and an id that is not 24 hex.

`indexes.cr` is `create_indexes!` and duplicate key 422.

`http_app.cr` mounts the adapter on `Alumna::App` and calls it with `Alumna::Testing::AppClient`. No port is opened.

`rules.cr` runs one rule with `Alumna::Testing.run_rule`, then mounts `Alumna.validate` and a price rule so `AppClient` hits them.

## Specs

```bash
crystal spec examples/service_spec.cr
crystal spec examples/adapter_suite.cr
```

`service_spec.cr` is one example that uses `Alumna::Testing.build_ctx`.

`adapter_suite.cr` is `Alumna::Testing::AdapterSuite`. The factory schema is the set of fields that suite writes. `expect_incremental_ids: false` because ids are ObjectId hex. `mixed_sort: :bson` because mixed `$sort` follows MongoDB, not SQLite.
