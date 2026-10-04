require "./support"

# One transaction on this fiber. Other fibers do not see the writes until commit.
# Returning a ServiceError aborts. Raising aborts and the exception continues.
# Do not `return` from inside the block: that leaves the method, and the adapter
# never sees the value. A replica set, mongos, or load balancer is required.

TxnSchema = Alumna::Schema.new
  .str("title")
  .float("price")

products = Alumna.mongo(Examples.client, Examples::DB, "products", TxnSchema)

committed = products.transaction do
  products.create(Examples.ctx(
    products,
    Alumna::ServiceMethod::Create,
    data: Alumna.hash(title: "Txn", price: 3.0),
  ))
end
row = Examples.must(committed, "commit")
raise "committed row missing" unless products.get(Examples.ctx(products, Alumna::ServiceMethod::Get, id: row["id"].as(String)))

aborted = products.transaction do
  products.create(Examples.ctx(
    products,
    Alumna::ServiceMethod::Create,
    data: Alumna.hash(title: "AbortMe", price: 3.0),
  ))
  Alumna::ServiceError.bad_request("stop")
end
raise "abort returns the ServiceError" unless aborted.is_a?(Alumna::ServiceError) && aborted.status == 400
left = products.find(Examples.ctx(products, Alumna::ServiceMethod::Find, params: {"title" => "AbortMe"}))
raise "aborted write is visible" unless left.is_a?(Array) && left.empty?

begin
  products.transaction do
    products.transaction { nil }
  end
  raise "nested transaction was allowed"
rescue ex : Alumna::MongoAdapter::TransactionError
  message = ex.message || ""
  raise message unless message.includes?("already running")
end

puts "transactions ok"
