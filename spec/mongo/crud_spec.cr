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
    dotted_patch = as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: {"user.name" => "Nope".as(Alumna::AnyData)})))
    dotted_patch.status.should eq(400)

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
end
