class Alumna::MongoAdapter
  # AnyData → BSON in one Builder pass. Nested Hash/Array use in-place document/array
  # helpers (same IO). Pre-size the top-level builder IO from known size.
  module BsonWrite
    def self.document(oid : BSON::ObjectId, data : Hash(String, AnyData)) : BSON
      build(data.size * 16 + 22) do |bson|
        bson["_id"] = oid
        data.each do |key, value|
          next if key == "id" || key == "_id"
          write_field(bson, key, value)
        end
      end
    end

    # `{ $set: { fields } }` in one Builder. Nested Hash/Array use document/array.
    def self.set_document(data : Hash(String, AnyData)) : BSON
      build(data.size * 16 + 16) do |bson|
        bson.document("$set") do
          data.each do |key, value|
            next if key == "id" || key == "_id"
            write_field(bson, key, value)
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

    # Same as BSON.build, but the IO buffer starts at *byte_cap* (min 64, the Builder default).
    private def self.build(byte_cap : Int32, &) : BSON
      cap = byte_cap < 64 ? 64 : byte_cap
      builder = BSON::Builder.new(IO::Memory.new(cap))
      yield builder
      BSON.view(builder.to_bson)
    end
  end
end
