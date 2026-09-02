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
end
