class Alumna::MongoAdapter
  # AnyData → BSON in one Builder pass. Nested Hash/Array use in-place document/array
  # helpers (same IO). Pre-size the top-level builder IO from known size.
  module BsonWrite
    def self.document(oid : BSON::ObjectId, data : Hash(String, AnyData)) : BSON
      build(document_bytes(data)) do |bson|
        bson["_id"] = oid
        data.each do |key, value|
          next if key == "id" || key == "_id"
          write_field(bson, key, value)
        end
      end
    end

    # `{ $set: { fields } }` and/or `{ $unset: { path: "" } }` on one parent
    # Builder. Nested Hash/Array in `$set` still use document/array.
    # A dotted `$set` key stays a field name that contains dots (`"user.name"`).
    # That is MongoDB nested `$set`. Do not split it into a nested document here.
    # Omit `$set` when *has_set* is false. Omit `$unset` when *unset_paths* is empty.
    # `$unset` values are empty strings (MongoDB ignores the value).
    def self.update_document(data : Hash(String, AnyData), unset_paths : Array(String), has_set : Bool) : BSON
      build(update_bytes(data, unset_paths, has_set)) do |bson|
        if has_set
          bson.document("$set") do
            data.each do |key, value|
              next if key == "id" || key == "_id"
              write_field(bson, key, value)
            end
          end
        end
        unless unset_paths.empty?
          bson.document("$unset") do
            unset_paths.each do |path|
              bson[path] = ""
            end
          end
        end
      end
    end

    def self.write_field(builder : BSON::Builder, key : String, value : AnyData) : Nil
      case value
      when Hash
        builder.document(key) do
          value.each { |k, v| write_field(builder, k, v) }
        end
      when Array
        builder.array(key) do
          value.each_with_index do |item, index|
            idx = index < 128 ? BSON::Builder::STATIC_INDICES.unsafe_fetch(index) : index.to_s
            write_field(builder, idx, item)
          end
        end
      when Nil
        builder[key] = nil
      when Bool
        builder[key] = value
      when Int64
        builder[key] = value
      when Float64
        builder[key] = value
      when String
        builder[key] = value
      when Time
        builder[key] = value
      when Bytes
        builder[key] = value
      end
    end

    # *byte_cap* is the full document size (header included). The builder
    # buffer is that size, so to_bson does not allocate a second copy.
    private def self.build(byte_cap : Int32, &) : BSON
      cap = byte_cap < 5 ? 5 : byte_cap
      builder = BSON::Builder.new(cap)
      yield builder
      doc = BSON.view(builder.to_bson)
      {% unless flag?(:release) %}
        if doc.size != cap
          raise BSON::Error.new("BSON size estimate #{cap} != #{doc.size}")
        end
      {% end %}
      doc
    end

    # Header (5) plus `_id` (17) plus each stored field.
    private def self.document_bytes(data : Hash(String, AnyData)) : Int32
      total = 22
      data.each do |key, value|
        next if key == "id" || key == "_id"
        total += 2 + key.bytesize + value_bytes(value)
      end
      total
    end

    private def self.update_bytes(data : Hash(String, AnyData), unset_paths : Array(String), has_set : Bool) : Int32
      total = 5
      if has_set
        nested = 5
        data.each do |key, value|
          next if key == "id" || key == "_id"
          nested += 2 + key.bytesize + value_bytes(value)
        end
        total += 6 + nested # type + "$set" + NUL + nested document
      end
      unless unset_paths.empty?
        nested = 5
        unset_paths.each do |path|
          nested += 2 + path.bytesize + 5 # empty string payload
        end
        total += 8 + nested # type + "$unset" + NUL + nested document
      end
      total
    end

    private def self.value_bytes(value : AnyData) : Int32
      case value
      when Nil
        0
      when Bool
        1
      when Int64, Float64, Time
        8
      when String
        5 + value.bytesize
      when Bytes
        5 + value.size
      when Hash
        hash_bytes(value)
      when Array
        array_bytes(value)
      else
        raise BSON::Error.new("Unsupported AnyData in BSON size estimate")
      end
    end

    private def self.hash_bytes(data : Hash(String, AnyData)) : Int32
      total = 5
      data.each do |key, value|
        total += 2 + key.bytesize + value_bytes(value)
      end
      total
    end

    private def self.array_bytes(items : Array(AnyData)) : Int32
      total = 5
      items.each_with_index do |item, index|
        key = index < 128 ? BSON::Builder::STATIC_INDICES.unsafe_fetch(index) : index.to_s
        total += 2 + key.bytesize + value_bytes(item)
      end
      total
    end
  end
end
