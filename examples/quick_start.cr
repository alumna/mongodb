require "./support"

# The service methods, called the way a script calls them.
# HTTP builds this context for you. Alumna::Testing.build_ctx is the same object.

ProductSchema = Alumna::Schema.new
  .str("title", min_length: 2)
  .float("price")
  .bool("is_published", required: false)
  .array("tags", of: :str, required: false)
  .hash("user", required: false) do |user|
    user.str("name")
    user.int("age")
  end

products = Alumna.mongo(Examples.client, Examples::DB, "products", ProductSchema)
products.create_indexes!

created = products.create(Examples.ctx(
  products,
  Alumna::ServiceMethod::Create,
  data: Alumna.hash(
    title: "Laptop",
    price: 999.0,
    is_published: true,
    tags: ["tech"].to_any,
    user: Alumna.hash(name: "Ada", age: 36),
  ),
))
raise created.message if created.is_a?(Alumna::ServiceError)
id = created["id"].as(String)
raise "id is 24 hex" unless id.bytesize == 24

got = Examples.must(
  products.get(Examples.ctx(products, Alumna::ServiceMethod::Get, id: id)),
  "get",
)
raise "title" unless got["title"] == "Laptop"
raise "_id is not stored under that name" if got.has_key?("_id")

# "$unset" and "user.name" are not Crystal named arguments.
patch = Alumna.hash(price: 10.0)
patch["$unset"] = ["user.age"] of Alumna::AnyData
cleared = Examples.must(
  products.patch(Examples.ctx(products, Alumna::ServiceMethod::Patch, id: id, data: patch)),
  "patch",
)
raise "age removed" if cleared["user"].as(Hash).has_key?("age")

dotted = {} of String => Alumna::AnyData
dotted["user.name"] = "Grace"
renamed = Examples.must(
  products.patch(Examples.ctx(products, Alumna::ServiceMethod::Patch, id: id, data: dotted)),
  "dotted patch",
)
raise "dotted key stored as a field name" if renamed.has_key?("user.name")
raise "nested name" unless renamed["user"].as(Hash)["name"] == "Grace"

products.remove(Examples.ctx(products, Alumna::ServiceMethod::Remove, id: id))
raise "still present" unless products.get(Examples.ctx(products, Alumna::ServiceMethod::Get, id: id)).nil?

# No encryption client was opened, so close does not close the process client.
products.close
Examples.must(
  products.create(Examples.ctx(products, Alumna::ServiceMethod::Create, data: Alumna.hash(title: "Still", price: 1.0))),
  "after close",
)

puts "quick_start ok id=#{id}"
