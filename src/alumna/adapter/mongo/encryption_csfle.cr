# Auto-encryption implementation. cryomongo >= 1.0.0-beta defines
# `Mongo::AutoEncryption`, so `encryption.cr` always loads this file.

class Alumna::MongoAdapter
  private def apply_encryption(enc : Encryption) : Nil
    unless Mongo::ClientEncryption.lib_linked?
      # LCOV_EXCL_START - needs a build without libmongocrypt
      raise EncryptionError.new("Client-side encryption needs libmongocrypt.")
      # LCOV_EXCL_STOP
    end

    shared = crypt_shared_file(enc.crypt_shared_lib_path)
    uri = csfle_uri(enc)
    kms = Encryption.local_kms(enc.local_master_key)
    schema = enc.schema_map
    unless schema
      key_id = ensure_data_key(enc.key_vault_namespace, kms)
      schema = Encryption.schema_map("#{@database}.#{@collection_name}", enc.fields, key_id)
    end

    extra = BSON.build do |bson|
      bson["cryptSharedLibPath"] = shared
      bson["cryptSharedLibRequired"] = true
    end

    auto = Mongo::Client.new(
      uri,
      auto_encryption: Mongo::AutoEncryption.new(
        key_vault_namespace: enc.key_vault_namespace,
        kms_providers: kms,
        schema_map: schema,
        extra_options: extra,
      )
    )
    begin
      @client = auto
      @collection = auto[@database][@collection_name]
      @owns_client = true
    rescue ex
      # LCOV_EXCL_START - Client.new succeeded; collection lookup should not fail
      auto.close
      raise ex
      # LCOV_EXCL_STOP
    end
  rescue ex : EncryptionError
    raise ex
  rescue ex : Mongo::Error
    # LCOV_EXCL_START - driver setup errors after the explicit checks above
    raise EncryptionError.new(Errors.safe_message(ex))
    # LCOV_EXCL_STOP
  end

  private def crypt_shared_file(explicit : String?) : String
    if given = explicit
      return given if File.file?(given)
      raise EncryptionError.new("crypt_shared library not found: #{given}")
    end
    if p = Mongo::AutoEncryption.crypt_shared_lib_path
      return p if File.file?(p)
    end
    # LCOV_EXCL_START - host copy, or the error when no library exists.
    # Specs cover the explicit path and CRYPT_SHARED_LIB_PATH branches above.
    fallback = "/usr/local/lib/mongo_crypt_v1.so"
    return fallback if File.file?(fallback)
    raise EncryptionError.new("Client-side encryption needs crypt_shared (mongo_crypt_v1.so). Set CRYPT_SHARED_LIB_PATH.")
    # LCOV_EXCL_STOP
  end

  private def csfle_uri(enc : Encryption) : String
    if u = enc.uri
      return u unless u.empty?
    end
    uri_from_client(@client)
  end

  # Rebuild a mongodb:// URI from topology seeds and client options.
  # Apps with auth should pass `Encryption.uri`.
  private def uri_from_client(client : Mongo::Client) : String
    if client.topology.type.unknown?
      # LCOV_EXCL_START - SHARED_CLIENT has already pinged in spec_helper
      begin
        client.command(Mongo::Commands::Ping)
      rescue Mongo::Error
      end
      # LCOV_EXCL_STOP
    end
    servers = client.topology.servers
    host = "127.0.0.1:27017"
    if first = servers[0]?
      host = first.address
    end
    params = Array(String).new(initial_capacity: 3)
    if rs = client.options.replica_set
      # LCOV_EXCL_START - clustered URI options; kcov stays standalone
      params << "replicaSet=#{rs}" unless rs.empty?
      # LCOV_EXCL_STOP
    end
    if client.options.load_balanced
      # LCOV_EXCL_START - clustered URI options; kcov stays standalone
      params << "loadBalanced=true"
      # LCOV_EXCL_STOP
    end
    if client.options.direct_connection
      # LCOV_EXCL_START - clustered URI options; kcov stays standalone
      params << "directConnection=true"
      # LCOV_EXCL_STOP
    end
    if params.empty?
      "mongodb://#{host}"
    else
      # LCOV_EXCL_START - replicaSet / loadBalanced / directConnection
      "mongodb://#{host}/?#{params.join("&")}"
      # LCOV_EXCL_STOP
    end
  end

  # Reuse the first data key in the vault, or create one. Always `#close` the
  # explicit handle. Never destroy it from GC `finalize`.
  private def ensure_data_key(namespace : String, kms : BSON) : BSON::Binary
    handle = Mongo::ClientEncryption.new(
      @client,
      key_vault_namespace: namespace,
      kms_providers: kms,
    )
    begin
      existing = handle.get_keys
      if first = data_key_id(existing)
        first
      else
        handle.create_data_key("local")
      end
    ensure
      handle.close
    end
  end

  private def data_key_id(docs : Array(BSON)) : BSON::Binary?
    docs.each do |doc|
      doc.each do |key, value, _code, subtype|
        next unless key == "_id"
        if value.is_a?(UUID)
          return BSON::Binary.new(value)
        end
        # LCOV_EXCL_START - data-key `_id` is UUID (subtype 0x04); BSON yields UUID
        if value.is_a?(Bytes)
          st = subtype || BSON::Binary::SubType::UUID
          return BSON::Binary.new(st, value.clone)
        end
        # LCOV_EXCL_STOP
      end
    end
    nil
  end
end
