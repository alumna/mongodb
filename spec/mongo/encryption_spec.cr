require "../spec_helper"
require "random/secure"

private def enc_schema
  Alumna::Schema.new(strict: false)
    .str("name", required: false)
    .str("ssn", required: false)
end

private def master_key : Bytes
  Random::Secure.random_bytes(Alumna::MongoAdapter::Encryption::LOCAL_KEY_BYTES)
end

private def spec_crypt_shared : String?
  candidates = [] of String
  if p = ENV["CRYPT_SHARED_LIB_PATH"]?
    candidates << p
  end
  # `shards install` puts cryomongo at lib/cryomongo. A path override is a
  # symlink, so this is also the workbench copy. CI downloads the library there.
  # One process can load only one crypt_shared path. Every live example below
  # passes this same path.
  candidates << File.expand_path("../../lib/cryomongo/tmp/mongo_crypt_v1.so", __DIR__)
  candidates << "/usr/local/lib/mongo_crypt_v1.so"
  candidates.each do |p|
    return p if File.file?(p)
  end
  nil
end

private def ssn_encrypted?(doc : BSON) : Bool
  doc.each do |key, value, code, subtype|
    next unless key == "ssn"
    return false unless code.binary?
    return false unless value.is_a?(Bytes)
    if st = subtype
      return st.encrypted_bson?
    end
    return false
  end
  false
end

describe Alumna::MongoAdapter::Encryption do
  it "normalizes deterministic and random algorithm names" do
    det = Alumna::MongoAdapter::Encryption::ALGORITHM_DETERMINISTIC
    rnd = Alumna::MongoAdapter::Encryption::ALGORITHM_RANDOM
    Alumna::MongoAdapter::Encryption.algorithm("deterministic").should eq(det)
    Alumna::MongoAdapter::Encryption.algorithm(det).should eq(det)
    Alumna::MongoAdapter::Encryption.algorithm("random").should eq(rnd)
    Alumna::MongoAdapter::Encryption.algorithm(rnd).should eq(rnd)
    expect_raises(ArgumentError, /Unknown encryption algorithm/) do
      Alumna::MongoAdapter::Encryption.algorithm("aes")
    end
  end

  it "builds local KMS and a FLE1 schema map" do
    key = Bytes.new(Alumna::MongoAdapter::Encryption::LOCAL_KEY_BYTES, 1_u8)
    kms = Alumna::MongoAdapter::Encryption.local_kms(key)
    has_local = false
    kms.each do |name, _value, _code, _subtype|
      has_local = true if name == "local"
    end
    has_local.should be_true

    key_id = BSON::Binary.new(BSON::Binary::SubType::UUID, Bytes.new(16, 0_u8))
    fields = {"ssn" => Alumna::MongoAdapter::Encryption::ALGORITHM_DETERMINISTIC}
    map = Alumna::MongoAdapter::Encryption.schema_map("hr.people", fields, key_id)
    found_ns = false
    map.each do |name, _value, _code, _subtype|
      found_ns = true if name == "hr.people"
    end
    found_ns.should be_true
  end

  it "rejects a short master key, a bad namespace, _id, and empty fields" do
    key = master_key
    expect_raises(ArgumentError, /96 bytes/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "keyvault.datakeys",
        local_master_key: Bytes.new(8),
        fields: {"ssn" => "deterministic"},
      )
    end
    expect_raises(ArgumentError, /database.collection/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "nodot",
        local_master_key: key,
        fields: {"ssn" => "deterministic"},
      )
    end
    expect_raises(ArgumentError, /database.collection/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: ".datakeys",
        local_master_key: key,
        fields: {"ssn" => "deterministic"},
      )
    end
    expect_raises(ArgumentError, /database.collection/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "keyvault.",
        local_master_key: key,
        fields: {"ssn" => "deterministic"},
      )
    end
    expect_raises(ArgumentError, /Do not encrypt _id/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "keyvault.datakeys",
        local_master_key: key,
        fields: {"_id" => "deterministic"},
      )
    end
    expect_raises(ArgumentError, /Do not encrypt _id/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "keyvault.datakeys",
        local_master_key: key,
        fields: {"id" => "random"},
      )
    end
    expect_raises(ArgumentError, /fields or schema_map/) do
      Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "keyvault.datakeys",
        local_master_key: key,
      )
    end
  end

  it "stores fields, schema_map, uri, and crypt_shared_lib_path" do
    key = master_key
    key_id = BSON::Binary.new(BSON::Binary::SubType::UUID, Bytes.new(16, 2_u8))
    map = Alumna::MongoAdapter::Encryption.schema_map(
      "hr.people",
      {"ssn" => Alumna::MongoAdapter::Encryption::ALGORITHM_DETERMINISTIC},
      key_id,
    )
    enc = Alumna::MongoAdapter::Encryption.new(
      key_vault_namespace: "keyvault.datakeys",
      local_master_key: key,
      fields: {"ssn" => "deterministic", "note" => "random"},
      schema_map: map,
      uri: "mongodb://127.0.0.1:27017",
      crypt_shared_lib_path: "/tmp/mongo_crypt_v1.so",
    )
    enc.key_vault_namespace.should eq("keyvault.datakeys")
    enc.local_master_key.should eq(key)
    enc.fields["ssn"].should eq(Alumna::MongoAdapter::Encryption::ALGORITHM_DETERMINISTIC)
    enc.fields["note"].should eq(Alumna::MongoAdapter::Encryption::ALGORITHM_RANDOM)
    enc.schema_map.should eq(map)
    enc.uri.should eq("mongodb://127.0.0.1:27017")
    enc.crypt_shared_lib_path.should eq("/tmp/mongo_crypt_v1.so")
  end

  it "close is a no-op when the adapter does not own the client" do
    adapter = mongo_adapter("wave26_close")
    adapter.close
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
    created["name"].should eq("Ada")
  end
