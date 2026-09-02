require "../spec_helper"

private def filter_of(params : Hash(String, String))
  adapter = mongo_adapter("wave5_filter_shape")
  q = ctx(adapter, Alumna::ServiceMethod::Find, params: params).query
  typed = q.typed_filters(sample_schema)
  typed.should be_a(Hash(String, Array(Alumna::Query::TypedCondition)))
  Alumna::MongoAdapter::Query.filter_bson(typed.as(Hash(String, Array(Alumna::Query::TypedCondition))), sample_schema)
end

private def names(rows : Array(Hash(String, Alumna::AnyData)))
  rows.map { |r| r["name"] }
end

describe "MongoAdapter Query.filter_bson" do
  it "returns EMPTY when there are no filters" do
    empty = Hash(String, Array(Alumna::Query::TypedCondition)).new
    Alumna::MongoAdapter::Query.filter_bson(empty, sample_schema).should eq(Alumna::MongoAdapter::Query::EMPTY)
  end

  it "rejects unknown fields with 400" do
    filters = Hash(String, Array(Alumna::Query::TypedCondition)).new
    filters["nope"] = [Alumna::Query::TypedCondition.new(Alumna::Query::Op::Eq, "x", nil)]
    err = Alumna::MongoAdapter::Query.filter_bson(filters, sample_schema)
    err.should be_a(Alumna::ServiceError)
    if err.is_a?(Alumna::ServiceError)
      err.status.should eq(400)
    end
  end

  it "encodes $eq as a plain field and other ops as operator documents" do
    eq = filter_of({"name" => "Ada"})
    eq.should be_a(BSON)
    if eq.is_a?(BSON)
      eq["name"].should eq("Ada")
    end

    ne = filter_of({"name[$ne]" => "Ada"})
    ne.should be_a(BSON)
    if ne.is_a?(BSON)
      ne["name"].as(BSON)["$ne"].should eq("Ada")
    end
  end

  it "encodes comparison, $in, and $nin operators" do
    cmp = filter_of({"age[$gt]" => "1", "age[$gte]" => "2", "age[$lt]" => "9", "age[$lte]" => "8"})
    cmp.should be_a(BSON)
    if cmp.is_a?(BSON)
      age = cmp["age"].as(BSON)
      age["$gt"].should eq(1_i64)
      age["$gte"].should eq(2_i64)
      age["$lt"].should eq(9_i64)
      age["$lte"].should eq(8_i64)
    end

    inn = filter_of({"name[$in]" => "Ada,Bob"})
    inn.should be_a(BSON)
    if inn.is_a?(BSON)
      inn["name"].as(BSON)["$in"].should be_a(BSON)
    end

    nin = filter_of({"name[$nin]" => "Ada"})
    nin.should be_a(BSON)
    if nin.is_a?(BSON)
      nin["name"].as(BSON)["$nin"].should be_a(BSON)
    end
  end

  it "maps id and _id to ObjectId _id, and leaves invalid hex as a string" do
    hex = BSON::ObjectId.new.to_s
    oid = filter_of({"id" => hex})
    oid.should be_a(BSON)
    if oid.is_a?(BSON)
      oid["_id"].should eq(BSON::ObjectId.new(hex))
    end

    alt = filter_of({"_id" => hex})
    alt.should be_a(BSON)
    if alt.is_a?(BSON)
      alt["_id"].should eq(BSON::ObjectId.new(hex))
    end

    bad = filter_of({"id" => "99"})
    bad.should be_a(BSON)
    if bad.is_a?(BSON)
      bad["_id"].should eq("99")
    end
  end

  it "encodes id $in with ObjectIds, strings, other types, and more than 128 values" do
    hex = BSON::ObjectId.new.to_s
    items = Array(Alumna::AnyData).new(129)
    items << hex
    items << "99"
    items << 1_i64
    126.times { items << "x" }

    filters = Hash(String, Array(Alumna::Query::TypedCondition)).new
    filters["id"] = [Alumna::Query::TypedCondition.new(Alumna::Query::Op::In, items, nil)]
    bson = Alumna::MongoAdapter::Query.filter_bson(filters, sample_schema)
    bson.should be_a(BSON)
    if bson.is_a?(BSON)
      arr = bson["_id"].as(BSON)["$in"].as(BSON)
      arr["0"].should eq(BSON::ObjectId.new(hex))
      arr["1"].should eq("99")
      arr["2"].should eq(1_i64)
      arr["128"].should eq("x")
    end
  end

  it "writes a non-string id $eq through BsonWrite" do
    filters = Hash(String, Array(Alumna::Query::TypedCondition)).new
    filters["id"] = [Alumna::Query::TypedCondition.new(Alumna::Query::Op::Eq, 1_i64, nil)]
    bson = Alumna::MongoAdapter::Query.filter_bson(filters, sample_schema)
    bson.should be_a(BSON)
    if bson.is_a?(BSON)
      bson["_id"].should eq(1_i64)
    end
  end

  it "ANDs $eq with another operator on the same field using $eq" do
    name_fd = sample_schema.find_field("name")
    filters = Hash(String, Array(Alumna::Query::TypedCondition)).new
    filters["name"] = [
      Alumna::Query::TypedCondition.new(Alumna::Query::Op::Eq, "Ada", name_fd),
      Alumna::Query::TypedCondition.new(Alumna::Query::Op::Ne, "Bob", name_fd),
    ]
    bson = Alumna::MongoAdapter::Query.filter_bson(filters, sample_schema)
    bson.should be_a(BSON)
    if bson.is_a?(BSON)
      inner = bson["name"].as(BSON)
      inner["$eq"].should eq("Ada")
      inner["$ne"].should eq("Bob")
    end
  end
