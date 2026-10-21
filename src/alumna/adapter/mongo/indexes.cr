class Alumna::MongoAdapter
  # Schema → MongoDB index models. Names are stable so 11000 can map back to a path.
  module Indexes
    EMPTY_MODELS = [] of BSON
    EMPTY_NAMES  = {} of String => String

    def self.prepare(collection_name : String, schema : Schema) : {Array(BSON), Hash(String, String)}
      indexed = schema.indexed_fields
      extras = schema.schema_indexes
      if indexed.empty? && extras.empty?
        return {EMPTY_MODELS, EMPTY_NAMES}
      end

      coll = String.build { |io| append_safe(io, collection_name) }
      capacity = indexed.size + extras.size
      models = Array(BSON).new(initial_capacity: capacity)
      names = Hash(String, String).new(initial_capacity: capacity)
      seen = Set(String).new(initial_capacity: capacity)

      indexed.each do |(path, fd)|
        next if id_path?(path)
        add_index(models, names, seen, coll, schema, [path], fd.unique, fd.partial, path)
      end

      extras.each do |idx|
        fields = idx.fields
        next if fields.empty?
        next if fields.all? { |field| id_path?(field) }
        details_key = fields.size == 1 ? fields[0] : fields.join("_")
        add_index(models, names, seen, coll, schema, fields, idx.unique, idx.partial, details_key)
      end

      if models.empty?
        {EMPTY_MODELS, EMPTY_NAMES}
      else
        {models, names}
      end
    end

    def self.create!(collection : Mongo::Collection, models : Array(BSON)) : Nil
      return if models.empty?
      collection.create_indexes(models: models)
      nil
    end

    private def self.add_index(
      models : Array(BSON),
      names : Hash(String, String),
      seen : Set(String),
      coll : String,
      schema : Schema,
      fields : Array(String),
      unique : Bool,
      partial : Bool,
      details_key : String,
    ) : Nil
      sig = fields.size == 1 ? fields[0] : fields.join('\0')
      return unless seen.add?(sig)

      name = String.build do |io|
        io << (unique ? "uniq_" : "idx_")
        io << coll << '_'
        fields.each_with_index do |field, i|
          io << '_' if i > 0
          append_safe(io, field)
        end
      end

      keys = BSON.build do |bson|
        fields.each { |field| bson[field] = 1 }
      end
      filter = partial ? partial_filter(schema, fields) : nil
      options = BSON.build do |bson|
        bson["name"] = name
        bson["unique"] = unique
        if filter
          bson["partialFilterExpression"] = filter
        end
      end
      models << BSON.build do |bson|
        bson["keys"] = keys
        bson["options"] = options
      end
      names[name] = details_key
    end

    # One `$type` clause per key. MongoDB ANDs them. Missing and null are not that type.
    private def self.partial_filter(schema : Schema, fields : Array(String)) : BSON
      BSON.build do |bson|
        fields.each do |path|
          fd = schema.find_field(path)
          unless fd
            raise ArgumentError.new("partial index field #{path} is not on the schema")
          end
          bson.document(path) do
            bson["$type"] = partial_bson_type(path, fd.type)
          end
        end
      end
    end

    private def self.partial_bson_type(path : String, type : FieldType) : String
      case type
      when .str?   then "string"
      when .int?   then "long"
      when .bool?  then "bool"
      when .time?  then "date"
      when .bytes? then "binData"
      else              raise ArgumentError.new("partial index #{path} does not support #{type}")
      end
    end

    private def self.id_path?(path : String) : Bool
      path == "id" || path == "_id"
    end

    private def self.append_safe(io : IO, s : String) : Nil
      s.each_byte do |byte|
        if safe_byte?(byte)
          io.write_byte(byte)
        else
          io.write_byte(95_u8)
        end
      end
    end

    private def self.safe_byte?(byte : UInt8) : Bool
      (byte >= 48_u8 && byte <= 57_u8) ||
        (byte >= 65_u8 && byte <= 90_u8) ||
        (byte >= 97_u8 && byte <= 122_u8) ||
        byte == 95_u8
    end
  end
end
