class Alumna::MongoAdapter
  # Raised when opt-in client-side encryption cannot start (missing driver
  # auto-encryption, missing crypt_shared, or a setup error).
  class EncryptionError < Exception
  end

  # Opt-in client-side encryption (FLE1). Apps pass this into `MongoAdapter.new`
  # / `Alumna.mongo`. Service methods stay AnyData in / AnyData out.
  #
  # Local KMS only. Marked fields are encrypted in MongoDB as BSON binary
  # subtype `0x06`. With auto-decrypt they come back as plaintext AnyData.
  # Do not encrypt `_id`. Schema is still required (D10).
  #
  # cryomongo >= 1.0.0-beta defines `Mongo::AutoEncryption`. This type still
  # compiles against an older driver: opening an adapter with `encryption:`
  # then raises `EncryptionError`. Live encryption needs libmongocrypt and
  # `CRYPT_SHARED_LIB_PATH` (`mongo_crypt_v1.so`).
  class Encryption
    LOCAL_KEY_BYTES = 96

    # FLE1 deterministic (same plaintext → same ciphertext). Equality queries work.
    ALGORITHM_DETERMINISTIC = "AEAD_AES_256_CBC_HMAC_SHA_512-Deterministic"
    # FLE1 random (same plaintext → different ciphertext).
    ALGORITHM_RANDOM = "AEAD_AES_256_CBC_HMAC_SHA_512-Random"

    getter key_vault_namespace : String
    getter local_master_key : Bytes
    getter fields : Hash(String, String)
    getter schema_map : BSON?
    getter uri : String?
    getter crypt_shared_lib_path : String?

    # *fields* maps schema field name → `"deterministic"` / `"random"` (or the
    # full algorithm string). *schema_map* is a driver FLE1 map and wins when set.
    def initialize(
      *,
      key_vault_namespace : String,
      local_master_key : Bytes,
      fields : Hash(String, String)? = nil,
      schema_map : BSON? = nil,
      uri : String? = nil,
      crypt_shared_lib_path : String? = nil,
    )
      unless local_master_key.size == LOCAL_KEY_BYTES
        raise ArgumentError.new("local_master_key must be #{LOCAL_KEY_BYTES} bytes")
      end
      unless valid_namespace?(key_vault_namespace)
        raise ArgumentError.new("key_vault_namespace must be database.collection")
      end

      @key_vault_namespace = key_vault_namespace
      @local_master_key = local_master_key.clone
      @schema_map = schema_map
      @uri = uri
      @crypt_shared_lib_path = crypt_shared_lib_path
      @fields = Hash(String, String).new(initial_capacity: fields ? fields.size : 0)
      if src = fields
        src.each do |name, algo|
          if name == "_id" || name == "id"
            raise ArgumentError.new("Do not encrypt _id")
          end
          @fields[name] = algorithm(algo)
        end
      end
      if @fields.empty? && schema_map.nil?
        raise ArgumentError.new("Encryption needs fields or schema_map")
      end
    end

    # Normalize a short name or a full FLE1 algorithm string.
    def self.algorithm(name : String) : String
      case name
      when "deterministic", ALGORITHM_DETERMINISTIC
        ALGORITHM_DETERMINISTIC
      when "random", ALGORITHM_RANDOM
        ALGORITHM_RANDOM
      else
        raise ArgumentError.new("Unknown encryption algorithm: #{name}. Use deterministic or random.")
      end
    end

    # Local KMS document for the driver. No libmongocrypt types.
    def self.local_kms(master_key : Bytes) : BSON
      BSON.build do |bson|
        bson.document("local") do
          bson["key"] = BSON::Binary.new(BSON::Binary::SubType::Generic, master_key)
        end
      end
    end

    # FLE1 schemaMap for one namespace. *key_id* is a UUID binary (subtype 0x04).
    def self.schema_map(namespace : String, fields : Hash(String, String), key_id : BSON::Binary) : BSON
      BSON.build do |bson|
        bson.document(namespace) do
          bson["bsonType"] = "object"
          bson.document("properties") do
            fields.each do |name, algo|
              bson.document(name) do
                bson.document("encrypt") do
                  bson["bsonType"] = "string"
                  bson["algorithm"] = algo
                  bson.array("keyId") do
                    bson["0"] = key_id
                  end
                end
              end
            end
          end
        end
      end
    end

    private def algorithm(name : String) : String
      self.class.algorithm(name)
    end

    private def valid_namespace?(ns : String) : Bool
      dot = ns.index('.')
      return false unless dot
      return false if dot == 0 || dot == ns.bytesize - 1
      true
    end
  end

  MISSING_CSFLE = "Client-side encryption needs cryomongo with auto-encryption. Use the workbench driver or a tagged CSFLE release."

  # Close an adapter-owned auto-encryption client. No-op when the caller owns
  # the client (the usual `SHARED_CLIENT` / process client).
  def close : Nil
    {% if Mongo.has_constant?("AutoEncryption") %}
      if @owns_client
        @owns_client = false
        @client.close
      end
    {% else %}
      @owns_client = false
    {% end %}
  end

  {% if flag?(:alumna_csfle) && !Mongo.has_constant?("AutoEncryption") %}
    {% raise "alumna_csfle needs cryomongo with Mongo::AutoEncryption (workbench path or a tagged CSFLE release)" %}
  {% end %}
end

{% if Mongo.has_constant?("AutoEncryption") %}
  require "./encryption_csfle"
{% else %}
  class Alumna::MongoAdapter
    private def apply_encryption(_enc : Encryption) : Nil
      raise EncryptionError.new(MISSING_CSFLE)
    end
  end
{% end %}
