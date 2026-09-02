require "alumna"
require "cryomongo"

module Alumna
  # MongoDB adapter for Alumna.
  # Path: AnyData → BSON → cryomongo → BSON → AnyData.
  class MongoAdapter < Service
    @client : Mongo::Client
    @database : String
    @collection_name : String
    @collection : Mongo::Collection
    @sch : Schema
    @field_count : Int32
    @max_limit : Int32?
    @unique_fields : Array({String, FieldDescriptor})
    @index_models : Array(BSON)
    @index_names : Hash(String, String)

    def initialize(
      client : Mongo::Client,
      database : String,
      collection : String,
      schema : Schema? = nil,
      max_limit : Int32? = nil,
    )
      raise ArgumentError.new("MongoAdapter requires a Schema") unless schema

      super(schema)

      @client = client
      @database = database
      @collection_name = collection
      @collection = client[database][collection]
      @sch = schema
      @field_count = schema.fields.size
      @max_limit = max_limit
      @unique_fields = schema.unique_fields
      @index_models, @index_names = Indexes.prepare(collection, schema)
    end

    def find(ctx : RuleContext) : Array(Hash(String, AnyData)) | ServiceError
      q = ctx.query
      filters = q.typed_filters(@sch)
      return filters if filters.is_a?(ServiceError)

      sort = FindOptions.sort_bson(q, @sch)
      return sort if sort.is_a?(ServiceError)

      projection = FindOptions.projection_bson(q, @sch)
      return projection if projection.is_a?(ServiceError)

      skip = FindOptions.skip(q)
      limit = FindOptions.limit(q, @max_limit)
      filter = Query.filter_bson(filters, @sch)
      return filter if filter.is_a?(ServiceError)
      results = Array(Hash(String, AnyData)).new(initial_capacity: limit || 16)

      err = mongo {
        @collection.find(filter, sort: sort, projection: projection, skip: skip, limit: limit) do |doc|
          results << BsonRead.to_record(doc, @field_count)
        end
      }
      return err if err.is_a?(ServiceError)
      results
    end

    def get(ctx : RuleContext) : Hash(String, AnyData)? | ServiceError
      raw_id = ctx.id
      return nil unless raw_id
      oid = Identity.parse?(raw_id)
      return nil unless oid

      doc = mongo { @collection.find_one(Identity.filter(oid)) }
      return doc if doc.is_a?(ServiceError)
      return nil unless doc
      BsonRead.to_record(doc, @field_count)
    end

    def create(ctx : RuleContext) : Hash(String, AnyData) | ServiceError
      oid = BSON::ObjectId.new
      doc = BsonWrite.document(oid, ctx.data)
      err = mongo { @collection.insert_one(doc) }
      return err if err.is_a?(ServiceError)
      record_from_data(oid, ctx.data)
    end

    def update(ctx : RuleContext) : Hash(String, AnyData) | ServiceError
      raw_id = ctx.id
      return ServiceError.bad_request("ID required for update") unless raw_id
      if dotted = dotted_key_error(ctx.data)
        return dotted
      end
      oid = Identity.parse?(raw_id)
      return ServiceError.not_found unless oid

      replacement = BsonWrite.document(oid, ctx.data)
      result = mongo { @collection.replace_one(Identity.filter(oid), replacement) }
      return result if result.is_a?(ServiceError)
      return ServiceError.not_found if matched_zero?(result)
      record_from_data(oid, ctx.data)
    end

    def patch(ctx : RuleContext) : Hash(String, AnyData) | ServiceError
      raw_id = ctx.id
      return ServiceError.bad_request("ID required for patch") unless raw_id
      if dotted = dotted_key_error(ctx.data)
        return dotted
      end
      oid = Identity.parse?(raw_id)
      return ServiceError.not_found unless oid

      filter = Identity.filter(oid)
      existing_doc = mongo { @collection.find_one(filter) }
      return existing_doc if existing_doc.is_a?(ServiceError)
      return ServiceError.not_found unless existing_doc

      record = BsonRead.to_record(existing_doc, @field_count)
      unless has_write_keys?(ctx.data)
        return record
      end

      update_doc = BsonWrite.set_document(ctx.data)
      result = mongo { @collection.update_one(filter, update_doc) }
      return result if result.is_a?(ServiceError)
      return ServiceError.not_found if matched_zero?(result)

      ctx.data.each do |key, value|
        next if key == "id" || key == "_id"
        record[key] = value
      end
      record
    end

    def remove(ctx : RuleContext) : Nil | ServiceError
      raw_id = ctx.id
      return ServiceError.bad_request("ID required for remove") unless raw_id
      oid = Identity.parse?(raw_id)
      return ServiceError.not_found unless oid

      result = mongo { @collection.delete_one(Identity.filter(oid)) }
      return result if result.is_a?(ServiceError)
      n = result.try(&.n) || 0
      return ServiceError.not_found if n == 0
      nil
    end

    def create_indexes! : Nil
      Indexes.create!(@collection, @index_models)
    end

    private def mongo(& : -> T) : T | ServiceError forall T
      yield
    rescue ex : Mongo::Error
      Errors.from_mongo(ex, @index_names)
    end

    private def record_from_data(oid : BSON::ObjectId, data : Hash(String, AnyData)) : Hash(String, AnyData)
      record = Hash(String, AnyData).new(initial_capacity: data.size + 1)
      record["id"] = Identity.hex(oid)
      data.each do |key, value|
        next if key == "id" || key == "_id"
        record[key] = value
      end
      record
    end

    private def dotted_key_error(data : Hash(String, AnyData)) : ServiceError?
      data.each_key do |key|
        next if key == "id" || key == "_id"
        return ServiceError.bad_request("Dotted keys are not allowed") if key.includes?('.')
      end
      nil
    end

    private def has_write_keys?(data : Hash(String, AnyData)) : Bool
      data.each_key do |key|
        return true unless key == "id" || key == "_id"
      end
      false
    end

    private def matched_zero?(result : Mongo::Commands::Common::UpdateResult?) : Bool
      n = result.try(&.n) || 0
      n == 0
    end
  end
end

require "./mongo/bson_write"
require "./mongo/bson_read"
require "./mongo/identity"
require "./mongo/query"
require "./mongo/find_options"
require "./mongo/indexes"
require "./mongo/errors"
