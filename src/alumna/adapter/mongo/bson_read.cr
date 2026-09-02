class Alumna::MongoAdapter
  # BSON → Hash(String, AnyData). Walk `each`. Do not use `to_h` or `from_bson`.
  module BsonRead
    def self.to_record(bson : BSON, field_count : Int32) : Hash(String, AnyData)
      hash = Hash(String, AnyData).new(initial_capacity: field_count + 1)
      bson.each do |key, value, code, subtype|
        if key == "_id"
          hash["id"] = oid_to_hex(value)
        else
          hash[key] = to_any(value, code, subtype)
        end
      end
      hash
    end

    def self.to_any(value : BSON::Value, code : BSON::Element, _subtype : BSON::Binary::SubType?) : AnyData
      case value
      when Nil
        nil
      when Bool
        value
      when Int32
        value.to_i64
      when Int64
        value
      when Float64
        value
      when String
        value
      when Time
        value
      when BSON::DateTime
        value.to_time?
      when Bytes
        # Decoder yields a view into the parent document. Copy before the parent is gone.
        value.clone
      when BSON::ObjectId
        value.to_s
      when UUID
        value.to_s
      when BSON::Decimal128
        value.to_s
      when BSON::Regex
        value.pattern
      when BSON
        if code.array?
          to_array(value)
        else
          to_hash(value)
        end
      when BSON::MinKey
        "$minKey"
      when BSON::MaxKey
        "$maxKey"
      when BSON::Undefined
        "$undefined"
      when BSON::Timestamp
        "#{value.t}:#{value.i}"
      when BSON::Code
        value.code
      when BSON::Symbol
        value.data
      when BSON::DBPointer
        "#{value.data}:#{value.oid}"
      end
    end

    private def self.to_array(bson : BSON) : Array(AnyData)
      arr = Array(AnyData).new(initial_capacity: capacity_from(bson))
      bson.each do |_, value, code, subtype|
        arr << to_any(value, code, subtype)
      end
      arr
    end

    private def self.to_hash(bson : BSON) : Hash(String, AnyData)
      hash = Hash(String, AnyData).new(initial_capacity: capacity_from(bson))
      bson.each do |key, value, code, subtype|
        hash[key] = to_any(value, code, subtype)
      end
      hash
    end

    # Do not walk `each` just to count: that decodes every value twice.
    # Payload bytes / 4 is a size hint (empty BSON is 5 bytes → 0, so no Hash table).
    private def self.capacity_from(bson : BSON) : Int32
      payload = bson.size - 5
      payload <= 0 ? 0 : payload // 4
    end

    private def self.oid_to_hex(value : BSON::Value) : String
      case value
      when BSON::ObjectId
        value.to_s
      else
        value.to_s
      end
    end
  end
end