end

describe "MongoAdapter find query operators" do
  it "filters nested user.name and sorts nested user.age" do
    adapter = mongo_adapter("wave5_nested")
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(user: Alumna.hash(name: "Alice", age: 40_i64))))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(user: Alumna.hash(name: "Bob", age: 30_i64))))

    found = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"user.name" => "Bob"})))
    found.size.should eq(1)
    found[0]["user"].as(Hash(String, Alumna::AnyData))["name"].should eq("Bob")

    sorted = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "user.age:1"})))
    sorted.size.should eq(2)
    sorted[0]["user"].as(Hash(String, Alumna::AnyData))["age"].should eq(30_i64)
  end

  it "matches tags $eq/$ne/$in/$nin the same way as MemoryAdapter" do
    adapter = mongo_adapter("wave5_tags")
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "has-tech", tags: ["tech", "science"].to_any)))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "art", tags: ["art"].to_any)))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "science", tags: ["science"].to_any)))

    eq = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"tags" => "tech"})))
    names(eq).should eq(["has-tech".as(Alumna::AnyData)])

    ne = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"tags[$ne]" => "tech", "$sort" => "name:1"})))
    names(ne).should eq(["art".as(Alumna::AnyData), "science".as(Alumna::AnyData)])

    inn = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"tags[$in]" => "tech,art", "$sort" => "name:1"})))
    names(inn).should eq(["art".as(Alumna::AnyData), "has-tech".as(Alumna::AnyData)])

    nin = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"tags[$nin]" => "tech", "$sort" => "name:1"})))
    names(nin).should eq(["art".as(Alumna::AnyData), "science".as(Alumna::AnyData)])
  end

  it "filters Time, Bool, Float, Int, and String operators" do
    adapter = mongo_adapter("wave5_types")
    t1 = Time.utc(2024, 1, 1, 12, 0, 0)
    t2 = Time.utc(2024, 1, 2, 12, 0, 0)
    t3 = Time.utc(2024, 2, 1)
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "a", age: 10_i64, score: 3.5_f64, active: true, created: t1, grade: "a")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "b", age: 20_i64, score: 4.5_f64, active: false, created: t2, grade: "b")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "c", age: 30_i64, score: 5.0_f64, active: true, created: t3, grade: "c")))

    age = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"age[$gt]" => "15", "age[$lt]" => "25"})))
    age.size.should eq(1)
    age[0]["age"].should eq(20_i64)

    gte = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"age[$gte]" => "20", "age[$lte]" => "30", "$sort" => "age:1"})))
    gte.map { |r| r["age"] }.should eq([20_i64, 30_i64])

    score = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"score[$gt]" => "4.0", "score[$lt]" => "4.9"})))
    score.size.should eq(1)
    score[0]["score"].should eq(4.5)

    grade = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"grade[$gt]" => "a", "grade[$lt]" => "c"})))
    grade.size.should eq(1)
    grade[0]["grade"].should eq("b")

    bool_gt = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"active[$gt]" => "false"})))
    bool_gt.size.should eq(2)
    bool_gt.each { |r| r["active"].should eq(true) }

    bool_lt = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"active[$lt]" => "true"})))
    bool_lt.size.should eq(1)
    bool_lt[0]["active"].should eq(false)

    created = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"created[$gt]" => "2024-01-15T00:00:00Z", "created[$lt]" => "2024-02-15T00:00:00Z"})))
    created.size.should eq(1)
    created[0]["created"].should eq(t3)

    created_eq = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"created" => "2024-01-01T12:00:00Z"})))
    created_eq.size.should eq(1)
    created_eq[0]["created"].should eq(t1)

    created_in = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"created[$in]" => "2024-01-01T12:00:00Z,2024-01-02T12:00:00Z"})))
    created_in.size.should eq(2)

    created_ne = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"created[$ne]" => "2024-01-01T12:00:00Z"})))
    created_ne.size.should eq(2)

    created_nin = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"created[$nin]" => "2024-01-01T12:00:00Z"})))
    created_nin.size.should eq(2)
  end

  it "ANDs multiple fields and returns empty for empty $in" do
    adapter = mongo_adapter("wave5_and_in")
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(role: "admin", active: true, name: "a")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(role: "admin", active: false, name: "b")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(role: "user", active: true, name: "c")))

    both = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"role" => "admin", "active" => "true"})))
    both.size.should eq(1)
    both[0]["name"].should eq("a")

    none = ctx(adapter, Alumna::ServiceMethod::Find)
    none.query.filters["name"] << Alumna::Query::Condition.new(Alumna::Query::Op::In, [] of String)
    as_list(adapter.find(none)).should be_empty
  end

  it "filters scalar $in and $nin" do
    adapter = mongo_adapter("wave5_in_nin")
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(status: "pending", name: "p")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(status: "active", name: "a")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(status: "archived", name: "z")))

    pending = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"status[$in]" => "pending,active", "$sort" => "name:1"})))
    pending.map { |r| r["status"] }.should eq(["active".as(Alumna::AnyData), "pending".as(Alumna::AnyData)])

    nin = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"status[$nin]" => "pending,active"})))
    nin.size.should eq(1)
    nin[0]["status"].should eq("archived")
  end

  it "finds by id ObjectId and matches nothing for invalid hex" do
    adapter = mongo_adapter("wave5_id")
    a = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
    b = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Bob"))))
    id_a = a["id"].as(String)
    id_b = b["id"].as(String)

    by_id = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"id" => id_a})))
    by_id.size.should eq(1)
    by_id[0]["name"].should eq("Ada")

    by_oid = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"_id" => id_a})))
    by_oid.size.should eq(1)

    as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"id" => "99"}))).should be_empty

    inn = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"id[$in]" => "#{id_a},99"})))
    inn.size.should eq(1)
    inn[0]["name"].should eq("Ada")

    ne = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"id[$ne]" => id_a})))
    ne.size.should eq(1)
    ne[0]["name"].should eq("Bob")

    nin = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"id[$nin]" => id_a})))
    nin.size.should eq(1)
    nin[0]["id"].should eq(id_b)
  end

  it "sorts mixed numbers together, and sorts array metadata by min element" do
    nums_adapter = mongo_adapter("wave5_num_sort")
    nums_adapter.create(ctx(nums_adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(score: 10_i64)))
    nums_adapter.create(ctx(nums_adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(score: 9.5_f64)))
    nums = as_list(nums_adapter.find(ctx(nums_adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "score:1"})))
    nums.map(&.["score"]).should eq([9.5_f64, 10_i64])

    adapter = mongo_adapter("wave5_meta_sort")
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(metadata: "10")))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(metadata: 2_i64)))
    adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(metadata: [1_i64].to_any)))
    rows = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find, params: {"$sort" => "metadata:1"})))
    # Native MongoDB compares arrays by min element, so [1] sorts as 1, before 2.
    # SQLite/MemoryAdapter type-weight order is [2, "10", [1]] (D32). Suite uses mixed_sort (D33).
    rows.map(&.["metadata"]).should eq([[1_i64] of Alumna::AnyData, 2_i64, "10"])
  end
end
