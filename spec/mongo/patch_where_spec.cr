require "../spec_helper"

describe "MongoAdapter#patch_where" do
  it "rejects an empty match, a bad id, and a field that is not on the schema" do
    adapter = mongo_adapter("wave_patch_where_reject")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada", status: "requested"))))
    id = created["id"].as(String)

    empty = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Grace")), {} of String => Alumna::AnyData))
    empty.status.should eq(400)
    empty.message.should eq("Match is empty")

    no_id = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, data: Alumna.hash(name: "Grace")), {"status" => "requested"}))
    no_id.status.should eq(400)

    bad = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: "99", data: Alumna.hash(name: "Grace")), {"status" => "requested"}))
    bad.status.should eq(404)

    missing = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: BSON::ObjectId.new.to_s, data: Alumna.hash(name: "Grace")), {"status" => "requested"}))
    missing.status.should eq(404)

    id_key = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Grace")), {"id" => id}))
    id_key.status.should eq(400)
    id_key.message.should eq("Match field is not allowed")

    oid_key = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Grace")), {"_id" => id}))
    oid_key.status.should eq(400)

    unknown = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Grace")), {"nope" => "x"}))
    unknown.status.should eq(400)
    unknown.message.should eq("Unknown match field: nope")

    bad_unset = {"status" => "closed", "$unset" => 1_i64} of String => Alumna::AnyData
    unset_err = as_error(adapter.patch_where(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: bad_unset), {"status" => "requested"}))
    unset_err.status.should eq(400)

    bad_path = as_error(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"user.nope" => "x".as(Alumna::AnyData)}),
      {"status" => "requested"},
    ))
    bad_path.status.should eq(400)

    kept = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    kept["name"].should eq("Ada")
    kept["status"].should eq("requested")
  end

  it "patches only when every equality matches and leaves the row when the count is 0" do
    adapter = mongo_adapter("wave_patch_where_match")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada", status: "requested", age: 1_i64))))
    id = created["id"].as(String)

    missed = as_error(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Grace")),
      {"status" => "closed"},
    ))
    missed.status.should eq(404)
    still = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    still["name"].should eq("Ada")
    still["status"].should eq("requested")

    empty_miss = as_error(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {} of String => Alumna::AnyData),
      {"status" => "closed"},
    ))
    empty_miss.status.should eq(404)

    same = as_hash(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {} of String => Alumna::AnyData),
      {"status" => "requested"},
    ))
    same["name"].should eq("Ada")

    patched = as_hash(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Grace", age: 2_i64)),
      {"status" => "requested"},
    ))
    patched["name"].should eq("Grace")
    patched["age"].should eq(2_i64)
    patched["status"].should eq("requested")
    patched["id"].should eq(id)

    stored = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    stored["name"].should eq("Grace")
  end

  it "matches a nested path and can unset in the same write" do
    adapter = mongo_adapter("wave_patch_where_nested")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "Keep",
      status: "requested",
      user: Alumna.hash(name: "Ada", age: 3_i64),
    ))))
    id = created["id"].as(String)

    nested_miss = as_error(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Nope")),
      {"user.name" => "Bob"},
    ))
    nested_miss.status.should eq(404)

    bad_path = as_error(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Nope")),
      {"user.nope" => "x"},
    ))
    bad_path.status.should eq(400)

    unset = {"status" => "closed"} of String => Alumna::AnyData
    unset["$unset"] = ["name"] of Alumna::AnyData
    patched = as_hash(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: unset),
      {"user.name" => "Ada"},
    ))
    patched.has_key?("name").should be_false
    patched["status"].should eq("closed")
    patched["user"].as(Hash(String, Alumna::AnyData))["name"].should eq("Ada")

    gone = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    gone.has_key?("name").should be_false
  end

  it "maps a unique-index failure and does not apply that write" do
    schema = Alumna::Schema.new(strict: false)
      .str("email", unique: true)
      .str("status", required: false)
      .str("name", required: false)
    adapter = mongo_adapter("wave_patch_where_unique", schema)
    adapter.create_indexes!

    first = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "a@test.com", name: "Ada", status: "requested"))))
    second = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "b@test.com", name: "Bob", status: "requested"))))
    id = second["id"].as(String)

    dup = as_error(adapter.patch_where(
      ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(email: "a@test.com")),
      {"status" => "requested"},
    ))
    dup.status.should eq(422)

    kept = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    kept["email"].should eq("b@test.com")
    first["email"].should eq("a@test.com")
  end
end
