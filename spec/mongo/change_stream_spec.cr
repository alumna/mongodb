require "../spec_helper"

private def seed_adapter(name : String) : Alumna::MongoAdapter
  adapter = mongo_adapter(name)
  as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "seed"))))
  adapter
end

# Poll `#try_next` until one event or *timeout*. Specs must not hang on `#next`.
private def wait_change(
  stream : Alumna::MongoAdapter::ChangeStream,
  timeout : Time::Span = 8.seconds,
) : Hash(String, Alumna::AnyData)
  deadline = Time.instant + timeout
  loop do
    if event = stream.try_next
      return event
    end
    raise "timed out waiting for a change event" if Time.instant >= deadline
  end
end

describe "MongoAdapter change streams" do
  it "raises a clear error on a standalone server" do
    pending!("this process uses a clustered topology") if clustered?
    adapter = mongo_adapter("wave17_standalone")
    expect_raises(Alumna::MongoAdapter::WatchError, /replica set/) do
      adapter.watch
    end
  end

  it "raises on standalone for the block form" do
    pending!("this process uses a clustered topology") if clustered?
    adapter = mongo_adapter("wave17_standalone_block")
    expect_raises(Alumna::MongoAdapter::WatchError, /replica set/) do
      adapter.watch { }
    end
  end

  it "does not put a URI password in the standalone watch error" do
    pending!("this process uses a clustered topology") if clustered?
    adapter = mongo_adapter("wave17_standalone_msg")
    message = ""
    begin
      adapter.watch
    rescue ex : Alumna::MongoAdapter::WatchError
      message = ex.message || ""
    end
    message.includes?("secret").should be_false
    message.includes?("replica set").should be_true
  end

  it "emits an insert event with mapped id and full document" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_insert")
    stream = adapter.watch(max_await_time_ms: 500_i64)
    begin
      created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
      id = created["id"].as(String)
      event = wait_change(stream)
      event["operation_type"].should eq("insert")
      event["document_id"].should eq(id)
      token = event["resume_token"]
      token.should be_a(Bytes)
      full = event["full_document"]
      full.should be_a(Hash(String, Alumna::AnyData))
      if full.is_a?(Hash(String, Alumna::AnyData))
        full["id"].should eq(id)
        full["name"].should eq("Ada")
        full.has_key?("_id").should be_false
      end
      ns = event["ns"]
      ns.should be_a(Hash(String, Alumna::AnyData))
      if ns.is_a?(Hash(String, Alumna::AnyData))
        ns["coll"].should eq("wave17_insert")
      end
    ensure
      stream.close
    end
  end

  it "emits an update event for patch" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_update")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
    id = created["id"].as(String)
    stream = adapter.watch(max_await_time_ms: 500_i64, full_document: "updateLookup")
    begin
      as_hash(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: id, data: Alumna.hash(name: "Bob"))))
      event = wait_change(stream)
      event["operation_type"].should eq("update")
      event["document_id"].should eq(id)
      full = event["full_document"]
      full.should be_a(Hash(String, Alumna::AnyData))
      if full.is_a?(Hash(String, Alumna::AnyData))
        full["name"].should eq("Bob")
      end
    ensure
      stream.close
    end
  end

  it "emits a delete event for remove" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_delete")
    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Gone"))))
    id = created["id"].as(String)
    stream = adapter.watch(max_await_time_ms: 500_i64)
    begin
      adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove, id: id))
      event = wait_change(stream)
      event["operation_type"].should eq("delete")
      event["document_id"].should eq(id)
      event.has_key?("full_document").should be_false
    ensure
      stream.close
    end
  end

  it "resumes after a token and skips the earlier event" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_resume")
    stream = adapter.watch(max_await_time_ms: 500_i64)
    token = Bytes.empty
    first_id = ""
    begin
      first = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "First"))))
      first_id = first["id"].as(String)
      event = wait_change(stream)
      event["document_id"].should eq(first_id)
      raw = event["resume_token"]
      raw.should be_a(Bytes)
      token = raw.as(Bytes)
      cursor_token = stream.resume_token
      cursor_token.should eq(token)
    ensure
      stream.close
    end

    resumed = adapter.watch(resume_after: token, max_await_time_ms: 500_i64)
    begin
      second = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Second"))))
      second_id = second["id"].as(String)
      event = wait_change(resumed)
      event["operation_type"].should eq("insert")
      event["document_id"].should eq(second_id)
      event["document_id"].should_not eq(first_id)
    ensure
      resumed.close
    end
  end

  it "try_next returns nil when idle" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_idle")
    stream = adapter.watch(max_await_time_ms: 200_i64)
    begin
      stream.try_next.should be_nil
    ensure
      stream.close
    end
  end

  it "rejects a bad resume token with WatchError" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_bad_token")
    expect_raises(Alumna::MongoAdapter::WatchError) do
      adapter.watch(resume_after: Bytes.new(1, 0_u8))
    end
  end

  it "close is safe to call twice" do
    pending!("needs a clustered topology") unless clustered?
    adapter = seed_adapter("wave17_close")
    stream = adapter.watch(max_await_time_ms: 200_i64)
    stream.close
    stream.close
  end
end
