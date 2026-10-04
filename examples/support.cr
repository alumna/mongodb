require "alumna"
require "../src/alumna-mongodb"

# The facilitators, without `alumna/testing`'s adapter suite (that file loads `spec`).
require "alumna/testing/mock_context"
require "alumna/testing/rule_runner"
require "alumna/testing/app_client"

# Shared connection for the example programs. Each program is its own process.
# They all use the database `alumna_examples` and drop it on exit.
module Examples
  MONGO_URI = ENV["MONGODB_URI"]? || "mongodb://127.0.0.1:27017/?replicaSet=rs0"
  DB        = "alumna_examples"

  @@client : Mongo::Client? = nil

  def self.client : Mongo::Client
    @@client ||= Mongo::Client.new(MONGO_URI)
  end

  def self.ctx(
    adapter : Alumna::MongoAdapter,
    method : Alumna::ServiceMethod,
    *,
    id : String? = nil,
    data = {} of String => Alumna::AnyData,
    params = {} of String => String,
  ) : Alumna::RuleContext
    Alumna::Testing.build_ctx(service: adapter, method: method, id: id, data: data, params: params)
  end

  # `create` returns the record or a ServiceError. Indexing the union does not compile.
  def self.must(result, label : String) : Hash(String, Alumna::AnyData)
    if result.is_a?(Alumna::ServiceError)
      raise "#{label}: #{result.status} #{result.message} #{result.details}"
    end
    result.as(Hash(String, Alumna::AnyData))
  end

  # The file, not the directory. One process can load only one crypt_shared path.
  def self.crypt_shared : String
    candidates = [] of String
    if env = ENV["CRYPT_SHARED_LIB_PATH"]?
      candidates << env
    end
    candidates << File.expand_path("../lib/cryomongo/tmp/mongo_crypt_v1.so", __DIR__)
    candidates << "/usr/local/lib/mongo_crypt_v1.so"
    candidates.each do |path|
      return path if File.file?(path)
    end
    abort <<-MSG
      mongo_crypt_v1.so was not found.
      From the adapter root, after shards install:
        lib/cryomongo/scripts/download-crypt-shared.sh
      Then set CRYPT_SHARED_LIB_PATH to the file that script prints.
      MSG
  end
end

at_exit do
  Examples.client[Examples::DB].drop
rescue Mongo::Error
end
