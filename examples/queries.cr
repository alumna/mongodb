require "./support"

# find reads ctx.query. From Crystal the keys are the query-string keys.
# max_limit: 2 clamps a client $limit. It does not add a page size when $limit is absent.

QuerySchema = Alumna::Schema.new
  .str("title")
  .float("price")
  .bool("is_published", required: false)
  .array("tags", of: :str, required: false)
  .hash("user", required: false) { |user| user.str("name") }

products = Alumna.mongo(Examples.client, Examples::DB, "products", QuerySchema, max_limit: 2)

[
  Alumna.hash(title: "Laptop", price: 999.0, is_published: true, tags: ["tech"].to_any, user: Alumna.hash(name: "Ada")),
  Alumna.hash(title: "Mouse", price: 25.0, is_published: true, tags: ["tech"].to_any, user: Alumna.hash(name: "Grace")),
  Alumna.hash(title: "Keyboard", price: 80.0, is_published: false, tags: ["desk"].to_any, user: Alumna.hash(name: "Ada")),
].each do |data|
  Examples.must(products.create(Examples.ctx(products, Alumna::ServiceMethod::Create, data: data)), "seed")
end

def find(products, params)
  result = products.find(Examples.ctx(products, Alumna::ServiceMethod::Find, params: params))
  raise result.message if result.is_a?(Alumna::ServiceError)
  result.as(Array(Hash(String, Alumna::AnyData)))
end

expensive = find(products, {"price[$gt]" => "50"})
raise "$gt" unless expensive.size == 2

listed = find(products, {"title[$in]" => "Laptop,Mouse"})
raise "$in" unless listed.size == 2

ada = find(products, {"user.name" => "Ada"})
raise "nested" unless ada.size == 2

tagged = find(products, {"tags" => "tech"})
raise "array element" unless tagged.size == 2

page = find(products, {
  "$sort"   => "price:-1",
  "$limit"  => "10",
  "$select" => "id,title,price",
})
raise "max_limit clamps $limit 10 down to 2" unless page.size == 2
raise "descending price" unless page[0]["price"].as(Float64) > page[1]["price"].as(Float64)
raise "$select dropped title" unless page[0].has_key?("title")
raise "$select kept tags" if page[0].has_key?("tags")

unknown = products.find(Examples.ctx(products, Alumna::ServiceMethod::Find, params: {"nope" => "x"}))
raise "unknown field is 400" unless unknown.is_a?(Alumna::ServiceError) && unknown.status == 400

none = find(products, {"id" => "not-an-object-id"})
raise "bad id matches nothing" unless none.empty?

puts "queries ok"