end

{% if Mongo.has_constant?("AutoEncryption") && Mongo.has_constant?("ClientEncryption") %}
  describe "MongoAdapter client-side encryption" do
    shared = spec_crypt_shared
    if Mongo::ClientEncryption.lib_linked? && shared
      it "creates and finds a marked field as plaintext; storage is 0x06" do
        drop_collection("wave26_enc_people")
        drop_collection("wave26_enc_datakeys")
        key = master_key
        enc = Alumna::MongoAdapter::Encryption.new(
          key_vault_namespace: "#{TEST_DB}.wave26_enc_datakeys",
          local_master_key: key,
          fields: {"ssn" => "deterministic"},
          crypt_shared_lib_path: shared,
        )
        adapter = Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "wave26_enc_people", enc_schema, encryption: enc)
        begin
          created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada", ssn: "123-45-6789"))))
          created["ssn"].should eq("123-45-6789")
          created["ssn"].should be_a(String)
          created["name"].should eq("Ada")
          id = created["id"].as(String)

          got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
          got["ssn"].should eq("123-45-6789")
          got["name"].should eq("Ada")

          found = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"name" => "Ada"})))
          found.size.should eq(1)
          found[0]["ssn"].should eq("123-45-6789")

          oid = Alumna::MongoAdapter::Identity.parse?(id)
          oid.should be_a(BSON::ObjectId)
          if oid.is_a?(BSON::ObjectId)
            raw = SHARED_CLIENT[TEST_DB]["wave26_enc_people"].find_one(Alumna::MongoAdapter::Identity.filter(oid))
            raw.should_not be_nil
            if stored = raw
              ssn_encrypted?(stored).should be_true
              stored["name"].should eq("Ada")
            end
          end
        ensure
          adapter.close
          drop_collection("wave26_enc_people")
          drop_collection("wave26_enc_datakeys")
        end
      end

      it "reuses a data key, accepts schema_map plus uri, and Alumna.mongo passes encryption" do
        drop_collection("wave26_enc_reuse")
        drop_collection("wave26_enc_map")
        drop_collection("wave26_enc_reuse_keys")
        key = master_key
        vault = "#{TEST_DB}.wave26_enc_reuse_keys"
        crypt = shared
        unless crypt
          raise "crypt_shared path missing"
        end

        first = Alumna::MongoAdapter::Encryption.new(
          key_vault_namespace: vault,
          local_master_key: key,
          fields: {"ssn" => "deterministic"},
          uri: "",
          crypt_shared_lib_path: crypt,
        )
        adapter1 = Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "wave26_enc_reuse", enc_schema, encryption: first)
        adapter2 = nil.as(Alumna::MongoAdapter?)
        mapped = nil.as(Alumna::MongoAdapter?)
        begin
          created = as_hash(adapter1.create(ctx(adapter1, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Bob", ssn: "111-22-3333"))))
          created["ssn"].should eq("111-22-3333")

          again = Alumna::MongoAdapter::Encryption.new(
            key_vault_namespace: vault,
            local_master_key: key,
            fields: {"ssn" => "deterministic"},
            uri: MONGODB_URI,
            crypt_shared_lib_path: crypt,
          )
          adapter2 = Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "wave26_enc_reuse", enc_schema, encryption: again)
          got = as_hash(adapter2.get(ctx(adapter2, Alumna::ServiceMethod::Get, id: created["id"].as(String))))
          got["ssn"].should eq("111-22-3333")

          handle = Mongo::ClientEncryption.new(
            SHARED_CLIENT,
            key_vault_namespace: vault,
            kms_providers: Alumna::MongoAdapter::Encryption.local_kms(key),
          )
          key_id = begin
            docs = handle.get_keys
            id = nil.as(BSON::Binary?)
            docs.each do |doc|
              doc.each do |k, value, _code, subtype|
                next unless k == "_id"
                case value
                when UUID
                  id = BSON::Binary.new(value)
                when Bytes
                  st = subtype || BSON::Binary::SubType::UUID
                  id = BSON::Binary.new(st, value.clone)
                end
              end
            end
            id
          ensure
            handle.close
          end
          unless key_id
            raise "expected a data key in the vault"
          end
          map = Alumna::MongoAdapter::Encryption.schema_map("#{TEST_DB}.wave26_enc_map", {"ssn" => Alumna::MongoAdapter::Encryption::ALGORITHM_DETERMINISTIC}, key_id)
          mapped_opts = Alumna::MongoAdapter::Encryption.new(
            key_vault_namespace: vault,
            local_master_key: key,
            schema_map: map,
            uri: MONGODB_URI,
            crypt_shared_lib_path: crypt,
          )
          mapped = Alumna.mongo(SHARED_CLIENT, TEST_DB, "wave26_enc_map", enc_schema, encryption: mapped_opts) do
            create_indexes!
          end
          created_map = as_hash(mapped.create(ctx(mapped, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Cara", ssn: "999-88-7777"))))
          created_map["ssn"].should eq("999-88-7777")
        ensure
          adapter1.close
          adapter2.try(&.close)
          mapped.try(&.close)
          drop_collection("wave26_enc_reuse")
          drop_collection("wave26_enc_map")
          drop_collection("wave26_enc_reuse_keys")
        end
      end

      it "raises EncryptionError when crypt_shared_lib_path is not a file" do
        enc = Alumna::MongoAdapter::Encryption.new(
          key_vault_namespace: "#{TEST_DB}.wave26_missing_crypt",
          local_master_key: master_key,
          fields: {"ssn" => "deterministic"},
          crypt_shared_lib_path: "/no/such/mongo_crypt_v1.so",
        )
        expect_raises(Alumna::MongoAdapter::EncryptionError, /not found/) do
          Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "wave26_missing_crypt", enc_schema, encryption: enc)
        end
      end
    else
      it "skips live encryption when libmongocrypt or crypt_shared is missing" do
        # `true && nil` is nil. A missing .so must count as "not ready".
        (Mongo::ClientEncryption.lib_linked? && !shared.nil?).should be_false
      end
    end
  end
{% else %}
  describe "MongoAdapter client-side encryption without driver AutoEncryption" do
    it "raises EncryptionError from the constructor" do
      enc = Alumna::MongoAdapter::Encryption.new(
        key_vault_namespace: "keyvault.datakeys",
        local_master_key: master_key,
        fields: {"ssn" => "deterministic"},
      )
      expect_raises(Alumna::MongoAdapter::EncryptionError, /auto-encryption/) do
        Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "wave26_no_ae", enc_schema, encryption: enc)
      end
      expect_raises(Alumna::MongoAdapter::EncryptionError, /auto-encryption/) do
        Alumna.mongo(SHARED_CLIENT, TEST_DB, "wave26_no_ae_helper", enc_schema, encryption: enc)
      end
    end
  end
{% end %}
