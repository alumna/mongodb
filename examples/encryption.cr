require "random/secure"
require "./support"

# Opt-in FLE1, local KMS. Service methods stay the same.
# "deterministic" keeps equality filters working. "random" does not.
# The shorthand marks string fields. The master key is 96 bytes.
# #close closes the client this adapter opened. It does not close Examples.client.

PeopleSchema = Alumna::Schema.new
  .str("name")
  .str("ssn", required: false)
  .str("note", required: false)

key = Random::Secure.random_bytes(96)
shared = Examples.crypt_shared
people = Alumna.mongo(
  Examples.client, Examples::DB, "people", PeopleSchema,
  encryption: Alumna::MongoAdapter::Encryption.new(
    key_vault_namespace: "#{Examples::DB}.datakeys",
    local_master_key: key,
    fields: {"ssn" => "deterministic", "note" => "random"},
    crypt_shared_lib_path: shared,
  ),
)

begin
  created = people.create(Alumna::Testing.build_ctx(
    service: people,
    method: Alumna::ServiceMethod::Create,
    data: Alumna.hash(name: "Ada", ssn: "123-45-6789", note: "hello"),
  ))
  raise created.message if created.is_a?(Alumna::ServiceError)
  raise "decrypted ssn" unless created["ssn"] == "123-45-6789"

  again = people.create(Alumna::Testing.build_ctx(
    service: people,
    method: Alumna::ServiceMethod::Create,
    data: Alumna.hash(name: "Bea", ssn: "123-45-6789", note: "hello"),
  ))
  raise again.message if again.is_a?(Alumna::ServiceError)

  ssns = [] of Bytes
  notes = [] of Bytes
  Examples.client[Examples::DB]["people"].find { |doc|
    doc.each do |field, value, code, subtype|
      next unless value.is_a?(Bytes) && code.binary? && subtype.try(&.encrypted_bson?)
      ssns << value if field == "ssn"
      notes << value if field == "note"
    end
  }
  raise "deterministic ssn" unless ssns.size == 2 && ssns[0] == ssns[1]
  raise "random note" unless notes.size == 2 && notes[0] != notes[1]
ensure
  people.close
end

begin
  Alumna.mongo(
    Examples.client, Examples::DB, "missing", PeopleSchema,
    encryption: Alumna::MongoAdapter::Encryption.new(
      key_vault_namespace: "#{Examples::DB}.datakeys",
      local_master_key: key,
      fields: {"ssn" => "deterministic"},
      crypt_shared_lib_path: "/no/such/mongo_crypt_v1.so",
    ),
  )
  raise "missing library should raise"
rescue ex : Alumna::MongoAdapter::EncryptionError
  message = ex.message || ""
  raise message unless message.includes?("not found")
end

puts "encryption ok path=#{shared}"
