require "../spec_helper"

describe "MongoAdapter CRUD" do
  it "returns nil from get when id is nil, invalid, or unknown" do
    adapter = mongo_adapter("wave4_get")
    adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: nil)).should be_nil
    adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: "99")).should be_nil
    missing = BSON::ObjectId.new.to_s
    adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: missing)).should be_nil
  end

  it "creates, replaces, patches, and removes" do
    adapter = mongo_adapter("wave4_writes")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(id: "99", name: "Ada", age: 42_i64))))
    id = created["id"].as(String)
    created["name"].should eq("Ada")

    dotted_update = as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: id, data: {"user.name" => "Nope".as(Alumna::AnyData)})))
    dotted_update.status.should eq(400)

    no_id_update = as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, data: Alumna.hash(name: "x"))))
    no_id_update.status.should eq(400)
    as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: "99", data: Alumna.hash(name: "x")))).status.should eq(404)
    as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: BSON::ObjectId.new.to_s, data: Alumna.hash(name: "x")))).status.should eq(404)

    replaced = as_hash(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: id, data: Alumna.hash(id: id, _id: "x", name: "OnlyName"))))
    replaced["name"].should eq("OnlyName")
    replaced.has_key?("age").should be_false
    replaced["id"].should eq(id)

    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, data: Alumna.hash(name: "x")))).status.should eq(400)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: "99", data: Alumna.hash(name: "x")))).status.should eq(404)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: BSON::ObjectId.new.to_s, data: Alumna.hash(name: "x")))).status.should eq(404)

    empty = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(id: id))))
    empty["name"].should eq("OnlyName")
    empty_id = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"_id" => "x".as(Alumna::AnyData)})))
    empty_id["name"].should eq("OnlyName")
    none = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {} of String => Alumna::AnyData)))
    none["name"].should eq("OnlyName")

    patched = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(id: id, name: "Grace", age: 1_i64))))
    patched["name"].should eq("Grace")
    patched["age"].should eq(1_i64)
    patched["id"].should eq(id)

    as_error(adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove))).status.should eq(400)
    as_error(adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove, id: "99"))).status.should eq(404)
    as_error(adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove, id: BSON::ObjectId.new.to_s))).status.should eq(404)

    adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove, id: id)).should be_nil
    adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)).should be_nil
  end

  it "finds an empty collection and applies skip, limit, sort, and select" do
    adapter = mongo_adapter("wave4_find")
    as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find))).should be_empty

    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Bob", age: 2_i64)))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Cara", age: 3_i64)))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada", age: 1_i64)))

    all = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find)))
    all.size.should eq(3)

    sorted = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "name:1"})))
    sorted.map { |r| r["name"] }.should eq(["Ada".as(Alumna::AnyData), "Bob".as(Alumna::AnyData), "Cara".as(Alumna::AnyData)])

    by_id = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "id:1"})))
    by_id.size.should eq(3)

    by_oid = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "_id:-1"})))
    by_oid.size.should eq(3)

    page = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "name:1", "$skip" => "1", "$limit" => "1"})))
    page.size.should eq(1)
    page[0]["name"].should eq("Bob")

    past = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$skip" => "50"})))
    past.should be_empty

    selected = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$select" => "id,_id,name", "$sort" => "name:1", "$limit" => "1"})))
    selected.size.should eq(1)
    selected[0].has_key?("id").should be_true
    selected[0].has_key?("name").should be_true
    selected[0].has_key?("age").should be_false

    as_error(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "nope:1"}))).status.should eq(400)
    as_error(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$select" => "nope"}))).status.should eq(400)
    as_error(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"age" => "nope"}))).status.should eq(400)
    as_error(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"nope" => "1"}))).status.should eq(400)

    empty = Hash(String, Array(Alumna::Query::TypedCondition)).new
    Alumna::MongoAdapter::Query.filter_bson(empty, sample_schema).should eq(Alumna::MongoAdapter::Query::EMPTY)
  end

  it "clamps $limit when max_limit is set and leaves it alone when not" do
    capped = mongo_adapter("wave4_max_limit", max_limit: 1)
    capped.create(ctx(capped, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "a")))
    capped.create(ctx(capped, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "b")))
    high = as_list(capped.find(ctx(capped, Alumna::ServiceMethod::Find, params: {"$limit" => "10"})))
    high.size.should eq(1)
    low = as_list(capped.find(ctx(capped, Alumna::ServiceMethod::Find, params: {"$limit" => "1"})))
    low.size.should eq(1)

    open = mongo_adapter("wave4_no_max_limit")
    open.create(ctx(open, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "a")))
    open.create(ctx(open, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "b")))
    both = as_list(open.find(ctx(open, Alumna::ServiceMethod::Find, params: {"$limit" => "10"})))
    both.size.should eq(2)
  end

  it "patches a nested schema path and keeps other nested fields" do
    adapter = mongo_adapter("wave14_nested_patch")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "KeepMe",
      user: Alumna.hash(name: "Bob", age: 30_i64),
    ))))
    id = created["id"].as(String)

    nested_set = {} of String => Alumna::AnyData
    nested_set["id"] = id
    nested_set["user.name"] = "Ada"
    patched = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: nested_set)))
    patched.has_key?("user.name").should be_false
    nested = patched["user"].as(Hash(String, Alumna::AnyData))
    nested["name"].should eq("Ada")
    nested["age"].should eq(30_i64)
    patched["name"].should eq("KeepMe")

    got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    got_user = got["user"].as(Hash(String, Alumna::AnyData))
    got_user["name"].should eq("Ada")
    got_user["age"].should eq(30_i64)

    found = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"user.name" => "Ada"})))
    found.size.should eq(1)
    found[0]["user"].as(Hash(String, Alumna::AnyData))["name"].should eq("Ada")

    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"nope.x" => "x".as(Alumna::AnyData)}))).status.should eq(400)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"user.nope" => "x".as(Alumna::AnyData)}))).status.should eq(400)
  end

  it "creates a nested hash when patch $set walks a missing parent" do
    adapter = mongo_adapter("wave14_nested_create_path")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Solo"))))
    id = created["id"].as(String)

    create_path = {} of String => Alumna::AnyData
    create_path["_id"] = "x"
    create_path["user.name"] = "Ada"
    create_path["age"] = 1_i64
    patched = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: create_path)))
    patched.has_key?("user.name").should be_false
    nested = patched["user"].as(Hash(String, Alumna::AnyData))
    nested["name"].should eq("Ada")
    nested.has_key?("age").should be_false
    patched["name"].should eq("Solo")
    patched["age"].should eq(1_i64)

    got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    got_user = got["user"].as(Hash(String, Alumna::AnyData))
    got_user["name"].should eq("Ada")
    got["age"].should eq(1_i64)
  end

  it "unsets a nested schema path and keeps other nested fields" do
    adapter = mongo_adapter("wave15_nested_unset")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "KeepMe",
      user: Alumna.hash(name: "Bob", age: 30_i64),
    ))))
    id = created["id"].as(String)

    unset_one = {} of String => Alumna::AnyData
    unset_one["$unset"] = "user.age"
    patched = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: unset_one)))
    patched.has_key?("user.age").should be_false
    nested = patched["user"].as(Hash(String, Alumna::AnyData))
    nested.has_key?("age").should be_false
    nested["name"].should eq("Bob")
    patched["name"].should eq("KeepMe")

    got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    got_user = got["user"].as(Hash(String, Alumna::AnyData))
    got_user.has_key?("age").should be_false
    got_user["name"].should eq("Bob")

    # Last nested field: parent hash stays empty. Do not delete the parent.
    only_age = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "Leaf",
      user: Alumna.hash(age: 1_i64),
    ))))
    leaf_id = only_age["id"].as(String)
    cleared = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: leaf_id, data: {"$unset" => "user.age".as(Alumna::AnyData)})))
    cleared["user"].as(Hash(String, Alumna::AnyData)).should be_empty
    got_leaf = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: leaf_id)))
    got_leaf["user"].as(Hash(String, Alumna::AnyData)).should be_empty

    # Schema path exists but the parent is missing: `$unset` is a no-op.
    solo = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Solo"))))
    solo_id = solo["id"].as(String)
    noop = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: solo_id, data: {"$unset" => "user.age".as(Alumna::AnyData)})))
    noop["name"].should eq("Solo")
    noop.has_key?("user").should be_false
  end

  it "sets and unsets in the same patch" do
    adapter = mongo_adapter("wave15_set_and_unset")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "KeepMe",
      age: 9_i64,
      user: Alumna.hash(name: "Bob", age: 30_i64),
    ))))
    id = created["id"].as(String)

    both = {} of String => Alumna::AnyData
    both["name"] = "Grace"
    both["$unset"] = ["user.age", "age"] of Alumna::AnyData
    patched = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: both)))
    patched["name"].should eq("Grace")
    patched.has_key?("age").should be_false
    nested = patched["user"].as(Hash(String, Alumna::AnyData))
    nested["name"].should eq("Bob")
    nested.has_key?("age").should be_false

    got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    got["name"].should eq("Grace")
    got.has_key?("age").should be_false
    got["user"].as(Hash(String, Alumna::AnyData)).has_key?("age").should be_false
  end

  it "rejects unknown or invalid $unset and treats empty $unset as a no-op" do
    adapter = mongo_adapter("wave15_unset_errors")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "Ada",
      user: Alumna.hash(name: "Bob", age: 30_i64),
    ))))
    id = created["id"].as(String)

    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => "nope.x".as(Alumna::AnyData)}))).status.should eq(400)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => "user.nope".as(Alumna::AnyData)}))).status.should eq(400)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => nil.as(Alumna::AnyData)}))).status.should eq(400)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => 1_i64.as(Alumna::AnyData)}))).status.should eq(400)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => (["user.age", 1_i64] of Alumna::AnyData).as(Alumna::AnyData)}))).status.should eq(400)

    empty_list = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => ([] of Alumna::AnyData).as(Alumna::AnyData)})))
    empty_list["name"].should eq("Ada")
    empty_list["user"].as(Hash(String, Alumna::AnyData))["age"].should eq(30_i64)

    still_set = {} of String => Alumna::AnyData
    still_set["$unset"] = [] of Alumna::AnyData
    still_set["name"] = "Grace"
    named = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: still_set)))
    named["name"].should eq("Grace")
    named["user"].as(Hash(String, Alumna::AnyData))["age"].should eq(30_i64)

    id_only = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => "id".as(Alumna::AnyData)})))
    id_only["name"].should eq("Grace")
    oid_only = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"$unset" => "_id".as(Alumna::AnyData)})))
    oid_only["name"].should eq("Grace")

    strip_ids = {} of String => Alumna::AnyData
    strip_ids["$unset"] = ["id", "_id", "user.age"] of Alumna::AnyData
    stripped = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: strip_ids)))
    stripped["user"].as(Hash(String, Alumna::AnyData)).has_key?("age").should be_false
    stripped["user"].as(Hash(String, Alumna::AnyData))["name"].should eq("Bob")
  end

  it "sets JSON null on a nested field and does not unset it" do
    adapter = mongo_adapter("wave15_null_is_set")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(
      name: "KeepMe",
      user: Alumna.hash(name: "Bob", age: 30_i64),
    ))))
    id = created["id"].as(String)

    set_null = {} of String => Alumna::AnyData
    set_null["user.name"] = nil
    patched = as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: set_null)))
    nested = patched["user"].as(Hash(String, Alumna::AnyData))
    nested.has_key?("name").should be_true
    nested["name"].should be_nil
    nested["age"].should eq(30_i64)

    got = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    got_user = got["user"].as(Hash(String, Alumna::AnyData))
    got_user.has_key?("name").should be_true
    got_user["name"].should be_nil
    got_user["age"].should eq(30_i64)
  end
end
