require "./support"

# The block form calls #next until the cursor ends. A live stream does not end
# after one event, so this program polls with try_next.
# The collection has to exist first. resume_token is Bytes, not a String.
# A replica set, mongos, or load balancer is required.

WatchSchema = Alumna::Schema.new
  .str("title")
  .float("price")

products = Alumna.mongo(Examples.client, Examples::DB, "products", WatchSchema)
Examples.must(
  products.create(Examples.ctx(products, Alumna::ServiceMethod::Create, data: Alumna.hash(title: "Seed", price: 1.0))),
  "seed",
)

stream = products.watch(max_await_time_ms: 1000_i64, full_document: "updateLookup")
begin
  created = Examples.must(
    products.create(Examples.ctx(products, Alumna::ServiceMethod::Create, data: Alumna.hash(title: "Watch", price: 4.0))),
    "insert",
  )
  deadline = Time.utc + 8.seconds
  event = nil
  loop do
    event = stream.try_next
    break if event
    raise "no change event within 8s" if Time.utc >= deadline
  end
  raise "operation_type" unless event.not_nil!["operation_type"] == "insert"
  raise "document_id" unless event.not_nil!["document_id"] == created["id"]
  token = event.not_nil!["resume_token"].as(Bytes)

  later = products.watch(resume_after: token)
  later.close
ensure
  stream.close
end

puts "change_streams ok"
