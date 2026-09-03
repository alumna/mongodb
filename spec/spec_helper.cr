require "spec"
require "uuid"
require "alumna/testing"
require "../src/alumna-mongodb"

MONGODB_URI   = ENV["MONGODB_URI"]? || "mongodb://127.0.0.1:27017"
SHARED_CLIENT = Mongo::Client.new(MONGODB_URI)
TEST_DB       = "alumna_test"

# Live `#transaction` examples need a replica set. GitHub CI stays standalone.
def replica_set_uri? : Bool
  MONGODB_URI.includes?("replicaSet=")
end

def drop_collection(name : String) : Nil
  SHARED_CLIENT[TEST_DB][name].drop
rescue Mongo::Error
end

def mongo_coll(name : String) : Mongo::Collection
  SHARED_CLIENT[TEST_DB][name]
end

def sample_schema : Alumna::Schema
  Alumna::Schema.new(strict: false)
    .str("name", required: false)
    .str("email", required: false)
    .int("age", required: false)
    .float("score", required: false)
    .bool("active", required: false)
    .time("created", required: false)
    .bytes("blob", required: false)
    .hash("user", required: false) { |s|
      s.str("name", required: false)
      s.int("age", required: false)
    }
    .array("tags", of: :str, required: false)
    .any("n", required: false)
    .any("extra", required: false)
    .any("meta", required: false)
    .any("metadata", required: false)
    .str("role", required: false)
    .str("status", required: false)
    .str("grade", required: false)
end

def mongo_adapter(
  collection : String,
  schema : Alumna::Schema = sample_schema,
  max_limit : Int32? = nil,
) : Alumna::MongoAdapter
  drop_collection(collection)
  Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, collection, schema, max_limit)
end

def ctx(
  adapter : Alumna::MongoAdapter,
  method : Alumna::ServiceMethod,
  id : String? = nil,
  data : Hash(String, Alumna::AnyData) = {} of String => Alumna::AnyData,
  params : Hash(String, String) = {} of String => String,
) : Alumna::RuleContext
  Alumna::Testing.build_ctx(
    service: adapter,
    method: method,
    id: id,
    data: data,
    params: params
  )
end

def as_hash(result) : Hash(String, Alumna::AnyData)
  result.should be_a(Hash(String, Alumna::AnyData))
  result.as(Hash(String, Alumna::AnyData))
end

def as_list(result) : Array(Hash(String, Alumna::AnyData))
  result.should be_a(Array(Hash(String, Alumna::AnyData)))
  result.as(Array(Hash(String, Alumna::AnyData)))
end

def as_error(result) : Alumna::ServiceError
  result.should be_a(Alumna::ServiceError)
  result.as(Alumna::ServiceError)
end
