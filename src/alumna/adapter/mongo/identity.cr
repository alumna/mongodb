class Alumna::MongoAdapter
  # ObjectId ↔ Alumna `id` (24 hex). Never call `ObjectId.new(str)` without validate.
  module Identity
    def self.valid?(id : String) : Bool
      BSON::ObjectId.validate(id)
    end

    def self.parse?(id : String) : BSON::ObjectId?
      return nil unless BSON::ObjectId.validate(id)
      BSON::ObjectId.new(id)
    end

    def self.hex(oid : BSON::ObjectId) : String
      oid.to_s
    end

    # {_id: ObjectId} is always 22 bytes. Builder would allocate a 64-byte IO then copy.
    FILTER_BYTES = 22
    OID_AT       =  9

    def self.filter(oid : BSON::ObjectId) : BSON
      bytes = Bytes.new(FILTER_BYTES)
      IO::ByteFormat::LittleEndian.encode(FILTER_BYTES, bytes[0, 4])
      bytes[4] = BSON::Element::ObjectId.value
      bytes[5] = 0x5f_u8 # _
      bytes[6] = 0x69_u8 # i
      bytes[7] = 0x64_u8 # d
      bytes[8] = 0x00_u8
      oid.to_slice.copy_to(bytes + OID_AT)
      BSON.view(bytes)
    end
  end
end
