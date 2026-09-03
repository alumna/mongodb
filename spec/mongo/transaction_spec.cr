require "../spec_helper"

private def txn_schema
  Alumna::Schema.new(strict: false)
    .str("name", required: false)
    .str("email", unique: true, required: false)
    .int("age", required: false)
end

describe "MongoAdapter transactions" do
  it "leaves ordinary CRUD unchanged when no transaction is open" do
    adapter = mongo_adapter("wave16_plain")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
    id = created["id"].as(String)
    as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))["name"].should eq("Ada")
  end

  it "raises a clear error on a standalone server" do
    pending!("this process uses a replica set") if replica_set_uri?
    adapter = mongo_adapter("wave16_standalone")
    expect_raises(Alumna::MongoAdapter::TransactionError, /replica set/) do
      adapter.transaction { 1 }
    end
  end

  it "does not put a URI password in the standalone transaction error" do
    pending!("this process uses a replica set") if replica_set_uri?
    adapter = mongo_adapter("wave16_standalone_msg")
    message = ""
    begin
      adapter.transaction { 1 }
    rescue ex : Alumna::MongoAdapter::TransactionError
      message = ex.message || ""
    end
    message.includes?("secret").should be_false
    message.includes?("replica set").should be_true
  end

  it "commits several CRUD calls in one transaction" do
    pending!("needs replicaSet= in MONGODB_URI") unless replica_set_uri?
    adapter = mongo_adapter("wave16_commit", txn_schema)
    id = ""
    adapter.transaction do
      created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada", age: 1_i64))))
      id = created["id"].as(String)
      as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))["name"].should eq("Ada")
      as_hash(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: id, data: Alumna.hash(name: "Bob"))))
      as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(age: 2_i64))))
      found = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find)))
      found.size.should eq(1)
      found[0]["name"].should eq("Bob")
      found[0]["age"].should eq(2_i64)
      found[0]
    end
    stored = as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id)))
    stored["name"].should eq("Bob")
    stored["age"].should eq(2_i64)
  end

  it "aborts and rolls back when the block raises" do
    pending!("needs replicaSet= in MONGODB_URI") unless replica_set_uri?
    adapter = mongo_adapter("wave16_abort_raise", txn_schema)
    expect_raises(Exception, "boom") do
      adapter.transaction do
        adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Temp")))
        raise "boom"
      end
    end
    as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find))).should be_empty
  end

  it "aborts when the block returns ServiceError" do
    pending!("needs replicaSet= in MONGODB_URI") unless replica_set_uri?
    adapter = mongo_adapter("wave16_abort_svc", txn_schema)
    adapter.create_indexes!
    as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "a@test.com"))))
    result = adapter.transaction do
      adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "b@test.com")))
      adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "a@test.com")))
    end
    err = as_error(result)
    err.status.should eq(422)
    emails = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find))).map { |row| row["email"] }
    emails.should eq(["a@test.com".as(Alumna::AnyData)])
  end

  it "commits remove inside the transaction" do
    pending!("needs replicaSet= in MONGODB_URI") unless replica_set_uri?
    adapter = mongo_adapter("wave16_remove", txn_schema)
    keep = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Keep"))))
    gone = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Gone"))))
    adapter.transaction do
      adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove, id: gone["id"].as(String)))
    end
    adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: gone["id"].as(String))).should be_nil
    as_hash(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: keep["id"].as(String))))["name"].should eq("Keep")
  end

  it "raises when #transaction is nested on the same fiber" do
    pending!("needs replicaSet= in MONGODB_URI") unless replica_set_uri?
    adapter = mongo_adapter("wave16_nested", txn_schema)
    nested = false
    adapter.transaction do
      expect_raises(Alumna::MongoAdapter::TransactionError, /already running/) do
        adapter.transaction { 1 }
      end
      nested = true
      as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "AfterNested"))))
    end
    nested.should be_true
    as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find))).size.should eq(1)
  end

  it "can start a new transaction after commit and after abort" do
    pending!("needs replicaSet= in MONGODB_URI") unless replica_set_uri?
    adapter = mongo_adapter("wave16_reuse", txn_schema)
    adapter.transaction do
      as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "One"))))
    end
    expect_raises(Exception, "again") do
      adapter.transaction do
        adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Nope")))
        raise "again"
      end
    end
    adapter.transaction do
      as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Two"))))
    end
    names = as_list(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find))).map { |row| row["name"].as(String) }
    names.sort.should eq(["One", "Two"])
  end
end
