require "spec"
require "uuid"
require "alumna/testing"
require "../src/alumna-mongodb"

# SHARED_CLIENT is created at load. Set MONGODB_URI and TOPOLOGY before the process.
MONGODB_URI   = ENV["MONGODB_URI"]? || "mongodb://127.0.0.1:27017"
SHARED_CLIENT = Mongo::Client.new(MONGODB_URI)
TEST_DB       = "alumna_test"

# GitHub matrix names. Replica set, sharded, and load-balanced all run live
# `#transaction` / `#watch`. CRUD, indexes, AdapterSuite, and GridFS run on all four.
CLUSTERED_TOPOLOGY_NAMES = {"replicaset", "sharded", "load-balanced"}

# Resolved once. TOPOLOGY env is CI source of truth. Local runs may omit it;
# then URI query (replicaSet= / loadBalanced=true), then hello on SHARED_CLIENT.
# Do not key off replicaSet= alone: mongos has no replicaSet= and can still
# run transactions and change streams.
SPEC_TOPOLOGY = detect_spec_topology

# True on replica set, mongos, or load-balanced.
def clustered? : Bool
  CLUSTERED_TOPOLOGY_NAMES.includes?(SPEC_TOPOLOGY)
end

def standalone? : Bool
  !clustered?
end

# TOPOLOGY env, then URI, then hello. Empty TOPOLOGY falls through.
private def detect_spec_topology : String
  if raw = ENV["TOPOLOGY"]?
    name = raw.strip.downcase
    return name unless name.empty?
  end
  if from_uri = topology_from_uri(MONGODB_URI)
    return from_uri
  end
  topology_from_hello
end

# URI is enough for replica set and load-balanced. Sharded mongos often has
# neither replicaSet= nor loadBalanced=true, so hello is required.
private def topology_from_uri(uri : String) : String?
  return "load-balanced" if uri.includes?("loadBalanced=true")
  return "replicaset" if uri.includes?("replicaSet=")
  nil
end

# Ping so Unknown becomes a real SDAM type, then map the client topology.
private def topology_from_hello : String
  begin
    SHARED_CLIENT.command(Mongo::Commands::Ping)
  rescue Mongo::Error
  end
  type = SHARED_CLIENT.topology.type
  return "replicaset" if type.replica_set_with_primary? || type.replica_set_no_primary?
  return "sharded" if type.sharded?
  return "load-balanced" if type.load_balanced?
  "standalone"
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
