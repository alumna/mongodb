require "../spec_helper"

private def uniqueness_schema
  Alumna::Schema.new(strict: false)
    .str("id", unique: true)
    .str("email", unique: true)
    .str("username", unique: true)
    .str("bio", required: false)
    .hash("profile", required: false) do |p|
      p.str("handle", required: false)
    end
    .int("tenant_id", required: false)
    .str("role", required: false)
    .index("profile.handle", unique: true)
    .index(["tenant_id", "role"], unique: true)
    .index("email")
    .index("_id")
    .index(["id", "_id"])
    .index([] of String)
    .index("role")
end

private def index_options(models : Array(BSON), name : String) : BSON
  models.each do |model|
    options = model["options"].as(BSON)
    return options if options["name"].as(String) == name
  end
  raise "missing index #{name}"
end

private def partial_type(options : BSON, field : String) : String
  options["partialFilterExpression"].as(BSON)[field].as(BSON)["$type"].as(String)
end

private def object_id_id(record : Hash(String, Alumna::AnyData)) : String
  id = record["id"].as(String)
  id.size.should eq(24)
  BSON::ObjectId.validate(id).should be_true
  id
end

describe Alumna::MongoAdapter::Indexes do
  it "builds stable names and skips id, empty, and duplicate key lists" do
    models, names = Alumna::MongoAdapter::Indexes.prepare("Wave6-idx", uniqueness_schema)
    names["uniq_Wave6_idx_email"].should eq("email")
    names["uniq_Wave6_idx_username"].should eq("username")
    names["uniq_Wave6_idx_profile_handle"].should eq("profile.handle")
    names["uniq_Wave6_idx_tenant_id_role"].should eq("tenant_id_role")
    names["idx_Wave6_idx_role"].should eq("role")
    names.has_key?("uniq_Wave6_idx_id").should be_false
    names.has_key?("idx_Wave6_idx__id").should be_false
    names.has_key?("idx_Wave6_idx_email").should be_false
    models.size.should eq(5)
    email_options = index_options(models, "uniq_Wave6_idx_email")
    email_options["unique"].as(Bool).should be_true
    email_options.has_key?("partialFilterExpression").should be_false

    empty_models, empty_names = Alumna::MongoAdapter::Indexes.prepare("none", sample_schema)
    empty_models.empty?.should be_true
    empty_names.empty?.should be_true

    id_only = Alumna::Schema.new
      .str("id", unique: true)
      .index("_id")
      .index([] of String)
      .index(["id", "_id"])
    skipped_models, skipped_names = Alumna::MongoAdapter::Indexes.prepare("onlyid", id_only)
    skipped_models.empty?.should be_true
    skipped_names.empty?.should be_true
  end

  it "creates indexes idempotently and enforces unique email, handle, and compound keys" do
    name = "wave6_idx"
    adapter = mongo_adapter(name, uniqueness_schema)
    adapter.create_indexes!
    adapter.create_indexes!

    first = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: {
      "email"     => "test@test.com",
      "username"  => "tester",
      "profile"   => {"handle" => "tester"} of String => Alumna::AnyData,
      "tenant_id" => 1_i64,
      "role"      => "admin",
    } of String => Alumna::AnyData)))
    id = object_id_id(first)

    email_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: {
      "email"     => "test@test.com",
      "username"  => "other",
      "profile"   => {"handle" => "other"} of String => Alumna::AnyData,
      "tenant_id" => 2_i64,
      "role"      => "user",
    } of String => Alumna::AnyData)))
    email_dup.status.should eq(422)
    email_dup.details["email"].should eq("already exists")

    handle_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: {
      "email"     => "other@test.com",
      "username"  => "other2",
      "profile"   => {"handle" => "tester"} of String => Alumna::AnyData,
      "tenant_id" => 2_i64,
      "role"      => "user",
    } of String => Alumna::AnyData)))
    handle_dup.status.should eq(422)
    handle_dup.details["profile.handle"].should eq("already exists")

    compound_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: {
      "email"     => "other2@test.com",
      "username"  => "other3",
      "profile"   => {"handle" => "tester3"} of String => Alumna::AnyData,
      "tenant_id" => 1_i64,
      "role"      => "admin",
    } of String => Alumna::AnyData)))
    compound_dup.status.should eq(422)
    compound_dup.details["tenant_id_role"].should eq("already exists")

    username_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: {
      "email"    => "bob@test.com",
      "username" => "tester",
    } of String => Alumna::AnyData)))
    username_dup.status.should eq(422)
    username_dup.details["username"].should eq("already exists")

    self_update = as_hash(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: id, data: {
      "email"     => "test@test.com",
      "username"  => "tester",
      "profile"   => {"handle" => "tester"} of String => Alumna::AnyData,
      "tenant_id" => 1_i64,
      "role"      => "admin",
    } of String => Alumna::AnyData)))
    self_update["email"].should eq("test@test.com")

    same_unique_patch = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(email: "test@test.com", bio: "new bio"))))
    same_unique_patch["bio"].should eq("new bio")
    same_unique_patch["email"].should eq("test@test.com")

    bio_only = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(bio: "still me"))))
    bio_only["bio"].should eq("still me")

    second = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: {
      "email"     => "bob@test.com",
      "username"  => "bob",
      "profile"   => {"handle" => "bob"} of String => Alumna::AnyData,
      "tenant_id" => 2_i64,
      "role"      => "user",
    } of String => Alumna::AnyData)))
    id2 = object_id_id(second)

    steal_patch = as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id2, data: Alumna.hash(email: "test@test.com"))))
    steal_patch.status.should eq(422)
    steal_patch.details["email"].should eq("already exists")

    steal_update = as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: id2, data: {
      "email"     => "test@test.com",
      "username"  => "bob",
      "profile"   => {"handle" => "bob"} of String => Alumna::AnyData,
      "tenant_id" => 2_i64,
      "role"      => "user",
    } of String => Alumna::AnyData)))
    steal_update.status.should eq(422)
    steal_update.details["email"].should eq("already exists")
  end

  it "returns 422 when a second document omits the same unique field" do
    name = "wave6_null_unique"
    schema = Alumna::Schema.new(strict: false)
      .str("email", unique: true, required: false)
      .str("name", required: false)
    adapter = mongo_adapter(name, schema)
    adapter.create_indexes!

    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
    dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Bob"))))
    dup.status.should eq(422)
    dup.details["email"].should eq("already exists")
  end

  it "unsets a unique field unless another document already omits it" do
    name = "wave15_unset_unique"
    schema = Alumna::Schema.new(strict: false)
      .str("email", unique: true, required: false)
      .str("name", required: false)
    adapter = mongo_adapter(name, schema)
    adapter.create_indexes!

    first = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada", email: "ada@test.com"))))
    id = object_id_id(first)
    cleared = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => "email".as(Alumna::AnyData)})))
    cleared.has_key?("email").should be_false
    got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    got.has_key?("email").should be_false

    second = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Bob", email: "bob@test.com"))))
    id2 = object_id_id(second)
    clash = as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id2, data: {"$unset" => "email".as(Alumna::AnyData)})))
    clash.status.should eq(422)
    clash.details["email"].should eq("already exists")
  end

  it "builds a partial filter from the field type and keeps the first key list" do
    schema = Alumna::Schema.new(strict: false)
      .str("email", unique: true)
      .str("phone_pair", unique: true, required: false, partial: true)
      .int("rank", unique: true, required: false, partial: true)
      .bool("flag", unique: true, required: false, partial: true)
      .time("seen_at", unique: true, required: false, partial: true)
      .bytes("blob", unique: true, required: false, partial: true)
      .hash("profile", required: false) do |profile|
        profile.str("handle", unique: true, required: false, partial: true)
      end
      .int("tenant_id", required: false)
      .str("role", required: false)
      .index("email", unique: true, partial: true)
      .index(["tenant_id", "role"], unique: true, partial: true)

    models, names = Alumna::MongoAdapter::Indexes.prepare("partials", schema)
    names["uniq_partials_phone_pair"].should eq("phone_pair")
    phone = index_options(models, "uniq_partials_phone_pair")
    partial_type(phone, "phone_pair").should eq("string")
    partial_type(index_options(models, "uniq_partials_rank"), "rank").should eq("long")
    partial_type(index_options(models, "uniq_partials_flag"), "flag").should eq("bool")
    partial_type(index_options(models, "uniq_partials_seen_at"), "seen_at").should eq("date")
    partial_type(index_options(models, "uniq_partials_blob"), "blob").should eq("binData")
    partial_type(index_options(models, "uniq_partials_profile_handle"), "profile.handle").should eq("string")

    compound = index_options(models, "uniq_partials_tenant_id_role")
    partial_type(compound, "tenant_id").should eq("long")
    partial_type(compound, "role").should eq("string")

    # The field index is first. The later schema.index does not replace it.
    index_options(models, "uniq_partials_email").has_key?("partialFilterExpression").should be_false

    expect_raises(ArgumentError, "partial index field missing is not on the schema") do
      missing = Alumna::Schema.new(strict: false).index("missing", unique: true, partial: true)
      Alumna::MongoAdapter::Indexes.prepare("missing", missing)
    end

    ["float", "any", "hash", "array"].each do |kind|
      bad = Alumna::Schema.new(strict: false)
      case kind
      when "float" then bad.float("score", unique: true, partial: true)
      when "any"   then bad.any("score", unique: true, partial: true)
      when "hash"  then bad.field("score", :hash, unique: true, partial: true)
      else              bad.field("score", :array, unique: true, partial: true)
      end
      expect_raises(ArgumentError, /partial index score does not support/) do
        Alumna::MongoAdapter::Indexes.prepare("bad_#{kind}", bad)
      end
    end
  end

  it "allows many omitted partial values and still rejects a repeated string" do
    name = "wave_partial_unique"
    schema = Alumna::Schema.new(strict: false)
      .str("name", required: false)
      .str("phone_pair", unique: true, required: false, partial: true)
      .int("rank", unique: true, required: false, partial: true)
      .bool("flag", unique: true, required: false, partial: true)
      .time("seen_at", unique: true, required: false, partial: true)
      .bytes("blob", unique: true, required: false, partial: true)
      .int("tenant_id", required: false)
      .str("role", required: false)
      .index(["tenant_id", "role"], unique: true, partial: true)
    adapter = mongo_adapter(name, schema)
    adapter.create_indexes!
    adapter.create_indexes!

    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Omit1"))))
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Omit2"))))
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Null1", phone_pair: nil))))
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Null2", phone_pair: nil))))

    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Empty1", phone_pair: ""))))
    empty_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Empty2", phone_pair: ""))))
    empty_dup.status.should eq(422)
    empty_dup.details["phone_pair"].should eq("already exists")

    kept = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Kept", phone_pair: "BR:11999990000"))))
    kept_id = object_id_id(kept)
    phone_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Dup", phone_pair: "BR:11999990000"))))
    phone_dup.status.should eq(422)
    phone_dup.details["phone_pair"].should eq("already exists")

    other = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Other", phone_pair: "BR:11888880000"))))
    other_id = object_id_id(other)
    steal = as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: other_id, data: Alumna.hash(phone_pair: "BR:11999990000"))))
    steal.status.should eq(422)
    steal.details["phone_pair"].should eq("already exists")

    cleared = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: kept_id, data: {"$unset" => "phone_pair".as(Alumna::AnyData)})))
    cleared.has_key?("phone_pair").should be_false

    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Rank", rank: 1))))
    rank_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "RankDup", rank: 1))))
    rank_dup.details["rank"].should eq("already exists")

    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Flag", flag: true))))
    flag_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "FlagDup", flag: true))))
    flag_dup.details["flag"].should eq("already exists")

    at = Time.utc(2026, 10, 21, 12, 0, 0)
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "When", seen_at: at))))
    time_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "WhenDup", seen_at: at))))
    time_dup.details["seen_at"].should eq("already exists")

    blob = Bytes[1_u8, 2_u8, 3_u8]
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Blob", blob: blob))))
    blob_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "BlobDup", blob: blob))))
    blob_dup.details["blob"].should eq("already exists")

    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Member", tenant_id: 1, role: "admin"))))
    compound_dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "MemberDup", tenant_id: 1, role: "admin"))))
    compound_dup.details["tenant_id_role"].should eq("already exists")
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "TenantOnly", tenant_id: 1))))
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "TenantOnly2", tenant_id: 1))))
  end
end
